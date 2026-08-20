// Nanopore 16S shared QC module (Variant A + Variant B).
// Single-end ONT reads only; per-sample tuple shape mirrors nf-edna's qc.nf
// for interface consistency even though single_end is always true here.
// Steps: Chopper (length/quality filter) → cutadapt (5' primer trim) → NanoPlot.

process chopper {
    tag "Chopper ${sample_id}"
    label 'process_low'
    publishDir "${params.results_dir}/${params.run_id}/qc/chopper/${sample_id}", mode: 'copy', overwrite: false

    input:
    tuple val(sample_id), path(reads), val(single_end)

    output:
    tuple val(sample_id), path("${sample_id}.chopped.fastq.gz"), val(single_end), emit: reads

    script:
    """
    pixi run --manifest-path ${baseDir}/runners/nextflow-runner/env/qc/pixi.toml \
        chopper -i ${reads} -o ${sample_id}.chopped.fastq.gz \
        --minlength ${params.min_length} --maxlength ${params.max_length} \
        --minquality ${params.min_qual} --threads ${task.cpus}
    """
}

process trim {
    tag "Cutadapt trim ${sample_id} [SE]"
    label 'process_low'
    publishDir "${params.results_dir}/${params.run_id}/qc/trimmed/${sample_id}", mode: 'copy', overwrite: false

    input:
    tuple val(sample_id), path(reads), val(single_end)

    output:
    tuple val(sample_id), path("${sample_id}.trimmed.fastq.gz"), val(single_end), emit: reads

    script:
    // Single-end ONT: trim 5' primer (-g) and 3' reverse primer via its RC (-a).
    // Mirrors nf-edna's qc.nf cutadapt logic but drops the paired-end branch
    // entirely (ONT is single-read).
    """
    rev_primer_rc=\$(echo "${params.primers_rev}" | tr 'ACGTacgt' 'TGCAtgca' | rev)

    pixi run --manifest-path ${baseDir}/runners/nextflow-runner/env/qc/pixi.toml \
        cutadapt --error-rate 0.1 --times 1 --overlap 3 \
        -j ${task.cpus} -g ${params.primers_fwd} --discard-untrimmed \
        -o ${sample_id}.fwd_trimmed.fastq.gz ${reads}

    # --maximum-length intentionally OMITTED: nanopore amplicon reads can
    # read through the 3' primer into adapter; any length cap belongs on
    # the polished-consensus step, not on primer trimming.
    pixi run --manifest-path ${baseDir}/runners/nextflow-runner/env/qc/pixi.toml \
        cutadapt --error-rate 0.1 --times 1 --overlap 3 \
        --minimum-length ${params.min_length} \
        -j ${task.cpus} -a \${rev_primer_rc} \
        -o ${sample_id}.trimmed.fastq.gz ${sample_id}.fwd_trimmed.fastq.gz
    """
}

process nanoplot {
    tag "NanoPlot ${sample_id}"
    publishDir "${params.results_dir}/${params.run_id}/qc/nanoplot/${sample_id}", mode: 'copy', overwrite: false

    input:
    tuple val(sample_id), path(reads), val(single_end)
    tuple val(trim_id),  path(trimmed_reads), val(trim_single_end)

    output:
    path "raw_nanoplot",      emit: raw_report
    path "trimmed_nanoplot",  emit: trimmed_report

    script:
    """
    pixi run --manifest-path ${baseDir}/runners/nextflow-runner/env/qc/pixi.toml \
        NanoPlot -t ${task.cpus} --fastq ${reads} -o raw_nanoplot --raw
    pixi run --manifest-path ${baseDir}/runners/nextflow-runner/env/qc/pixi.toml \
        NanoPlot -t ${task.cpus} --fastq ${trimmed_reads} -o trimmed_nanoplot
    """
}

workflow QC {
    take:
    reads  // tuple(sample_id, reads, single_end)

    main:
    chopper(reads)
    trim(chopper.out.reads)
    nanoplot(reads, trim.out.reads)

    emit:
    trimmed_reads  = trim.out.reads
    raw_report     = nanoplot.out.raw_report
    trimmed_report = nanoplot.out.trimmed_report
}