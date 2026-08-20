// classify_consensus.nf
//
// Variant A classify stage for nf-edna-nanopore.
//
// Takes polished consensus sequences produced by cluster_consensus.nf and
// assigns a lineage via one of three classifiers, selectable at run time
// via params.classifier:
//
//   "minimap2"  (default): minimap2 + LCA against a 16S reference MMI
//                            (mirrors ONT's wf-16s default; see
//                            docs/superpowers/specs/2026-08-19-...md §1).
//   "kraken2"             : Kraken2 k-mer classification against a
//                            16S k-mer DB. Kraken2's native output is
//                            reshaped inline into the same
//                            {superkingdom..species} rank column shape.
//   "idtaxa"              : Opt-in reuse of nf-edna's DECIPHER::IdTaxa
//                            pipeline (bin/idtaxa_rds.R byte-for-byte
//                            copy). IdTaxa's bootstrap confidence
//                            degrades on ONT reads (research note in
//                            scratch-nanopore-16s-tools-2.md), so this is
//                            NOT the default. Kept for users who need
//                            phylogenetically placed trees and accept
//                            genus-level resolution.
//
// All three modes emit the same channel shape:
//   tuple path(taxonomy_table), path(confidence_tsv)
// so the downstream nf-edna stages (filter_idtaxa_by_confidence.jl,
// agglomerate_data.R, diversity, association) keep working unmodified.

process classification_minimap2_lca {
    tag "minimap2-LCA classification"
    publishDir "${params.results_dir}/${params.run_id}/taxonomy", mode: 'copy', overwrite: false

    input:
    path rep_seqs_fna
    path ref_mmi
    path tax_lookup

    output:
    path "minimap2_lca_classification.tsv", emit: taxonomy_table
    path "minimap2_lca_confidence.tsv",    emit: confidence

    script:
    """
    pixi run --manifest-path ${baseDir}/runners/nextflow-runner/env/classification/pixi.toml \\
        python ${baseDir}/runners/nextflow-runner/bin/minimap2_lca.py \\
        --query_fasta ${rep_seqs_fna} \\
        --ref_mmi ${ref_mmi} \\
        --tax_lookup ${tax_lookup} \\
        --min_percent_identity ${params.minimap2_min_pct_identity} \\
        --min_ref_coverage ${params.minimap2_min_ref_coverage} \\
        --output_classification minimap2_lca_classification.tsv \\
        --output_confidence minimap2_lca_confidence.tsv
    """
}

process classification_kraken2 {
    tag "Kraken2 classification"
    publishDir "${params.results_dir}/${params.run_id}/taxonomy", mode: 'copy', overwrite: false

    input:
    path rep_seqs_fna
    path kraken2_db

    output:
    path "kraken2_classification.tsv", emit: taxonomy_table
    path "kraken2_confidence.tsv",    emit: confidence

    // Kraken2's per-read output (--output) is `read_id<TAB>taxon_id<TAB>hit_length`,
    // and `kraken2_inspect` dumps the taxonomy tree. We reshape both into the
    // same {SequenceID + superkingdom..species + confidence} shape that
    // minimap2_lca emits, so downstream stages are classifier-agnostic.
    //
    // The reshape is implemented inline (per design spec) as a heredoc with
    // the python body at column 0 so Python's indentation rules are satisfied.
    script:
    """
    set -euo pipefail

    pixi run --manifest-path ${baseDir}/runners/nextflow-runner/env/classification/pixi.toml \\
        kraken2 --db ${kraken2_db} --threads ${task.cpus} \\
        --report kraken2.report.txt --output kraken2.raw.tsv \\
        ${rep_seqs_fna}

    pixi run --manifest-path ${baseDir}/runners/nextflow-runner/env/classification/pixi.toml \\
        kraken2_inspect --db ${kraken2_db} > kraken2_inspect.tsv

    # Inline Python reshape: write the script body to a temp file (via
    # heredoc + sed to strip the indentation the .nf block would add),
    # then execute it. This keeps the conversion logic in this module
    # (per design spec) without exposing it as a separate bin/ script.
    cat <<'PY' | sed 's/^    //' > _kraken2_reshape.py
    import csv, sys
    RANK_COLUMNS = ["superkingdom", "phylum", "class", "order", "family", "genus", "species"]

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

    with open("kraken2.raw.tsv", newline="") as raw_fh:
        raw_reader = csv.reader(raw_fh, delimiter="\t")
        with open("kraken2_classification.tsv", "w", newline="") as cls_fh:
            cls_writer = csv.writer(cls_fh, delimiter="\t")
            cls_writer.writerow(["SequenceID"] + RANK_COLUMNS + ["confidence"])
            with open("kraken2_confidence.tsv", "w", newline="") as conf_fh:
                conf_writer = csv.writer(conf_fh, delimiter="\t")
                conf_writer.writerow(["SequenceID"] + RANK_COLUMNS)
                for row in raw_reader:
                    if len(row) < 3:
                        continue
                    read_id = row[0].strip()
                    taxid   = row[1].strip()
                    is_classified = taxid != "0"
                    rank_dict = resolve_lineage(taxid) if is_classified else {r: "" for r in RANK_COLUMNS}
                    # Kraken2 has no per-read confidence; use 1.0 if classified
                    # else 0.0 so filter_idtaxa_by_confidence.jl can be reused
                    # with --threshold 1.0 to drop unclassified reads.
                    conf = 1.0 if is_classified else 0.0
                    cls_writer.writerow([read_id] + [rank_dict[r] for r in RANK_COLUMNS] + [f"{conf:.4f}"])
                    row_out = [read_id]
                    for rc in RANK_COLUMNS:
                        if rank_dict[rc]:
                            row_out.append(f"{conf:.4f}")
                        else:
                            row_out.append("NA")
                    conf_writer.writerow(row_out)

    print("[kraken2 reshape] wrote kraken2_classification.tsv and kraken2_confidence.tsv", file=sys.stderr)
PY

    pixi run --manifest-path ${baseDir}/runners/nextflow-runner/env/classification/pixi.toml \
        python _kraken2_reshape.py
    """
}

process classification_idtaxa {
    tag "IDTAXA classification (opt-in)"
    publishDir "${params.results_dir}/${params.run_id}/taxonomy", mode: 'copy', overwrite: false

    input:
    path rep_seqs_fna
    path idtaxa_model

    output:
    path "idtaxa_classification.tsv"
    path "idtaxa_classification_confident.tsv", emit: taxonomy_table
    path "idtaxa_confidence.tsv",               emit: confidence

    // This process is a thin re-call of nf-edna's idtaxa classify stage.
    // The bin/idtaxa_rds.R script is a byte-for-byte copy from
    // skills/nf-edna/runners/nextflow-runner/bin/ (md5 verified at
    // build time). Output file names match so downstream filter /
    // agglomerate / diversity / association stages are classifier-agnostic.
    script:
    """
    pixi run --manifest-path ${baseDir}/runners/nextflow-runner/env/classification/pixi.toml \\
        Rscript ${baseDir}/runners/nextflow-runner/bin/idtaxa_rds.R \\
        --query_sequences ${rep_seqs_fna} --idtaxa_model ${idtaxa_model} \\
        --output_classification idtaxa_classification.tsv \\
        --output_confidence idtaxa_confidence.tsv

    pixi run --manifest-path ${baseDir}/runners/nextflow-runner/env/decontam/pixi.toml \\
        julia ${baseDir}/runners/nextflow-runner/bin/filter_idtaxa_by_confidence.jl \\
        --classification_file idtaxa_classification.tsv \\
        --confidence_file idtaxa_confidence.tsv \\
        --output_file idtaxa_classification_confident.tsv \\
        --threshold ${params.idtaxa_threshold}
    """
}

process agglomerate {
    tag "Agglomerate by taxonomy"
    publishDir "${params.results_dir}/${params.run_id}/taxonomy", mode: 'copy', overwrite: false

    // Copied verbatim from nf-edna's classify.nf `agglomerate` process
    // (bin/agglomerate_data.R is a byte-for-byte copy). Missing from the
    // first draft of this file — CLASSIFY_CONSENSUS called agglomerate()
    // without a matching process definition, which would fail to compile.
    input:
    path asv_counts
    path taxonomy_table
    path metadata
    path asv_fasta

    output:
    path "agglomerated_data/asv_counts.tsv",      emit: asv_counts
    path "agglomerated_data/asv_taxonomy.tsv",    emit: asv_taxonomy
    path "agglomerated_data/genus_counts.tsv",    emit: genus_counts
    path "agglomerated_data/genus_taxonomy.tsv"
    path "agglomerated_data/phylum_counts.tsv",   optional: true
    path "agglomerated_data/phylum_taxonomy.tsv", optional: true
    path "agglomerated_data/class_counts.tsv",    optional: true
    path "agglomerated_data/class_taxonomy.tsv",  optional: true
    path "agglomerated_data/family_counts.tsv",   optional: true
    path "agglomerated_data/family_taxonomy.tsv", optional: true
    path "agglomerated_data/species_counts.tsv",  optional: true
    path "agglomerated_data/species_taxonomy.tsv", optional: true
    path "filtered_asvs.fna",                     emit: filtered_fasta

    script:
    """
    pixi run --manifest-path ${baseDir}/runners/nextflow-runner/env/classification/pixi.toml \
        Rscript ${baseDir}/runners/nextflow-runner/bin/agglomerate_data.R \
        --asv_counts_file ${asv_counts} --taxonomy_file ${taxonomy_table} \
        --metadata_file ${metadata} --output_dir agglomerated_data \
        --kingdoms ${params.kingdoms} --ranks ${params.target_ranks}

    tail -n +2 agglomerated_data/asv_counts.tsv | awk '{print \$1}' > asv_ids_to_keep.txt
    sed 's/;size=[0-9]*//' ${asv_fasta} > rep_seqs_clean.fna
    pixi run --manifest-path ${baseDir}/runners/nextflow-runner/env/classification/pixi.toml \
        seqtk subseq rep_seqs_clean.fna asv_ids_to_keep.txt > filtered_asvs.fna
    """
}

process filter_confidence {
    // Shared confidence filter for the minimap2/kraken2 branches, so all
    // three classifier modes go through the same confidence-gating step
    // before agglomerate — the idtaxa branch already does this internally
    // (classification_idtaxa emits the already-filtered
    // idtaxa_classification_confident.tsv as its taxonomy_table).
    tag "Confidence filter (${classifier_tag})"
    publishDir "${params.results_dir}/${params.run_id}/taxonomy", mode: 'copy', overwrite: false

    input:
    tuple val(classifier_tag), path(classification_file), path(confidence_file)

    output:
    path "${classifier_tag}_classification_confident.tsv", emit: taxonomy_table

    script:
    """
    pixi run --manifest-path ${baseDir}/runners/nextflow-runner/env/decontam/pixi.toml \
        julia ${baseDir}/runners/nextflow-runner/bin/filter_idtaxa_by_confidence.jl \
        --classification_file ${classification_file} \
        --confidence_file ${confidence_file} \
        --output_file ${classifier_tag}_classification_confident.tsv \
        --threshold ${params.idtaxa_threshold}
    """
}

workflow CLASSIFY_CONSENSUS {
    take:
    rep_seqs        // path: polished consensus fasta from cluster_consensus.nf
    asv_counts      // path: feature-table TSV (per-cluster read counts per sample)
    ref_mmi         // path: 16S reference MMI (minimap2 mode)
    tax_lookup      // path: accession -> lineage TSV (minimap2 mode)
    kraken2_db      // path: Kraken2 16S DB directory (kraken2 mode)
    idtaxa_model    // path: DECIPHER IdTaxa trainingSet RDS (idtaxa mode)
    metadata        // path: sample metadata TSV (passed through to agglomerate)

    main:
    if (params.classifier == 'kraken2') {
        classification_kraken2(rep_seqs, kraken2_db)
        confidence = classification_kraken2.out.confidence
        filter_confidence(
            classification_kraken2.out.taxonomy_table
                .combine(confidence)
                .map { cls, conf -> tuple('kraken2', cls, conf) }
        )
        taxonomy_table = filter_confidence.out.taxonomy_table
    } else if (params.classifier == 'idtaxa') {
        // classification_idtaxa already emits the confidence-filtered table
        classification_idtaxa(rep_seqs, idtaxa_model)
        taxonomy_table = classification_idtaxa.out.taxonomy_table
        confidence     = classification_idtaxa.out.confidence
    } else {
        // default: minimap2-LCA (mirrors wf-16s default)
        classification_minimap2_lca(rep_seqs, ref_mmi, tax_lookup)
        confidence = classification_minimap2_lca.out.confidence
        filter_confidence(
            classification_minimap2_lca.out.taxonomy_table
                .combine(confidence)
                .map { cls, conf -> tuple('minimap2_lca', cls, conf) }
        )
        taxonomy_table = filter_confidence.out.taxonomy_table
    }

    // Agglomerate downstream (Variant A). nf-edna's agglomerate_data.R
    // is invoked via the classification/pixi env (same pixi env has the
    // mia/data.table deps agglomerate_data.R needs). asv_counts comes from
    // the cluster_consensus.nf stage upstream.
    agglomerate(
        asv_counts,
        taxonomy_table,
        metadata,
        rep_seqs
    )

    emit:
    taxonomy_table   // path: classifier's *_classification.tsv
    confidence       // path: matching confidence.tsv
    asv_counts       = agglomerate.out.asv_counts
    asv_taxonomy     = agglomerate.out.asv_taxonomy
    filtered_fasta   = agglomerate.out.filtered_fasta
}