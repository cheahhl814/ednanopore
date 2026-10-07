#!/bin/bash
# Method 3/3: cluster QC-trimmed reads per-sample (self-mapping minimap2 +
# yacrd chimera filtering + greedy identity-graph clustering), polish each
# cluster with medaka, then classify the polished consensus sequences with
# DECIPHER IdTaxa + SILVA. Error-corrects noisy ONT reads before
# classification (unlike the two readbased methods), and SILVA's broader
# environmental/candidate-taxon coverage picks up lineages RefSeq misses --
# but the pretrained SILVA IdTaxa model has NO species rank at all (verified
# directly against the .RData training object: every node tops out at
# genus), so this method cannot produce species-level calls no matter the
# confidence threshold. Cross-check against run_readbased_minimap2.sh for
# species-level identity and rare-taxon sensitivity.
#
# Validated default cluster_min_identity=0.95 (not 0.85 -- that value is
# for the UNRELATED minimap2_min_pct_identity read-vs-reference threshold
# used by run_readbased_minimap2.sh). Also watch disk/CPU: the self-mapping
# step is all-vs-all within a sample and its cost scales with compositional
# SKEW, not just read count -- a sample heavily dominated by one organism
# (e.g. one genus at >90% of reads) can make this step take hours even at
# modest total read counts.
#
# Usage:
#   run_consensus_idtaxa.sh <manifest.tsv> <qc_dir> <out_dir> <idtaxa_model.RData> \
#     <metadata.tsv> [cluster_min_identity] [cluster_min_coverage] \
#     [yacrd_min_coverage] [medaka_model] [idtaxa_threshold] \
#     [decontam_threshold] [neg_control_column] [kingdoms] [target_ranks] [threads]
set -uo pipefail

MANIFEST=$1
QC_DIR=$2
OUT_DIR=$3
IDTAXA_MODEL=$4
METADATA=$5
CLUSTER_MIN_ID=${6:-0.95}
CLUSTER_MIN_COV=${7:-0.8}
YACRD_MIN_COV=${8:-0.4}
MEDAKA_MODEL=${9:-r1041_e82_400bps_sup_v5.0.0}
IDTAXA_THRESHOLD=${10:-60}
DECONTAM_THRESHOLD=${11:-0.1}
NEG_COL=${12:-is_negative}
KINGDOMS=${13:-Bacteria,Archaea}
TARGET_RANKS=${14:-Phylum,Family,Genus}
THREADS=${15:-4}

PIPE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FILTER_CONDITION="${NEG_COL} == false"

mapfile -t SAMPLES < <(awk -F'\t' 'NR==1 && $1=="sample_id"{next} {print $1}' "$MANIFEST")

mkdir -p "$OUT_DIR"/{cluster/selfmap,cluster/chimera,cluster/clusters,cluster/consensus,asv_table,taxonomy}

process_sample() {
  local sample=$1
  local reads="$QC_DIR/$sample/${sample}.trimmed.fastq.gz"
  local sdir_selfmap="$OUT_DIR/cluster/selfmap/$sample"
  local sdir_chimera="$OUT_DIR/cluster/chimera/$sample"
  local sdir_clusters="$OUT_DIR/cluster/clusters/$sample"
  local sdir_consensus="$OUT_DIR/cluster/consensus/$sample"
  mkdir -p "$sdir_selfmap" "$sdir_chimera" "$sdir_clusters" "$sdir_consensus"

  echo "[$sample] selfmap..."
  pixi run --manifest-path "$PIPE/../../pixi.toml" -e cluster \
    minimap2 -a -x map-ont -t "$THREADS" "$reads" "$reads" 2>"$sdir_selfmap/minimap2_sam.log" \
    | pixi run --manifest-path "$PIPE/../../pixi.toml" -e cluster \
      samtools view -b -@ "$THREADS" -o "$sdir_selfmap/${sample}.self.bam" - 2>>"$sdir_selfmap/minimap2_sam.log"
  pixi run --manifest-path "$PIPE/../../pixi.toml" -e cluster \
    minimap2 -x map-ont -t "$THREADS" "$reads" "$reads" > "$sdir_selfmap/${sample}.self.paf" 2>"$sdir_selfmap/minimap2_paf.log"

  echo "[$sample] chimera_filter (yacrd)..."
  pixi run --manifest-path "$PIPE/../../pixi.toml" -e cluster \
    yacrd -i "$sdir_selfmap/${sample}.self.paf" -o "$sdir_chimera/${sample}.yacrd.yacrd" \
    -c 4 -n "$YACRD_MIN_COV" \
    scrubb -i "$reads" -o "$sdir_chimera/${sample}.good.fastq.gz" \
    > "$sdir_chimera/yacrd.log" 2>&1

  echo "[$sample] cluster_graph (identity=$CLUSTER_MIN_ID)..."
  pixi run --manifest-path "$PIPE/../../pixi.toml" -e cluster \
    python "$PIPE/bin/cluster_graph.py" \
    "$sdir_selfmap/${sample}.self.paf" "$sdir_chimera/${sample}.good.fastq.gz" \
    "$sdir_clusters/${sample}.clusters.tsv" "$sdir_clusters/cluster_dir" \
    "$CLUSTER_MIN_COV" "$CLUSTER_MIN_ID" "$sample" \
    > "$sdir_clusters/cluster_graph.log" 2>&1

  echo "[$sample] medaka_polish..."
  bash "$PIPE/bin/medaka_polish_one.sh" "$PIPE" "$sample" \
    "$sdir_chimera/${sample}.good.fastq.gz" "$sdir_clusters/${sample}.clusters.tsv" \
    "$MEDAKA_MODEL" "$THREADS" "$sdir_consensus" \
    > "$sdir_consensus/medaka_polish.log" 2>&1

  echo "[$sample] biom2tsv..."
  pixi run --manifest-path "$PIPE/../../pixi.toml" -e cluster \
    biom convert -i "$sdir_consensus/${sample}.table.biom" -o "$sdir_consensus/${sample}.table.tsv" --to-tsv \
    2>"$sdir_consensus/biom_convert.log" \
    || printf '# Constructed from biom file\n#OTU ID\t%s\n' "$sample" > "$sdir_consensus/${sample}.table.tsv"

  n_clusters=$(wc -l < "$sdir_clusters/${sample}.clusters.tsv" 2>/dev/null || echo 0)
  n_seqs=$(grep -c '>' "$sdir_consensus/${sample}.sequences.fasta" 2>/dev/null || echo 0)
  echo "[$sample] clusters=$n_clusters polished_seqs=$n_seqs"
}

for sample in "${SAMPLES[@]}"; do
  process_sample "$sample" &
done
wait
echo "=== all samples clustered+polished, merging ==="

TABLES=()
FASTAS=()
for sample in "${SAMPLES[@]}"; do
  TABLES+=("$OUT_DIR/cluster/consensus/$sample/${sample}.table.tsv")
  FASTAS+=("$OUT_DIR/cluster/consensus/$sample/${sample}.sequences.fasta")
done

pixi run --manifest-path "$PIPE/../../pixi.toml" -e classification \
  Rscript "$PIPE/bin/merge_tables.R" \
  --input_files "${TABLES[@]}" --output_table "$OUT_DIR/asv_table/feature-table.tsv" \
  2>&1 | tee "$OUT_DIR/asv_table/merge_tables.log"

cat "${FASTAS[@]}" > "$OUT_DIR/asv_table/rep-seqs.fna"
awk 'BEGIN{FS=OFS="\t"} {gsub(/:/,"_",$1); print}' "$OUT_DIR/asv_table/feature-table.tsv" > "$OUT_DIR/asv_table/feature-table_renamed.tsv"
sed '/^>/s/:/_/g' "$OUT_DIR/asv_table/rep-seqs.fna" > "$OUT_DIR/asv_table/rep-seqs_renamed.fna"

echo "merged: $(grep -c '>' "$OUT_DIR/asv_table/rep-seqs_renamed.fna") sequences, $(wc -l < "$OUT_DIR/asv_table/feature-table_renamed.tsv") table rows"

echo "=== decontam ==="
pixi run --manifest-path "$PIPE/../../pixi.toml" -e decontam \
  julia "$PIPE/bin/decontam.jl" \
  --feature_table "$OUT_DIR/asv_table/feature-table_renamed.tsv" \
  --metadata "$METADATA" \
  --rep_seqs "$OUT_DIR/asv_table/rep-seqs_renamed.fna" \
  --output_cleaned_table "$OUT_DIR/asv_table/decontam_asv_table.tsv" \
  --output_cleaned_rep_seqs "$OUT_DIR/asv_table/decontam_rep_seqs.fna" \
  --output_contaminants_summary "$OUT_DIR/asv_table/decontam_summary.tsv" \
  --threshold "$DECONTAM_THRESHOLD" \
  --neg_control_column "$NEG_COL" \
  2>&1 | tee "$OUT_DIR/asv_table/decontam.log"

echo "=== filter_table ==="
pixi run --manifest-path "$PIPE/../../pixi.toml" -e decontam \
  julia "$PIPE/bin/filter_table.jl" \
  --feature_table "$OUT_DIR/asv_table/decontam_asv_table.tsv" \
  --rep_seqs "$OUT_DIR/asv_table/decontam_rep_seqs.fna" \
  --metadata "$METADATA" \
  --filter_condition "$FILTER_CONDITION" \
  --output_table "$OUT_DIR/asv_table/filtered_asv_table.tsv" \
  --output_rep_seqs "$OUT_DIR/asv_table/filtered_rep_seqs.fna" \
  2>&1 | tee "$OUT_DIR/asv_table/filter_table.log"

echo "filtered: $(grep -c '>' "$OUT_DIR/asv_table/filtered_rep_seqs.fna") sequences, $(wc -l < "$OUT_DIR/asv_table/filtered_asv_table.tsv") table rows"

echo "=== idtaxa classification ==="
pixi run --manifest-path "$PIPE/../../pixi.toml" -e classification \
  Rscript "$PIPE/bin/idtaxa_rds.R" \
  --query_sequences "$OUT_DIR/asv_table/filtered_rep_seqs.fna" --idtaxa_model "$IDTAXA_MODEL" \
  --output_classification "$OUT_DIR/taxonomy/idtaxa_classification.tsv" \
  --output_confidence "$OUT_DIR/taxonomy/idtaxa_confidence.tsv" \
  2>&1 | tee "$OUT_DIR/taxonomy/idtaxa_classify.log"

pixi run --manifest-path "$PIPE/../../pixi.toml" -e decontam \
  julia "$PIPE/bin/filter_idtaxa_by_confidence.jl" \
  --classification_file "$OUT_DIR/taxonomy/idtaxa_classification.tsv" \
  --confidence_file "$OUT_DIR/taxonomy/idtaxa_confidence.tsv" \
  --output_file "$OUT_DIR/taxonomy/idtaxa_classification_confident.tsv" \
  --threshold "$IDTAXA_THRESHOLD" \
  2>&1 | tee "$OUT_DIR/taxonomy/idtaxa_confidence_filter.log"

echo "classified: $(wc -l < "$OUT_DIR/taxonomy/idtaxa_classification_confident.tsv") rows"

echo "=== agglomerate ==="
mkdir -p "$OUT_DIR/taxonomy/agglomerated_data"
pixi run --manifest-path "$PIPE/../../pixi.toml" -e classification \
  Rscript "$PIPE/bin/agglomerate_data.R" \
  --asv_counts_file "$OUT_DIR/asv_table/filtered_asv_table.tsv" \
  --taxonomy_file "$OUT_DIR/taxonomy/idtaxa_classification_confident.tsv" \
  --metadata_file "$METADATA" --output_dir "$OUT_DIR/taxonomy/agglomerated_data" \
  --kingdoms "$KINGDOMS" --ranks "$TARGET_RANKS" \
  2>&1 | tee "$OUT_DIR/taxonomy/agglomerate.log"

tail -n +2 "$OUT_DIR/taxonomy/agglomerated_data/asv_counts.tsv" | awk '{print $1}' > "$OUT_DIR/asv_table/asv_ids_to_keep.txt"
sed 's/;size=[0-9]*//' "$OUT_DIR/asv_table/filtered_rep_seqs.fna" > "$OUT_DIR/asv_table/rep_seqs_clean.fna"
pixi run --manifest-path "$PIPE/../../pixi.toml" -e classification \
  seqtk subseq "$OUT_DIR/asv_table/rep_seqs_clean.fna" "$OUT_DIR/asv_table/asv_ids_to_keep.txt" > "$OUT_DIR/taxonomy/filtered_asvs.fna"

echo "=== consensus+idtaxa complete: $OUT_DIR ==="
echo "final ASVs: $(wc -l < "$OUT_DIR/taxonomy/agglomerated_data/asv_counts.tsv")"
