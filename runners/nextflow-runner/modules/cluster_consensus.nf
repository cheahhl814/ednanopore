// Variant A: cluster + polish + chimera filter for Nanopore 16S amplicons.
// Replaces nf-edna's denoise.nf. Output contract (fasta + biom tuple shapes)
// matches denoise.nf exactly so the original nf-edna bin/ scripts
// (biom2tsv, merge_denoise, decontam.jl, agglomerate_data.R, etc.)
// are reused unmodified downstream.
// Pipeline order: minimap2 self-map → yacrd chimera filter → cluster graph → medaka polish → BIOM emit.

process selfmap {
    tag "minimap2 self-map ${sample_id}"
    label 'process_medium'
    publishDir "${params.results_dir}/${params.run_id}/cluster/selfmap/${sample_id}", mode: 'copy', overwrite: false

    input:
    tuple val(sample_id), path(reads), val(single_end)

    output:
    tuple val(sample_id), path("${sample_id}.self.paf"), emit: paf
    tuple val(sample_id), path("${sample_id}.sorted.bam"), path("${sample_id}.sorted.bam.bai"), emit: bam

    script:
    // ONT preset (-x map-ont); all-vs-all self-mapping; sort + index for yacrd pile-up.
    """
    pixi run --manifest-path ${baseDir}/runners/nextflow-runner/env/cluster/pixi.toml \
        minimap2 -x map-ont -t ${task.cpus} \
        ${reads} ${reads} \
        | pixi run --manifest-path ${baseDir}/runners/nextflow-runner/env/cluster/pixi.toml \
            samtools view -b -@ ${task.cpus} -o ${sample_id}.self.bam -

    pixi run --manifest-path ${baseDir}/runners/nextflow-runner/env/cluster/pixi.toml \
        samtools sort -@ ${task.cpus} -o ${sample_id}.sorted.bam ${sample_id}.self.bam
    pixi run --manifest-path ${baseDir}/runners/nextflow-runner/env/cluster/pixi.toml \
        samtools index ${sample_id}.sorted.bam

    # PAF for graph clustering (no sort needed; minimap2 emits by query order)
    pixi run --manifest-path ${baseDir}/runners/nextflow-runner/env/cluster/pixi.toml \
        minimap2 -x map-ont -t ${task.cpus} \
        ${reads} ${reads} > ${sample_id}.self.paf
    """
}

process chimera_filter {
    tag "yacrd ${sample_id}"
    label 'process_low'
    publishDir "${params.results_dir}/${params.run_id}/cluster/chimera/${sample_id}", mode: 'copy', overwrite: false

    input:
    tuple val(sample_id), path(sorted_bam), path(bai)

    output:
    tuple val(sample_id), path("${sample_id}.chimeric_read_ids.txt"), emit: chimeric_ids
    tuple val(sample_id), path("${sample_id}.good.fastq.gz"),         emit: clean_reads

    script:
    // yacrd flags reads with internal low-coverage regions (= chimeric joins).
    // Runs BEFORE clustering so the cluster graph is built on non-chimeric reads.
    """
    pixi run --manifest-path ${baseDir}/runners/nextflow-runner/env/cluster/pixi.toml \
        yacrd filter -i ${sorted_bam} -o ${sample_id}.yacrd.yacrd \
        -c ${task.cpus} -t ${params.yacrd_min_coverage} -n ${params.yacrd_min_length} > ${sample_id}.yacrd.log

    pixi run --manifest-path ${baseDir}/runners/nextflow-runner/env/cluster/pixi.toml \
        yacrd extract -i ${sorted_bam} -o ${sample_id}.chimeric.txt \
        -c ${task.cpus} -t ${params.yacrd_min_coverage} -n ${params.yacrd_min_length} || true

    pixi run --manifest-path ${baseDir}/runners/nextflow-runner/env/cluster/pixi.toml \
        yacrd scrub -i ${sorted_bam} -o ${sample_id}.good.bam \
        -c ${task.cpus} -t ${params.yacrd_min_coverage} -n ${params.yacrd_min_length}

    pixi run --manifest-path ${baseDir}/runners/nextflow-runner/env/cluster/pixi.toml \
        samtools fastq ${sample_id}.good.bam | gzip > ${sample_id}.good.fastq.gz

    # Combine yacrd extract + filter outputs into a single id list for audit
    cat ${sample_id}.chimeric.txt ${sample_id}.yacrd.yacrd 2>/dev/null \
        | sort -u > ${sample_id}.chimeric_read_ids.txt || touch ${sample_id}.chimeric_read_ids.txt
    """
}

process cluster_graph {
    tag "Cluster graph ${sample_id}"
    label 'process_low'
    publishDir "${params.results_dir}/${params.run_id}/cluster/clusters/${sample_id}", mode: 'copy', overwrite: false

    input:
    tuple val(sample_id), path(paf)
    tuple val(sample_id), path(clean_reads)

    output:
    tuple val(sample_id), path("${sample_id}.clusters.tsv"), emit: cluster_tsv
    tuple val(sample_id), path("cluster_dir"),              emit: cluster_dir

    script:
    // Graph-based clustering: build an undirected overlap graph from minimap2 PAF
    // (edge when alignment covers >= coverage_fraction of either read and identity >= min_identity),
    // then take connected components. Each component = one cluster → one consensus.
    // Lightweight inline Python; avoids dragging in transcriptome-tuned isONclust.
    """
    cat <<'PYEOF' > cluster_graph.py
import sys, gzip, collections, itertools

paf_file, reads_file, out_tsv, out_dir, cov_frac, min_id = sys.argv[1:7]
cov_frac = float(cov_frac); min_id = float(min_id)

# Load read lengths from the (gzipped) fastq of clean reads
lengths = {}
opener = gzip.open if reads_file.endswith('.gz') else open
with opener(reads_file, 'rt') as f:
    for i, line in enumerate(f):
        if i % 4 == 0:
            hdr = line.strip().lstrip('@').split()[0]
        if i % 4 == 1:
            lengths[hdr] = len(line.strip())

# Build overlap graph from PAF: only self vs self, primary alignments
adj = collections.defaultdict(set)
with open(paf_file) as f:
    for line in f:
        p = line.rstrip('\n').split('\t')
        if len(p) < 12: continue
        q, qlen, qs, qe = p[0], int(p[1]), int(p[2]), int(p[3])
        t, tlen, ts, te = p[5], int(p[6]), int(p[7]), int(p[8])
        if q != t: continue  # self only
        if qlen == 0 or tlen == 0: continue
        aln_len = max(qe - qs, te - ts)
        frac_q  = aln_len / qlen
        frac_t  = aln_len / tlen
        if frac_q < cov_frac or frac_t < cov_frac: continue
        # minimap2 doesn't emit %identity by default; use NM tag if present
        try:
            nm = int(p[11]) if p[10].startswith('nm') else None
        except Exception:
            nm = None
        if nm is None:
            ident = 1.0 - (min(qlen, tlen) * 0.15 / aln_len)  # conservative ONT assumption
        else:
            ident = 1.0 - nm / aln_len
        if ident < min_id: continue
        adj[q].add(t)
        if q != t:
            adj[t].add(q)

# Union-find connected components
parent = {}
def find(x):
    parent.setdefault(x, x)
    while parent[x] != x:
        parent[x] = parent[parent[x]]
        x = parent[x]
    return x
def union(a, b):
    ra, rb = find(a), find(b)
    if ra != rb: parent[ra] = rb

nodes = set(lengths) | set(adj)
for n in nodes: parent.setdefault(n, n)
for a, bs in adj.items():
    for b in bs: union(a, b)

comp = collections.defaultdict(list)
for n in nodes:
    comp[find(n)].append(n)

import os
os.makedirs(out_dir, exist_ok=True)
with open(out_tsv, 'w') as f:
    for cid, (_, members) in enumerate(
        sorted(comp.items(), key=lambda kv: -len(kv[1]))
    ):
        if len(members) < 2: continue  # singletons go to singleton bin
        f.write(f"cluster_{cid}\t{len(members)}\t{','.join(sorted(members))}\n")
        # per-cluster reads file for medaka
        with open(f"{out_dir}/cluster_{cid}.txt", 'w') as cf:
            cf.write('\n'.join(sorted(members)) + '\n')
PYEOF

    pixi run --manifest-path ${baseDir}/runners/nextflow-runner/env/cluster/pixi.toml \
        python cluster_graph.py ${paf} ${clean_reads} \
        ${sample_id}.clusters.tsv cluster_dir \
        ${params.cluster_min_coverage_fraction} ${params.cluster_min_identity}
    """
}

process medaka_polish {
    tag "medaka consensus ${sample_id}"
    label 'process_high'
    publishDir "${params.results_dir}/${params.run_id}/cluster/consensus/${sample_id}", mode: 'copy', overwrite: false

    input:
    tuple val(sample_id), path(reads)
    tuple val(sample_id), path(cluster_tsv)
    tuple val(sample_id), path(cluster_dir)

    output:
    tuple val(sample_id), path("${sample_id}.sequences.fasta"), emit: fasta
    tuple val(sample_id), path("${sample_id}.table.biom"),      emit: biom

    script:
    // Per-cluster medaka polish; emit one consensus fasta + BIOM table whose
    // tuple shape matches nf-edna's denoise.nf output so downstream
    // biom2tsv / merge_denoise / decontam.jl scripts are reused unmodified.
    // Uses medaka's built-in consensus mode (-m r941_min_hac_g507 for older
    // chemistry; users override via params.medaka_model).
    """
    mkdir -p consensus_dir

    # One medaka invocation per cluster (cheap parallelism; Nextflow task.cpus is per cluster).
    # Per-cluster pipeline:
    #   1. Inline Python: extract this cluster's reads from the gzip fastq by ID, and pick the
    #      longest read as a naive draft (BAM/samtools-free — ${reads} is a plain-gzip fastq,
    #      not a bgzip/BAM that samtools faidx/view can handle).
    #   2. medaka_consensus high-level wrapper: aligns reads to the draft internally, polishes,
    #      and writes consensus.fasta — no separately-built BAM required.
    #   3. Promote medaka_out/consensus.fasta -> consensus_dir/${cluster_id}.fasta so the
    #      downstream concatenation / sanitize / BIOM block (unchanged) keeps working.
    while IFS=$'\t' read -r cluster_id size read_ids; do
        [ -z "\$cluster_id" ] && continue

        # Extract this cluster's reads by ID and pick the longest as a draft
        # (gzip-aware, 4-line FASTQ records; bash expand $read_ids / ${cluster_id}).
        pixi run --manifest-path ${baseDir}/runners/nextflow-runner/env/cluster/pixi.toml \
            python -c "
import gzip
keep = set('''\${read_ids}'''.split(','))
kept = []
draft_fa = ''
draft_len = -1
with gzip.open('${reads}', 'rt') as f:
    while True:
        hdr = f.readline()
        if not hdr: break
        seq = f.readline()
        plus = f.readline()
        qual = f.readline()
        if not (seq and plus and qual): break
        rid = hdr.strip().lstrip('@').split()[0]
        if rid in keep:
            rec = hdr + seq + plus + qual
            kept.append(rec)
            sl = len(seq.strip())
            if sl > draft_len:
                draft_len = sl
                draft_fa = hdr + seq
with open('cluster_\${cluster_id}.fastq', 'w') as o:
    o.write(''.join(kept))
if draft_len >= 0:
    hdr_line, seq_body = draft_fa.split('\n', 1)
    with open('cluster_\${cluster_id}.draft.fasta', 'w') as o:
        o.write('>' + hdr_line[1:] + '\n' + seq_body)
"

        # Skip clusters where extraction yielded nothing (e.g. tiny clusters)
        [ -s cluster_\${cluster_id}.fastq ] || { echo "[medaka_polish] cluster \$cluster_id has no reads, skipping" >&2; continue; }
        [ -s cluster_\${cluster_id}.draft.fasta ] || { echo "[medaka_polish] cluster \$cluster_id has no draft, skipping" >&2; continue; }

        # High-level wrapper: aligns reads to draft internally; writes consensus.fasta
        pixi run --manifest-path ${baseDir}/runners/nextflow-runner/env/cluster/pixi.toml \
            medaka_consensus -i cluster_\${cluster_id}.fastq \
            -d cluster_\${cluster_id}.draft.fasta \
            -o cluster_\${cluster_id}.medaka_out \
            -m ${params.medaka_model} -t ${task.cpus} \
            || { echo "[medaka_polish] cluster \$cluster_id failed, skipping" >&2; continue; }

        # Promote medaka's output to the canonical consensus_dir/${cluster_id}.fasta path
        cp cluster_\${cluster_id}.medaka_out/consensus.fasta consensus_dir/\${cluster_id}.fasta
    done < ${cluster_tsv}

    # Concatenate per-cluster polished consensii into the canonical
    # ${sample_id}.sequences.fasta and write a BIOM with one sample column.
    cat consensus_dir/*.fasta > raw_consensus.fasta 2>/dev/null || touch raw_consensus.fasta
    # Sanitize: rename ">cluster_N" to ">cluster_N;size=N" (VSEARCH-style abundance annotation)
    pixi run --manifest-path ${baseDir}/runners/nextflow-runner/env/cluster/pixi.toml \
        python -c "
import re, sys
sizes = {}
with open('${cluster_tsv}') as f:
    for line in f:
        p = line.rstrip('\n').split('\t')
        if len(p) >= 2: sizes[p[0]] = p[1]
out = []
with open('raw_consensus.fasta') as f:
    for line in f:
        if line.startswith('>'):
            name = line[1:].split()[0]
            sz = sizes.get(name, 1)
            out.append(f'>{name};size={sz}\n')
        else:
            out.append(line)
open('${sample_id}.sequences.fasta','w').write(''.join(out))
"

    # Build BIOM v1 with sample_id column; counts = cluster size
    pixi run --manifest-path ${baseDir}/runners/nextflow-runner/env/cluster/pixi.toml \
        python -c "
import json, sys
sizes = {}
with open('${cluster_tsv}') as f:
    for line in f:
        p = line.rstrip('\n').split('\t')
        if len(p) >= 2: sizes[p[0]] = int(p[1])
rows = []
data = []
idx = 0
for cid, n in sorted(sizes.items()):
    rows.append({'id': cid, 'metadata': None})
    data.append([idx, 0, n])
    idx += 1
biom = {'id': None, 'format': 'Biological Observation Matrix 1.0.0',
        'format_url': 'http://biom-format.org',
        'type': 'Process',
        'generated_by': 'nf-edna-nanopore cluster_consensus',
        'date': '2026-01-01',
        'rows': rows, 'columns': [{'id': '${sample_id}', 'metadata': None}],
        'matrix_type': 'sparse', 'matrix_element_type': 'int',
        'shape': [len(rows), 1], 'data': data}
open('${sample_id}.table.biom','w').write(json.dumps(biom))
"
    """
}

workflow CLUSTER_CONSENSUS {
    take:
    reads  // tuple(sample_id, reads, single_end)

    main:
    selfmap(reads)
    chimera_filter(selfmap.out.bam)
    cluster_graph(selfmap.out.paf, chimera_filter.out.clean_reads)
    medaka_polish(
        chimera_filter.out.clean_reads,
        cluster_graph.out.cluster_tsv,
        cluster_graph.out.cluster_dir
    )

    emit:
    fasta  = medaka_polish.out.fasta  // tuple(sample_id, ${sample_id}.sequences.fasta)
    biom   = medaka_polish.out.biom   // tuple(sample_id, ${sample_id}.table.biom)
}