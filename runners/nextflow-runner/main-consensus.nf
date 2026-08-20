#!/usr/bin/env nextflow
nextflow.enable.dsl=2

// Variant A — cluster + medaka-polish ONT reads into ASV-like consensus
// sequences, classify, then reuse nf-edna's decontam/diversity/association
// stages unmodified. See docs/superpowers/specs/2026-08-19-nf-edna-nanopore-design.md

include { QC }                 from './modules/qc.nf'
include { CLUSTER_CONSENSUS }  from './modules/cluster_consensus.nf'
include { MERGE_DECONTAM }     from './modules/merge_decontam.nf'
include { CLASSIFY_CONSENSUS } from './modules/classify_consensus.nf'
include { DIVERSITY }          from './modules/diversity.nf'
include { ASSOCIATION }        from './modules/association.nf'

// ── Input helpers ────────────────────────────────────────────────────────────
// ONT is single-read (no R1/R2 to merge) — always single_end=true, unlike
// nf-edna's main.nf which branches on manifest column count for PE support.

def createInputChannel(manifest_path) {
    def manifest_file = file(manifest_path)
    if (!manifest_file.exists()) error "Manifest not found: ${manifest_path}"

    def lines = manifest_file.readLines()
    log.info "Manifest: ${manifest_path} | Type: SE (ONT) | Samples: ${lines.size() - 1}"

    return channel.fromPath(manifest_path).splitCsv(header: true)
        .map { row ->
            def f = file(row.'absolute-filepath')
            if (!f.exists()) error "File not found: ${f}"
            tuple(row.'sample-id', f, true)
        }
}

// ── State writer ─────────────────────────────────────────────────────────────

process WRITE_STATE {
    publishDir "${params.results_dir}/${params.run_id}", mode: 'copy', overwrite: true

    input:
    val stages
    val last_stage

    output:
    path "pipeline_state.json"

    exec:
    def stageList = stages
    def outputs = [:]
    if ('qc' in stageList)
        outputs.trimmed_reads = "${params.results_dir}/${params.run_id}/qc/trimmed/"
    if ('cluster' in stageList) {
        outputs.asv_table = "${params.results_dir}/${params.run_id}/asv_table/feature-table_renamed.tsv"
        outputs.rep_seqs  = "${params.results_dir}/${params.run_id}/asv_table/rep-seqs_renamed.fna"
    }
    if ('classify' in stageList) {
        outputs.taxonomy   = "${params.results_dir}/${params.run_id}/taxonomy/classification.tsv"
        outputs.asv_counts = "${params.results_dir}/${params.run_id}/taxonomy/agglomerated_data/asv_counts.tsv"
    }
    if ('diversity' in stageList)
        outputs.diversity = "${params.results_dir}/${params.run_id}/diversity/"
    if ('association' in stageList)
        outputs.association = "${params.results_dir}/${params.run_id}/association/"

    def state = [
        run_id           : params.run_id,
        pipeline         : "nf-edna-nanopore",
        pipeline_variant : "consensus",
        marker           : params.marker,
        classifier       : params.classifier,
        completed_stages : stageList,
        last_stage       : last_stage,
        params_used      : [
            primers_fwd  : params.primers_fwd,
            primers_rev  : params.primers_rev,
            min_length   : params.min_length,
            max_length   : params.max_length,
            kingdoms     : params.kingdoms,
            medaka_model : params.medaka_model
        ],
        outputs : outputs
    ]

    def json = groovy.json.JsonOutput.prettyPrint(
        groovy.json.JsonOutput.toJson(state)
    )
    task.workDir.resolve("pipeline_state.json").text = json
}

// ── Named workflow entry points (mirrors nf-edna's main.nf staging) ─────────

workflow QC_ONLY {
    reads = createInputChannel(params.input_manifest)
    QC(reads)
    WRITE_STATE(channel.value(['qc']), channel.value('qc'))
}

workflow CLUSTER_ONLY {
    reads = createInputChannel(params.input_manifest)
    QC(reads)
    CLUSTER_CONSENSUS(QC.out.trimmed_reads)
    WRITE_STATE(channel.value(['qc', 'cluster']), channel.value('cluster'))
}

workflow CLASSIFY_ONLY {
    reads       = createInputChannel(params.input_manifest)
    metadata    = channel.fromPath(params.metadata)
    ref_mmi     = params.ref_mmi ? channel.fromPath(params.ref_mmi) : channel.value(file('NO_FILE'))
    tax_lookup  = params.tax_lookup ? channel.fromPath(params.tax_lookup) : channel.value(file('NO_FILE'))
    kraken2_db  = params.kraken2_db ? channel.fromPath(params.kraken2_db) : channel.value(file('NO_FILE'))
    idtaxa_model = params.idtaxa_model ? channel.fromPath(params.idtaxa_model) : channel.value(file('NO_FILE'))

    QC(reads)
    CLUSTER_CONSENSUS(QC.out.trimmed_reads)
    MERGE_DECONTAM(CLUSTER_CONSENSUS.out.fasta, CLUSTER_CONSENSUS.out.biom, metadata)
    CLASSIFY_CONSENSUS(
        MERGE_DECONTAM.out.fasta,
        MERGE_DECONTAM.out.table,
        ref_mmi, tax_lookup, kraken2_db, idtaxa_model,
        metadata
    )
    WRITE_STATE(channel.value(['qc', 'cluster', 'decontam', 'classify']), channel.value('classify'))
}

workflow {
    reads        = createInputChannel(params.input_manifest)
    metadata     = channel.fromPath(params.metadata)
    ref_mmi      = params.ref_mmi ? channel.fromPath(params.ref_mmi) : channel.value(file('NO_FILE'))
    tax_lookup   = params.tax_lookup ? channel.fromPath(params.tax_lookup) : channel.value(file('NO_FILE'))
    kraken2_db   = params.kraken2_db ? channel.fromPath(params.kraken2_db) : channel.value(file('NO_FILE'))
    idtaxa_model = params.idtaxa_model ? channel.fromPath(params.idtaxa_model) : channel.value(file('NO_FILE'))

    QC(reads)
    CLUSTER_CONSENSUS(QC.out.trimmed_reads)
    MERGE_DECONTAM(CLUSTER_CONSENSUS.out.fasta, CLUSTER_CONSENSUS.out.biom, metadata)
    CLASSIFY_CONSENSUS(
        MERGE_DECONTAM.out.fasta,
        MERGE_DECONTAM.out.table,
        ref_mmi, tax_lookup, kraken2_db, idtaxa_model,
        metadata
    )
    DIVERSITY(
        CLASSIFY_CONSENSUS.out.filtered_fasta,
        CLASSIFY_CONSENSUS.out.asv_counts,
        CLASSIFY_CONSENSUS.out.asv_taxonomy,
        metadata
    )
    ASSOCIATION(
        CLASSIFY_CONSENSUS.out.asv_counts,
        CLASSIFY_CONSENSUS.out.asv_taxonomy,
        metadata,
        DIVERSITY.out.alpha_diversity_metrics
    )
    WRITE_STATE(
        channel.value(['qc', 'cluster', 'classify', 'diversity', 'association']),
        channel.value('association')
    )
}
