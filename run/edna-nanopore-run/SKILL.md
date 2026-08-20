---
name: edna-nanopore-run
description: "Execute the correct nf-edna-nanopore Nextflow pipeline (consensus or read_based variant) for the run's marker + classifier + variant, monitor progress, and update pipeline_state.json. Picks main-consensus.nf or main-readbased.nf based on pipeline_state.json.pipeline_variant. Refuses to execute when the upstream preflight/edna-nanopore-intake verdict is NO-GO. Has 4 explicit ask-user stop points (SP1–SP4) that fire only when evidence is ambiguous. Triggers: 'run Nanopore 16S pipeline', 'execute nf-edna-nanopore', 'nextflow run main-consensus.nf', 'nextflow run main-readbased.nf', 'continue Nanopore run', 'Nanopore QC stage', 'Nanopore classify', 'Nanopore diversity', 'Nanopore association'."
version: 0.1.0
updated: "2026-08-19"
triggers:
  - "run Nanopore 16S pipeline"
  - "execute nf-edna-nanopore"
  - "nextflow run main-consensus.nf"
  - "nextflow run main-readbased.nf"
  - "continue Nanopore run"
  - "Nanopore QC stage"
  - "Nanopore classify"
  - "Nanopore diversity"
  - "Nanopore association"
---

# edna-nanopore-run

> **v0.1.0.** Initial version. Adds the canonical BettaMt structure (§0 Inputs/Outputs contract, §0.5 Ask-User Stop Points with Evidence + Recommend + Options, §Troubleshooting — Signature library, preflight verdict-gate enforcement). Mirrors `skills/nf-edna/run/edna-run/SKILL.md` with the Nanopore-specific deviations: a `pipeline_variant`-driven entry-point selection (consensus → `main-consensus.nf`, read_based → `main-readbased.nf`), a single flexible `params/16s-nanopore.json` preset, and a stage list that depends on the variant (consensus: qc → cluster → classify → diversity → association; read_based: qc → classify → decontam).

## Audience

This skill serves two simultaneous audiences:

- **AI Coding Agents** — triggered by the phrases above. The agent must read `pipeline_state.json`, enforce the verdict gate (SP1), determine the variant-specific entry point from `pipeline_state.json.pipeline_variant` (Step 2), construct the exact `nextflow run` command with the correct `-params-file` chain (Step 3), show it to the scientist before execution (Step 4), and update state only after confirmed success (Step 7).
- **Human Nanopore eDNA scientists** — read this document as a workflow guide. The `## When to Use` / `## Do NOT use` sections explain *why* the verdict gate exists (no compute without validated inputs), *why* the command must be shown before execution (mistakes cost hours of Nextflow runtime), and *why* `pipeline_state.json` is the source of truth for resumability.

## When to Use This Skill

Use this skill when you need to:

- **Continue** an existing Nanopore 16S run whose `pipeline_state.json` exists (verdict ≥ `GO-WITH-WARNINGS`).
- **Run one or more pipeline stages** with the correct `-params-file` chain. Stages are variant-dependent — see Step 2.
- **Resume** a partially-completed run via Nextflow's `-resume` (caches from prior stages are reused).
- **Update `pipeline_state.json`** after each successful stage so the next invocation knows where to pick up.

## Do NOT use this skill

- If there is **no `pipeline_state.json`** for the run → invoke `preflight/edna-nanopore-intake` first. This sub-skill refuses to run without intake-completed state (SP1).
- If the upstream intake verdict is **`NO-GO`** → fix the failing evidence item in `pipeline_state.json.evidence` first, then re-run intake.
- If you want to **interpret already-completed results** → invoke `interpret/edna-nanopore-interpret` instead.
- If you want to **change the `pipeline_variant` mid-run** → this requires a new intake (a new `run_id`); do not edit `pipeline_state.json` by hand to switch variants.
- If you only want to **look at the Nextflow log** → use `tail -f .nextflow.log` directly, no skill needed.

## 0. Inputs / Outputs contract

### Inputs (consumed)

| Path | Source | Required? | Notes |
| --- | --- | --- | --- |
| `results/{run_id}/pipeline_state.json` | `preflight/edna-nanopore-intake` | yes | Must exist with `verdict ∈ {GO, GO-WITH-WARNINGS}`. The `pipeline`, `pipeline_variant`, `marker`, `classifier`, `completed_stages`, `last_stage` fields drive entry-point and stage routing. |
| `results/{run_id}/params.json` | `preflight/edna-nanopore-intake` | yes | The run-specific parameter overrides; merged on top of `runners/nextflow-runner/params/16s-nanopore.json` via the merged `-params-file` (see SP2 / Step 3). |
| `runners/nextflow-runner/params/16s-nanopore.json` | this skill (skill-bundled) | yes | The single flexible preset; passed as part of the FIRST `-params-file` chain so user overrides win. |

### Outputs (produced)

| Path | Format | Owner | Notes |
| --- | --- | --- | --- |
| `results/{run_id}/pipeline_state.json` | JSON (updated) | this skill | After each successful stage: extend `completed_stages`, update `last_stage`, append new paths to `outputs`. **Never** update on failure (Step 7 invariant). |
| `results/{run_id}/run_summary.json` | JSON | this skill (or downstream summariser) | Compact, LLM-loadable summary of the full run — read by `interpret/edna-nanopore-interpret`. Written when the final variant-specific stage completes (Step 8). |
| `results/{run_id}/{stage}_output/...` | per-stage outputs | Nextflow pipeline | Stage-specific outputs (trimmed FASTQs, consensus FASTA, ASV tables, taxonomy files, diversity metrics). |

### Verdict gate enforcement

Before constructing any command, **read `pipeline_state.json.verdict`**. If `NO-GO` or missing → SP1 fires (refuse to execute). If `GO-WITH-WARNINGS` → one confirmation prompt ("verdict is GO-WITH-WARNINGS — continue?") before Step 3.

## 0.5 Ask-User Stop Points

This sub-skill has **4 stop points** (SP1–SP4). Each fires only when the evidence is ambiguous. The format is **Evidence + Recommend + Options**.

### SP1 — Pre-flight verdict gate fails

| Trigger | Evidence check | Action |
| --- | --- | --- |
| `pipeline_state.json` missing OR its `verdict` field is `NO-GO` OR `verdict` field missing | The intake gate has not been passed | Hard-stop: "I see no `pipeline_state.json` for run `{run_id}` (or its verdict is `NO-GO`). Invoke `preflight/edna-nanopore-intake` first." |
| `pipeline_state.json.verdict == GO-WITH-WARNINGS` | Some evidence items had warnings | Ask: "Verdict is `GO-WITH-WARNINGS` (`<failing evidence items>`). Pick: (A) continue anyway (the warnings are acceptable), (B) re-run intake to fix the warnings (recommended), (C) abort" |

**Auto-pick when**: `verdict == GO`. No ask.

### SP2 — Pipeline-state schema mismatch

| Trigger | Evidence check | Action |
| --- | --- | --- |
| `pipeline` field is not `nf-edna-nanopore`, OR `pipeline_variant` field is missing or not one of `consensus / read_based`, OR `marker` field is missing or not `16S` | State belongs to a different skill or was corrupted | Ask: "State at `<path>` doesn't look like nf-edna-nanopore intake (missing `pipeline: nf-edna-nanopore`, or `pipeline_variant` is `<X>`, or `marker` is `<Y>`). Pick: (A) it's an unrelated run — I'll give you the correct `run_id`, (B) it's nf-edna-nanopore with a typo — I'll fix it (only safe if it's a typo, not a variant change), (C) abort" |

**Auto-pick when**: `pipeline == "nf-edna-nanopore"` AND `pipeline_variant ∈ {consensus, read_based}` AND `marker == "16S"`. No ask.

### SP3 — Failure-handling choice

| Trigger | Evidence check | Action |
| --- | --- | --- |
| A Nextflow process exited non-zero OR `ERROR` / `FAILED` appeared in `.nextflow.log` | A stage genuinely failed | Ask: "`<stage>` failed with `<excerpt>`. Pick: (A) **retry** — adjust a parameter in `params.json` and rerun with `-resume` (tell me which), (B) **skip** this stage and continue with the next (record the skip in the report), (C) **abort** this run (state is preserved, resumable later)" |

**Auto-pick when**: stage succeeded. No ask.

### SP4 — Resume-from-stage ambiguity

| Trigger | Evidence check | Action |
| --- | --- | --- |
| `completed_stages` has ≥ 2 entries, AND user did not specify "next stage only" / "all remaining" | Multiple valid resumptions | Ask: "I see `<N>` stages already complete (`<list>`). Pick: (A) run only the **next** stage (incremental), (B) run **all remaining** stages (full pipeline from current point), (C) run a **specific** stage from the entry-point table (tell me which)" |

**Auto-pick when**: `completed_stages` has ≤ 1 entry AND user said "continue" (default: next stage only). No ask.

### Operating rule

> **Auto-pick when the evidence is unambiguous; ask when the agent genuinely cannot decide.** When asking, present the evidence first, then the recommendation, then 2–4 concrete options. Do not ask "what do you want?" — ask "I see X, recommend Y, which one of A/B/C?"

## Description

You are the pipeline execution agent for a Nanopore 16S eDNA metabarcoding analysis. Your job is to read the current `pipeline_state.json`, determine the variant-specific entry point and the next stage to run, show the scientist the exact command, and execute it after confirmation.

## Prerequisites

- **Environment**: `nextflow ≥ 23.10.0` and `pixi` on PATH (already validated by `preflight/edna-nanopore-intake` evidence item E6).
- **Upstream evidence**: `results/{run_id}/pipeline_state.json` with verdict ≥ `GO-WITH-WARNINGS` (SP1).
- **User-provided inputs**: `run_id` (gathered in Step 1 below); optionally a stage choice (incremental / all / specific).

## Procedure

### Step 1 — Locate the run

Ask if not already stated:

> "What is the `run_id` for this run?"

Read `results/{run_id}/pipeline_state.json`. **Enforce the verdict gate (SP1)**: if missing, `NO-GO`, or `verdict < GO-WITH-WARNINGS` → refuse to proceed.

> "No pipeline_state.json found for run `{run_id}` (or verdict is `NO-GO`). Please run `preflight/edna-nanopore-intake` first."

### Step 2 — Determine what to run (variant-aware)

From `pipeline_state.json`:
- `pipeline`: pipeline directory to use (always `nf-edna-nanopore` for this skill — SP2 enforces the schema)
- `pipeline_variant`: `consensus` → entry point `main-consensus.nf`; `read_based` → entry point `main-readbased.nf`
- `marker`: always `16S` for this skill (SP2 enforces)
- `classifier`: `minimap2` (default), `kraken2`, or `idtaxa` (consensus variant only) — drives module branching inside the entry point; the entry-point file choice does NOT change with classifier
- `completed_stages`: what has already run
- `last_stage`: last completed stage

Determine the next stage(s) from the variant-specific stage list:

| Variant | `last_stage` | Next stage to run | Entry point name |
| --- | --- | --- | --- |
| consensus | `intake` | `qc` | `QC_ONLY` (default workflow or `QC_ONLY`) |
| consensus | `qc` | `cluster` | `CLUSTER_ONLY` |
| consensus | `cluster` | `classify` | `CLASSIFY_ONLY` |
| consensus | `classify` | `diversity` | full workflow (no `-entry`) |
| consensus | `diversity` | `association` | full workflow (no `-entry`) |
| consensus | `association` | All stages complete — suggest `interpret/edna-nanopore-interpret` | — |
| read_based | `intake` | `qc` | `QC_ONLY` |
| read_based | `qc` | `classify` | full workflow (no `-entry`) |
| read_based | `classify` | `decontam` | full workflow (no `-entry`) |
| read_based | `decontam` | All stages complete — suggest `interpret/edna-nanopore-interpret` | — |

Entry point mapping (consensus variant, mirrors nf-edna's main.nf staging):
- Through QC only: `-entry QC_ONLY`
- Through CLUSTER: `-entry CLUSTER_ONLY`
- Through CLASSIFY: `-entry CLASSIFY_ONLY`
- Full pipeline (all consensus stages): omit `-entry` (uses default workflow)

Entry point mapping (read_based variant):
- Through QC only: `-entry QC_ONLY`
- Full read_based pipeline (qc → classify → decontam): omit `-entry` (uses default workflow)

Note: read_based variant does NOT run `cluster`, `diversity`, or `association` — see the design spec at `docs/superpowers/specs/2026-08-19-nf-edna-nanopore-design.md` for why (no rep-seqs → no tree, no UniFrac, no shared diversity/association modules reusable as-is).

If `completed_stages` has ≥ 2 entries, SP4 fires (ask user incremental vs full vs specific). Otherwise, default to "next stage only".

Note: Entry points are cumulative, not isolated — each entry point runs all stages from the beginning up to and including the named stage. To run from a mid-point, the pipeline must be run with `-resume` so Nextflow reuses cached work from prior stages.

### Step 3 — Construct the command

Determine:
- `PIPELINE_DIR`: the nf-edna-nanopore skill root (where `runners/nextflow-runner/` lives). Use the absolute path; do not rely on `cwd`.
- `MAIN_SCRIPT`: `runners/nextflow-runner/main-{pipeline_variant}.nf` — chosen from `pipeline_state.json.pipeline_variant` (consensus → `main-consensus.nf`, read_based → `main-readbased.nf`)
- `PRESET`: `runners/nextflow-runner/params/16s-nanopore.json` (single flexible preset for both variants)
- `PARAMS_FILE`: `results/{run_id}/params.json`
- `ENTRY`: the Nextflow entry point workflow name (or omit for default full workflow)
- `RESUME`: add `-resume` if any stages are already complete
- `PROFILE`: optional `-profile` selector (see "Available Nextflow profiles" below)

Note: `-params-file` accepts only one file. **Nextflow ≥ 24 rejects multiple `-params-file` flags** with `Can only specify option -params-file once` — merge `runners/nextflow-runner/params/16s-nanopore.json` (preset) + `results/{run_id}/params.json` (run-specific overrides, last wins) into one JSON object, then pass a single `-params-file <merged>.json`.

For running all remaining stages from the start:
```bash
nextflow run {PIPELINE_DIR}/runners/nextflow-runner/main-{variant}.nf \
    -params-file <merged_params.json> \
    -resume
```

For running up to a specific stage:
```bash
nextflow run {PIPELINE_DIR}/runners/nextflow-runner/main-{variant}.nf \
    -entry {ENTRY_POINT} \
    -params-file <merged_params.json> \
    -resume
```

### Available Nextflow profiles

`nextflow.config` does **not** declare custom `profiles {}` blocks in v0.1.0 — it relies on Nextflow's built-in profiles (`standard`, `conda`, `docker`, `singularity`, `podman`, `test`, `awsbatch`, `azurebatch`, `googlebatch`) only. If the scientist wants containerised execution, pass `-profile docker` (or `singularity`/`podman`) explicitly; no skill-bundled container configs ship in v0.1.0.

If the user requests a custom profile that does not exist, refuse and explain — do not invent a profile block.

### Step 4 — Show command and wait for confirmation

Display the full command and ask:

> "I will run:
>
> ```bash
> cd {SKILL_ROOT}
> {nextflow command}
> ```
>
> Proceed? (yes / no / change a parameter)"

If the scientist wants to change a parameter, update `results/{run_id}/params.json` accordingly and show the revised command.

Do not execute until the scientist confirms.

### Step 5 — Execute and monitor

Run the command using the Bash tool. Stream output as it runs.

Watch for:
- `Launching` — pipeline started
- `[xx/xxxxxx] process > WORKFLOW:process_name` — stage progress
- `Completed at:` — successful completion
- `ERROR` or `FAILED` — failure (trigger SP3)

Report progress to the scientist as stages complete:
> "✓ QC complete (188/200 reads survived trimming)"
> "✓ CLASSIFY complete (47 taxa across 3 samples)"

### Step 6 — Handle failures (SP3)

If a process fails (non-zero exit, ERROR in log):

1. Extract the relevant log excerpt:
```bash
grep -A 20 "ERROR\|FAILED\|Command exit" .nextflow.log | tail -40
```

2. Explain the likely cause in plain language. Common signatures are listed in the **Signature library** section below.

3. Present SP3's three options to the scientist (retry / skip / abort).

4. Do **not** update `pipeline_state.json` for a failed stage (invariant).

If retrying: update `results/{run_id}/params.json` with the new parameter value, then go back to Step 4.

If skipping: note the skipped stage in your response to the scientist and proceed to the next stage. Do not add the skipped stage to `completed_stages`.

If aborting: tell the scientist the run state is preserved and can be resumed later by re-running `run/edna-nanopore-run` with the same `run_id`.

### Step 7 — Update state on success

After each stage completes successfully, read the current `pipeline_state.json` and write an updated version with:
- `completed_stages` extended by the newly completed stage(s)
- `last_stage` set to the most recently completed stage
- `outputs` updated with paths to new outputs

Use the Write tool to overwrite `results/{run_id}/pipeline_state.json`.

Note: Variant B (read_based) `pipeline_state.json` includes a `limitations` field that is written once at intake and preserved across stage updates — do not strip it. The `WRITE_STATE` process in `main-readbased.nf` already encodes the limitations array.

### Step 8 — Generate run summary

When all stages are complete for the chosen variant, generate the AI-readable run summary. In v0.1.0, this skill emits a lightweight run summary directly (no `bin/summarise_run.py` is bundled yet — the nf-edna summariser is Illumina-oriented and not directly portable to Nanopore):

```bash
python3 - <<'PY'
import json, os, glob
from pathlib import Path

results_dir = Path("results") / "{run_id}"
state = json.load(open(results_dir / "pipeline_state.json"))

summary = {
    "run_id": state["run_id"],
    "pipeline": state["pipeline"],
    "pipeline_variant": state["pipeline_variant"],
    "marker": state["marker"],
    "classifier": state.get("classifier", "minimap2"),
    "completed_stages": state["completed_stages"],
    "last_stage": state["last_stage"],
    "outputs": state.get("outputs", {}),
    "limitations": state.get("limitations", []),
    "params_used": state.get("params_used", {}),
    "notes": [],
}

# Per-stage file-presence check (helps interpret catch missing outputs).
if state.get("outputs", {}).get("trimmed_reads"):
    summary["trimmed_reads_present"] = any(Path(state["outputs"]["trimmed_reads"]).glob("*.fastq.gz"))
if state["pipeline_variant"] == "consensus":
    if state.get("outputs", {}).get("asv_table"):
        summary["asv_table_present"] = Path(state["outputs"]["asv_table"]).exists()
    if state.get("outputs", {}).get("rep_seqs"):
        summary["rep_seqs_present"] = Path(state["outputs"]["rep_seqs"]).exists()
else:
    if state.get("outputs", {}).get("taxon_abundance"):
        summary["taxon_abundance_present"] = Path(state["outputs"]["taxon_abundance"]).exists()
    if state.get("outputs", {}).get("decontam_taxon_abundance"):
        summary["decontam_taxon_abundance_present"] = Path(state["outputs"]["decontam_taxon_abundance"]).exists()

# Variant-specific notes
if state["pipeline_variant"] == "read_based":
    summary["notes"].append(
        "Variant B (read_based) does not run diversity/association in v0.1.0 — "
        "no rep-seqs means no phylogenetic tree, so shared diversity/association "
        "modules (which hard-require --input_tree) cannot be reused as-is."
    )

out_path = results_dir / "run_summary.json"
out_path.write_text(json.dumps(summary, indent=2))
print(f"[run-summary] wrote {out_path}")
PY
```

This writes `results/{run_id}/run_summary.json`, which pre-compiles the run metadata (variant, classifier, completed stages, file-presence flags, variant-specific notes) into a single compact file used by `interpret/edna-nanopore-interpret`. When a Nanopore-specific `bin/summarise_run.py` lands in a future version, replace this inline snippet with that script's invocation.

### Step 9 — Hand off

When all requested stages are complete:

> "Pipeline complete through `{last_stage}` (`{pipeline_variant}` variant).
> Completed stages: {completed_stages}
>
> Run summary written to `results/{run_id}/run_summary.json`.
> To interpret results: `interpret/edna-nanopore-interpret`"

If only some stages were requested and more remain:
> "`{last_stage}` complete. Run `run/edna-nanopore-run` again to continue with the next stage, or `interpret/edna-nanopore-interpret` if you want to review results so far."

## Troubleshooting — Signature library

| Signature in stderr / log | Likely cause | Suggested fix |
| --- | --- | --- |
| `chopper: input file not found` | Manifest path is wrong, or FASTQ wasn't uploaded | Verify `cat $(head -2 {input_manifest})` and `ls -la <first-fastq>` |
| `cutadapt: adapter not found / primer not found in reads` | Primer sequence is wrong, or orientation flipped | Verify primer sequences against the source publication; pass `--primer_mismatch_rate 0.2` to tolerate degenerate bases (cutadapt's built-in default is already permissive) |
| **`Pipeline produced taxon calls but species assignments look like Bacteria / Archaea when the dataset should be fish/vertebrate`** | **Marker mis-assigned — the marker is hardcoded to 16S in v0.1.0. If the user actually meant 12S / MiFish-U, this is the wrong skill.** | **Stop. Re-route to `nf-edna`'s `12s.json` preset (Illumina), or wait for v0.2 which adds Nanopore 12S support.** |
| `minimap2: reference index (.mmi) not found at <path>` | `ref_mmi` path is wrong, or the index wasn't built | Verify with `minimap2 -d <path> 2>&1 \| head`; rebuild with `minimap2 -d <out.mmi> <ref.fasta>` |
| `minimap2_lca.py: query_fasta is empty` | QC stage produced no reads (all reads failed Chopper filtering) | Lower `min_length` or relax `min_qual` in `params.json`; check NanoPlot pre-trim report to see actual read length distribution |
| `medaka: model <name> not found in <env path>` | `medaka_model` value doesn't match the installed medaka version's available models | Run `medaka tools list_models` in the cluster pixi env and copy the exact model name into `params.json` |
| `yacrd: no reads survive coverage filter` | `yacrd_min_coverage` is too stringent for your per-cluster pileup depth | Lower `yacrd_min_coverage` to 0.2–0.3; spot-check by running `minimap2` on the consensus FASTA manually |
| `kraken2: DB not found at <path>` | `kraken2_db` is wrong, or DB was built with a different k-mer length | Verify with `kraken2-inspect --db <path> \| head`; rebuild DB if needed |
| `IDTAXA: model file is corrupt or wrong format` | The `.rds` file wasn't saved with `saveRDS()`, or training script aborted | Retrain with `bin/train_idtaxa_model.R --input <fasta> --taxonomy <headers.tsv> --output <model.rds>` (the nf-edna `idtaxa-training` sub-skill handles this) |
| `R script: package 'X' is not available` | pixi env for that stage didn't include the R package | Run `pixi add --manifest-path env/{stage}/pixi.toml r-X` then re-run with `-resume` |
| **`decontam_by_taxon.jl: neg_col 'is_negative' not found in metadata`** | **Metadata column-name mismatch (case, separator)** | **Verify the metadata column name matches exactly: `head -1 metadata.tsv \| tr '\t' ',' \| grep -i negative`. This is Variant B only.** |
| `decontam.jl: neg_col 'is_negative' not found in metadata` | Same issue, but Variant A (consensus) | Same fix — Variant A uses `bin/decontam.jl`, Variant B uses `bin/decontam_by_taxon.jl`. |
| `No space left on device` (work dir) | Nextflow `work/` filled the disk — common in consensus variant because medaka polishing produces large intermediate files | Free ≥ 20 GB or move the run to a larger disk; partial work is preserved on `-resume` |
| `nextflow: process cache invalidated` after `pixi add` | pixi env changes invalidate Nextflow's task hash | Run with `-resume` once to recover cached stages; new stages will recompute (expected) |
| `ERROR ~ Command exit (code 137)` | OOM-killed (Linux) | The stage ran out of RAM; reduce `task.memory` in `nextflow.config` (look for `process { memory = ... }` and `withLabel: process_medium`) or split the run into smaller batches |
| `Module not found: modules/X.nf` | Pipeline files were moved or the skill was deployed without the `modules/` dir | Verify `diff -rq @skills/nf-edna-nanopore/ ~/.pi/agent/skills/nf-edna-nanopore/` — the deploy copy should be md5-identical |
| `Can only specify option -params-file once` | Nextflow ≥ 24 rejects multiple `-params-file` flags | Merge `runners/nextflow-runner/params/16s-nanopore.json` + `results/{run_id}/params.json` into one JSON object before `-params-file <merged>.json`. Use Python: `merged = {**preset, **run_specific}` (last wins) |
| `ERROR: Cannot find Java or it's a wrong version -- Java 8 or later (up to 22) is installed` | Nextflow hard cap of Java 22; sdkman `current` defaults to Java 25 (fails) | Set `JAVA_HOME` to a Java 21 install before running nextflow: `export JAVA_HOME=/home/cheahhl814/.sdkman/candidates/java/21.0.11-tem` (or any Java 8–22) |
| `Entry point QC_ONLY not found in main-readbased.nf` | The read_based variant has `QC_ONLY` declared but not `CLUSTER_ONLY` etc. — using the wrong entry point name | Use only `QC_ONLY` for read_based; for full pipeline omit `-entry`. Never use `CLUSTER_ONLY` / `CLASSIFY_ONLY` with the read_based entry — those are consensus-only names |
| `Entry point CLUSTER_ONLY not found in main-consensus.nf` | The consensus variant's `main-consensus.nf` does declare `CLUSTER_ONLY`, but if you're hitting this it's likely you're pointing at the wrong entry script | Check `pipeline_state.json.pipeline_variant` — make sure it matches the entry script (`main-consensus.nf` vs `main-readbased.nf`) |
| **Variant B run completed but `run_summary.json` reports `diversity_present: false`** | **Expected — Variant B does not run diversity/association in v0.1.0 (documented limitation, not a bug).** | **None — surface the limitation in `interpret/edna-nanopore-interpret`'s report so the reader knows diversity/association sections are intentionally absent.** |

## Verification

- [ ] `results/{run_id}/pipeline_state.json.verdict` was `GO` or `GO-WITH-WARNINGS` before any `nextflow run` command was constructed (SP1).
- [ ] The chosen entry script (`main-consensus.nf` or `main-readbased.nf`) matches `pipeline_state.json.pipeline_variant` (SP2 invariant).
- [ ] The exact `nextflow run` command was shown to the scientist and explicitly confirmed (Step 4 invariant).
- [ ] `pipeline_state.json.completed_stages` was extended only after a stage succeeded (Step 7 invariant).
- [ ] `pipeline_state.json.last_stage` matches the most recent successful entry.
- [ ] When `last_stage` is the final stage for the chosen variant (`association` for consensus; `decontam` for read_based), `run_summary.json` was generated (Step 8).

## Invariants

- **Never** execute a Nextflow command without showing it first and waiting for explicit confirmation.
- **Never** update `pipeline_state.json` for a stage that failed.
- **Always** use `-resume` when any prior stage has completed, so Nextflow reuses cached work.
- **Always** pass the preset (`-params-file params/16s-nanopore.json` content) before the run's own `params.json`, so the run's values take precedence.
- **Always** enforce the SP1 verdict gate before Step 3.
- **Always** match the entry script to `pipeline_state.json.pipeline_variant`. Cross-launching (`pipeline_variant: consensus` → `main-readbased.nf`, or vice versa) is forbidden.
- **Never** invent a `-profile` that does not exist in `nextflow.config` or in Nextflow's built-ins.
