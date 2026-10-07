---
name: ednanopore-run
description: "Execute the ednanopore manual (agent-driven) pipeline: QC, then the classification methods in scope from the marker preset — readbased_minimap2 (default for every marker), readbased_idtaxa (default for 16S/18S via the stock SILVA SSU model; for 12S/COI/ITS it requires a custom-trained model and is opt-in), plus consensus polishing + classification by default — per CHANGELOG.md's conclusion that no single approach is sufficient for Nanopore eDNA. No Nextflow — every stage is a direct shell invocation of a script under runners/manual-runner/bin/, run via the Bash tool and shown to the scientist before execution. Monitors progress, updates pipeline_state.json after each stage. Has explicit ask-user stop points (SP1-SP5) that fire only when evidence is ambiguous. Triggers: 'run Nanopore 16S pipeline', 'run ednanopore', 'run Nanopore 18S/12S/COI/ITS pipeline', 'continue Nanopore run', 'Nanopore QC stage', 'Nanopore classify', 'Nanopore consensus clustering'.""
version: 0.5.1
updated: "2026-10-07"
triggers:
  - "run Nanopore 16S pipeline"
  - "run ednanopore"
  - "continue Nanopore run"
  - "Nanopore QC stage"
  - "Nanopore classify"
  - "Nanopore consensus clustering"
---

# ednanopore-run

> **v0.2.0.** Nextflow removed. The pipeline is now **agent-driven**: an
> agent (you) invokes the scripts under `runners/manual-runner/bin/`
> directly via the Bash tool, one stage at a time, showing each command to
> the scientist before running it — the same mechanism that already drove
> every validated run of this dataset (see `CHANGELOG.md`'s framing
> note on why the Nextflow orchestrator was abandoned after bug #27: 27
> fixes deep into the orchestrator, retries moved to direct shell
> invocation of the same underlying tool scripts, and never looked back).
> This version also changes the **default scope**: v0.1.0 asked the
> scientist to pick ONE of two mutually-exclusive "variants"
> (`consensus` / `read_based`). v0.2.0 runs classification **three ways by
> default** — see "Why three methods, not one" below — because the
> dataset-specific comparison that motivated this rewrite found real,
> substantial divergences between methods (e.g. one phylum's abundance
> estimate ranged 3.6% / 9.4% / 19.3% across the three methods on the same
> samples) that only showed up because all three were run and compared.
> Picking one variant up front would have hidden that.

## Audience

- **AI Coding Agents** — triggered by the phrases above. Read
  `pipeline_state.json`, enforce the verdict gate (SP1), run each stage's
  script via Bash after showing the exact command and getting confirmation,
  update state only after confirmed success.
- **Human Nanopore eDNA scientists** — read this as a workflow guide. The
  "Why three methods" section explains why you'll see three sets of
  taxonomy output instead of one, and why that is the point, not a
  mistake.

## Why three methods, not one

Nanopore 16S reads are higher-error than Illumina and amplicon length is
usually too short to span the whole taxonomic signal unambiguously. Three
independent error-correction/reference-coverage trade-offs exist, and
**each has a known, different blind spot**:

| Method | Script | Error-corrects reads? | Reference | Species-level? | Known blind spot |
| --- | --- | --- | --- | --- | --- |
| **readbased + minimap2** | `bin/run_readbased_minimap2.sh` | No (classifies raw trimmed reads) | RefSeq Targeted Loci (or similar) | Yes, where reference has species headers | RefSeq under-represents uncultured/`Candidatus` environmental lineages — can silently drop a whole genus to zero (verified case: `Candidatus Solibacter`/`Koribacter`, RefSeq has 0 usable hits for either) |
| **readbased + IdTaxa** | `bin/run_readbased_idtaxa.sh` | No (classifies raw trimmed reads) | SILVA (DECIPHER pre-trained) | **No — this specific pre-trained model has no species rank in its training hierarchy at all** (verified directly against the `.RData` object: every one of 14,699 taxonomy nodes tops out at genus) | Same reads as above, broader reference, but genus is the resolution ceiling |
| **consensus + IdTaxa** | `bin/run_consensus_idtaxa.sh` | Yes (cluster + medaka polish before classifying) | SILVA | No, same ceiling as above | Clustering can itself amplify a reference-driven signal further (observed, not fully explained — see case study below); also the one method whose cost scales with *compositional skew*, not just read count (self-mapping blowup risk) |

**Run all three, every time, by default.** Treat large disagreements
between them as a signal to investigate (that is how the Acidobacteriota
case below was found), not noise to average away. Only skip a method if
the scientist explicitly says so (SP5).

### Case study that justifies this default (keep for context, don't delete)

On a validating Nanopore 16S eDNA dataset, isolating the classifier/reference from the
clustering step gave a clean 3-way gradient for one phylum
(Acidobacteriota): **3.6% (readbased+minimap2) → 9.4%
(readbased+IdTaxa) → 19.3% (consensus+IdTaxa)**. Running only
readbased+minimap2 (the old Variant B) would have reported 3.6% and
nobody would have known to question it. Running only consensus+IdTaxa
(the old Variant A default) would have reported 19.3% with no way to
tell how much of that was reference-coverage vs. clustering amplification.
Only running all three — and specifically the middle one, which isolates
the reference-swap effect from the clustering effect — made the
decomposition possible. The same reasoning applies to any future dataset:
you don't know in advance which phylum/genus will show this kind of
method-sensitivity, so don't pre-commit to one method.

## When to Use This Skill

- **Continue** an existing Nanopore 16S run whose `pipeline_state.json`
  exists (verdict ≥ `GO-WITH-WARNINGS`).
- **Run one or more stages** of the manual pipeline (QC, then the three
  classification methods, then interpret).
- **Resume** a partially-completed run — each `bin/run_*.sh` script is
  idempotent-ish at the sample level (reruns overwrite that sample's
  outputs) but does not itself skip already-done samples; track progress
  via `pipeline_state.json.completed_stages` and only invoke scripts for
  stages not yet complete.

## Do NOT use this skill

- If there is **no `pipeline_state.json`** → invoke
  `preflight/ednanopore-intake` first.
- If the upstream intake verdict is **`NO-GO`** → fix the failing evidence
  item first, then re-run intake.
- If you want to **interpret already-completed results** → invoke
  `interpret/ednanopore-interpret` instead.
- If you only want to tail a log → use `tail -f` directly, no skill
  needed.

## 0. Inputs / Outputs contract

### Inputs (consumed)

| Path | Source | Required? | Notes |
| --- | --- | --- | --- |
| `results/{run_id}/pipeline_state.json` | `preflight/ednanopore-intake` | yes | Must exist with `verdict ∈ {GO, GO-WITH-WARNINGS}`. Drives which stages have run and what's next. |
| `results/{run_id}/params.json` | `preflight/ednanopore-intake` | yes | Run-specific parameter overrides, merged on top of `runners/manual-runner/defaults/16s-nanopore.json`. |
| `results/{run_id}/manifest.tsv` | `preflight/ednanopore-intake` | yes | `sample_id<TAB>fastq_filename`, one row per sample (no header). Consumed directly by every `bin/run_*.sh` script. |
| `runners/manual-runner/defaults/16s-nanopore.json` | this skill (bundled) | yes | The single flexible default-parameter set; see its `qc` / `readbased_minimap2` / `readbased_idtaxa` / `consensus` sub-objects. |

### Outputs (produced)

| Path | Format | Owner | Notes |
| --- | --- | --- | --- |
| `results/{run_id}/pipeline_state.json` | JSON (updated) | this skill | After each successful stage: extend `completed_stages`, update `last_stage`, append new paths to `outputs`. **Never** update on failure. |
| `results/{run_id}/run_summary.json` | JSON | this skill | Compact run summary read by `interpret/ednanopore-interpret`. Written once all three classification methods (or the subset the scientist chose at SP5) are complete. |
| `results/{run_id}/qc/{sample}/...` | per-sample FASTQs + logs | `bin/run_qc.sh` | Shared QC output, consumed by all three classification methods. |
| `results/{run_id}/readbased_minimap2/...` | taxon-abundance TSVs | `bin/run_readbased_minimap2.sh` | |
| `results/{run_id}/readbased_idtaxa/...` | taxon-abundance TSVs | `bin/run_readbased_idtaxa.sh` | |
| `results/{run_id}/consensus_idtaxa/...` | ASV table + taxonomy + agglomerated data | `bin/run_consensus_idtaxa.sh` | |

### Verdict gate enforcement

Before running any stage, **read `pipeline_state.json.verdict`**. If
`NO-GO` or missing → SP1 fires (refuse to execute). If
`GO-WITH-WARNINGS` → one confirmation prompt before proceeding.

## 0.5 Ask-User Stop Points

### SP1 — Pre-flight verdict gate fails

| Trigger | Action |
| --- | --- |
| `pipeline_state.json` missing OR `verdict` is `NO-GO`/missing | Hard-stop: "No valid `pipeline_state.json` for run `{run_id}`. Invoke `preflight/ednanopore-intake` first." |
| `verdict == GO-WITH-WARNINGS` | Ask: "Verdict is `GO-WITH-WARNINGS` (`<failing items>`). (A) continue anyway, (B) re-run intake to fix the warnings (recommended), (C) abort" |

**Auto-pick when**: `verdict == GO`.

### SP2 — Pipeline-state schema mismatch

| Trigger | Action |
| --- | --- |
| `pipeline` field is not `ednanopore` | Ask: "State at `<path>` doesn't look like ednanopore intake. (A) wrong `run_id` — give me the right one, (B) typo in the state file — I'll fix it, (C) abort" |
| `marker` has no matching preset under `runners/manual-runner/defaults/` | Ask: "State file names marker `<marker>` but there's no preset for it (it predates v0.5.0, or a custom preset was deleted). (A) scaffold the preset now (SP2b path), (B) fix the marker field, (C) abort" |

**Auto-pick when**: `pipeline == "ednanopore"` AND a preset resolves for `marker` (any bundled marker since v0.5.0).

### SP3 — Failure-handling choice

| Trigger | Action |
| --- | --- |
| A `bin/run_*.sh` script exits non-zero, or a per-sample log contains `ERROR`/`Error`/`Traceback` | Ask: "`<script>` failed for `<sample(s)>` with `<excerpt>`. (A) retry — adjust a parameter in `params.json` and rerun that script, (B) skip this sample/method and continue, (C) abort (state preserved, resumable)" |

**Auto-pick when**: exit code 0 and no error signature in the log.

### SP4 — Resume-from-stage ambiguity

| Trigger | Action |
| --- | --- |
| `completed_stages` has ≥ 2 entries and the scientist said only "continue" | Ask: "`<N>` stages already complete (`<list>`). (A) run only the next stage, (B) run all remaining stages, (C) run a specific stage/method (tell me which)" |

**Auto-pick when**: `completed_stages` has ≤ 1 entry (default: next stage only).

### SP5 — Scientist wants to skip a method

| Trigger | Action |
| --- | --- |
| Scientist explicitly says to skip one of the three classification methods (e.g. "just do consensus", "skip readbased-idtaxa") | Ask once, with the blind-spot table from "Why three methods, not one" reproduced inline: "Running only `<method(s)>` means you lose `<the other method(s)>`'s blind-spot coverage — specifically `<relevant blind spot from the table>`. (A) proceed with just `<method(s)>` anyway, (B) run all three (recommended), (C) abort and reconsider" |

**Auto-pick when**: scientist did not ask to skip anything — default is all three.

### Operating rule

> **Auto-pick when the evidence is unambiguous; ask when the agent
> genuinely cannot decide.** Present evidence, then recommendation, then
> 2-4 concrete options.

## Prerequisites

- **Environment**: `pixi` on PATH (validated by
  `preflight/ednanopore-intake` evidence item E6). No Nextflow, no
  Java — those are no longer dependencies of this skill.
- **Upstream evidence**: `results/{run_id}/pipeline_state.json` with
  verdict ≥ `GO-WITH-WARNINGS` (SP1).
- **User-provided inputs**: `run_id`; optionally which stage/method
  (incremental / all remaining / specific).

## Procedure

### Step 1 — Locate the run

Ask if not already stated: "What is the `run_id` for this run?"

Read `results/{run_id}/pipeline_state.json`. Enforce the verdict gate
(SP1) and schema check (SP2).

### Step 2 — Determine what to run

Stage list (methods are independent of each other after `qc` completes —
they can run in any order, or in parallel background jobs, since each
writes to its own `results/{run_id}/{method}/` directory):

| `last_stage` | Next stage | Script |
| --- | --- | --- |
| `intake` | `qc` | `bin/run_qc.sh` |
| `qc` | `readbased_minimap2` | `bin/run_readbased_minimap2.sh` |
| `qc` (or `readbased_minimap2` done) | `readbased_idtaxa` | `bin/run_readbased_idtaxa.sh` |
| `qc` (or either above done) | `consensus_idtaxa` | `bin/run_consensus_idtaxa.sh` |
| all three classification stages done | — | suggest `interpret/ednanopore-interpret` |

If `completed_stages` has ≥ 2 entries and the scientist only said
"continue", SP4 fires. If the scientist asked to skip one of the three
methods, SP5 fires.

### Step 3 — Construct the command

Each script's full argument list and defaults are documented in its own
header comment (`runners/manual-runner/bin/run_*.sh`) — read the relevant
script before constructing the call so argument order is exact. Resolve
argument values from, in this precedence order: (1) `results/{run_id}/params.json`
run-specific overrides, (2) `runners/manual-runner/defaults/16s-nanopore.json`.

Example (QC stage):
```bash
bash {SKILL_ROOT}/runners/manual-runner/bin/run_qc.sh \
  {SKILL_ROOT}/results/{run_id}/manifest.tsv \
  {input_data_dir} \
  {SKILL_ROOT}/results/{run_id}/qc \
  "{primers_fwd}" "{primers_rev}" \
  {min_length} {min_length_trimmed} {max_length} {min_qual} {threads}
```

Example (all three classification methods, once QC is done — these can be
launched as three separate background jobs since they don't depend on
each other, only on `qc`'s output):
```bash
bash {SKILL_ROOT}/runners/manual-runner/bin/run_readbased_minimap2.sh \
  {run_dir}/manifest.tsv {run_dir}/qc {run_dir}/readbased_minimap2 \
  {ref_mmi} {tax_lookup} {metadata} \
  {min_percent_identity} {min_ref_coverage} {decontam_threshold} {neg_control_column}

bash {SKILL_ROOT}/runners/manual-runner/bin/run_readbased_idtaxa.sh \
  {run_dir}/manifest.tsv {run_dir}/qc {run_dir}/readbased_idtaxa \
  {idtaxa_model} {metadata} \
  {idtaxa_threshold} {decontam_threshold} {neg_control_column} {subsample_n} {subsample_seed}

bash {SKILL_ROOT}/runners/manual-runner/bin/run_consensus_idtaxa.sh \
  {run_dir}/manifest.tsv {run_dir}/qc {run_dir}/consensus_idtaxa \
  {idtaxa_model} {metadata} \
  {cluster_min_identity} {cluster_min_coverage} {yacrd_min_coverage} {medaka_model} \
  {idtaxa_threshold} {decontam_threshold} {neg_control_column} {kingdoms} {target_ranks} {threads}
```

**Before launching `run_readbased_idtaxa.sh` or `run_consensus_idtaxa.sh`
at full scale**, estimate runtime: IdTaxa's classification call uses all
available cores and costs ~0.17-0.2 sec/sequence on a 64-core machine
(measured; scale by core count on other hardware). `run_readbased_idtaxa.sh`
classifies raw reads directly (hundreds of thousands per dataset is
common) — this is why it defaults to subsampling (`subsample_n=10000`).
If the scientist wants the full, non-subsampled run, multiply total read
count by the measured per-sequence rate and tell them the estimate before
running; this can be many hours to about a day. Let the scientist decide
whether to subsample or wait (do not silently pick for them — this is
effectively an SP, ask if the estimate exceeds ~2 hours and the scientist
hasn't already specified full vs. subsampled).

### Step 4 — Show command and wait for confirmation

Display the full command(s) and ask: "I will run: ```bash\n{command}\n```
Proceed? (yes / no / change a parameter)"

If changing a parameter, update `results/{run_id}/params.json` and show
the revised command. Do not execute until confirmed.

### Step 5 — Execute and monitor

Run via the Bash tool. For the long-running methods
(`run_readbased_idtaxa.sh`, `run_consensus_idtaxa.sh`), prefer
`run_in_background` or the Monitor tool over a blocking foreground call,
and report progress as per-sample log lines appear (`[sample] done: N
rows`). Watch for `ERROR`, `Traceback`, non-zero exit — trigger SP3.

### Step 6 — Handle failures (SP3)

1. Extract the relevant per-sample log (`grep -i "error\|traceback" <log>`).
2. Explain the likely cause — see the Signature library below.
3. Present SP3's three options.
4. Do **not** update `pipeline_state.json` for a failed stage.

### Step 7 — Update state on success

After each stage/method completes, read and rewrite
`results/{run_id}/pipeline_state.json`:
- `completed_stages` extended by the newly completed stage
- `last_stage` set accordingly
- `outputs` updated with new paths

### Step 8 — Generate run summary

Once all requested methods are complete:

```bash
python3 - <<'PY'
import json
from pathlib import Path

results_dir = Path("results") / "{run_id}"
state = json.load(open(results_dir / "pipeline_state.json"))

summary = {
    "run_id": state["run_id"],
    "pipeline": state["pipeline"],
    "marker": state["marker"],
    "methods_run": [s for s in state["completed_stages"] if s != "qc" and s != "intake"],
    "completed_stages": state["completed_stages"],
    "last_stage": state["last_stage"],
    "outputs": state.get("outputs", {}),
    "params_used": state.get("params_used", {}),
    "notes": [
        "This run uses ednanopore v0.2.0's default of running all three "
        "classification methods (readbased_minimap2, readbased_idtaxa, "
        "consensus_idtaxa) unless the scientist explicitly chose to skip one "
        "(SP5). Large disagreements between methods are expected and should "
        "be investigated (see run/ednanopore-run/SKILL.md's case study), "
        "not treated as noise."
    ],
}

out_path = results_dir / "run_summary.json"
out_path.write_text(json.dumps(summary, indent=2))
print(f"[run-summary] wrote {out_path}")
PY
```

### Step 9 — Hand off

> "Pipeline complete through `{last_stage}`. Methods run: `{methods_run}`.
> Run summary written to `results/{run_id}/run_summary.json`.
> To interpret results (including a cross-method comparison): invoke
> `interpret/ednanopore-interpret`."

## Troubleshooting — Signature library

| Signature in stderr / log | Likely cause | Suggested fix |
| --- | --- | --- |
| `chopper: input file not found` | Manifest path wrong, or FASTQ not where `manifest.tsv` says | `cat {run_dir}/manifest.tsv`, `ls -la {input_data_dir}` |
| `cutadapt: adapter not found / primer not found in reads` | Primer sequence wrong, or orientation issue not covered by `--revcomp` | Verify primers against the source publication |
| **Read survival through QC is <10%** | **Likely Bug 28/29 territory even with the fixes applied — check `--revcomp` is actually present in the `run_qc.sh` invocation (it's hardcoded in the script, should not need a flag) and that `min_length_trimmed` (not `min_length`) is what's passed as the post-trim floor** | Diff the actual `cutadapt` commands in `{sample}/cutadapt_fwd.log` / `cutadapt_rev.log` against `bin/run_qc.sh`'s documented invocation |
| `minimap2: reference index (.mmi) not found` | `ref_mmi` path wrong or index not built | `minimap2 -d <path> 2>&1 \| head`; rebuild with `minimap2 -d <out.mmi> <ref.fasta>` |
| `minimap2_lca.py: query_fasta is empty` | QC produced no reads for that sample | Check `{sample}/cutadapt_rev.log` read counts; relax `min_length`/`min_qual` in `params.json` |
| `medaka: model <name> not found` | `medaka_model` doesn't match installed medaka version | `pixi run --manifest-path runners/manual-runner/env/cluster/pixi.toml medaka tools list_models` |
| `yacrd: no reads survive coverage filter` | `yacrd_min_coverage` too stringent | Lower toward 0.2-0.3 |
| **Self-mapping step (in `run_consensus_idtaxa.sh`) running for hours on a modest-sized sample** | **Compositional skew, not read count — a sample heavily dominated by one organism makes all-vs-all self-mapping blow up combinatorially** | Check per-sample composition first (`seqkit stats`, or a quick minimap2-LCA pass); this is expected behavior for that kind of sample, not a bug — budget more wall-clock time or accept the method's limitation for that sample |
| `IDTAXA: model file is corrupt or wrong format` | `.RData`/`.rds` wasn't saved correctly, or path is wrong | Re-verify the SHA/size of `assets/16s_idtaxa/SILVA_SSU_r138.2_v2.RData` against its source |
| **`run_readbased_idtaxa.sh` or `run_consensus_idtaxa.sh` producing zero species-level calls** | **Not a bug — the pre-trained SILVA IdTaxa model has no species rank at all (verified: 0 of 14,699 training nodes have a genus-rank parent)** | Do not try to fix by lowering `idtaxa_threshold` — that cannot recover a rank the model was never trained on. Use `readbased_minimap2`'s output for species-level identity instead |
| **Lowering `idtaxa_threshold` below 60 has no effect on output** | **Not a bug — `DECIPHER::IdTaxa()`'s own internal default `threshold` is 60; it never records a confidence value below that, so a downstream filter at the same value is a no-op** | To genuinely change the threshold, it must be passed into the `IdTaxa()` call inside `bin/idtaxa_rds.R` itself (`threshold=` argument), then rerun classification — not just the downstream `filter_idtaxa_by_confidence.jl` step |
| `decontam_by_taxon.jl: neg_col 'is_negative' not found in metadata` | Metadata column-name mismatch | `head -1 metadata.tsv \| tr '\t' ',' \| grep -i negative` |
| `R script: package 'X' is not available` | pixi env for that stage missing the package | `pixi add --manifest-path runners/manual-runner/env/{stage}/pixi.toml r-X` |
| `No space left on device` | Clustering/polishing produces large intermediates | Free ≥ 20 GB; per-sample outputs are independent, so partial progress on other samples is preserved |

## Verification

- [ ] `pipeline_state.json.verdict` was `GO` or `GO-WITH-WARNINGS` before any script was run (SP1).
- [ ] Every `bin/run_*.sh` command was shown to the scientist and explicitly confirmed (Step 4).
- [ ] `completed_stages` was extended only after a stage/method succeeded (Step 7).
- [ ] If the scientist chose to skip a method, SP5 fired and the choice (plus the resulting blind-spot gap) is recorded in `run_summary.json["notes"]`.
- [ ] When all requested methods are complete, `run_summary.json` was generated (Step 8).

## Invariants

- **Never** execute a `bin/run_*.sh` command without showing it first and waiting for confirmation.
- **Never** update `pipeline_state.json` for a stage that failed.
- **Default to running all three classification methods.** Skipping one requires an explicit scientist decision via SP5.
- **Always** report large (e.g. >2x) disagreements between methods to the scientist as a finding to investigate, not a discrepancy to silently resolve in the report.
- **Always** estimate and disclose runtime before launching `run_readbased_idtaxa.sh` or `run_consensus_idtaxa.sh` at full (non-subsampled) scale.
