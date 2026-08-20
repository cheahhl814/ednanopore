// classify_reads.nf
//
// Variant B classify stage for nf-edna-nanopore — mirrors ONT's wf-16s
// read-classification mode (see docs/superpowers/specs/2026-08-19-...md §2).
//
// Per-read classification of QC'd ONT reads; no clustering step upstream;
// no ASV/feature table — abundance is just read counts per taxon per sample.
//
// Two classifier modes (idtaxa is intentionally omitted — it needs polished
// consensus, not raw noisy reads; see research note):
//
//   "minimap2"  (default): minimap2 + LCA against a 16S reference MMI.
//   "kraken2"             : Kraken2 k-mer classification.
//
// Both modes emit the same channel shape:
//   path taxon_abundance_table   (TSV: Taxon + lineage cols + count col per sample)
//   path confidence_table         (TSV: per-read lineage confidence, for filter reuse)
// This is what downstream alpha_diversity.R / beta_diversity.R /
// differential_abundance.R / correlation_analysis.R expect for non-phylogenetic
// diversity metrics (the spec documents UniFrac/phylogenetic metrics as
// unsupported in Variant B).

process classify_reads_minimap2_lca {
    tag "minimap2-LCA per-read classification"
    publishDir "${params.results_dir}/${params.run_id}/taxonomy", mode: 'copy', overwrite: false

    input:
    tuple val(sample_id), path(reads_fq)
    path ref_mmi
    path tax_lookup

    output:
    tuple val(sample_id), path("${sample_id}.minimap2_lca_classification.tsv"), emit: per_sample_class
    tuple val(sample_id), path("${sample_id}.minimap2_lca_confidence.tsv"),    emit: per_sample_conf

    script:
    """
    pixi run --manifest-path ${baseDir}/runners/nextflow-runner/env/classification/pixi.toml \
        python ${baseDir}/runners/nextflow-runner/bin/minimap2_lca.py \
        --query_fasta ${reads_fq} \
        --ref_mmi ${ref_mmi} \
        --tax_lookup ${tax_lookup} \
        --min_percent_identity ${params.minimap2_min_pct_identity} \
        --min_ref_coverage ${params.minimap2_min_ref_coverage} \
        --output_classification ${sample_id}.minimap2_lca_classification.tsv \
        --output_confidence ${sample_id}.minimap2_lca_confidence.tsv
    """
}

process classify_reads_kraken2 {
    tag "Kraken2 per-read classification ${sample_id}"
    publishDir "${params.results_dir}/${params.run_id}/taxonomy", mode: 'copy', overwrite: false

    input:
    tuple val(sample_id), path(reads_fq)
    path kraken2_db

    output:
    tuple val(sample_id), path("${sample_id}.kraken2_classification.tsv"), emit: per_sample_class
    tuple val(sample_id), path("${sample_id}.kraken2_confidence.tsv"),    emit: per_sample_conf

    script:
    """
    set -euo pipefail

    pixi run --manifest-path ${baseDir}/runners/nextflow-runner/env/classification/pixi.toml \
        kraken2 --db ${kraken2_db} --threads ${task.cpus} \
        --report ${sample_id}.kraken2.report.txt \
        --output ${sample_id}.kraken2.raw.tsv \
        ${reads_fq}

    pixi run --manifest-path ${baseDir}/runners/nextflow-runner/env/classification/pixi.toml \
        kraken2_inspect --db ${kraken2_db} > kraken2_inspect.tsv

    # Inline Python reshape (same pattern as classify_consensus.nf). Per
    # design spec: conversion logic lives in this module, not bin/.
    cat <<'PY' | sed 's/^    //' > _kraken2_reshape.py
    import csv, sys
    RANK_COLUMNS = ["superkingdom", "phylum", "class", "order", "family", "genus", "species"]
    SAMPLE = "${sample_id}"

    parent_map, rank_map, name_map = {}, {}, {}
    with open("kraken2_inspect.tsv", newline="") as fh:
        for row in csv.reader(fh, delimiter="\t"):
            if len(row) < 6:
                continue
            tid = row[4].strip()
            parent_map[tid] = row[2].strip()
            rank_map[tid]   = row[3].strip().lower()
            name_map[tid]   = row[5].strip()

    def resolve_lineage(taxid):
        chain = []
        seen = set()
        cur = taxid
        while cur and cur != "1" and cur not in seen:
            seen.add(cur)
            if cur in rank_map:
                chain.append((rank_map[cur], name_map[cur]))
            cur = parent_map.get(cur, "")
        chain.reverse()
        out = {r: "" for r in RANK_COLUMNS}
        for rank, name in chain:
            if rank in ("domain", "superkingdom"):
                out["superkingdom"] = name
            elif rank in RANK_COLUMNS and not out.get(rank):
                out[rank] = name
        return out

    with open(f"{SAMPLE}.kraken2.raw.tsv", newline="") as raw_fh:
        raw_reader = csv.reader(raw_fh, delimiter="\t")
        with open(f"{SAMPLE}.kraken2_classification.tsv", "w", newline="") as cls_fh:
            cls_writer = csv.writer(cls_fh, delimiter="\t")
            cls_writer.writerow(["SequenceID"] + RANK_COLUMNS + ["confidence"])
            with open(f"{SAMPLE}.kraken2_confidence.tsv", "w", newline="") as conf_fh:
                conf_writer = csv.writer(conf_fh, delimiter="\t")
                conf_writer.writerow(["SequenceID"] + RANK_COLUMNS)
                for row in raw_reader:
                    if len(row) < 3:
                        continue
                    read_id = row[0].strip()
                    taxid   = row[1].strip()
                    is_classified = taxid != "0"
                    rank_dict = resolve_lineage(taxid) if is_classified else {r: "" for r in RANK_COLUMNS}
                    conf = 1.0 if is_classified else 0.0
                    cls_writer.writerow([read_id] + [rank_dict[r] for r in RANK_COLUMNS] + [f"{conf:.4f}"])
                    row_out = [read_id]
                    for rc in RANK_COLUMNS:
                        row_out.append(f"{conf:.4f}" if rank_dict[rc] else "NA")
                    conf_writer.writerow(row_out)
PY

    pixi run --manifest-path ${baseDir}/runners/nextflow-runner/env/classification/pixi.toml \
        python _kraken2_reshape.py
    """
}

process aggregate_taxon_abundance {
    tag "Aggregate per-read classifications to taxon abundance table"
    publishDir "${params.results_dir}/${params.run_id}/asv_table", mode: 'copy', overwrite: false

    // Aggregate per-sample per-read classifications into a single
    // taxon-by-sample abundance table. Inline awk/python — small enough
    // that a separate bin script would be overkill.
    //
    // Output shape: TSV with header
    //     <rank_col_1> <rank_col_2> ... <rank_col_N> <sample_1> <sample_2> ...
    // and one row per unique lineage observed in any sample.
    //
    // Reads with the same lineage are summed per sample; unclassified
    // reads (all rank columns empty) are aggregated into a synthetic
    // '__unclassified__' lineage so the row is visible in the table.
    //
    // This shape is consumed directly by alpha_diversity.R / beta_diversity.R
    // / differential_abundance.R / correlation_analysis.R — no further
    // reshaping needed for Variant B's non-phylogenetic metrics.

    input:
    path per_sample_classifications   // collection of per-sample classification TSVs
    val  sample_ids                   // matching list of sample IDs (Nextflow collects the val parts)

    output:
    path "taxon_abundance_table.tsv", emit: table

    script:
    """
    set -euo pipefail

    # Aggregate per-sample per-read classifications into a single
    # taxon-by-sample abundance table. Same heredoc-then-sed pattern as
    # above so the Python body is independent of the .nf indentation.
    cat <<'PY' | sed 's/^    //' > _aggregate_taxon.py
    import csv, glob, os, sys
    from collections import OrderedDict

    RANK_COLUMNS = ["superkingdom", "phylum", "class", "order", "family", "genus", "species"]

    sample_ids = "${sample_ids}".split()

    # Per-sample classification files were emitted by classify_reads_*.nf
    # with prefix = sample_id. We pick up whichever classifier produced
    # outputs (one TSV per sample, matching its sample_id prefix).
    files = sorted(glob.glob("*.minimap2_lca_classification.tsv") + glob.glob("*.kraken2_classification.tsv"))
    sample_to_file = {}
    for f in files:
        sid = os.path.basename(f).split(".", 1)[0]
        sample_to_file[sid] = f
    files_in_order = [sample_to_file[s] for s in sample_ids if s in sample_to_file]

    # Collect per-sample per-lineage counts.
    table = OrderedDict()  # lineage_tuple -> {sample -> count}
    for sample, path in zip(sample_ids, files_in_order):
        with open(path, newline="") as fh:
            reader = csv.DictReader(fh, delimiter="\t")
            for row in reader:
                lineage = tuple(row.get(r, "") for r in RANK_COLUMNS)
                if not any(lineage):
                    lineage = ("__unclassified__",) * len(RANK_COLUMNS)
                table.setdefault(lineage, {}).setdefault(sample, 0)
                table[lineage][sample] += 1

    # Emit header + rows in deterministic order.
    writer = csv.writer(sys.stdout, delimiter="\t")
    writer.writerow(RANK_COLUMNS + list(sample_ids))
    for lineage in table:
        counts = [table[lineage].get(s, 0) for s in sample_ids]
        writer.writerow(list(lineage) + counts)
PY

    pixi run --manifest-path ${baseDir}/runners/nextflow-runner/env/classification/pixi.toml \
        python _aggregate_taxon.py > taxon_abundance_table.tsv
    """
}

workflow CLASSIFY_READS {
    take:
    reads           // tuple(sample_id, reads_fq) from qc.nf (Chopper/cutadapt output)
    ref_mmi         // path: 16S reference MMI (minimap2 mode)
    tax_lookup      // path: accession -> lineage TSV (minimap2 mode)
    kraken2_db      // path: Kraken2 16S DB directory (kraken2 mode)

    main:
    if (params.classifier == 'kraken2') {
        classify_reads_kraken2(reads, kraken2_db)
        per_sample_class = classify_reads_kraken2.out.per_sample_class
        per_sample_conf   = classify_reads_kraken2.out.per_sample_conf
    } else {
        // default: minimap2-LCA
        classify_reads_minimap2_lca(reads, ref_mmi, tax_lookup)
        per_sample_class = classify_reads_minimap2_lca.out.per_sample_class
        per_sample_conf   = classify_reads_minimap2_lca.out.per_sample_conf
    }

    // Collect sample IDs (val parts) alongside the classification paths.
    sample_ids_ch = per_sample_class.map { sid, f -> sid }.collect()
    aggregate_taxon_abundance(
        per_sample_class.map { sid, f -> f }.collect(),
        sample_ids_ch
    )

    emit:
    taxon_abundance_table = aggregate_taxon_abundance.out.table
    per_sample_confidence = per_sample_conf
}