#!/bin/bash
# Method 1/3: per-read classification via minimap2 + LCA against a RefSeq-16S
# (or similar) reference. No clustering -- every QC-trimmed read is
# classified independently. Reaches species-level resolution where the
# reference has species-level headers (RefSeq does); every read counts, so
# rare taxa aren't diluted/merged by a clustering threshold. Known weakness
# (see BUG_FIX_REPORT.md / the readbased-vs-consensus comparison): RefSeq's
# curated Targeted Loci collection under-represents uncultured/Candidatus
# environmental lineages -- cross-check against run_consensus_idtaxa.sh
# and/or run_readbased_idtaxa.sh (SILVA reference) before trusting a phylum
# that looks surprisingly rare here.
#
# Usage:
#   run_readbased_minimap2.sh <manifest.tsv> <qc_dir> <out_dir> <ref_mmi> \
#     <tax_lookup.tsv> <metadata.tsv> [min_pct_identity] [min_ref_coverage] \
#     [decontam_threshold] [neg_control_column]
#
# manifest.tsv: sample_id<TAB>fastq_filename (first column only is used here;
# reads are taken from <qc_dir>/<sample_id>/<sample_id>.trimmed.fastq.gz)
set -euo pipefail

MANIFEST=$1
QC_DIR=$2
OUT_DIR=$3
REF_MMI=$4
TAX_LOOKUP=$5
METADATA=$6
MIN_PCT_ID=${7:-0.85}
MIN_REF_COV=${8:-0.8}
DECONTAM_THRESHOLD=${9:-0.1}
NEG_COL=${10:-is_negative}

PIPE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TAX="$OUT_DIR/taxonomy"
ASV="$OUT_DIR/asv_table"
mkdir -p "$TAX" "$ASV"

mapfile -t SAMPLES < <(awk -F'\t' 'NR==1 && $1=="sample_id"{next} {print $1}' "$MANIFEST")

classify_one() {
  local sample=$1
  echo "[$sample] minimap2_lca classification..."
  pixi run --manifest-path "$PIPE/../../pixi.toml" -e classification \
    python "$PIPE/bin/minimap2_lca.py" \
    --query_fasta "$QC_DIR/$sample/${sample}.trimmed.fastq.gz" \
    --ref_mmi "$REF_MMI" \
    --tax_lookup "$TAX_LOOKUP" \
    --min_percent_identity "$MIN_PCT_ID" \
    --min_ref_coverage "$MIN_REF_COV" \
    --output_classification "$TAX/${sample}.minimap2_lca_classification.tsv" \
    --output_confidence "$TAX/${sample}.minimap2_lca_confidence.tsv" \
    > "$TAX/${sample}.classify.log" 2>&1
  echo "[$sample] done: $(wc -l < "$TAX/${sample}.minimap2_lca_classification.tsv") rows"
}

for sample in "${SAMPLES[@]}"; do
  classify_one "$sample" &
done
wait
echo "=== classification complete, aggregating ==="

python3 - "$TAX" "$ASV/taxon_abundance_table.tsv" "${SAMPLES[@]}" <<'PYEOF'
import csv, sys, os
from collections import OrderedDict

tax_dir, out_path, *sample_ids = sys.argv[1:]
RANK_COLUMNS = ["superkingdom", "phylum", "class", "order", "family", "genus", "species"]

table = OrderedDict()
for sample in sample_ids:
    path = os.path.join(tax_dir, f"{sample}.minimap2_lca_classification.tsv")
    with open(path, newline="") as fh:
        reader = csv.DictReader(fh, delimiter="\t")
        for row in reader:
            lineage = tuple(row.get(r, "") for r in RANK_COLUMNS)
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
pixi run --manifest-path "$PIPE/../../pixi.toml" -e decontam \
  julia "$PIPE/bin/decontam_by_taxon.jl" \
  --taxon_table "$ASV/taxon_abundance_table.tsv" \
  --metadata "$METADATA" \
  --output_cleaned_table "$TAX/decontam_taxon_abundance.tsv" \
  --output_contaminants_summary "$TAX/decontam_summary.tsv" \
  --threshold "$DECONTAM_THRESHOLD" \
  --neg_control_column "$NEG_COL" \
  2>&1 | tee "$TAX/decontam.log"

echo "=== readbased (minimap2) complete: $OUT_DIR ==="
wc -l "$ASV/taxon_abundance_table.tsv" "$TAX/decontam_taxon_abundance.tsv"
