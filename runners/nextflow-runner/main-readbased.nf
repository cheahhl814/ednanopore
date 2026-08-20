#!/usr/bin/env nextflow
nextflow.enable.dsl=2

// Variant B — classify every ONT read directly (mirrors ONT's own wf-16s),
// no clustering/consensus step. v1 scope stops at classify + taxon-abundance
// table + taxon-based decontam: no rep-seqs exist, so the shared
// diversity.nf/association.nf modules (which hard-require --input_tree)
// cannot be reused here. See docs/superpowers/specs/2026-08-19-nf-edna-nanopore-design.md

include { QC }             from './modules/qc.nf'
include { CLASSIFY_READS } from './modules/classify_reads.nf'

// ── Input helpers ────────────────────────────────────────────────────────────

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

// ── Taxon-based decontam (Variant B has no rep-seqs, so nf-edna's
// sequence-keyed decontam.jl does not apply — see bin/decontam_by_taxon.jl) ──

process decontam_by_taxon {
    tag "Decontaminate taxon-abundance table"
    publishDir "${params.results_dir}/${params.run_id}/taxonomy", mode: 'copy', overwrite: false

    input:
    path taxon_abundance_table
    path metadata

    output:
    path "decontam_taxon_abundance.tsv", emit: table
    path "decontam_summary.tsv",         emit: summary

    script:
    """
    pixi run --manifest-path ${baseDir}/runners/nextflow-runner/env/decontam/pixi.toml \
        julia ${baseDir}/runners/nextflow-runner/bin/decontam_by_taxon.jl \
        --taxon_table ${taxon_abundance_table} \
        --metadata ${metadata} \
        --output_cleaned_table decontam_taxon_abundance.tsv \
        --output_contaminants_summary decontam_summary.tsv \
        --threshold ${params.decontam_threshold} \
        --neg_control_column ${params.neg_col}
    """
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
    if ('classify' in stageList)
        outputs.taxon_abundance = "${params.results_dir}/${params.run_id}/taxonomy/taxon_abundance.tsv"
    if ('decontam' in stageList)
        outputs.decontam_taxon_abundance = "${params.results_dir}/${params.run_id}/taxonomy/decontam_taxon_abundance.tsv"

    def state = [
        run_id           : params.run_id,
        pipeline         : "nf-edna-nanopore",
        pipeline_variant : "read_based",
        marker           : params.marker,
        classifier       : params.classifier,
        completed_stages : stageList,
        last_stage       : last_stage,
        params_used      : [
            primers_fwd : params.primers_fwd,
            primers_rev : params.primers_rev,
            min_length  : params.min_length,
            max_length  : params.max_length,
            kingdoms    : params.kingdoms
        ],
        limitations : [
            "no rep-seqs: decontam is taxon-based, not sequence-based",
            "no phylogenetic diversity/UniFrac (no tree possible without rep-seqs)",
            "geocuration, edna-visualize, edna-gbif-publish not supported for this variant in v1"
        ],
        outputs : outputs
    ]

    def json = groovy.json.JsonOutput.prettyPrint(
        groovy.json.JsonOutput.toJson(state)
    )
    task.workDir.resolve("pipeline_state.json").text = json
}

// ── Named workflow entry points ───────────────────────────────────────────────

workflow QC_ONLY {
    reads = createInputChannel(params.input_manifest)
    QC(reads)
    WRITE_STATE(channel.value(['qc']), channel.value('qc'))
}

workflow {
    reads      = createInputChannel(params.input_manifest)
    metadata   = channel.fromPath(params.metadata)
    ref_mmi    = params.ref_mmi ? channel.fromPath(params.ref_mmi) : channel.value(file('NO_FILE'))
    tax_lookup = params.tax_lookup ? channel.fromPath(params.tax_lookup) : channel.value(file('NO_FILE'))
    kraken2_db = params.kraken2_db ? channel.fromPath(params.kraken2_db) : channel.value(file('NO_FILE'))

    QC(reads)
    CLASSIFY_READS(
        QC.out.trimmed_reads.map { sid, f, se -> tuple(sid, f) },
        ref_mmi, tax_lookup, kraken2_db
    )
    decontam_by_taxon(CLASSIFY_READS.out.taxon_abundance_table, metadata)

    WRITE_STATE(
        channel.value(['qc', 'classify', 'decontam']),
        channel.value('decontam')
    )
}
