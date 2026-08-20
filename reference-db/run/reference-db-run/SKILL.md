---
name: reference-db-run
description: Executes nf-edna-nanopore's reference-db download/build workflow after preflight has passed. For classifier_mode "minimap2" (default) — downloads NCBI RefSeq Targeted Loci 16S FASTA, builds a minimap2 MMI, and derives the tax_lookup TSV from the EPI2ME ref2taxid/taxdump bundle. For "kraken2" — downloads and extracts a pre-built Kraken2 16S database. For "idtaxa" (opt-in, Variant A only) — downloads the SILVA DECIPHER pre-trained file via gdown, reusing nf-edna's exact workflow. Writes run_summary.json for downstream consumers.
version: 0.1.0
updated: "2026-08-19"
triggers:
  - "run reference-db nanopore"
  - "build 16S minimap2 index"
  - "download Kraken2 16S database"
  - "fetch SILVA idtaxa nanopore"
requires:
  - "Preflight verdict = GO or GO-WITH-WARNINGS (gates this sub-skill)"
  - "curl or wget (for downloads)"
  - "minimap2 (for the minimap2-mode build step)"
  - "python3 (for the tax_lookup TSV join step)"
---

# Sub-Skill: reference-db-run (nf-edna-nanopore)

## Audience

1. **AI Coding Agents** — invoked by the parent `reference-db` orchestrator after preflight verdict is `GO` / `GO-WITH-WARNINGS`. The agent must run the stop points for the active mode in order, write `run_summary.json`, and never modify an already-written artifact.
2. **Human Nanopore eDNA scientists** — read this document to understand the download/build phases per classifier mode.

## When to Use

Use this sub-skill **after** `preflight/reference-db-preflight` returns a `GO` or `GO-WITH-WARNINGS` verdict.

**Do NOT use this sub-skill** for: preflight validation (use `reference-db-preflight`); production classification (use `nf-edna-nanopore`'s `run/edna-nanopore-run`).

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
curl -L -o 16S_refseq_bacteria.fna.gz \
  https://ftp.ncbi.nlm.nih.gov/refseq/TargetedLoci/Bacteria/bacteria.16SrRNA.fna.gz
curl -L -o 16S_refseq_archaea.fna.gz \
  https://ftp.ncbi.nlm.nih.gov/refseq/TargetedLoci/Archaea/archaea.16SrRNA.fna.gz
zcat 16S_refseq_bacteria.fna.gz 16S_refseq_archaea.fna.gz > "$ASSETS_DIR/16s_minimap2/16S_refseq.fna"

# (b) build the minimap2 index
pixi run --manifest-path runners/nextflow-runner/env/cluster/pixi.toml \
  minimap2 -d "$ASSETS_DIR/16s_minimap2/16S_refseq.mmi" -x map-ont \
  "$ASSETS_DIR/16s_minimap2/16S_refseq.fna"

# (c) download the EPI2ME ref2taxid + taxdump bundle (accession<->taxid map + lineage source)
curl -L -o ref2taxid.tsv \
  https://ont-open-data.s3-eu-west-1.amazonaws.com/workflow-databases/wf-metagenomics-dbs/ncbi_16s_18s/ref2taxid.targloci.tsv
curl -L -o new_taxdump.zip \
  https://ont-open-data.s3-eu-west-1.amazonaws.com/workflow-databases/wf-metagenomics-dbs/ncbi_16s_18s/new_taxdump_2025-01-01.zip
unzip -o new_taxdump.zip -d taxdump/

# (d) join ref2taxid + rankedlineage.dmp -> tax_lookup.tsv (accession<TAB>full_lineage)
python3 reference-db/bin/build_tax_lookup.py ref2taxid.tsv taxdump/rankedlineage.dmp \
  "$ASSETS_DIR/16s_minimap2/tax_lookup.tsv"
```

**`kraken2` mode:**

```bash
# Recommended default: 16S Silva 138 (most current SILVA in the frozen Langmead set)
mkdir -p "$ASSETS_DIR/16s_kraken2" && cd "$ASSETS_DIR/16s_kraken2"
curl -L -o 16S_Silva138.tgz \
  https://genome-idx.s3.amazonaws.com/kraken/16S_Silva138_20200326.tgz
tar -xzf 16S_Silva138.tgz
# Resulting directory: 16S_SILVA138_k2db/ — set params.kraken2_db to its full path.

# Alternative, matches ONT wf-16s's own kraken2 default exactly:
mkdir -p "$ASSETS_DIR/16s_kraken2/ncbi_16s_18s" && cd "$ASSETS_DIR/16s_kraken2/ncbi_16s_18s"
curl -L -o ncbi_targeted_loci_kraken2.tar.gz \
  https://ont-open-data.s3.amazonaws.com/workflow-databases/wf-metagenomics-dbs/ncbi_16s_18s/ncbi_targeted_loci_kraken2.tar.gz
tar -xzf ncbi_targeted_loci_kraken2.tar.gz
# Files land at the top level of this directory (no subdir wrap) — set params.kraken2_db to this path.
```

**`idtaxa` mode (opt-in, Variant A only) — identical to nf-edna's workflow:**

```bash
# gdown is not bundled by default. On PEP-668-managed systems (Debian/Ubuntu
# 24.04+), plain `pip install --user gdown` is blocked — use a venv or pixi
# env instead (see preflight SP6, which checks for gdown before this runs):
python3 -m venv /tmp/gdown_env && /tmp/gdown_env/bin/pip install -q gdown
/tmp/gdown_env/bin/gdown "1w3wdSCpSihntWkbP_zvXz7r3s-tNB8DV" \
  -O "$ASSETS_DIR/16s_idtaxa/SILVA_SSU_r138.2.rdata"
```

- ✅ PASS if: file(s) downloaded/built, size matches the catalog's expected size (within 5%)
- ⚠️ WARN if: size mismatch (could be a different/updated version at the source)
- ❌ FAIL if: download or build failed (HTTP error, timeout, disk full, `minimap2 -d` non-zero exit)

> **Recommend**: PASS → proceed to SP3 (validate). WARN → accept the version difference or re-download. FAIL → retry, or switch to the catalog's alternative source (e.g. NCBI FTP ⟷ EPI2ME S3 bundle for minimap2 mode; SILVA-138 ⟷ `ncbi_16s_18s` for kraken2 mode).
>
> Options:
> - **(A) Download/build succeeded, proceed to validation (Recommended)**
> - (B) Size mismatch — investigate
> - (C) Use the catalog's alternative source
> - (D) Abort

**Auto-pick when**: size within 5% of the catalog's expected value (or `minimap2 -d` exits 0 and the `.mmi` is non-empty) — auto-pick (A).

---

### SP3 — Validate

> **Evidence**: mode-specific load/sanity check.
>
> `minimap2` mode:
> ```bash
> pixi run --manifest-path runners/nextflow-runner/env/cluster/pixi.toml \
>   minimap2 -a "$ASSETS_DIR/16s_minimap2/16S_refseq.mmi" /dev/null > /dev/null \
>   && echo "MMI loads OK"
> # tax_lookup: spot-check a random accession has a non-empty lineage
> shuf -n 5 "$ASSETS_DIR/16s_minimap2/tax_lookup.tsv"
> ```
>
> `kraken2` mode:
> ```bash
> ls "$ASSETS_DIR/16s_kraken2/<db_dir>"/{hash,opts,taxo}.k2d  # all three must exist
> ```
>
> `idtaxa` mode — identical to nf-edna's check:
> ```bash
> pixi run --manifest-path runners/nextflow-runner/env/classification/pixi.toml \
>   Rscript runners/nextflow-runner/bin/idtaxa_rds.R \
>     --query_sequences /dev/null \
>     --idtaxa_model "$ASSETS_DIR/16s_idtaxa/SILVA_SSU_r138.2.rdata" \
>     --output_classification "$RUN_DIR/sanity_classification.tsv" \
>     --output_confidence "$RUN_DIR/sanity_confidence.tsv"
> ```

- ✅ PASS if: MMI loads / all three `.k2d` files present / IdTaxa model loads
- ⚠️ WARN if: `tax_lookup.tsv` has an unexpectedly high fraction of empty lineages (> 5% — indicates a taxdump/ref2taxid version mismatch)
- ❌ FAIL if: load error, missing `.k2d` file, or corrupted MMI

> **Recommend**: PASS → proceed to write `run_summary.json`. WARN → confirm or re-run the tax_lookup join with a fresher `new_taxdump`. FAIL → re-download/rebuild or switch source.
>
> Options:
> - **(A) Validation passed, proceed (Recommended)**
> - (B) High empty-lineage fraction — re-run the join with a fresh taxdump
> - (C) Re-download / rebuild
> - (D) Abort

**Auto-pick when**: validation passes cleanly — auto-pick (A).

---

## 1. Run State

After the active mode's stop points pass, write `run_summary.json`:

```json
{
  "skill": "reference-db",
  "version": "0.1.0",
  "run_id": "...",
  "classifier_mode": "minimap2",
  "reference_choice": "ncbi-targeted-loci-16s",
  "outputs": {
    "ref_mmi": "/home/user/data/nf-edna-nanopore/assets/16s_minimap2/16S_refseq.mmi",
    "tax_lookup": "/home/user/data/nf-edna-nanopore/assets/16s_minimap2/tax_lookup.tsv"
  },
  "sources": [
    "https://ftp.ncbi.nlm.nih.gov/refseq/TargetedLoci/Bacteria/bacteria.16SrRNA.fna.gz",
    "https://ftp.ncbi.nlm.nih.gov/refseq/TargetedLoci/Archaea/archaea.16SrRNA.fna.gz",
    "https://ont-open-data.s3-eu-west-1.amazonaws.com/workflow-databases/wf-metagenomics-dbs/ncbi_16s_18s/ref2taxid.targloci.tsv"
  ],
  "license": "Public domain (NCBI)",
  "completed_at": "2026-08-19T21:50:00Z"
}
```

(Adjust `classifier_mode`/`outputs`/`sources`/`license` per the active mode's actual choice — `kraken2` mode reports a single `kraken2_db` output path; `idtaxa` mode mirrors nf-edna's `run_summary.json` shape exactly.)

## 2. Troubleshooting — Signature library

| Signature in stderr / log | Likely cause | Suggested fix |
| --- | --- | --- |
| `minimap2 -d: ERROR: failed to open file` | FASTA path wrong or `zcat` step skipped | Re-check step (a) produced a valid, non-gzipped `.fna` before step (b) |
| `tax_lookup.tsv` mostly empty lineages | `ref2taxid.tsv` and `new_taxdump` are from different snapshot dates | Re-download both from the same EPI2ME bundle listing (`ncbi_16s_18s/`) so the taxid space matches |
| `curl: (28) Connection timed out` on `ont-open-data` S3 | Regional routing hiccup | Retry with `--retry 3 --retry-delay 5`; try the non-regioned `s3.amazonaws.com` hostname variant |
| `tar: unexpected end of file` (Kraken2 archive) | Truncated download | `curl -C -` to resume; verify size against the catalog table in the parent `SKILL.md` |
| Kraken2 `--db` errors "not a Kraken 2 database" | Extracted into a nested subdir, or wrong dir passed | `ls <dir>` — must show `hash.k2d`/`opts.k2d`/`taxo.k2d` directly, not one level down |
| `gdown: cannot retrieve file` (idtaxa mode) | Same as nf-edna's reference-db — file ID wrong or made private | Verify via the DECIPHER Downloads page; identical fix to nf-edna's `reference-db-run` §2 |

## 3. Related skills

- **`reference-db`** (parent) — invokes this sub-skill from SP0
- **`preflight/reference-db-preflight`** (prerequisite) — must pass verdict before this sub-skill runs
- **`nf-edna/reference-db-run`** — template source; also the exact workflow reused verbatim for `idtaxa` mode
- **`nf-edna-nanopore`** — downstream: consumes the reference for classification

## Verification

- [ ] `preflight_verdict.txt` was `GO` or `GO-WITH-WARNINGS` before any command was constructed (SP1).
- [ ] The exact command sequence for the active mode was shown to the user and explicitly confirmed.
- [ ] Downloaded/built file sizes match the catalog's expected values (within 5%).
- [ ] Mode-specific validation passed (MMI loads / `.k2d` triad present / IdTaxa model loads).
- [ ] `run_summary.json` was written at the end of the run.

## Invariants

- **Never** invoke a download or build command without showing it and waiting for explicit confirmation.
- **Never** skip the preflight sub-skill — its verdict gates this sub-skill.
- **Always** keep `ref2taxid.tsv` and `new_taxdump` from the same EPI2ME bundle snapshot — mixing dates produces empty lineages.
- **Always** use `gdown` (not `curl`) for the opt-in idtaxa mode's Google Drive download.
