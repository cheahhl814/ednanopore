#!/bin/bash
# Per-sample medaka polish, mirroring modules/cluster_consensus.nf's
# medaka_polish process exactly (extracted logic, shell-variable version).
set -uo pipefail

PIPE=$1
SAMPLE=$2
READS=$3          # good.fastq.gz (chimera-filtered)
CLUSTER_TSV=$4     # sample.clusters.tsv
MEDAKA_MODEL=$5
THREADS=$6
OUTDIR=$7          # working dir for this sample's medaka run

mkdir -p "$OUTDIR/consensus_dir"
cd "$OUTDIR"

while IFS=$'\t' read -r cluster_id size read_ids; do
  [ -z "$cluster_id" ] && continue

  pixi run --manifest-path "$PIPE/../../pixi.toml" -e cluster \
    python -c "
import gzip
keep = set('''${read_ids}'''.split(','))
kept = []
draft_fa = ''
draft_len = -1
with gzip.open('$READS', 'rt') as f:
    while True:
        hdr = f.readline()
        if not hdr: break
        seq = f.readline()
        plus = f.readline()
        qual = f.readline()
        if not (seq and plus and qual): break
        rid = hdr.strip().lstrip('@').split()[0].split('_')[0]
        if rid in keep:
            rec = hdr + seq + plus + qual
            kept.append(rec)
            sl = len(seq.strip())
            if sl > draft_len:
                draft_len = sl
                draft_fa = hdr + seq
with open('cluster_${cluster_id}.fastq', 'w') as o:
    o.write(''.join(kept))
if draft_len >= 0:
    hdr_line, seq_body = draft_fa.split(chr(10), 1)
    with open('cluster_${cluster_id}.draft.fasta', 'w') as o:
        o.write('>' + hdr_line[1:] + chr(10) + seq_body)
"

  [ -s "cluster_${cluster_id}.fastq" ] || { echo "[$SAMPLE] cluster $cluster_id has no reads, skipping" >&2; continue; }
  [ -s "cluster_${cluster_id}.draft.fasta" ] || { echo "[$SAMPLE] cluster $cluster_id has no draft, skipping" >&2; continue; }

  pixi run --manifest-path "$PIPE/../../pixi.toml" -e cluster \
    medaka_consensus -i "cluster_${cluster_id}.fastq" \
    -d "cluster_${cluster_id}.draft.fasta" \
    -o "cluster_${cluster_id}.medaka_out" \
    -m "$MEDAKA_MODEL" -t "$THREADS" \
    > "cluster_${cluster_id}.medaka.log" 2>&1 \
    || { echo "[$SAMPLE] cluster $cluster_id medaka failed, skipping" >&2; continue; }

  sed "1s/^>.*/>${cluster_id}/" "cluster_${cluster_id}.medaka_out/consensus.fasta" > "consensus_dir/${cluster_id}.fasta"
done < "$CLUSTER_TSV"

cat consensus_dir/*.fasta > raw_consensus.fasta 2>/dev/null || touch raw_consensus.fasta

pixi run --manifest-path "$PIPE/../../pixi.toml" -e cluster \
  python -c "
sizes = {}
with open('$CLUSTER_TSV') as f:
    for line in f:
        p = line.rstrip(chr(10)).split(chr(9))
        if len(p) >= 2: sizes[p[0]] = p[1]
out = []
with open('raw_consensus.fasta') as f:
    for line in f:
        if line.startswith('>'):
            name = line[1:].split()[0]
            sz = sizes.get(name, 1)
            out.append(f'>{name};size={sz}' + chr(10))
        else:
            out.append(line)
open('${SAMPLE}.sequences.fasta','w').write(''.join(out))
"

pixi run --manifest-path "$PIPE/../../pixi.toml" -e cluster \
  python -c "
import json, os
sizes = {}
with open('$CLUSTER_TSV') as f:
    for line in f:
        p = line.rstrip(chr(10)).split(chr(9))
        if len(p) >= 2: sizes[p[0]] = int(p[1])
polished = {os.path.splitext(f)[0] for f in os.listdir('consensus_dir')}
rows = []
data = []
idx = 0
for cid, n in sorted(sizes.items()):
    if cid not in polished: continue
    rows.append({'id': cid, 'metadata': None})
    data.append([idx, 0, n])
    idx += 1
biom = {'id': None, 'format': 'Biological Observation Matrix 1.0.0',
        'format_url': 'http://biom-format.org',
        'type': 'Process',
        'generated_by': 'ednanopore cluster_consensus (manual)',
        'date': '2026-01-01',
        'rows': rows, 'columns': [{'id': '$SAMPLE', 'metadata': None}],
        'matrix_type': 'sparse', 'matrix_element_type': 'int',
        'shape': [len(rows), 1], 'data': data}
open('${SAMPLE}.table.biom','w').write(json.dumps(biom))
"

echo "[$SAMPLE] medaka_polish done: $(grep -c '>' ${SAMPLE}.sequences.fasta 2>/dev/null || echo 0) sequences"
