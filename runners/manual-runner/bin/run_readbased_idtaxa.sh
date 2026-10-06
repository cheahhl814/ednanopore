#!/bin/bash
# Method 2/3: per-read classification via DECIPHER IdTaxa + SILVA. No
# clustering -- same QC-trimmed reads as run_readbased_minimap2.sh, swapping
# the classifier+reference. Exists to isolate "is a composition difference
# caused by the reference database, or by clustering?" -- run this
# alongside run_readbased_minimap2.sh (same reads) and run_consensus_idtaxa.sh
# (same classifier+reference) to triangulate. See BUG_FIX_REPORT.md and the
# Acidobacteriota case study: RefSeq-vs-SILVA alone explained part of a
# divergence, clustering added more on top -- a 2-way comparison alone
# can't tell you which.
#
# SLOW: IdTaxa's classification call already uses all available cores
# internally, so samples are classified SEQUENTIALLY (parallel invocations
# would just oversubscribe the same cores). Measured throughput on a
# 64-core machine: ~0.17 sec/read, i.e. ~170,000 reads/8hr. A full run
# (no subsampling) over hundreds of thousands of reads can take a day+;
# SUBSAMPLE_N below defaults to capping each sample for a faster read on
# whether SILVA's picture broadly agrees with the full-depth readbased run,
# at the cost of exact comparability and rare-taxon sensitivity. Set
# SUBSAMPLE_N=0 to disable and classify every read (budget accordingly).
#
# Usage:
#   run_readbased_idtaxa.sh <manifest.tsv> <qc_dir> <out_dir> <idtaxa_model.RData> \
#     <metadata.tsv> [idtaxa_threshold] [decontam_threshold] [neg_control_column] \
#     [subsample_n] [subsample_seed]
set -euo pipefail

MANIFEST=$1
QC_DIR=$2
OUT_DIR=$3
IDTAXA_MODEL=$4
METADATA=$5
IDTAXA_THRESHOLD=${6:-60}
DECONTAM_THRESHOLD=${7:-0.1}
NEG_COL=${8:-is_negative}
SUBSAMPLE_N=${9:-10000}
SUBSAMPLE_SEED=${10:-42}

PIPE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TAX="$OUT_DIR/taxonomy"
ASV="$OUT_DIR/asv_table"
mkdir -p "$TAX" "$ASV"

mapfile -t SAMPLES < <(cut -f1 "$MANIFEST")

classify_one() {
  local sample=$1
  local fastq="$QC_DIR/$sample/${sample}.trimmed.fastq.gz"
  local fasta="$TAX/${sample}.trimmed.fasta"

  if [ "$SUBSAMPLE_N" -gt 0 ]; then
    echo "[$sample] subsampling (n=$SUBSAMPLE_N, seed=$SUBSAMPLE_SEED) + converting to fasta..."
    pixi run --manifest-path "$PIPE/env/qc/pixi.toml" bash -c "
      seqkit sample -s $SUBSAMPLE_SEED -n $SUBSAMPLE_N '$fastq' | seqkit fq2fa -o '$fasta'
    " > "$TAX/${sample}.fq2fa.log" 2>&1
  else
    echo "[$sample] converting full read set to fasta (no subsampling)..."
    pixi run --manifest-path "$PIPE/env/qc/pixi.toml" \
      seqkit fq2fa "$fastq" -o "$fasta" > "$TAX/${sample}.fq2fa.log" 2>&1
  fi

  echo "[$sample] IdTaxa classification ($(grep -c '^>' "$fasta") reads)..."
  pixi run --manifest-path "$PIPE/env/classification/pixi.toml" \
    Rscript "$PIPE/bin/idtaxa_rds.R" \
    --query_sequences "$fasta" \
    --idtaxa_model "$IDTAXA_MODEL" \
    --output_classification "$TAX/${sample}.idtaxa_classification.tsv" \
    --output_confidence "$TAX/${sample}.idtaxa_confidence.tsv" \
    > "$TAX/${sample}.idtaxa_classify.log" 2>&1

  echo "[$sample] filtering by confidence (threshold=$IDTAXA_THRESHOLD)..."
  pixi run --manifest-path "$PIPE/env/decontam/pixi.toml" \
    julia "$PIPE/bin/filter_idtaxa_by_confidence.jl" \
    --classification_file "$TAX/${sample}.idtaxa_classification.tsv" \
    --confidence_file "$TAX/${sample}.idtaxa_confidence.tsv" \
    --output_file "$TAX/${sample}.idtaxa_classification_confident.tsv" \
    --threshold "$IDTAXA_THRESHOLD" \
    > "$TAX/${sample}.idtaxa_filter.log" 2>&1

  rm -f "$fasta"
  echo "[$sample] done: $(wc -l < "$TAX/${sample}.idtaxa_classification_confident.tsv") rows"
}

# Sequential by design -- see header note. Do not parallelize.
for sample in "${SAMPLES[@]}"; do
  classify_one "$sample"
done
echo "=== classification complete, aggregating ==="

python3 - "$TAX" "$ASV/taxon_abundance_table.tsv" "${SAMPLES[@]}" <<'PYEOF'
import csv, sys, os
from collections import OrderedDict

tax_dir, out_path, *sample_ids = sys.argv[1:]
RANK_COLUMNS = ["superkingdom", "phylum", "class", "order", "family", "genus", "species"]

table = OrderedDict()
for sample in sample_ids:
    path = os.path.join(tax_dir, f"{sample}.idtaxa_classification_confident.tsv")
    with open(path, newline="") as fh:
        reader = csv.DictReader(fh, delimiter="\t")
        for row in reader:
            lineage = tuple((row.get(r, "") or "").replace("NA", "") for r in RANK_COLUMNS)
            if not any(lineage):
                lineage = ("__unclassified__",) * len(RANK_COLUMNS)
            table.setdefault(lineage, {}).setdefault(sample, 0)
            table[lineage][sample] += 1

with open(out_path, "w", newline="") as out:
    writer = csv.writer(out, delimiter="\t")
    writer.writerow(RANK_COLUMNS + list(sample_ids))
    for lineage in table:
        counts = [table[lineage].get(s, 0) for s in sample_ids]
        writer.writerow(list(lineage) + counts)

print(f"Wrote {out_path}: {len(table)} lineage rows")
PYEOF

echo "=== decontaminating ==="
pixi run --manifest-path "$PIPE/env/decontam/pixi.toml" \
  julia "$PIPE/bin/decontam_by_taxon.jl" \
  --taxon_table "$ASV/taxon_abundance_table.tsv" \
  --metadata "$METADATA" \
  --output_cleaned_table "$TAX/decontam_taxon_abundance.tsv" \
  --output_contaminants_summary "$TAX/decontam_summary.tsv" \
  --threshold "$DECONTAM_THRESHOLD" \
  --neg_control_column "$NEG_COL" \
  2>&1 | tee "$TAX/decontam.log"

echo "=== readbased (idtaxa) complete: $OUT_DIR ==="
wc -l "$ASV/taxon_abundance_table.tsv" "$TAX/decontam_taxon_abundance.tsv"
