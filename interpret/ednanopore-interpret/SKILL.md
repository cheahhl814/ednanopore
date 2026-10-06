---
name: ednanopore-interpret
description: "Turn ednanopore pipeline outputs (readbased_minimap2, readbased_idtaxa, consensus_idtaxa — up to three methods, run by default) into a structured Markdown report with a mandatory cross-method comparison, a plain-language narrative summary, and an interactive Q&A session. The report always surfaces large (>2x) disagreements between methods as findings to flag, not noise to average away — this is the core value of running three methods instead of one. Diversity/DAA/correlation sections are consensus_idtaxa-only (it's the only method producing rep-seqs for phylogenetic placement). Refuses to interpret if upstream pipeline_state.json.completed_stages lacks at least one classification method. Has 4 explicit ask-user stop points (SP1-SP4). Triggers: 'interpret Nanopore 16S results', 'ONT 16S report', 'summarize Nanopore run', 'MinION 16S Results section', 'eDNA Nanopore diversity interpretation', 'eDNA Nanopore differential abundance', 'compare Nanopore classification methods'."
version: 0.4.0
updated: "2026-10-06"
triggers:
  - "interpret Nanopore 16S results"
  - "ONT 16S report"
  - "summarize Nanopore run"
  - "MinION 16S Results section"
  - "eDNA Nanopore diversity interpretation"
  - "eDNA Nanopore differential abundance"
  - "compare Nanopore classification methods"
---

# ednanopore-interpret

> **v0.2.0.** v0.1.0 had a mandatory "Pipeline Variant & Limitations"
> banner because the scientist had picked exactly one of two
> mutually-exclusive variants at intake. v0.2.0 replaces it with a
> mandatory **"Methods Run & Cross-Method Comparison"** banner, because
> up to three methods now run on the same samples by default. This is not
> a cosmetic rename — the comparison section is this report's most
> important output. A real cross-method comparison on this project's
> dataset found a 3.6% / 9.4% / 19.3% spread for one phylum's abundance
> across the three methods on identical samples; a report that only
> showed one method's number would have hidden that entirely. Diversity /
> DAA / correlation remain limited to `consensus_idtaxa` output (same
> underlying reason as before — only that method produces rep-seqs for a
> phylogenetic tree), but the limitation is now framed as "this specific
> method's ceiling," not "the variant you didn't pick."

## Audience

- **AI Coding Agents** — triggered by the phrases above. Read
  `pipeline_state.json.completed_stages` and enforce the gate (SP1), run
  the anomaly scan (SP2) including a cross-method divergence check, and
  write `<run_id>-report.md` grounded in real data — never invent
  findings.
- **Human Nanopore eDNA scientists** — read this as a workflow guide
  explaining why the comparison section exists and why a large
  disagreement between methods is something to investigate, not resolve
  by picking a favorite number.

## When to Use This Skill

- **Interpret a completed Nanopore 16S run** (at least one classification method has run).
- **Generate `<run_id>-report.md`** with Run Summary, Methods Run & Cross-Method Comparison, QC, Taxonomy Overview (per method + comparison), Diversity/DAA/Correlation (consensus_idtaxa only), Caveats.
- **Generate a plain-language narrative** for a manuscript Results-section draft.
- **Enter an interactive Q&A session**.

## Do NOT use this skill

- If `pipeline_state.json.completed_stages` contains **no** classification method (SP1 hard-stop).
- If you only want to **look at raw output files** — use `Read`/`Bash` directly.
- If you want to **re-run the pipeline** — invoke `run/ednanopore-run` instead.
- If the run is still **in progress** on a method you need — wait for it, or interpret the subset that's done (SP3).
- If your data is **Illumina** short reads — use `nf-edna`'s `interpret/edna-interpret`.

## 0. Inputs / Outputs contract

### Inputs (consumed)

| Path | Source | Required? | Notes |
| --- | --- | --- | --- |
| `results/{run_id}/pipeline_state.json` | `run/ednanopore-run` | yes | `completed_stages` must include ≥1 classification method (SP1). Used for `run_id`, `pipeline`, `marker`, `methods`, `params_used`, `outputs`. |
| `results/{run_id}/run_summary.json` | `run/ednanopore-run` Step 8 | yes | Metadata-only summary (methods run, file-presence flags, stage list). Per-stage numeric detail is read directly from output files. |
| `results/{run_id}/{method}/...` | `bin/run_*.sh` scripts | conditional | Read on-demand: per-sample counts, taxonomy tables, decontam summaries. |

### Outputs (produced)

| Path | Format | Owner | Notes |
| --- | --- | --- | --- |
| `results/{run_id}/{run_id}-report.md` | Markdown | this skill | Sections: Run Summary, **Methods Run & Cross-Method Comparison** (mandatory), QC Summary, Taxonomy Overview (per method, then comparison), Alpha/Beta Diversity (`consensus_idtaxa` only), Differential Abundance (`consensus_idtaxa` only), Correlation Analysis (`consensus_idtaxa` only), Caveats. |
| `results/{run_id}/narrative.md` | Markdown | this skill | 2-3 paragraph plain-language summary, names which methods were run and flags any large cross-method divergence in its first paragraph. |
| (no on-disk output for Q&A) | conversation | this skill | Transcript saved only if the scientist asks (SP4). |

### Verdict gate enforcement

Before reading any output, read `pipeline_state.json.completed_stages`. If it contains none of `readbased_minimap2`/`readbased_idtaxa`/`consensus_idtaxa` → SP1 fires.

## 0.5 Ask-User Stop Points

### SP1 — Stage-completeness gate

| Trigger | Action |
| --- | --- |
| `completed_stages` has no classification method | Hard-stop: "No classification method has completed for this run (`completed_stages` = `<list>`). Run `run/ednanopore-run` first, or I can describe the QC outputs so far — want that?" |

**Auto-pick when**: ≥1 method is in `completed_stages`.

### SP2 — Anomaly severity (including cross-method divergence)

| Trigger | Action |
| --- | --- |
| Any of: zero classified reads/taxa in a completed method; empty taxonomy table; very low read counts; missing expected output files; blank contamination in shared negatives; no decontam filtering despite contaminated blanks; **any phylum/genus differing >2x in relative abundance between two completed methods** | A report that doesn't surface these would mislead | Ask: "I detected `<N>` anomalies before writing the report (listed below, including any >2x cross-method divergences). (A) proceed, surfacing each prominently in the comparison/Caveats sections (recommended), (B) investigate first — tell me which to dig into, (C) abort until upstream re-runs\n\nAnomalies:\n- `<list>`" |

**Auto-pick when**: zero anomalies AND no cross-method divergence >2x on the top 10 most abundant phyla.

### SP3 — Report-scope ambiguity

| Trigger | Action |
| --- | --- |
| Only a subset of the three methods have completed, or the scientist asks for diversity/DAA/correlation and `consensus_idtaxa` hasn't completed | Ask: "`<N>` of 3 methods complete (`<list>`). (A) write the report for what's done, marking missing methods' sections as 'Output unavailable' and noting the comparison is partial (recommended), (B) write only what's fully available, (C) wait for more methods to finish" |

**Auto-pick when**: all methods the scientist asked about are complete.

### SP4 — Q&A termination

| Trigger | Action |
| --- | --- |
| Scientist signals completion, or no follow-up for ≥3 turns | Ask: "Before closing: (A) save the Q&A transcript to `results/{run_id}/qa_transcript.md`, (B) discard, (C) append it to the report inline" |

**Auto-pick when**: mid-Q&A (no ask — the Q&A is the conversation).

### Operating rule

> **Auto-pick when the evidence is unambiguous; ask when the agent genuinely cannot decide.**

## Description

Turn pipeline output files into scientific understanding: a structured
report whose centerpiece is the cross-method comparison (not any single
method's numbers taken at face value), a narrative summary, and an
interactive Q&A session grounded in the actual data.

## Prerequisites

- **Environment**: pixi env with `python ≥ 3.10`.
- **Upstream evidence**: `results/{run_id}/pipeline_state.json` with ≥1 classification method complete (SP1), and `results/{run_id}/run_summary.json`.
- **User-provided inputs**: `run_id`.

## Procedure

### Step 1 — Locate the run + enforce gate (SP1)

Ask if not stated: "What is the `run_id` for the run you want to interpret?"

Read `results/{run_id}/pipeline_state.json`. Enforce SP1. Extract `methods` (which of the three ran) — this drives the report template (Step 3) and SP3.

### Step 2 — Load run summary

Read `results/{run_id}/run_summary.json` if present (primary data source). If absent, generate it via the inline snippet from `run/ednanopore-run` Step 8.

### Step 2b — Anomaly scan, including cross-method divergence (SP2 trigger)

Before writing anything:

- **Zero classified reads/taxa**, **empty taxonomy**, **missing expected files**, **very low read counts**, **blank contamination** — same checks as before, applied per completed method.
- **Cross-method divergence** (new, and the most important check): for every method pair that both completed, compute mean relative abundance per phylum (and per genus if time allows) and flag any phylum where the ratio between two methods' estimates exceeds 2x. This is not automatically a problem — it may be a genuine, informative finding (see the Acidobacteriota case: 3.6% / 9.4% / 19.3% across the three methods was real and traceable to RefSeq vs. SILVA coverage, not a bug) — but it must never be silently smoothed over. Report the magnitude and, if you can isolate which factor (reference database vs. clustering) using the specific method pairs available, say so; if you can't fully isolate it, say that too.
- **Consensus method missing rep-seqs**: if `consensus_idtaxa` is in `methods` but `outputs.rep_seqs`/`filtered_rep_seqs.fna` is missing, flag for investigation — it must produce rep-seqs by construction.

### Step 3 — Mode 1: Structured report

Write `results/{run_id}/{run_id}-report.md`.

#### Run Summary

Pipeline (`ednanopore`), marker (`16S`), run ID, methods run, parameters used (primers, length range, kingdoms, `medaka_model` if `consensus_idtaxa` ran), sample count, completed stages.

#### Methods Run & Cross-Method Comparison (mandatory banner — always first after Run Summary)

```markdown
## Methods Run & Cross-Method Comparison

This run used **`{methods}`** of ednanopore's three classification methods.

| Method | Error-corrects reads? | Reference | Species-level? |
| --- | --- | --- | --- |
| readbased_minimap2 | No | RefSeq (or similar) | Yes |
| readbased_idtaxa | No | SILVA | No (model has no species rank) |
| consensus_idtaxa | Yes (cluster + medaka) | SILVA | No (model has no species rank) |

[If 2+ methods ran:] ### Phylum-level comparison

| Phylum | {method 1} | {method 2} | {method 3} |
|---|---|---|---|
| ... top 10-15 by combined abundance ...

**Divergences >2x:** {list any, with the magnitude and, where isolable, which
factor — reference database vs. clustering — likely explains it. If a
divergence can't be explained with the methods available, say that explicitly
rather than guessing.}

[If only 1 method ran:] This report reflects only `{method}` — the other
two methods' blind spots (see run/ednanopore-run/SKILL.md's method table)
are not cross-checked in this report. Consider re-running with all three.
```

This banner must be the first thing after Run Summary — never buried in Caveats.

#### QC Summary

Per-sample trimmed read counts (`qc/{sample}/{sample}.trimmed.fastq.gz`), blank read counts, any sample <1,000 reads, number of samples passing trimming. (Shared across all methods — compute once.)

#### Taxonomy Overview

For each method in `methods`, report: row/ASV count, classification rate per rank, top taxa by total reads at the finest available rank. Then a **cross-method summary**: top 5 taxa that are abundant in every method vs. taxa that appear substantially in only one (candidates for the blind-spot cases documented in `run/ednanopore-run/SKILL.md`).

Note: `readbased_idtaxa` and `consensus_idtaxa` will show 0% species-level resolution — this is expected (no species rank in the SILVA training set), not a failure. Don't flag it as an anomaly.

#### Alpha Diversity / Beta Diversity / Differential Abundance / Correlation Analysis *(`consensus_idtaxa` only)*

Same content/sources as before (`asv_table`/`taxonomy/agglomerated_data` under `results/{run_id}/consensus_idtaxa/`). If `consensus_idtaxa` is not in `methods`: "**Not produced.** Only `consensus_idtaxa` produces rep-seqs for phylogenetic diversity/DAA/correlation; this run didn't include that method." If `consensus_idtaxa` ran but didn't reach these stages: "Output unavailable."

#### Caveats

Anomalies from SP2 (including cross-method divergences not already resolved in the comparison section), stages/methods that didn't run, decontam summary presence/absence, blank contamination, low classification rates, ONT-specific indel-error caveats, `medaka_model` choice if non-default.

### Step 4 — Mode 2: Narrative summary

2-3 paragraphs, appended under `## Narrative Summary`. First sentence names which method(s) were run. If a cross-method divergence was found, name it and its likely cause in the first paragraph — don't bury it. Past tense, passive voice, avoid jargon for a general audience.

### Step 5 — Mode 3: Interactive Q&A

> "Report complete. Ask me anything — e.g. which taxa drive group separation, whether a low read count is a problem, why two methods disagree on a phylum, what functional roles the dominant taxa likely have."

Ground every answer in actual files. If a question needs `consensus_idtaxa`-only output and that method didn't run, say so plainly — don't compute it on the fly. SP4 fires when the scientist signals they're done.

## Troubleshooting — Signature library

| Signature in stderr / log | Likely cause | Suggested fix |
| --- | --- | --- |
| `run_summary.json missing` | `run/ednanopore-run` Step 8 skipped/failed | Re-run that step's inline snippet |
| `pipeline_state.json.methods missing or empty` | State predates v0.2.0, or intake didn't resolve scope | Re-run `preflight/ednanopore-intake` |
| **`Phylum X differs >2x between methods`** | **Not automatically a bug** — could be a genuine reference-coverage or clustering effect (see the Acidobacteriota case study) | Report it; try to isolate using whichever method pair differs only in reference (readbased_minimap2 vs readbased_idtaxa) vs. only in clustering (readbased_idtaxa vs consensus_idtaxa) |
| `species-level resolution is 0% for readbased_idtaxa / consensus_idtaxa` | Expected — the SILVA IdTaxa model has no species rank | Not an anomaly; use `readbased_minimap2` for species-level claims |
| `top_taxa table empty at finest rank` | All features filtered at that agglomeration rank | Fall back to the next coarser rank; mention the fallback in Caveats |
| `blank contamination, scientist asks "which site is affected?"` | Negative controls are shared across all biological samples | Say contamination findings apply run-wide, not per-site |
| `Outputs paths in pipeline_state.json point to a different machine's home directory` | State generated elsewhere and copied | Don't trust `outputs` paths literally; navigate relative to the current `results/{run_id}/` |
| `Q&A answer requires consensus_idtaxa output and it didn't run` | Scope limitation, not a bug | Say so; recommend re-running with `consensus_idtaxa` included if needed |

## Verification

- [ ] `<run_id>-report.md` has the **Methods Run & Cross-Method Comparison** banner as the first section after Run Summary — always present, even for a single-method run.
- [ ] Every reported number traces to `run_summary.json` or a specific output file.
- [ ] Every anomaly from SP2 (including any >2x cross-method divergence) is in the comparison section or Caveats.
- [ ] The narrative names the method(s) run and any major divergence in its first paragraph.
- [ ] If Q&A ran and a transcript was requested, it's at `results/{run_id}/qa_transcript.md`.

## Invariants

- Never write a report section from assumed data — read the actual files.
- Never omit the Methods Run & Cross-Method Comparison banner.
- **Never** silently resolve a cross-method disagreement by picking one number — report the spread and your best explanation (or say you can't fully explain it).
- Never claim a taxon was detected without reading the taxonomy file.
- Never compute diversity/DAA/correlation on the fly for a run that didn't include `consensus_idtaxa`.
