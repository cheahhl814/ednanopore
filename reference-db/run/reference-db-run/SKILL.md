---
name: reference-db-run
description: Executes ednanopore's reference-db download/build workflow after preflight has passed. For classifier_mode "minimap2" (default) — downloads NCBI RefSeq Targeted Loci 16S FASTA, builds a minimap2 MMI, and derives the tax_lookup TSV from the EPI2ME ref2taxid/taxdump bundle. For "kraken2" — downloads and extracts a pre-built Kraken2 16S database. For "idtaxa" (opt-in, Variant A only) — fetches the SILVA DECIPHER pre-trained file via biodb-fetch's `decipher` key (gdown runs inside biodb-fetch's env — no ad-hoc venv). All downloads go through the biodb-fetch dependency skill (scripts/marker_refs.py, manifest.tsv contract). Writes run_summary.json for downstream consumers.
version: 0.5.0
updated: "2026-10-06"
triggers:
  - "run reference-db nanopore"
  - "build 16S minimap2 index"
  - "download Kraken2 16S database"
  - "fetch SILVA idtaxa nanopore"
requires:
  - "Preflight verdict = GO or GO-WITH-WARNINGS (gates this sub-skill)"
  - "biodb-fetch sibling skill, deployed + pixi-resolved (owns all download execution; its env bundles requests/gdown)"
  - "minimap2 (for the minimap2-mode build step)"
  - "python3 (for the tax_lookup TSV join step)"
---

# Sub-Skill: reference-db-run (ednanopore)

## Audience

1. **AI Coding Agents** — invoked by the parent `reference-db` orchestrator after preflight verdict is `GO` / `GO-WITH-WARNINGS`. The agent must run the stop points for the active mode in order, write `run_summary.json`, and never modify an already-written artifact.
2. **Human Nanopore eDNA scientists** — read this document to understand the download/build phases per classifier mode.

## When to Use

Use this sub-skill **after** `preflight/reference-db-preflight` returns a `GO` or `GO-WITH-WARNINGS` verdict.

**Do NOT use this sub-skill** for: preflight validation (use `reference-db-preflight`); production classification (use `ednanopore`'s `run/ednanopore-run`).

## 0. Inputs / Outputs

### Inputs (consumed from preflight evidence)

| Variable | Source | Description |
| --- | --- | --- |
| `classifier_mode` | preflight SP1 | `minimap2` / `kraken2` / `idtaxa` |
| `reference_choice` | preflight (catalog selection) | Shorthand ID from the parent `reference-db/SKILL.md` catalog |
| `assets_dir` | preflight SP4 | Target directory |
| `preflight_verdict` | preflight verdict file | Must be `GO` or `GO-WITH-WARNINGS` |

### Outputs

- `minimap2` mode: `$ASSETS_DIR/16s_minimap2/16S_refseq.mmi` + `$ASSETS_DIR/16s_minimap2/tax_lookup.tsv`
- `kraken2` mode: `$ASSETS_DIR/16s_kraken2/<db_dir>/{hash,opts,taxo}.k2d`
- `idtaxa` mode: `$ASSETS_DIR/16s_idtaxa/SILVA_SSU_r138.2.rdata`
- `$RUN_DIR/run_summary.json` — compact LLM-loadable summary
- `$RUN_DIR/preflight.md` + `$RUN_DIR/preflight_verdict.txt` — re-used from preflight

## 0.5 Ask-User Stop Points

Each stop point follows the canonical **Evidence + Recommend + Options** pattern.

---

### SP1 — Preflight verdict confirmed

Identical gate to `nf-edna/reference-db-run` SP1: `cat "$RUN_DIR/preflight_verdict.txt"` must be `GO` or `GO-WITH-WARNINGS`, else abort back to preflight.

---

### SP2 — Download (+ build, for minimap2 mode)

> **Evidence**: I will show the user the exact command sequence for the active mode, wait for explicit confirmation, then run it.

**`minimap2` mode (default):**

```bash
# (a) download NCBI RefSeq Targeted Loci FASTA (Bacteria + Archaea)
# v0.3.0: downloads below EXECUTE via biodb-fetch (sibling skill) — set BIOFETCH first:
#   BIOFETCH="<path-to-deployed-biodb-fetch>"
# generic-url fetches land manifest rows (md5, bytes, retrieval_date, contract_version):
pixi run --manifest-path "$BIOFETCH/pixi.toml" python3 scripts/marker_refs.py url \
  --url https://ftp.ncbi.nlm.nih.gov/refseq/TargetedLoci/Bacteria/bacteria.16SrRNA.fna.gz \
  --source ncbi-refseq-targeted-loci --outdir "$ASSETS_DIR/16s_minimap2"
pixi run --manifest-path "$BIOFETCH/pixi.toml" python3 scripts/marker_refs.py url \
  --url https://ftp.ncbi.nlm.nih.gov/refseq/TargetedLoci/Archaea/archaea.16SrRNA.fna.gz \
  --source ncbi-refseq-targeted-loci --outdir "$ASSETS_DIR/16s_minimap2"
# fetched files live in biodb-fetch's content-addressed store; resolve paths from the
# manifest that the fetch printed (md5 + contract_version included):
FETCHED=$(awk -F'\t' 'NR>1{print $4}' "$ASSETS_DIR/16s_minimap2/manifest.tsv" | tail -2 | head -1)
zcat 16S_refseq_bacteria.fna.gz 16S_refseq_archaea.fna.gz > "$ASSETS_DIR/16s_minimap2/16S_refseq.fna"

# (b) build the minimap2 index
pixi run --manifest-path <skill-root>/pixi.toml -e cluster \
  minimap2 -d "$ASSETS_DIR/16s_minimap2/16S_refseq.mmi" -x map-ont \
  "$ASSETS_DIR/16s_minimap2/16S_refseq.fna"

# (c) download the EPI2ME ref2taxid + taxdump bundle (accession<->taxid map + lineage source)
pixi run --manifest-path "$BIOFETCH/pixi.toml" python3 scripts/marker_refs.py url \
  --url https://ont-open-data.s3-eu-west-1.amazonaws.com/workflow-databases/wf-metagenomics-dbs/ncbi_16s_18s/ref2taxid.targloci.tsv \
  --source ont-epi2me-ncbi-16s-18s --outdir "$ASSETS_DIR/16s_minimap2"
pixi run --manifest-path "$BIOFETCH/pixi.toml" python3 scripts/marker_refs.py url \
  --url https://ont-open-data.s3-eu-west-1.amazonaws.com/workflow-databases/wf-metagenomics-dbs/ncbi_16s_18s/new_taxdump_2025-01-01.zip \
  --source ont-epi2me-ncbi-16s-18s
unzip -o new_taxdump.zip -d taxdump/

# (d) join ref2taxid + rankedlineage.dmp -> tax_lookup.tsv (accession<TAB>full_lineage)
python3 reference-db/bin/build_tax_lookup.py ref2taxid.tsv taxdump/rankedlineage.dmp \
  "$ASSETS_DIR/16s_minimap2/tax_lookup.tsv"
```

**`kraken2` mode:**

```bash
# Recommended default: 16S Silva 138 (most current SILVA in the frozen Langmead set)
mkdir -p "$ASSETS_DIR/16s_kraken2" && cd "$ASSETS_DIR/16s_kraken2"
pixi run --manifest-path "$BIOFETCH/pixi.toml" python3 scripts/marker_refs.py url \
  --url https://genome-idx.s3.amazonaws.com/kraken/16S_Silva138_20200326.tgz \
  --source kraken2-16s-silva138 --outdir "$ASSETS_DIR/16s_kraken2"
FETCHED=$(awk -F'\t' 'NR>1{print $4}' "$ASSETS_DIR/16s_kraken2/manifest.tsv" | tail -1)
tar -xzf "$FETCHED" 
# Resulting directory: 16S_SILVA138_k2db/ — set params.kraken2_db to its full path.

# Alternative, matches ONT wf-16s's own kraken2 default exactly:
mkdir -p "$ASSETS_DIR/16s_kraken2/ncbi_16s_18s" && cd "$ASSETS_DIR/16s_kraken2/ncbi_16s_18s"
pixi run --manifest-path "$BIOFETCH/pixi.toml" python3 scripts/marker_refs.py url \
  --url https://ont-open-data.s3.amazonaws.com/workflow-databases/wf-metagenomics-dbs/ncbi_16s_18s/ncbi_targeted_loci_kraken2.tar.gz \
  --source ont-epi2me-ncbi-16s-18s --outdir "$ASSETS_DIR/16s_kraken2"
FETCHED=$(awk -F'\t' 'NR>1{print $4}' "$ASSETS_DIR/16s_kraken2/manifest.tsv" | tail -1)
tar -xzf "$FETCHED" 
# Files land at the top level of this directory (no subdir wrap) — set params.kraken2_db to this path.
```

**`idtaxa` mode (opt-in, Variant A only) — identical to nf-edna's workflow:**

```bash
# v0.3.0: the Google-Drive IdTaxa model goes through biodb-fetch's `decipher` key
# (gdown lives in biodb-fetch's pixi env — no venv, no PEP-668 workaround):
pixi run --manifest-path "$BIOFETCH/pixi.toml" python3 scripts/marker_refs.py decipher \
  --drive-id "1w3wdSCpSihntWkbP_zvXz7r3s-tNB8DV" --outdir "$ASSETS_DIR/16s_idtaxa"
FETCHED=$(awk -F'\t' 'NR>1{print $4}' "$ASSETS_DIR/16s_idtaxa/manifest.tsv" | tail -1)
ln -sf "$FETCHED" "$ASSETS_DIR/16s_idtaxa/SILVA_SSU_r138.2.rdata"
