#!/bin/bash
# Stage 1/4 (shared by every downstream method): chopper length/quality
# filter, then orientation-aware cutadapt primer trimming.
#
# Validated defaults baked in below come from BUG_FIX_REPORT.md Bugs 28-29:
#   --revcomp on the forward-primer cutadapt call (ONT reads are not
#   consistently oriented; without --revcomp, cutadapt -g ... --discard-untrimmed
#   silently discards ~55-63% of genuine reverse-strand amplicon reads).
#   A SEPARATE post-trim length floor (min_length_trimmed, 350bp) distinct
#   from the raw-read floor (min_length, 450bp) -- reusing the raw floor
#   after primer removal rejects most correctly-trimmed inserts, since
#   trimming removes ~30-60bp.
#
# Usage:
#   run_qc.sh <manifest.tsv> <input_dir> <out_dir> <primers_fwd> <primers_rev> \
#     [min_length] [min_length_trimmed] [max_length] [min_qual] [threads]
#
# manifest.tsv: sample_id<TAB>fastq_filename (filename resolved under <input_dir>)
set -euo pipefail

MANIFEST=$1
INPUT_DIR=$2
OUT_DIR=$3
PRIMERS_FWD=$4
PRIMERS_REV=$5
MIN_LENGTH=${6:-450}
MIN_LENGTH_TRIMMED=${7:-350}
MAX_LENGTH=${8:-1600}
MIN_QUAL=${9:-10}
THREADS=${10:-4}

PIPE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
QC_ENV="$PIPE/env/qc/pixi.toml"

rev_primer_rc=$(echo "$PRIMERS_REV" | tr 'ACGTacgt' 'TGCAtgca' | rev)

run_one() {
  local sample=$1 infile=$2
  local sdir="$OUT_DIR/$sample"
  mkdir -p "$sdir"

  echo "[$sample] chopper..."
  pixi run --manifest-path "$QC_ENV" \
    chopper -i "$INPUT_DIR/$infile" \
    --minlength "$MIN_LENGTH" --maxlength "$MAX_LENGTH" \
    --quality "$MIN_QUAL" --threads "$THREADS" \
    2>"$sdir/chopper.log" | gzip > "$sdir/${sample}.chopped.fastq.gz"

  echo "[$sample] cutadapt fwd (--revcomp)..."
  pixi run --manifest-path "$QC_ENV" \
    cutadapt --error-rate 0.1 --times 1 --overlap 3 --revcomp \
    -j "$THREADS" -g "$PRIMERS_FWD" --discard-untrimmed \
    -o "$sdir/${sample}.fwd_trimmed.fastq.gz" "$sdir/${sample}.chopped.fastq.gz" \
    > "$sdir/cutadapt_fwd.log" 2>&1

  echo "[$sample] cutadapt rev..."
  pixi run --manifest-path "$QC_ENV" \
    cutadapt --error-rate 0.1 --times 1 --overlap 3 \
    --minimum-length "$MIN_LENGTH_TRIMMED" \
    -j "$THREADS" -a "$rev_primer_rc" \
    -o "$sdir/${sample}.trimmed.fastq.gz" "$sdir/${sample}.fwd_trimmed.fastq.gz" \
    > "$sdir/cutadapt_rev.log" 2>&1

  n_raw=$(zcat "$INPUT_DIR/$infile" | wc -l | awk '{print $1/4}')
  n_chopped=$(zcat "$sdir/${sample}.chopped.fastq.gz" | wc -l | awk '{print $1/4}')
  n_trimmed=$(zcat "$sdir/${sample}.trimmed.fastq.gz" | wc -l | awk '{print $1/4}')
  echo "[$sample] raw=$n_raw chopped=$n_chopped trimmed=$n_trimmed"
}

while IFS=$'\t' read -r sample infile; do
  [ -z "$sample" ] && continue
  run_one "$sample" "$infile" &
done < "$MANIFEST"
wait
echo "=== QC complete: $OUT_DIR ==="
