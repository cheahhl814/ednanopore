// Cross-sample merge + decontam + filter, run between CLUSTER_CONSENSUS
// (per-sample clustering/polishing) and CLASSIFY_CONSENSUS (classify +
// agglomerate). Copied verbatim from nf-edna's denoise.nf (biom2tsv,
// merge_denoise, decontam, filter_table processes) — this logic is
// platform-agnostic (it operates on a biom/fasta pair per sample and a
// metadata table), so it applies unchanged to Variant A's ONT consensus
// output. See docs/superpowers/specs/2026-08-19-nf-edna-nanopore-design.md

process biom2tsv {
    tag "BIOM to TSV ${sample_id}"

    input:
    tuple val(sample_id), path(biom)

    output:
    tuple val(sample_id), path("${sample_id}.table.tsv"), emit: table_tsv

    script:
    """
    pixi run --manifest-path ${baseDir}/runners/nextflow-runner/env/cluster/pixi.toml \
        biom convert -i ${biom} -o ${sample_id}.table.tsv --to-tsv \
    || printf '# Constructed from biom file\n#OTU ID\t${sample_id}\n' \
        > ${sample_id}.table.tsv
    """
}

process merge_denoise {
    tag "Merge clustered outputs"
    publishDir "${params.results_dir}/${params.run_id}/asv_table", mode: 'copy', overwrite: false

    input:
    path tables
    path fastas

    output:
    path "feature-table_renamed.tsv", emit: merged_table
    path "rep-seqs_renamed.fna",      emit: merged_fasta

    script:
    """
    pixi run --manifest-path ${baseDir}/runners/nextflow-runner/env/cluster/pixi.toml \
        Rscript ${baseDir}/runners/nextflow-runner/bin/merge_tables.R \
        --input_files ${tables} --output_table feature-table.tsv

    cat ${fastas} > rep-seqs.fna
    awk 'BEGIN{FS=OFS="\\t"} {gsub(/:/,"_",\$1); print}' feature-table.tsv > feature-table_renamed.tsv
    sed '/^>/s/:/_/g' rep-seqs.fna > rep-seqs_renamed.fna
    """
}

process decontam {
    tag "Decontaminate ASV table"
    publishDir "${params.results_dir}/${params.run_id}/asv_table", mode: 'copy', overwrite: false

    input:
    path asv_table
    path rep_seqs
    path metadata

    output:
    path "decontam_asv_table.tsv", emit: table
    path "decontam_rep_seqs.fna",  emit: fasta
    path "decontam_summary.tsv",   emit: summary

    script:
    """
    pixi run --manifest-path ${baseDir}/runners/nextflow-runner/env/decontam/pixi.toml \
        julia ${baseDir}/runners/nextflow-runner/bin/decontam.jl \
        --feature_table ${asv_table} \
        --metadata ${metadata} \
        --rep_seqs ${rep_seqs} \
        --output_cleaned_table decontam_asv_table.tsv \
        --output_cleaned_rep_seqs decontam_rep_seqs.fna \
        --output_contaminants_summary decontam_summary.tsv \
        --threshold ${params.decontam_threshold} \
        --neg_control_column ${params.neg_col}
    """
}

process filter_table {
    tag "Filter negative controls from ASV table"
    publishDir "${params.results_dir}/${params.run_id}/asv_table", mode: 'copy', overwrite: false

    input:
    path asv_table
    path rep_seqs
    path metadata

    output:
    path "filtered_asv_table.tsv", emit: table
    path "filtered_rep_seqs.fna",  emit: fasta

    script:
    """
    pixi run --manifest-path ${baseDir}/runners/nextflow-runner/env/decontam/pixi.toml \
        julia ${baseDir}/runners/nextflow-runner/bin/filter_table.jl \
        --feature_table ${asv_table} \
        --rep_seqs ${rep_seqs} \
        --metadata ${metadata} \
        --filter_condition "${params.filter_condition}" \
        --output_table filtered_asv_table.tsv \
        --output_rep_seqs filtered_rep_seqs.fna
    """
}

workflow MERGE_DECONTAM {
    take:
    fasta     // tuple(sample_id, sequences.fasta) from CLUSTER_CONSENSUS
    biom      // tuple(sample_id, table.biom) from CLUSTER_CONSENSUS
    metadata  // path

    main:
    biom2tsv(biom)

    merge_denoise(
        biom2tsv.out.table_tsv.map { sid, f -> f }.collect(),
        fasta.map { sid, f -> f }.collect()
    )

    decontam(
        merge_denoise.out.merged_table,
        merge_denoise.out.merged_fasta,
        metadata
    )

    filter_table(
        decontam.out.table,
        decontam.out.fasta,
        metadata
    )

    emit:
    table = filter_table.out.table
    fasta = filter_table.out.fasta
}
