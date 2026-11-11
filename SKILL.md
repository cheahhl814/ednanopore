---
name: ednanopore
description: Agent orchestration of the ednanopore manual pipeline (no Nextflow) for Nanopore eDNA metabarcoding, multi-marker since v0.5.0 — 16S, 18S, 12S, COI and ITS, each with a bundled marker preset (validated length windows, kingdoms, biodb-fetch retrieval keys). Runs three complementary classification methods by default — readbased+minimap2/LCA (species-level), readbased+IdTaxa/SILVA (genus-level ceiling) and consensus+medaka-polish+classification (error-corrected) — as no single method suffices. References are DELEGATED to the biodb-fetch dependency skill (download, md5, retries, license gating); this skill keeps catalog curation + local index-building; 12S/COI/ITS default to minimap2-LCA, custom-trained IdTaxa opt-in. Use for ONT/MinION/PromethION amplicon reads of any bundled marker — ONT-native, unlike nf-edna's Illumina NGmerge + VSEARCH UNOISE3 chain. Builds on read-qc-trimming (upstream); pairs with edna-gbif-publish / edna-visualize (downstream; consensus outputs of GBIF-publishable markers only).
version: 0.6.0
updated: "2026-11-11"
triggers:
  - "Nanopore 16S metabarcoding"
  - "ONT 16S amplicon"
  - "MinION 16S eDNA"
  - "long-read 16S classification"
  - "full-length 16S nanopore"
  - "ednanopore"
skills:
  - "biodb-fetch"
requires:
  - "Pixi (curl -fsSL https://pixi.sh/install.sh | bash) — single root pixi.toml with per-stage [feature.<env>] entries; run tools with `pixi run --manifest-path <skill-root>/pixi.toml -e <env>`"
  - "biodb-fetch skill (github.com/cheahhl814/biodb-fetch, deployed as a sibling skill) — dependency skill; owns reference-database download execution under the manifest.tsv contract (contract_version is verified by this skill's reference-db sub-skill)"
  - "git"
---

# Meta-Skill: ednanopore

> **v0.6.0.** Cross-skill adoption from edna-agent v1.3.x (see
> `CHANGELOG.md`): optional **cross-method comparison mode**
> (`bin/compare_classifications.R` — per-read rank agreement for
> minimap2-vs-IdTaxa on the same trimmed reads, abundance-lineage
> side-by-side to fold in consensus; ask-user SP5 in interpret, preset
> via `params.json.classification_comparison`); **SP6 —
> reference-coverage collapse gate** in the run stage (stop and audit
> reference coverage, never retry a collapsed stage with looser
> thresholds); interpret fills — **Pielou evenness** in alpha diversity,
> **rarefaction curves** (`bin/rarefaction.R`, env `diversity`),
> **ANCOM-BC + Maaslin2 differential abundance run side by side, never
> averaged** (`bin/ancombc_differential.R`, env `association`).
>
> **v0.3.0.** Structural rebuild on the skill-forge v1.4.0 standard
> (single root `pixi.toml` with per-stage `[feature.<env>]`/`[environments]` entries,
> `bin/skill-update-check.py` self-update check, `docs-corpus/`, deterministic
> `test-data/` fixtures, run-artifact gitignore) and **biodb-fetch wired in as the
> dependent database-retrieval skill**: `reference-db/` curates *which* reference
> (URL, version, license) and builds the MMI/tax-lookup/IdTaxa artifacts locally,
> while `biodb-fetch` (github.com/cheahhl814/biodb-fetch) *executes every download*
> under its manifest.tsv contract (`scripts/marker_refs.py`: `unite`/`bold`/`mitohelper`/
> `silva`/`pr2`/`midori2`/`decipher`/`url` retrieval keys with md5 + license gating).
>
> **Pipeline behavior is unchanged from v0.2.0** (still agent-manual, still three
> classification methods by default, still no Nextflow): an agent invokes
> `runners/manual-runner/bin/run_*.sh` scripts directly via the Bash tool, one stage
> at a time, confirming each command with the scientist before running it. This mirrors
> how every validated run of this pipeline actually ended up being executed in
> practice (see `CHANGELOG.md`'s "Bugs 28-30" framing note: 27 bugs
> deep into the Nextflow orchestrator, retries moved to direct shell
> invocation of the same underlying tool scripts and never looked back).
>
> The other major change: v0.1.0 made the scientist choose one of two
> mutually-exclusive "variants" (`consensus` vs. `read_based`) up front.
> **v0.2.0 runs three classification methods by default, not one** — see
> `run/ednanopore-run/SKILL.md`'s "Why three methods, not one" section.
> A real cross-method comparison on this project's dataset found a 3.6%
> / 9.4% / 19.3% spread for one phylum's abundance across the three
> methods, on identical samples — a gap invisible to anyone running only
> one method, and only decomposable (reference-coverage effect vs.
> clustering-amplification effect) by running the one method that isolates
> the two factors. Treat large method disagreements as findings, not noise.
>
> **This SKILL.md is a router.** It does not duplicate logic from the
> sub-skills. Its job is to ask: *what stage is the user at, and which
> sub-skill should they invoke next?* There is no variant-selection
> question anymore — intake no longer asks "which variant," because the
> default is "all three."

## Audience

1. **AI Coding Agents** — triggered by the phrases above. Follow the
   evidence chain (Preflight → Run → Interpret), respect each
   sub-skill's decision points, and write `pipeline_state.json`,
   `run_summary.json`, and `<run_id>-report.md`.
2. **Human Users (eDNA scientists)** — read this document as a workflow
   guide explaining *why* each phase exists and *why three methods run by
   default instead of one*.

## When to Use This Skill

- You have **Nanopore-sequenced** (ONT/MinION/PromethION) amplicon reads of a
  bundled marker — **16S** (partial ~350-600bp or near/full-length 1400-1850bp,
  Bacteria/Archaea), **18S** (full-length or V9/Euka02-class short fragments,
  Eukaryota), **12S** (MiFish-class, Vertebrata), **COI** (Metazoa), or **ITS**
  (Fungi) — and want taxonomy/abundance out of them, cross-validated
  across methods rather than trusting a single classifier+reference
  combination.
- (Since v0.5.0) Your marker is *not* in that list but you have primers + a
  length window: intake's SP2b scaffolds a new per-marker preset from the
  nearest existing one — no code changes needed.

**Do NOT use this skill** if:

- Your reads are **Illumina** short reads — use `nf-edna`'s marker presets
  instead; its NGmerge/UNOISE3/IdTaxa chain is calibrated for that error
  profile.
- You have **raw reads that have not been QC-trimmed** in the adapter
  sense (basecalled but un-demultiplexed, etc.) — demultiplex first;
  this skill's QC stage handles primer trimming + quality/length
  filtering, not basecalling or demultiplexing.
- (Pre-v0.5.0 behavior was 2S-only; multi-marker support is new — for
  12S/COI/ITS the IdTaxa-based methods need a custom-trained model
  (chain `nf-edna/idtaxa-training`); expect minimap2-LCA to be the
  default classifier for those markers, per the marker presets.)

## 0. Orchestrator — detect stage, route to the right sub-skill

### 0.1 Locate the run directory

`results/{run_id}/pipeline_state.json`. Override with `RUN_DIR` or
`--run-dir`.

### 0.2 Detect the user's stage

No `pipeline_state.json` → `intake`. `completed_stages` includes all
three classification methods (or the subset the scientist explicitly
chose to run, per intake's SP) → `interpret`. Otherwise → `run`.

### 0.3 Stage → sub-skill routing table

| Detected stage | Route to | Output artifact |
| --- | --- | --- |
| `intake` | `preflight/ednanopore-intake/SKILL.md` | `results/{run_id}/pipeline_state.json` |
| `run` | `run/ednanopore-run/SKILL.md` | `results/{run_id}/{method}/...` + updated `pipeline_state.json` |
| `interpret` | `interpret/ednanopore-interpret/SKILL.md` | `results/{run_id}/<run_id>-report.md` + `narrative.md`, including a cross-method comparison section |

### Operating rule

> **Auto-pick when the evidence is unambiguous; ask when the agent
> genuinely cannot decide.** There is no variant choice to ask about
> anymore — default to running all three methods. Only ask (at intake,
> once) if the scientist's request already implies skipping one (e.g.
> they explicitly ask for "just consensus" or "quick screening only") —
> and even then, state the blind-spot cost of skipping before agreeing.

## Description

Three phases:

1. **`preflight/ednanopore-intake`** — gather run parameters
   (primer pair, min/max length, classifier-specific reference paths,
   metadata, run_id, sample manifest), validate inputs, write
   `pipeline_state.json`. No `pipeline_variant` field anymore — intake
   resolves parameters for all three methods unless the scientist opts
   out of one.
2. **`run/ednanopore-run`** — read `pipeline_state.json`, run
   `runners/manual-runner/bin/run_qc.sh` then the three
   `run_{method}.sh` scripts (each shown to and confirmed by the
   scientist before execution), monitor progress, update state after
   each stage.
3. **`interpret/ednanopore-interpret`** — read `run_summary.json`,
   produce `<run_id>-report.md` + `narrative.md`, including a
   cross-method comparison table and explicit callouts for any large
   (>2x) disagreements between methods.

## Prerequisites

- **Pixi**, **git**. No Nextflow, no Java — removed as dependencies in
  v0.2.0.
- **Reference assets** — a 16S reference minimap2 index
  (`ref_mmi`) + taxonomy lookup TSV (`tax_lookup`) for
  `readbased_minimap2`; a trained IdTaxa `.RData`/`.rds` for
  `readbased_idtaxa` and `consensus_idtaxa` (both use the same SILVA
  model by default). Run this repo's own `reference-db/` sub-skill first
  if you don't have these yet.
- **`medaka_model`** (consensus method only) — set to match your flow
  cell chemistry and basecaller mode (e.g.
  `r1041_e82_400bps_sup_v5.0.0`); there is no universal default.

## Marker presets (`runners/manual-runner/defaults/`)

One JSON preset per marker — consumed by intake's SP2 (marker normalization +
preset discovery, SP2b for unlisted markers). Full field conventions in
`runners/manual-runner/defaults/README.md`.

| Preset | Marker | Length window (run-time override) | Kingdoms | Reference retrieval (biodb-fetch key) |
| --- | --- | --- | --- | --- |
| `16s-nanopore.json` | 16S | 450-1600 bp; full-length runs 1400-1700 | Bacteria, Archaea | `url`/`silva`/`decipher` (unchanged since v0.2.0) |
| `18s-full.json` | 18S full-length | 1700-1850 bp | Eukaryota | `silva`/`pr2`; IdTaxa = stock SILVA SSU model |
| `18s-v9.json` | 18S-V9 (Euka02-class) | 120-200 bp | Eukaryota | `silva`/`pr2`; IdTaxa = stock SILVA SSU model |
| `12s.json` | 12S (MiFish-class) | 180-260 bp | Vertebrata | `mitohelper`; IdTaxa opt-in only (custom training) |
| `coi.json` | COI | 260-450 bp | Metazoa | `midori2` (CC-BY-NC gated) or `bold`; IdTaxa opt-in only |
| `its.json` | ITS | set at intake (variable) | Fungi | `unite`; IdTaxa opt-in only |

The preset carries validated defaults for each of the three methods
(`readbased_minimap2`, `readbased_idtaxa`, `consensus` keys) — the 16S values
are inherited from v0.2.0's battle-tested tuning (e.g. `cluster_min_identity:
0.95`, `qc.min_length_trimmed: 350`); 12S/COI/ITS set `consensus.classifier:
"minimap2"` because no stock IdTaxa model exists for them. Primer sequences
are deliberately empty in every preset — they are a per-run intake input
(SP2/SP1), confirmed against the scientist's protocol.

## Output artifacts

```
results/{run_id}/
├── pipeline_state.json
├── run.log
├── qc/                        ← chopper + cutadapt (shared across all 3 methods)
├── readbased_minimap2/        ← taxonomy/ + asv_table/ (per-read, RefSeq)
├── readbased_idtaxa/          ← taxonomy/ + asv_table/ (per-read, SILVA)
├── consensus_idtaxa/          ← cluster/ + asv_table/ + taxonomy/ (clustered+polished, SILVA)
├── run_summary.json
├── <run_id>-report.md         ← includes cross-method comparison
└── narrative.md
```

## Composability with other AiX-BIO skills

| Skill | When to chain |
| --- | --- |
| `read-qc-trimming` | Not typically needed before this skill — this skill's own QC module does primer trimming + quality/length filtering. |
| `reference-db` (this repo) | Run **before** the first-ever ednanopore run if you don't yet have `ref_mmi`+`tax_lookup` or the IdTaxa `.RData`. |
| `nf-edna` | Reference for `idtaxa-training` if you want a custom-trained (non-SILVA) IdTaxa model instead of this skill's bundled one. |
| `edna-visualize` / `edna-gbif-publish` | `consensus_idtaxa` output only (it's the only method with rep-seqs for phylogenetic placement / Darwin Core records). |

## What NOT to do

- Do **not** skip `preflight/ednanopore-intake`.
- Do **not** silently run only one classification method — defaulting to
  one without the scientist explicitly agreeing to the blind-spot
  trade-off (see `run/ednanopore-run/SKILL.md` SP5) reintroduces
  exactly the risk this rewrite exists to close.
- Do **not** average or silently reconcile a large disagreement between
  methods in a report — surface it as a finding.
- Do **not** delete `pipeline_state.json` mid-run.
- Do **not** commit `assets/`, `results/`, `*.fq.gz`.

## Handoff

- **Manuscript writing** → `literature-pipeline`.
- **GBIF publishing** → `edna-gbif-publish` (from `consensus_idtaxa` output).
- **Comparing methods** → this is now the default behavior of a single
  run, not something requiring two separate runs — `interpret/ednanopore-interpret`
  produces the cross-method comparison directly.
