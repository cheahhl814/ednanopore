---
name: reference-db
description: Curated catalog of reference-database sources for ednanopore's classifiers — for 16S: NCBI RefSeq Targeted Loci (minimap2 MMI + taxonomy lookup TSV, the default `minimap2` classifier), pre-built Kraken2 16S indexes (the `kraken2` alt classifier), and SILVA DECIPHER IdTaxa (the opt-in `idtaxa` classifier); since v0.5.0 also non-16S markers — 18S (SILVA/PR2 + the same SILVA SSU IdTaxa model), 12S (MitoHelper/MitoFish), COI (MIDORI2 CC-BY-NC / BOLD), ITS (UNITE), all retrieved via the biodb-fetch dependency skill (github.com/cheahhl814/biodb-fetch — scripts/marker_refs.py + manifest.tsv contract); this sub-skill keeps curation (which URL/version/license), local index building (minimap2 -d, tax_lookup join, IdTaxa model placement), and verdict gating. Mirrors the BettaMt ask-user-stop-points pattern. Use when the user asks to "get a reference for ednanopore", "download the 16S minimap2 index", "get an 18S/12S/COI/ITS reference", "where do I get the reference for the Nanopore pipeline", or "build the tax_lookup TSV".
version: 0.5.1
updated: "2026-10-07"
triggers:
  - "reference for ednanopore"
  - "download 16S minimap2 index"
  - "get NCBI Targeted Loci 16S"
  - "download Kraken2 16S database"
  - "build tax_lookup TSV"
  - "where do I get the Nanopore 16S reference"
  - "reference-db nanopore"
requires:
  - "biodb-fetch skill, deployed as a sibling skill (its pixi env provides the fetch runtime: requests, gdown, biopython, ncbi-datasets-cli). Every download in the run sub-skill goes through its `scripts/marker_refs.py` / `scripts/ncbi_fetch.py` under the manifest.tsv contract — verify `contract_version` before consuming any fetch output"
  - "Internet access (via biodb-fetch: ftp.ncbi.nlm.nih.gov, ont-open-data S3, genome-idx.s3.amazonaws.com, drive.google.com for the opt-in IdTaxa mode)"
  - "Disk space: 16S_refseq FASTA + MMI ~50 MB; Kraken2 16S DB 9 MB (ncbi_16s_18s) to 300 MB (SILVA-based); opt-in IdTaxa SILVA file ~300 MB"
  - "minimap2, from this skill's root pixi.toml `cluster` env (for building the MMI from FASTA)"
  - "Optional: pixi env with DECIPHER (only for the opt-in idtaxa classifier mode)"
---

# Sub-Skill: reference-db (ednanopore)

> **v0.3.0.** Adapted from `nf-edna/reference-db` (v1.1.4). That original catalog is DECIPHER/IdTaxa-only — this pipeline's *default* classifier is `minimap2` (LCA against a reference MMI), with `kraken2` as a fast alt and `idtaxa` as an opt-in third mode. This SKILL.md carries three catalog sections instead of one, structured the same way (canonical source → download → build/validate → license/cadence).
> **v0.3.0 change:** download execution is now DELEGATED to the **biodb-fetch** dependency skill (github.com/cheahhl814/biodb-fetch) — this sub-skill remains the curation + local-build layer. See §0.6.
>
> **This SKILL.md is a router + catalog.** It does not duplicate download logic from the sub-skills. Its job is to answer: *which classifier mode is the user targeting, and what reference does that mode need?*

## Audience

1. **AI Coding Agents** — triggered by the phrases above. Follow the evidence chain (Preflight → Run), respect the ask-user stop points, and never silently pick a reference — the classifier mode (`minimap2` / `kraken2` / `idtaxa`) constrains the choice.
2. **Human Nanopore eDNA scientists** — read this document as a curated catalog. The tables below give the canonical URL, size, license, and build commands for each classifier's reference.

## When to Use This Skill

Use this sub-skill when you need to:

- Get the **default classifier's reference** — a minimap2 MMI + `tax_lookup` TSV built from NCBI RefSeq Targeted Loci 16S (§1).
- Get a **pre-built Kraken2 16S database** for `params.classifier: "kraken2"` (§2).
- Get the **opt-in IdTaxa reference** for `params.classifier: "idtaxa"` (§3 — SILVA SSU r138.2; the stock DECIPHER-pre-trained model covers BOTH 16S and 18S).
- Get a reference for a **non-16S marker** — 18S, 12S (MiFish), COI (MIDORI2/BOLD), ITS (UNITE) — from the per-marker catalog (§4, [`CATALOG_SECTION_NON16S.md`](CATALOG_SECTION_NON16S.md)).
- Decide which classifier mode fits your use case before committing to a reference download.

**Do NOT use this skill** if:

- You already have the reference files in place — invoke `preflight/ednanopore-intake` directly, which will only redirect here if a reference path is missing.
- You want a DECIPHER-trained reference for a marker other than 16S, or the Illumina pipeline — use `nf-edna`'s `reference-db` instead.
- You want to train a *custom* IdTaxa model from a raw FASTA (not SILVA) — chain to `idtaxa-training` (in `nf-edna`) directly.

## 0. Orchestrator — detect classifier mode, route to the right catalog section

### 0.1 Locate the run directory

By convention, evidence/handoff files go to a timestamped directory at the project root, or `$RUN_DIR` if set — same convention as `nf-edna`'s `reference-db`.

### 0.5 Master ask-user stop point (SP0)

> **Evidence**: I observed the user wants a 16S reference for ednanopore. I checked `pipeline_state.json` (if it exists) for `params.classifier`.
> **Recommend**: If `classifier` is already set in `pipeline_state.json`, auto-pick that section's catalog. Otherwise recommend `minimap2` (the pipeline default, §1) unless the user's downstream need points elsewhere (e.g. they mentioned Kraken2 speed, or explicitly want phylogenetically placed IdTaxa trees).
>
> Options:
> - **(A) minimap2 default — NCBI RefSeq Targeted Loci MMI + tax_lookup TSV (Recommended)**
> - (B) kraken2 alt — pre-built Kraken2 16S database
> - (C) idtaxa opt-in — SILVA DECIPHER pre-trained file (Variant A / consensus only)

**Auto-pick when**: `pipeline_state.json` already has `params.classifier` set — use that value's section without asking.

## 0.6 biodb-fetch delegation (v0.3.0)

Following biodb-fetch's division of responsibilities: **curation stays here** (which URL / which version / which license — the three catalog sections above), **download execution, md5, retries, manifest rows and Google-Drive-via-gdown go to biodb-fetch's `run/markers-reference` module** (`scripts/marker_refs.py`), and **NCBI record/gene fetches go to its `scripts/ncbi_fetch.py`/`ncbi_datasets.py`**.

```bash
# Resolve biodb-fetch's install root (sibling of this skill); set BIOFETCH accordingly:
#   BIOFETCH=~/.agents/skills/biodb-fetch        # deployed skill dir
BIOFETCH="<path-to-biodb-fetch>"

# RefSeq Targeted Loci FASTA (minimap2 mode, curated URLs in §1) — generic-url fetch,
# manifest rows land in <outdir>/manifest.tsv with md5 + contract_version:
pixi run --manifest-path "$BIOFETCH/pixi.toml" python3 scripts/marker_refs.py url \
    --url https://ftp.ncbi.nlm.nih.gov/refseq/TargetedLoci/Bacteria/bacteria.16SrRNA.fna.gz \
    --source ncbi-refseq-targeted-loci

# EPI2ME ref2taxid + taxdump bundle (kraken2/minimap2 modes) — same `url` key:
pixi run --manifest-path "$BIOFETCH/pixi.toml" python3 scripts/marker_refs.py url \
    --url https://ont-open-data.s3.amazonaws.com/workflow-databases/wf-metagenomics-dbs/ncbi_16s_18s/ref2taxid.targloci.tsv \
    --source ont-epi2me-ncbi-16s-18s

# Pre-built Kraken2 16S indexes (kraken2 mode, §2):
pixi run --manifest-path "$BIOFETCH/pixi.toml" python3 scripts/marker_refs.py url \
    --url https://genome-idx.s3.amazonaws.com/kraken/16S_Silva138_20200326.tgz \
    --source kraken2-16s-silva138

# SILVA DECIPHER pre-trained IdTaxa model (idtaxa mode, §3) — Google Drive, gdown
# is INSIDE biodb-fetch's env (no venv hack, no PEP-668 workaround):
pixi run --manifest-path "$BIOFETCH/pixi.toml" python3 scripts/marker_refs.py decipher \
    --drive-id 1w3wdSCpSihntWkbP_zvXz7r3s-tNB8DV
```

**Local steps that stay in this skill** (not delegated): `minimap2 -d` MMI build, the `ref2taxid`↔`new_taxdump` join into `tax_lookup.tsv`, `bin/idtaxa_rds.R` placement checks, and the Kraken2 archive extraction/verify. biodb-fetch's output manifest (`contract_version`, md5, bytes, retrieval_date) must be copied/registered next to the consumed files; verify `contract_version` matches the value in its `scripts/dbaccess_common.py` before declaring `run_summary.json`.

If `biodb-fetch` is not deployed as a sibling skill, STOP and tell the user to deploy it (`git clone https://github.com/cheahhl814/biodb-fetch`, then pixi-resolve its `pixi.toml`) — do NOT fall back to raw `curl`/manual `gdown`; that path predates v0.3.0 and drops the manifest contract.

## 1. NCBI RefSeq Targeted Loci → minimap2 MMI + tax_lookup TSV (default: `classifier: "minimap2"`)

See the full section: [`CATALOG_SECTION_TARGETED_LOCI.md`](CATALOG_SECTION_TARGETED_LOCI.md) — reproduced inline below for the catalog view.

NCBI RefSeq Targeted Loci is the canonical 16S rRNA reference for bacterial + archaeal type-material sequences (public domain, US Government work). Mirrors what ONT's own `wf-16s` bundles as its `ncbi_16s_18s` default DB.

| Source | URL | Size | License |
|---|---|---|---|
| NCBI FTP (raw FASTA, Bacteria) | `https://ftp.ncbi.nlm.nih.gov/refseq/TargetedLoci/Bacteria/bacteria.16SrRNA.fna.gz` | 7.7 MB | Public domain |
| NCBI FTP (raw FASTA, Archaea) | `https://ftp.ncbi.nlm.nih.gov/refseq/TargetedLoci/Archaea/archaea.16SrRNA.fna.gz` | 294 KB | Public domain |
| EPI2ME bundle (matches wf-16s: FASTA + `ref2taxid.targloci.tsv` + `new_taxdump`) | `https://ont-open-data.s3-eu-west-1.amazonaws.com/workflow-databases/wf-metagenomics-dbs/ncbi_16s_18s/` | ~40 MB combined | Public domain |
| GTDB (alternative, bacterial 16S only, no archaea) | `https://data.gtdb.ecogenomic.org/releases/release226/226.0/` | 97.8 MB (taxonomy) | Free academic/non-commercial |

Build pipeline: download FASTA → `minimap2 -d 16S_refseq.mmi -x map-ont 16S_refseq.fna` → derive `tax_lookup.tsv` by joining the EPI2ME bundle's `ref2taxid.targloci.tsv` against `new_taxdump/rankedlineage.dmp`. Full commands in `run/reference-db-run/SKILL.md` §2 and the catalog fragment linked above. NCBI's `datasets` CLI does **not** cover the Targeted Loci sub-project — use FTP or the EPI2ME bundle, not `datasets`.

## 2. Pre-built Kraken2 16S database (alt: `classifier: "kraken2"`)

See the full section: [`CATALOG_SECTION_KRAKEN2_16S.md`](CATALOG_SECTION_KRAKEN2_16S.md) — reproduced inline below.

| Collection | Source | Size | Build date | License |
|---|---|---|---|---|
| **16S Silva 138 (Recommended)** | Ben Langmead's k2 index collection | 112 MB | 2020-03-26 (frozen) | SILVA dual-license |
| 16S Greengenes 13.5 | Ben Langmead's k2 index collection | 72 MB | 2020-03-26 (frozen) | Free non-commercial |
| 16S RDP 11.5 | Ben Langmead's k2 index collection | 172 MB | 2020-03-26 (frozen) | Free non-commercial |
| `ncbi_16s_18s` (matches ONT wf-16s default) | ONT open-data S3 | 8.6 MB | 2026-01-21 (rebuilt with wf-16s releases) | Public domain |
| `SILVA_138_1` (Kraken2-built) | ONT open-data S3 | 297 MB | 2026-01-21 | SILVA dual-license |

Download + extract, then set `params.kraken2_db` to the resulting directory (must contain `hash.k2d`, `opts.k2d`, `taxo.k2d`). Full commands in `run/reference-db-run/SKILL.md` §3 and the catalog fragment linked above. A `kraken2-build --download-library` fallback is documented there for users who want a fully custom DB.

## 3. SILVA DECIPHER IdTaxa (opt-in: `classifier: "idtaxa"`, Variant A / consensus only)

Identical to nf-edna's `reference-db` §1.1 first row — reused unchanged, since `classify_consensus.nf`'s opt-in idtaxa mode calls the byte-for-byte-copied `bin/idtaxa_rds.R` against the same file format.

| Variant | URL | Size | Format | License |
|---|---|---|---|---|
| SILVA SSU r138.2 (DECIPHER pre-trained, modified) | `https://drive.google.com/file/d/1w3wdSCpSihntWkbP_zvXz7r3s-tNB8DV/view?usp=sharing` | 299 MB | RDX3 (XZ-compressed) | SILVA dual-license |

Download via biodb-fetch's `decipher` key (§0.6 — gdown runs inside its env). Set `params.idtaxa_model` to the downloaded path. **Not applicable to Variant B (read_based)** — idtaxa needs polished consensus sequences, not raw noisy reads.

## 4. Non-16S markers: 18S / 12S / COI / ITS (v0.5.0)

See the full section: [`CATALOG_SECTION_NON16S.md`](CATALOG_SECTION_NON16S.md).

Marker → source → biodb-fetch retrieval key routing (curation below, retrieval executed by biodb-fetch per §0.6):

| Marker | Reference | biodb-fetch key | IdTaxa? |
|---|---|---|---|
| 18S (full + V9) | SILVA 18S subset / PR2 | `silva` / `pr2` | ✅ stock SILVA SSU model (§3, shared with 16S — do not retrain) |
| 12S (MiFish-class) | MitoHelper / MitoFish (Zenodo v42) | `mitohelper --doi-id 17602902` | opt-in only — custom training via `nf-edna/idtaxa-training` |
| COI | MIDORI2 (CC-BY-NC, gated) or BOLD per-taxon | `midori2 --i-accept-license` / `bold --taxon <T>` | opt-in only — custom training |
| ITS | UNITE v10.2+ (PlutoF DOI-pinned) | `unite --version 10.2 ...` | opt-in only — custom training |

Default classifier for 12S/COI/ITS is **minimap2-LCA**; the marker presets
(`runners/manual-runner/defaults/*.json`) encode this in their `consensus.classifier`
field. Building the MMI + `tax_lookup` after each fetch works identically to
the 16S flow in `run/reference-db-run/SKILL.md` §2.

## 4b. Where downloaded files go

```
$ASSETS_DIR/                              # e.g. your project data area/ednanopore/assets/
├── 16s_minimap2/
│   ├── 16S_refseq.mmi                      # minimap2 index (default classifier)
│   └── tax_lookup.tsv                      # accession -> lineage TSV
├── 16s_kraken2/
│   └── 16S_SILVA138_k2db/                  # or ncbi_16s_18s/, etc.
│       ├── hash.k2d
│       ├── opts.k2d
│       └── taxo.k2d
├── 16s_idtaxa/                             # shared stock model — covers BOTH 16S and 18S
│   └── SILVA_SSU_r138.2.rdata
├── 18s_minimap2/                           # v0.5.0 — per-marker dirs mirror 16s_*
│   ├── 18S_refseq.mmi                      # e.g. PR2 or SILVA-18S-derived MMI
│   └── tax_lookup.tsv
├── 12s_minimap2/                           # v0.5.0 — MitoHelper/MitoFish-derived
│   ├── 12S_mitofish.mmi
│   └── tax_lookup.tsv
├── coi_minimap2/                           # v0.5.0 — MIDORI2/BOLD-derived
│   ├── COI_midori.mmi
│   └── tax_lookup.tsv
├── its_minimap2/                           # v0.5.0 — UNITE-derived
│   ├── ITS_unite.mmi
│   └── tax_lookup.tsv
└── coi_idtaxa/                             # custom-trained models (opt-in), one dir per marker
    └── COI_<source>_idtaxa.rds            # trained via nf-edna/idtaxa-training
```

Per-marker naming convention: `$ASSETS_DIR/<marker>_<mode>/` — intake SP3
validates the path the preset's `ref_db` implies; run_summary.json records
what was fetched (via biodb-fetch's manifest.tsv) and what was built locally.

## 5. Quick start

```bash
# 1. Preflight — confirms classifier mode, checks disk + connectivity
invoke_skill preflight/reference-db-preflight

# 2. Run — downloads (and builds, for the minimap2 MMI) the reference
invoke_skill run/reference-db-run

# Outputs:
#   reference_db_verdict.txt  — GO / GO-WITH-WARNINGS / NO-GO
#   preflight_evidence.json   — structured evidence for the run sub-skill
#   run_summary.json          — what was downloaded/built (URL, size, sha256 if available, format)
#   <ASSETS_DIR>/16s_<mode>/... — the reference file(s) in canonical location
```

## 6. Sub-skills

### Preflight (validate classifier mode, disk, connectivity)

→ `preflight/reference-db-preflight/SKILL.md`

### Run (download + build/validate)

→ `run/reference-db-run/SKILL.md`

## 7. Where this fits in the wider skill graph

```mermaid-like
                 ┌──────────────────────┐
                 │   biodb-fetch         │  (dependency skill — download execution, manifest.tsv)
                 └───────────┬───────────┘
                              │ fetched FASTA/taxdump/Kraken2 tar / SILVA .rdata
                              ▼
                 ┌──────────────────────┐
                 │   reference-db        │  (this skill — curation + local index build)
                 │   (ednanopore)  │
                 └───────────┬───────────┘
                              │ MMI+TSV (default) / Kraken2 dir (alt) / SILVA .rdata (opt-in)
                              ▼
                 ┌──────────────────────┐
                 │   ednanopore    │  ← main pipeline (uses the reference)
                 └──────────────────────┘
                              ▲
                              │ (idtaxa mode only, chains to)
                 ┌────────────┴──────────┐
                 │ nf-edna/idtaxa-training│  ← trains a custom raw FASTA -> DECIPHER .rds, if needed
                 └────────────────────────┘
```

- **Upstream**: `biodb-fetch` (download execution, manifest.tsv contract) — deploy as a sibling skill before any reference fetch (see §0.6).
- **Downstream**: `ednanopore` consumes the reference for classification (either variant).
- **Parallel**: `nf-edna/idtaxa-training` is invoked only if the user wants a custom-trained IdTaxa model instead of the stock SILVA one.

## 8. Related skills

- **`ednanopore`** (parent pipeline) — consumes `ref_mmi`+`tax_lookup` (default), `kraken2_db` (alt), or `idtaxa_model` (opt-in, Variant A only)
- **`nf-edna/reference-db`** — sibling for the Illumina pipeline; source of the reused SILVA/IdTaxa catalog row and the BettaMt template this sub-skill mirrors
- **`nf-edna/idtaxa-training`** — invoked only for the opt-in idtaxa mode if a custom (non-SILVA) reference is wanted

## Verification

- [ ] `preflight/reference-db-preflight/SKILL.md` produces a `GO` / `GO-WITH-WARNINGS` verdict before any download command is invoked.
- [ ] The exact `curl`/`minimap2 -d`/`tar` command for the chosen classifier mode was shown to the scientist and explicitly confirmed.
- [ ] For the `minimap2` mode: the built `.mmi` loads (via a minimap2 dry-run) and `tax_lookup.tsv` has a non-empty lineage for a random sample of accessions.
- [ ] For the `kraken2` mode: the extracted directory contains `hash.k2d`, `opts.k2d`, `taxo.k2d`.
- [ ] For the `idtaxa` mode: the file loads via `bin/idtaxa_rds.R` (same check as nf-edna's `reference-db`).
- [ ] `run_summary.json` was written at the end of the run.

## Invariants

- **Never** invoke a download/build command without showing the full command and waiting for explicit confirmation.
- **Never** skip the preflight sub-skill — its verdict gates the run sub-skill.
- **Always** surface the license for the chosen reference (SILVA dual-license and Greengenes/RDP non-commercial terms need explicit acceptance; NCBI/public-domain sources do not).
- **Always** check `pipeline_state.json.params.classifier` before recommending a catalog section — never default to `minimap2` if the user's run is already configured for a different mode.
