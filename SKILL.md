---
name: nf-edna-nanopore
description: End-to-end agent orchestration of the nf-edna-nanopore Nextflow DSL2 pipeline for Nanopore-sequenced bacterial/archaeal 16S rRNA eDNA metabarcoding (partial ~350-600bp or full-length ~1500bp amplicons). Ships two selectable pipeline variants — `consensus` (cluster + medaka-polish reads into ASV-like representative sequences, then classify, reusing nf-edna's decontam/diversity/association stages) and `read_based` (classify every read directly, mirroring ONT's own wf-16s, no clustering). Use when the user has ONT/MinION/PromethION 16S amplicon reads — nf-edna's Illumina-oriented 16S preset (NGmerge PE-merge + VSEARCH UNOISE3 + IdTaxa) is not appropriate for single-read, higher-error ONT data. Builds on read-qc-trimming (raw-read QC upstream) and pairs with edna-gbif-publish / edna-visualize (Variant A only, downstream).
version: 0.1.0
updated: "2026-08-19"
triggers:
  - "Nanopore 16S metabarcoding"
  - "ONT 16S amplicon"
  - "MinION 16S eDNA"
  - "long-read 16S classification"
  - "full-length 16S nanopore"
  - "nf-edna-nanopore"
requires:
  - "Nextflow ≥ 23.10.0 (DSL2-compatible release)"
  - "Pixi (curl -fsSL https://pixi.sh/install.sh | bash) — manages per-stage tool envs under env/"
  - "git"
---

# Meta-Skill: nf-edna-nanopore

> **v0.1.0.** Initial version. Two Nextflow entry points under one skill:
> `main-consensus.nf` (Variant A) and `main-readbased.nf` (Variant B).
> Both share a Chopper/cutadapt/NanoPlot QC module. Variant A reuses
> nf-edna's `agglomerate_data.R`, `decontam.jl`, `filter_table.jl`,
> `diversity.nf`, `association.nf` unmodified — see the design spec at
> `docs/superpowers/specs/2026-08-19-nf-edna-nanopore-design.md` in this
> repo for the full rationale and tool-selection research.
> 
> **This SKILL.md is a router.** It does not duplicate logic from the
> sub-skills. Its job is to ask: *what stage is the user at, which
> pipeline variant do they want, and which sub-skill should they invoke
> next?*

## Audience

1. **AI Coding Agents** — triggered by the phrases above. Follow the
   evidence chain (Preflight → Run → Interpret), respect each
   sub-skill's decision points, and write `pipeline_state.json`,
   `run_summary.json`, and `<run_id>-report.md`.
2. **Human Users (eDNA scientists)** — read this document as a workflow
   guide explaining *why* each phase exists and *which variant fits your
   question*.

## When to Use This Skill

- You have **Nanopore-sequenced** (ONT/MinION/PromethION) 16S rRNA
  amplicon reads — partial-region (~350-600bp) or near/full-length
  (~1500bp) — and want ASVs/taxonomy/diversity out of them.
- You want to **compare** the two supported analysis strategies
  (consensus-clustering vs. per-read classification) on the same data.

**Do NOT use this skill** if:

- Your reads are **Illumina** short reads — use `nf-edna`'s `16s.json`
  preset instead; its NGmerge/UNOISE3/IdTaxa chain is calibrated for
  that error profile.
- You have **raw reads that have not been QC-trimmed** in the adapter
  sense (basecalled but un-demultiplexed, etc.) — demultiplex first;
  this skill's QC stage handles primer trimming + quality/length
  filtering, not basecalling or demultiplexing.
- Your marker is not 16S — this skill is 16S-only in v0.1.0.

## 0. Orchestrator — detect stage and variant, route to the right sub-skill

### 0.1 Locate the run directory

Same convention as `nf-edna`: `results/{run_id}/pipeline_state.json`.
Override with `RUN_DIR` or `--run-dir`.

### 0.2 Detect the user's stage

Same stage-detection ladder as `nf-edna` (see that skill's SKILL.md §0.2)
— no `pipeline_state.json` → `intake`; `classify` in `completed_stages`
→ `interpret`; otherwise → `run`.

### 0.3 Pipeline-variant selection (new vs. nf-edna)

Unlike `nf-edna`, this skill has a second axis: **which pipeline
variant**. This is decided once, at intake, and stored in
`pipeline_state.json.pipeline_variant`. It is NOT re-asked on later
invocations — `run/edna-nanopore-run` reads it from the state file.

| `pipeline_variant`    | Entry point         | When to recommend                                                                                                                                                                                                                                     |
| --------------------- | ------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `consensus` (default) | `main-consensus.nf` | Multi-species community samples where you want per-feature (ASV-like) sequences for decontam, phylogenetic diversity, geocuration, GBIF publishing.                                                                                                   |
| `read_based`          | `main-readbased.nf` | Quick screening, very high sample counts, or when clustering-parameter sensitivity is a concern. **Limitation:** no rep-seqs → no phylogenetic diversity, no decontam-by-sequence, no geocuration, no edna-visualize/edna-gbif-publish chaining (v1). |

### 0.4 Stage → sub-skill routing table

| Detected stage | Route to                                     | Output artifact                                                       |
| -------------- | -------------------------------------------- | --------------------------------------------------------------------- |
| `intake`       | `preflight/edna-nanopore-intake/SKILL.md`    | `results/{run_id}/pipeline_state.json` (includes `pipeline_variant`)  |
| `run`          | `run/edna-nanopore-run/SKILL.md`             | `results/{run_id}/{stage}_output/...` + updated `pipeline_state.json` |
| `interpret`    | `interpret/edna-nanopore-interpret/SKILL.md` | `results/{run_id}/<run_id>-report.md` + `narrative.md`                |

### Operating rule

> **Auto-pick when the evidence is unambiguous; ask when the agent
> genuinely cannot decide.** For the variant choice specifically: if the
> user's request names a variant explicitly ("read-based", "no
> clustering", "consensus", "ASV") or names a downstream need that only
> one variant supports (decontam, geocuration, GBIF publishing → forces
> `consensus`), auto-pick. Otherwise ask once at intake with the
> Evidence + Recommend + Options format, defaulting the recommendation to
> `consensus`.

## Description

Three phases, same shape as `nf-edna`:

1. **`preflight/edna-nanopore-intake`** — gather run parameters
   (primer pair, min/max length, `pipeline_variant`, classifier mode,
   metadata, run_id), validate inputs, write `pipeline_state.json`.
2. **`run/edna-nanopore-run`** — read `pipeline_state.json`, construct
   and execute the correct `nextflow run main-<variant>.nf -params-file
   params/16s-nanopore.json -params-file ...` command, monitor progress,
   update state after each stage.
3. **`interpret/edna-nanopore-interpret`** — read `run_summary.json`,
   produce `<run_id>-report.md` + `narrative.md`, note in the report
   which variant was used and its documented limitations.

## Prerequisites

- **Nextflow ≥ 23.10.0**, **Pixi**, **git** — same as `nf-edna`.
- **Reference assets** — a 16S reference minimap2 index (`params.ref_mmi`,
  e.g. built from NCBI RefSeq Targeted Loci) + taxonomy lookup TSV
  (`params.tax_lookup`) for the default `minimap2` classifier mode; a
  Kraken2 DB for `classifier: "kraken2"`; a trained IdTaxa `.rds` for the
  opt-in `classifier: "idtaxa"` mode — Variant A only. Run this repo's own
  `reference-db/` sub-skill first if you don't have these yet — it covers
  all three modes (chain to `nf-edna`'s `idtaxa-training` only if you want
  a custom-trained, non-SILVA IdTaxa model).
- **`medaka_model`** (Variant A) — set to match your flow cell chemistry
  and basecaller mode (e.g. `r1041_e82_400bps_sup_v5.0.0`); there is no
  universal default.

## Marker preset (`params/`)

| Preset              | Marker | Length range (run-time override)                                                                 | Kingdoms          | Geocurate                    |
| ------------------- | ------ | ------------------------------------------------------------------------------------------------ | ----------------- | ---------------------------- |
| `16s-nanopore.json` | 16S    | 350-1600 bp default; set `min_length`/`max_length` per run for partial vs. full-length amplicons | Bacteria, Archaea | off (Variant A only, opt-in) |

Unlike `nf-edna`'s four hardcoded per-marker presets, this skill uses a
**single flexible preset** — partial (~600bp) and full-length (~1500bp)
16S are both "16S", just with different `min_length`/`max_length`
supplied at intake, not different marker files.

## Output artifacts

```
results/{run_id}/
├── pipeline_state.json           ← includes pipeline_variant
├── run.log
├── qc_output/                    ← Chopper + cutadapt + NanoPlot (shared)
├── cluster_output/                ← Variant A only: minimap2 selfmap + yacrd + medaka consensus
├── asv_table/                    ← Variant A only: ASV-like feature table + rep-seqs
├── taxonomy/                     ← both variants: classification (minimap2-LCA / kraken2 / idtaxa[A only])
├── diversity_output/              ← Variant A only (v1)
├── association_output/            ← Variant A only (v1)
├── run_summary.json
├── <run_id>-report.md
└── narrative.md
```

## Composability with other AiX-BIO skills

| Skill                                       | When to chain                                                                                                                                                                                                                                                |
| ------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `read-qc-trimming`                          | Not typically needed before this skill — ONT basecalled reads don't need Illumina-style adapter trimming; this skill's own QC module does primer trimming + quality/length filtering. Only chain it if your reads need additional platform-specific cleanup. |
| `reference-db` (this repo: `reference-db/`) | Run **before** the first-ever nf-edna-nanopore run if you don't yet have `ref_mmi`+`tax_lookup` (default), `kraken2_db` (alt), or `idtaxa_model` (opt-in). Catalog + download/build workflow for all three classifier modes.                                 |
| `nf-edna`                                   | Reference for the reused downstream `bin/`+`modules/` (diversity, association, decontam, agglomerate) and for `idtaxa-training` if the opt-in IdTaxa mode needs a custom-trained (non-SILVA) model instead of this skill's `reference-db`.                   |
| `edna-visualize`                            | Variant A only.                                                                                                                                                                                                                                              |
| `edna-gbif-publish`                         | Variant A only, after `interpret/edna-nanopore-interpret`.                                                                                                                                                                                                   |

## What NOT to do

- Do **not** skip `preflight/edna-nanopore-intake` — `pipeline_variant`
  must be resolved before `run/edna-nanopore-run` can pick an entry
  point.
- Do **not** run Variant B and then expect decontam/diversity/
  geocuration/GBIF-publish outputs — they are not produced in v1.
- Do **not** delete `pipeline_state.json` mid-run.
- Do **not** commit `assets/`, `results/`, `work/`, `.nextflow.log*`,
  `*.fq.gz`.

## Handoff

- **Manuscript writing** → `literature-pipeline`.
- **GBIF publishing** (Variant A only) → `edna-gbif-publish`.
- **Comparing variants** → run both with the same `run_id` prefix and a
  `_consensus`/`_readbased` suffix; `interpret/edna-nanopore-interpret`
  can be invoked twice and the two `narrative.md`s compared manually.
