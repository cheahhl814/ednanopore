---
name: ednanopore-intake
description: "Validate Nanopore (ONT/MinION/PromethION) 16S rRNA eDNA metabarcoding run inputs and write the initial pipeline_state.json with a GO / GO-WITH-WARNINGS / NO-GO verdict. No variant choice — resolves run-time primer/length inputs plus reference-asset paths for all three classification methods (readbased+minimap2/RefSeq, readbased+IdTaxa/SILVA, consensus+medaka+IdTaxa/SILVA), which run by default unless the scientist explicitly opts one out. Computes 7 evidence items. Refuses to write a GO verdict if any required tool or input is missing. The downstream run/ednanopore-run sub-skill refuses to execute without verdict ≥ GO-WITH-WARNINGS. Has 7 explicit ask-user stop points (SP1-SP7). Triggers: 'new Nanopore 16S run', 'ONT 16S intake', 'MinION eDNA intake', 'start ednanopore', 'long-read 16S eDNA pipeline', '16S Nanopore intake', 'eDNA Nanopore parameters'."
version: 0.5.0
updated: "2026-10-06"
triggers:
  - "new Nanopore 16S run"
  - "ONT 16S intake"
  - "MinION eDNA intake"
  - "start ednanopore"
  - "long-read 16S eDNA pipeline"
  - "16S Nanopore intake"
  - "eDNA Nanopore parameters"
---

# ednanopore-intake

> **v0.2.0.** Nextflow removed; no tool/version check for it, no
> `-params-file` framing. The bigger change: **the `pipeline_variant`
> choice is gone.** v0.1.0 asked the scientist to pick `consensus` or
> `read_based` up front, which meant intake decided which blind spots the
> scientist would live with before any data had been looked at. v0.2.0
> defaults to resolving inputs for **all three classification methods**
> (readbased+minimap2, readbased+IdTaxa, consensus+IdTaxa — see
> `run/ednanopore-run/SKILL.md`'s "Why three methods, not one") and
> only asks about dropping one if the scientist's own request implies it.

## Audience

- **AI Coding Agents** — triggered by the phrases above. Run the evidence
  collection steps, then write `pipeline_state.json` with `verdict` set.
  `run/ednanopore-run` refuses to execute if `verdict < GO-WITH-WARNINGS`.
- **Human Nanopore eDNA scientists** — read this as a workflow guide
  explaining why each input is asked for and what each evidence item
  guards against.

## When to Use This Skill

- Start a **new Nanopore 16S metabarcoding run** — partial-region
  (~600 bp, e.g. V3-V4 on MinION) or near/full-length (~1500 bp, e.g.
  27F-1492R on PromethION).
- **Resume** an interrupted run (detects `pipeline_state.json`, offers
  continue-vs-restart).
- Validate that all input files (manifest, metadata, reference assets,
  FASTQ paths) exist and have the expected schema **before** committing
  compute.
- Get a machine-readable `pipeline_state.json` that `run/ednanopore-run`
  reads without re-deriving choices.

## Do NOT use this skill

- If you have **Illumina** short reads — use `nf-edna`'s `16s.json` preset instead.
- If your marker is **not in the preset family and you decline SP2b's scaffold offer** — unlisted markers need either a quick preset (SP2b option A) or a different skill. Bundled since v0.5.0: 16S (full-length and partial), 18S (full + V9/Euka02-class), 12S (MiFish-class), COI, ITS.
- If you have **raw ONT reads that have not been basecalled + demultiplexed** — do that first.
- If you want to **run the pipeline immediately** — this skill only writes intake state; invoke `run/ednanopore-run` after.
- If you want to **interpret already-completed results** — invoke `interpret/ednanopore-interpret` instead.

## 0. Inputs / Outputs contract

### Inputs (consumed)

| Path / source | Required? | Notes |
| --- | --- | --- |
| User-provided primer pair (`primers_fwd`, `primers_rev`) | yes | SP1. Used by `run_qc.sh`'s cutadapt step. |
| User-provided amplicon length range (`min_length`/`min_length_trimmed`/`max_length`) | yes | SP1. `min_length_trimmed` defaults to 350 (post-primer-trim floor, distinct from the raw-read floor — see `CHANGELOG.md` Bug 29). |
| Reference assets for `readbased_minimap2` (`ref_mmi` + `tax_lookup`) | yes, unless this method is opted out (SP5) | |
| Reference asset for `readbased_idtaxa` + `consensus_idtaxa` (`idtaxa_model`, shared — both default to the same SILVA `.RData`) | yes, unless both methods opted out (SP5) | |
| `medaka_model` | yes, unless `consensus_idtaxa` opted out (SP5) | Chemistry-dependent — there is no universal default. |
| Path to sample manifest (CSV / TSV, `sample-id,absolute-filepath`) | yes | SP6. ONT is single-end only. |
| Path to metadata TSV | yes | SP7. Must contain `is_negative` column for decontam. |
| `results/{run_id}/pipeline_state.json` | conditional | If present → resume path (Step 2). |

### Outputs (produced)

| Path | Format | Owner | Notes |
| --- | --- | --- | --- |
| `results/{run_id}/pipeline_state.json` | JSON | this skill | Machine contract for `run/ednanopore-run`. `run_id`, `pipeline: "ednanopore"`, `marker`, `methods` (which of the three to run), `verdict`, `completed_stages`, `last_stage`, `params_used`, `outputs`. |
| `results/{run_id}/params.json` | JSON | this skill | Full parameter file, merged on top of `runners/manual-runner/defaults/16s-nanopore.json`. |
| `results/{run_id}/manifest.tsv` | TSV, no header | this skill | `sample_id<TAB>fastq_filename` — the exact format every `bin/run_*.sh` script expects. Derived from the input manifest CSV/TSV (column names normalized). |
| `results/{run_id}/intake_evidence.txt` | text | this skill | Raw evidence output, kept for debugging. |

### Verdict gate

| Verdict | Meaning | Downstream behaviour |
| --- | --- | --- |
| `GO` | All evidence items pass with no warnings | `run/ednanopore-run` proceeds without prompts |
| `GO-WITH-WARNINGS` | All evidence items pass with ≤ 1 warning | `run/ednanopore-run` proceeds after one confirmation prompt |
| `NO-GO` | Any evidence item fails | `run/ednanopore-run` refuses to execute |

## 0.5 Ask-User Stop Points

### SP1 — Primer / amplicon length ambiguous

| Trigger | Action |
| --- | --- |
| `primers_fwd`/`primers_rev` not provided | Ask: "What are your forward and reverse primer sequences? (e.g. 27F/1492R for full-length; 341F/806R for V3-V4 partial). Paste both, orientation matters." |
| `min_length`/`max_length` not provided and not inferable | Ask: "Expected amplicon length range (min/max bp, primers included)? Defaults: partial (V3-V4): 350-600bp; full-length (27F-1492R): 1400-1700bp. (A) partial, (B) full-length, (C) exact min/max, (D) abort" |

**Auto-pick when**: both primers and a length range are provided upfront. Default `min_length_trimmed`: 350 (validated for V3-V4 partial amplicons — re-derive if your amplicon class differs substantially).

### SP2 — Marker gene ambiguous

| Trigger | Action |
| --- | --- |
| User didn't name a marker and it's not inferable | Ask: "Which marker did you sequence? (A) 16S — Bacteria/Archaea, (B) 18S — full-length or V9 (Euka02/nano18S-class), (C) 12S — MiFish-class, (D) COI. The ITS / custom-marker path is also open — see below. (E) type something else / abort" |

**Auto-pick when**: the marker is named or obvious from context. **Normalization**: lowercase + hyphen-normalize (e.g. `"18S-V9"`/`"Euka02"` → `18s-v9.json`; `"MiFish"` → `12s.json`; `"16S"` → `16s-nanopore.json`).

### SP2b — Marker not in the preset family (multi-marker extension, v0.5.0+)

| Trigger | Action |
| --- | --- |
| A named marker has no `runners/manual-runner/defaults/<marker>.json` | Ask: "There's no bundled preset for `<marker>`. (A) I'll provide primers + a length window now and you scaffold a new preset from an existing one (recommended — presets carry no hardcoded primers anyway), (B) abort and check nf-edna (Illumina) first, (C) abort" |

If (A): copy the taxonomy-nearest preset as `runners/manual-runner/defaults/<kebab-marker>.json`, set kingdoms + length window, leave primers empty for SP1 confirmation, and re-run intake. No sub-skill code changes are needed — preset discovery is data-driven.

**Auto-pick when**: the marker matches an existing preset. Default: never silently guess an unlisted marker — always ask (SP2b).

### SP3 — Reference-asset paths missing for a method that's running

| Trigger | Action |
| --- | --- |
| `readbased_minimap2` is in scope and `ref_mmi`/`tax_lookup` missing | Ask: "readbased+minimap2 needs a reference MMI + taxonomy lookup TSV for `<marker>` (preset `ref_db` names the correct biodb-fetch source). (A) give paths now, (B) run `reference-db` sub-skill first, (C) opt this method out (SP5), (D) abort" |
| `readbased_idtaxa` or `consensus_idtaxa` is in scope and `idtaxa_model` missing | Ask: "Both IdTaxa-based methods need a trained model. For 16S/18S the stock SILVA SSU r138.2 pre-trained model covers both (fetched via biodb-fetch's `decipher` key). For 12S/COI/ITS there IS no stock model — train a custom one first via `nf-edna/idtaxa-training` from the biodb-fetch-fetched FASTA, or use minimap2-LCA as the default. (A) give the path now, (B) run `reference-db` sub-skill first, (C) opt the IdTaxa methods out (SP5), (D) abort" |

**Auto-pick when**: the relevant path(s) are already provided for every method in scope.

### SP4 — `medaka_model` missing (only matters if `consensus_idtaxa` is in scope)

| Trigger | Action |
| --- | --- |
| `consensus_idtaxa` in scope and `medaka_model` empty | Ask: "`medaka_model` must match your flow cell chemistry + basecaller mode (e.g. `r1041_e82_400bps_sup_v5.0.0`). (A) give the exact model name, (B) opt `consensus_idtaxa` out (SP5), (C) abort" |

**Auto-pick when**: `consensus_idtaxa` is opted out, or the model name is already provided.

### SP5 — Scientist wants to skip a method

| Trigger | Action |
| --- | --- |
| Scientist's request implies running fewer than all three methods (e.g. "quick screening", "just consensus", "no clustering") | Ask once, naming the specific blind spot being given up (reproduce the relevant row from `run/ednanopore-run/SKILL.md`'s method table): "Running only `<method(s)>` means losing `<other method>`'s coverage of `<specific blind spot>`. (A) proceed with just `<method(s)>` anyway, (B) run all three (recommended), (C) abort and reconsider" |

**Auto-pick when**: nothing in the request implies skipping a method — default is all three.

### SP6 — Manifest schema unparseable

| Trigger | Action |
| --- | --- |
| Manifest lacks `.csv`/`.tsv` extension, or first line doesn't match `sample-id,absolute-filepath` (ONT is single-end only — no R1/R2) | Ask: "Can't infer the column schema at `<path>`. (A) CSV SE with `sample-id,absolute-filepath`, (B) paste the first 3 lines, (C) abort" |

**Auto-pick when**: schema matches `sample-id,absolute-filepath` (CSV or TSV).

### SP7 — Negative-control column missing in metadata

| Trigger | Action |
| --- | --- |
| Metadata has no `is_negative` column | Ask: "No `is_negative` column — decontam needs this. (A) add it (recommended), (B) run without decontam, (C) abort" |

**Auto-pick when**: `is_negative` present with ≥1 TRUE row.

### SP8 — Disk space low

| Trigger | Action |
| --- | --- |
| Free space at `results/` < 10 GB | Ask: "`<X>` GB free. This pipeline (especially `consensus_idtaxa`'s clustering+polishing) typically needs ≥20GB intermediate space. (A) free up disk, (B) move `results/` elsewhere, (C) abort" |

**Auto-pick when**: free space ≥ 50 GB. 10-50 GB → `GO-WITH-WARNINGS`. <10 GB → `NO-GO` unless overridden.

### Operating rule

> **Auto-pick when the evidence is unambiguous; ask when the agent genuinely cannot decide.**

## Description

Gather every parameter needed to run all three classification methods
(unless the scientist opts one out via SP5), validate that required files
exist, and write `pipeline_state.json` with the verdict gate set. Never
assume defaults silently for primers/length/reference-asset paths — every
one is either provided or explicitly asked for. QC parameters and
threshold defaults (decontam, IdTaxa confidence, clustering identity) DO
have validated defaults (from `CHANGELOG.md`) that apply silently
unless the scientist wants to override.

## Prerequisites

- **Environment**: pixi env with `python ≥ 3.10`, `pyyaml`, `git`.
- **Upstream evidence**: optionally `results/{run_id}/pipeline_state.json` (resume path).
- **User-provided inputs** (gather once, at the top):
  - Marker (first-class input since v0.5.0 — resolved against `runners/manual-runner/defaults/*.json`) — SP2 (+SP2b for unlisted markers)
  - Forward + reverse primer sequences, length range — SP1
  - Reference-asset paths for whichever methods are in scope — SP3
  - `medaka_model` (if `consensus_idtaxa` in scope) — SP4
  - Any methods to opt out of — SP5
  - Sample manifest path — SP6
  - Metadata TSV path — SP7
  - Grouping variable + reference level for diversity/DAA (consensus method only)
  - Decontam threshold (default 0.1), kingdom filter (default `Bacteria,Archaea`)
  - Optional: `run_id`

## Procedure

### Step 1 — Marker + biological parameters (SP1, SP2)

If the user mentions "Illumina" or "short reads" → STOP, wrong skill, redirect to `nf-edna`.

Resolve SP2: normalize the marker name, locate the preset at
`runners/manual-runner/defaults/<marker>.json`, and load its kingdoms, length
windows, classifier defaults, and `ref_db` retrieval keys. The preset's length
windows are run-plan defaults — the run's own `min_length`/`max_length` from
SP1 win when provided. Record `marker_preset` (file path) + any overrides in
`pipeline_state.json`; the run sub-skill passes the resolved values to the
runner scripts, nothing re-derives them.

Ask for primers and length range per SP1 if not already given (the preset
ships empty primer fields on purpose).

### Step 2 — Resume path (if run_id provided)

Read `results/{run_id}/pipeline_state.json`. Report completed stages,
methods in scope, parameters used, prior verdict. Ask: "Continue from
where this left off, or start over?" If continuing: skip to Step 8.

### Step 3 — Which methods are in scope (SP5)

Default: all three (`readbased_minimap2`, `readbased_idtaxa`,
`consensus_idtaxa`). Only narrow this if the scientist's request implies
it — and even then, SP5 fires once to confirm the blind-spot trade-off
before proceeding.

### Step 4 — Validate required files

1. **Manifest** (SP6) — `sample-id,absolute-filepath`, CSV or TSV, ONT single-end only. After receiving: read first 3 lines, confirm sample count/columns (evidence **E2**). Then write `results/{run_id}/manifest.tsv` (TSV, no header, `sample_id<TAB>fastq_filename` — strip any directory prefix from the filepath column if `run_qc.sh`'s `input_dir` argument will supply it, otherwise keep the full path and pass `input_dir=""`).
2. **Metadata TSV** — must contain `sample-id`; check for `is_negative` (evidence **E4**, SP7). Confirm the grouping column if `consensus_idtaxa` is in scope.
3. **Reference assets** (SP3) — for whichever methods are in scope:
   - `readbased_minimap2`: `ref_mmi` + `tax_lookup`.
   - `readbased_idtaxa` and/or `consensus_idtaxa`: `idtaxa_model` (same file, shared).

### Step 5 — Elicit remaining parameters

Ask each only if not already provided, one at a time:

- **`medaka_model`** (SP4, only if `consensus_idtaxa` in scope): must match flow cell chemistry + basecaller mode (e.g. `r1041_e82_400bps_sup_v5.0.0`, `r1041_e82_400bps_fast_v5.0.0`, `r941_min_high_g360`). Find yours with `medaka tools list_models`.
- **Grouping variable** (consensus method only): metadata column for diversity/DAA grouping.
- **Reference level** (consensus method only): control/baseline group for DAA.
- **Decontam threshold**: default 0.1 (ratio threshold for `decontam_by_taxon.jl`/`decontam.jl` — note the two scripts' threshold semantics differ slightly; confirm against the script if precision matters).
- **Kingdom filter**: default `Bacteria,Archaea`.

### Step 6 — Optional parameter overrides

Only if the scientist wants to customize beyond the validated defaults in
`runners/manual-runner/defaults/16s-nanopore.json`:
- `readbased_minimap2`: `min_percent_identity` (default 0.85), `min_ref_coverage` (default 0.8)
- `readbased_idtaxa`: `idtaxa_threshold` (default 60 — note: this is a no-op below `DECIPHER::IdTaxa()`'s own internal default of 60, see `run/ednanopore-run/SKILL.md`'s troubleshooting table), `subsample_n` (default 10000)
- `consensus_idtaxa`: `cluster_min_identity` (default 0.95 — not 0.85, that's the unrelated `readbased_minimap2` value), `cluster_min_coverage_fraction` (default 0.8), `yacrd_min_coverage` (default 0.4), `idtaxa_threshold` (default 60)
- DAA level (default `Genus`), top-N taxa to plot (default 20)

### Step 7 — Tool and disk checks (E6, E7)

```bash
which pixi && pixi --version
df -h "$(dirname results/{run_id})"
```

If `which pixi` fails → ask the scientist to install it
(`curl -fsSL https://pixi.sh/install.sh | bash`). If free space < 10 GB → SP8.

### Step 8 — Compute evidence + emit verdict

| Code | Evidence item | Pass criterion | Verdict impact |
| --- | --- | --- | --- |
| **E1** | Primers + length range resolved | Both primers and min/max length set | Required for `GO` |
| **E2** | Manifest schema valid | SP6 auto-pick succeeded | Required for `GO` |
| **E3** | Sample-count parity | Manifest row count == distinct FASTQ path count | Required for `GO` |
| **E4** | Metadata completeness | `sample-id` + `is_negative` present | `GO-WITH-WARNINGS` if `is_negative` missing; `NO-GO` if `sample-id` missing |
| **E5** | Reference assets valid for every method in scope | All required paths exist and are non-empty | Required for `GO` |
| **E6** | Tool availability | `pixi` on PATH, version parses | Required for `GO` |
| **E7** | Disk space | Free at `results/` ≥ 10 GB | `GO-WITH-WARNINGS` for 10-50GB; `NO-GO` below 10GB |

```text
if any item is "NO-GO"          → verdict = "NO-GO"
elif any item is "GO-WITH-WARNINGS" → verdict = "GO-WITH-WARNINGS"
else                              → verdict = "GO"
```

### Step 9 — Confirm all parameters

```
Run ID:             {run_id}
Pipeline:           ednanopore
Methods in scope:   {readbased_minimap2, readbased_idtaxa, consensus_idtaxa}  (or a narrowed subset, per SP5)
Marker:             {marker}
Manifest:           {input_manifest}  ({N} samples, SE)
Metadata:           {metadata}  (grouping: {grouping_variable}, neg: {is_negative})
Primers fwd/rev:    {primers_fwd} / {primers_rev}
Length range:       {min_length}-{max_length}bp (post-trim floor: {min_length_trimmed}bp)
Reference assets:   ref_mmi={ref_mmi}  tax_lookup={tax_lookup}  idtaxa_model={idtaxa_model}
Medaka model:       {medaka_model}  (consensus_idtaxa only)
Decontam thresh:    {decontam_threshold}

Evidence:
  E1 primers/length  ✓
  E2 manifest        ✓ SE, {N} samples
  E3 sample parity   ✓ {M} manifest rows, {N} FASTQ files
  E4 metadata        ✓ / ⚠ / ✗  (neg col: {yes/no/missing})
  E5 reference assets ✓ / ✗  (per method in scope)
  E6 tools           ✓ pixi {ver}
  E7 disk space      ✓ / ⚠ / ✗  ({free_gb} GB free)

Overall verdict: {GO / GO-WITH-WARNINGS / NO-GO}
```

Ask: "Does this look correct? Type 'yes' to proceed, correct any parameter, or address any NO-GO items."

### Step 10 — Write outputs

1. **Generate `run_id`**: `16s-nanopore-{YYYYMMDD}-{short_descriptor}`. Ask for a short descriptor if not given.

2. **Write `results/{run_id}/pipeline_state.json`**:

```json
{
  "run_id": "{run_id}",
  "pipeline": "ednanopore",
  "marker": "16S",
  "methods": ["readbased_minimap2", "readbased_idtaxa", "consensus_idtaxa"],
  "verdict": "GO | GO-WITH-WARNINGS | NO-GO",
  "completed_stages": [],
  "last_stage": "intake",
  "evidence": {
    "E1_primers_length": "pass | warn | fail",
    "E2_manifest_schema": "pass | warn | fail",
    "E3_sample_count_parity": "pass | warn | fail",
    "E4_metadata_completeness": "pass | warn | fail",
    "E5_reference_assets": "pass | warn | fail",
    "E6_tool_availability": "pass | warn | fail",
    "E7_disk_space": "pass | warn | fail"
  },
  "params_used": {
    "input_manifest": "...",
    "primers_fwd": "...",
    "primers_rev": "...",
    "min_length": null,
    "max_length": null,
    "kingdoms": "..."
  },
  "outputs": {}
}
```

3. **Write `results/{run_id}/manifest.tsv`** (sample_id<TAB>fastq_filename, no header) and **`results/{run_id}/params.json`** (merged on top of `runners/manual-runner/defaults/16s-nanopore.json` — only include values here that differ from the preset, plus always-required run-specific fields: `input_manifest`, `metadata`, `ref_mmi`, `tax_lookup`, `idtaxa_model`, `medaka_model`, `primers_fwd`, `primers_rev`, `min_length`/`max_length`/`min_length_trimmed`, `grouping_variable`, `reference_level`, `methods`).

### Step 11 — Hand off

> "Intake complete. Run ID: `{run_id}`. Methods in scope: `{methods}`.
> Verdict: `{GO / GO-WITH-WARNINGS / NO-GO}`.
>
> To execute the pipeline: `run/ednanopore-run`"

## Troubleshooting — Signature library

| Signature in stderr / log | Likely cause | Suggested fix |
| --- | --- | --- |
| `Manifest has fewer samples than expected` | FASTQ files weren't all uploaded, or paths point elsewhere | `ls -la $(dirname <first-FASTpath>)`; cross-reference manifest paths with actual files |
| `Metadata 'is_negative' column missing` | User skipped SP7, or metadata was exported without the flag | Re-export with `is_negative=TRUE/FALSE`, or accept `GO-WITH-WARNINGS` and skip decontam |
| `Primer sequence contains ambiguous bases cutadapt can't parse` | Non-standard IUPAC codes or stray whitespace | Trim whitespace; verify against `cutadapt --help` (accepts A/C/G/T/N + W/S/R/Y/K/M/B/D/H/V) |
| `pixi: command not found` | Pixi not on PATH | `curl -fsSL https://pixi.sh/install.sh \| bash` then re-source `~/.bashrc` |
| `No space left on device` resolving a pixi env | First-run env resolution can take 1-3GB per stage | Free ≥20GB before intake (`consensus_idtaxa` is the heaviest), or move `results/` to a larger disk |
| `medaka_model is empty and consensus_idtaxa is in scope` | SP4 wasn't resolved | Run `medaka tools list_models` and provide the model name matching your flow cell + basecaller |
| `Metadata 'grouping_variable' has only 1 unique value` | All samples share the same label | Diversity/DAA will be uninformative for `consensus_idtaxa`'s downstream stages; either expand metadata or accept limited analysis |

## Verification

- [ ] `results/{run_id}/pipeline_state.json` exists with `verdict` set.
- [ ] `results/{run_id}/pipeline_state.json.methods` lists the method(s) actually in scope (all three by default).
- [ ] `results/{run_id}/manifest.tsv` exists in the `sample_id<TAB>fastq_filename` format every `bin/run_*.sh` script expects.
- [ ] `results/{run_id}/params.json` merges cleanly on top of `runners/manual-runner/defaults/16s-nanopore.json`.
- [ ] `results/{run_id}/intake_evidence.txt` exists with all 7 evidence items recorded.
- [ ] If any method was opted out, SP5 fired and the blind-spot trade-off was stated before confirming.

## Invariants

- Never silently assume a primer/length/reference-asset default. Every one is given or asked.
- Validate every file path before accepting it.
- Default scope is **all three methods** — narrowing requires an explicit SP5 confirmation.
- Never proceed to Step 10 (write) without explicit confirmation in Step 9.
- The verdict gate is never silently overridden.
