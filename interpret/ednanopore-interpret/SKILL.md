---
name: ednanopore-interpret
description: "Turn ednanopore pipeline outputs (readbased_minimap2, readbased_idtaxa, consensus_idtaxa — up to three methods, run by default) into a structured Markdown report with a mandatory cross-method comparison, an optional quantified cross-method comparison (compare_classifications.R — per-read rank agreement + abundance-lineage side-by-side), a plain-language narrative summary, and an interactive Q&A session. Diversity/DAA sections are consensus_idtaxa-only (only method producing rep-seqs): alpha diversity incl. Pielou, rarefaction curves, beta/PERMANOVA, and differential abundance with Maaslin2 AND ANCOM-BC run side by side, never averaged/merged. Refuses to interpret if upstream pipeline_state.json.completed_stages lacks at least one classification method. Has 5 explicit ask-user stop points (SP1-SP5). Triggers: 'interpret Nanopore 16S results', 'ONT 16S report', 'summarize Nanopore run', 'MinION 16S Results section', 'eDNA Nanopore diversity interpretation', 'eDNA Nanopore differential abundance', 'compare Nanopore classification methods'."
version: 0.6.0
updated: "2026-11-11"
triggers:
  - "interpret Nanopore 16S results"
  - "ONT 16S report"
  - "summarize Nanopore run"
  - "MinION 16S Results section"
  - "eDNA Nanopore diversity interpretation"
  - "eDNA Nanopore differential abundance"
  - "compare Nanopore classification methods"
disable-model-invocation: true
---

# ednanopore-interpret

> **v0.6.0.** Three additions from the edna-agent v1.3.x cross-skill review:
> (1) **Optional quantified cross-method comparison** (`bin/compare_classifications.R`
> in `runners/manual-runner/bin/` — per-read mode compares minimap2 vs
> readbased-IdTaxa on the SAME trimmed reads (identical SequenceID+rank-column
> contract); abundance mode folds in consensus via lineage tables / per-rank
> agglomerated tables, producing pairwise rank-agreement stats (shared taxa,
> Jaccard, median fold ratio, Spearman, >2x flagged taxa) plus side-by-side
> rel-abundance tables. The canonical taxonomy stays the primary method's —
> **side by side, never merged** (same rule as Maaslin2/ANCOM-BC). Ask the
> scientist at run time (new SP5) unless `params.json.classification_comparison`
> is preset true/false.
> (2) **Rarefaction curves** (`bin/rarefaction.R`, env `diversity`, mirrors QIIME2
> alpha-rarefaction — expected richness vs depth per sample).
> (3) **ANCOM-BC differential abundance** (`bin/ancombc_differential.R`, env
> `association`) alongside Maaslin2 — compositional-bias-corrected LFC;
> both run side by side, their disagreement is a robustness signal, never averaged.

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

- **Interpret a completed Nanopore run** (any marker; the report header records which marker/preset ran). (at least one classification method has run).
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

### SP5 — Quantified cross-method comparison (v0.6.0, ask at run time)

| Trigger | Evidence check | Action |
| --- | --- | --- |
| `params.json.classification_comparison` is `true` | preset | Auto-run: execute the comparison battery (Step 2c) and embed its tables in the comparison section |
| `params.json.classification_comparison` is `false` | preset | Auto-skip: prose comparison only (pre-v0.6.0 behavior) |
| Flag absent AND ≥2 classification methods completed | read-write context | Ask once: "`<N>` classification methods ran. I can run the quantified comparison (`bin/compare_classifications.R`): per-read minimap2-vs-IdTaxa rank agreement on the same trimmed reads, plus abundance-level side-by-side vs consensus — adds minutes of compute, produces pairwise-agreement TSVs and side-by-side tables (never merged). (A) run it (recommended), (B) prose comparison only, (C) abort" |
| Flag absent AND <2 methods completed | — | No ask — comparison impossible; note the limitation in the report |

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
- **Rejection audit (v0.5.1, zero compute — run it FIRST)**: per completed method, compute the unclassified fraction U (reads with no taxonomic assignment at any rank) over the method's true-sample reads. This is the Step-0 gate from the classifier debate: U ≈30% is the decision point; a large U on modern-chemistry (Q20+) reads means reference-driven per-read rejection, not error suppression; a small U (<20%) means recovery-as-main-channel is not supported. When per-read classification files and QC'd FASTQs are both present, also stratify the rejected pool by read quality (mean/median Q of rejected vs classified reads): clean rejected reads (Q20+) ⇒ reference-driven; noisy rejected reads ⇒ error-driven — report which branch the evidence supports.
- **Cross-method divergence**: for every method pair that both completed, compute mean relative abundance per phylum (and per genus if time allows) and flag any phylum where the ratio between two methods' estimates exceeds 2x. This is not automatically a problem — it may be a genuine, informative finding (see the Acidobacteriota case study: 3.6% / 9.4% / 19.3% in the original run was real and traced to reference coverage, not a bug; on the modern-chemistry 10k battle-test the same phylum decomposed as 9.2% / 15.8% / 14.8–17.1% with the gap dominated by the reference swap) — but it must never be silently smoothed over. With all three methods run, report the **decomposition arithmetic**: reference effect = (a)→(b) delta (same trimmed reads, RefSeq→SILVA), pooling/polish effect = (b)→(c) delta (same classifier+reference, clustered+polished reads). If you can't fully isolate the factor, say that too.
- **Consensus method missing rep-seqs**: if `consensus_idtaxa` is in `methods` but `outputs.rep_seqs`/`filtered_rep_seqs.fna` is missing, flag for investigation — it must produce rep-seqs by construction.

### Step 2c — Quantified cross-method comparison battery (v0.6.0, SP5)

Run only when SP5 resolved to "run" (preset `true` or the scientist opted in). The battery never touches the canonical method outputs — it writes into `results/{run_id}/classification_comparison/`.

**(a) Per-read agreement: readbased_minimap2 vs readbased_idtaxa** — these two classify the SAME trimmed reads (identical `SequenceID` + rank-column contract), so per-sample comparison on shared SequenceIDs isolates the reference-swap effect (this is the (a)→(b) delta of the bracket decomposition). Run per sample (read IDs are unique per sample FASTQ — don't pool files):

```bash
for s in $(awk -F'\t' '{print $1}' results/{run_id}/manifest.tsv); do
  pixi run --manifest-path {SKILL_ROOT}/pixi.toml -e classification \
    Rscript {SKILL_ROOT}/runners/manual-runner/bin/compare_classifications.R \
    --mode per_read \
    --classifications minimap2=results/{run_id}/readbased_minimap2/tax/${s}.minimap2_lca_classification.tsv \
                      idtaxa=results/{run_id}/readbased_idtaxa/tax/${s}.idtaxa_classification.tsv \
    --output_pairwise results/{run_id}/classification_comparison/per_read/${s}_pairwise.tsv \
    --output_concordance results/{run_id}/classification_comparison/per_read/${s}_concordance.tsv
done
```

Use the UNFILTERED idtaxa classification (not `*_confident.tsv`) so the unassigned fractions stay comparable — the confidence filter lives downstream of both methods.

**(b) Abundance-level: fold in consensus_idtaxa** — different ID space (polished cluster consensuses), so compare via lineage tables / per-rank agglomerated tables:

```bash
pixi run --manifest-path {SKILL_ROOT}/pixi.toml -e classification \
  Rscript {SKILL_ROOT}/runners/manual-runner/bin/compare_classifications.R \
  --mode abundance \
  --taxon_tables minimap2=lineage_table=results/{run_id}/readbased_minimap2/tax/decontam_taxon_abundance.tsv \
                  idtaxa=lineage_table=results/{run_id}/readbased_idtaxa/tax/decontam_taxon_abundance.tsv \
                  consensus=rank_table:genus=results/{run_id}/consensus_idtaxa/taxonomy/agglomerated_data/genus_counts.tsv \
  --ranks phylum class family genus \
  --output_pairwise results/{run_id}/classification_comparison/abundance_pairwise.tsv \
  --output_table results/{run_id}/classification_comparison/abundance_side_by_side.tsv
```

(If a per-rank agglomerated table is missing, regenerate it via `bin/agglomerate_data.R` first; a lineage-table spec also accepts the per-rank `*_counts.tsv` shape as `rank_table:<rank>`.)

When consensus_idtaxa didn't run, omit its spec — the script requires ≥2.

**Reporting rule:** quote the comparison numbers side by side in the Methods-Run banner and cite the TSV paths; flag any `n_divergent_gt2x > 0` row; never merge methods into one table and never pick one method's number as "correct" — the decomposition is the finding.

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

**Divergences, reported as bracket + decomposition (v0.5.1):** {for each
flagged phylum: the bracket (a)..(b)..(c), the reference-effect delta
(a→b) and the pooling/polish-effect delta (b→c), and which factor the
arithmetic says dominates. When only 2 methods ran, name the single
delta and its candidate factor explicitly — with no (b), the reference
and pooling effects are confounded and must not be split by guessing.
If a divergence can't be explained with the methods available, say that
explicitly rather than guessing.}

[If only 1 method ran:] This report reflects only `{method}` — the other
two methods' blind spots (see run/ednanopore-run/SKILL.md's method table)
are not cross-checked in this report. Consider re-running with all three.
```

This banner must be the first thing after Run Summary — never buried in Caveats.

> **v0.5.1 upgrade — rejection-audit table + bracket reporting.** Two
> changes from the 10k battle-test round 4: (1) the comparison must open
> with a **rejection-audit table** (per method: denominator reads,
> unclassified n/%, and the rejected pool's median read quality when QC
> data is present) — the unclassified reservoir is the evidence that
> decides what a disagreement means; (2) divergences are reported as a
> **bracket + decomposition arithmetic** — reference effect = (a)→(b)
> delta (same reads, swapped reference), pooling/polish effect = (b)→(c)
> delta (same classifier+reference, clustered reads) — never as a bare
> >2x flag. On the battle-test dataset this resolved the Acidobacteriota
> case: 9.2% (a) / 15.8% (b) / 14.8–17.1% (c) ⇒ the gap is
> reference-driven (RefSeq→SILVA +6.6 pt); pooling adds only ~+1.3 pt.
> Evidence: `run/stage1-audit-report.md` + the round-4 wiki audits.

#### QC Summary

Per-sample trimmed read counts (`qc/{sample}/{sample}.trimmed.fastq.gz`), blank read counts, any sample <1,000 reads, number of samples passing trimming. (Shared across all methods — compute once.)

#### Taxonomy Overview

For each method in `methods`, report: row/ASV count, classification rate per rank, top taxa by total reads at the finest available rank. Then a **cross-method summary**: top 5 taxa that are abundant in every method vs. taxa that appear substantially in only one (candidates for the blind-spot cases documented in `run/ednanopore-run/SKILL.md`).

Note: `readbased_idtaxa` and `consensus_idtaxa` will show 0% species-level resolution — this is expected (no species rank in the SILVA training set), not a failure. Don't flag it as an anomaly.

#### Alpha Diversity / Rarefaction / Beta Diversity / Differential Abundance / Correlation Analysis *(`consensus_idtaxa` only)*

Same content/sources as before (`asv_table`/`taxonomy/agglomerated_data` under `results/{run_id}/consensus_idtaxa/`; consensus method did not run: "**Not produced.** Only `consensus_idtaxa` produces rep-seqs for phylogenetic diversity/DAA/correlation; this run didn't include that method." If it ran but didn't reach these stages: "Output unavailable.").

v0.6.0 additions to this section:

- **Pielou evenness** — `bin/alpha_diversity.R` now computes `pielou` (Shannon / log(observed); NA for 0-feature samples) alongside observed/shannon/faith automatically; include it in the alpha table and plots.
- **Rarefaction curves** (mirrors QIIME2 `alpha-rarefaction`; run under env `diversity` against the agglomerated ASV counts + metadata):
```bash
pixi run --manifest-path {SKILL_ROOT}/pixi.toml -e diversity \
  Rscript {SKILL_ROOT}/runners/manual-runner/bin/rarefaction.R \
  --input_asv_counts results/{run_id}/consensus_idtaxa/taxonomy/agglomerated_data/asv_counts.tsv \
  --input_metadata results/{run_id}/metadata.tsv \
  --output_dir results/{run_id}/diversity/rarefaction \
  --grouping_variable {grouping_variable}
```
  Report per-sample observed totals and the shallowest-sample depth (the curve ceiling); a curve still rising at that ceiling means the group's richness estimate is depth-limited — say so in Caveats.
- **Differential abundance — Maaslin2 AND ANCOM-BC, side by side, never averaged (v0.6.0).** Keep the existing Maaslin2 run (`bin/differential_abundance.R`, TSS normalization) and add ANCOM-BC (compositional-bias-corrected log-fold changes):
```bash
pixi run --manifest-path {SKILL_ROOT}/pixi.toml -e association \
  Rscript {SKILL_ROOT}/runners/manual-runner/bin/ancombc_differential.R \
  --input_asv_counts results/{run_id}/consensus_idtaxa/taxonomy/agglomerated_data/genus_counts.tsv \
  --input_asv_taxonomy results/{run_id}/consensus_idtaxa/taxonomy/agglomerated_data/genus_taxonomy.tsv \
  --input_metadata results/{run_id}/metadata.tsv \
  --grouping_variable {grouping_variable} --reference_level {reference_level} \
  --level_to_analyze Genus \
  --output_dir results/{run_id}/association/ancombc_genus
```
  Report both methods' significant taxa side by side (one table: taxon, Maaslin2 result, ANCOM-BC result): taxa significant in BOTH are high-confidence; significant in only one are reported as method-sensitive, not dismissed. Never average p-values/LFCs across methods and never merge them into a single "consensus DA" list (same rule as the classification comparison).

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
| `compare_classifications.R: No common SequenceIDs` | Per-read files are from different samples/different stages (e.g. confident-filtered vs unfiltered), or files were pooled across samples | Compare per sample with the unfiltered idtaxa classification; never pool read-ID files across samples |
| `compare_classifications.R rank_table spec needs a valid rank` | Per-rank agglomerated table missing or rank misspelled | Regenerate via `bin/agglomerate_data.R`; valid ranks: superkingdom, phylum, class, order, family, genus, species |
| `ancombc_differential.R: Bioconductor package ANCOMBC not available` | association env not re-solved after the v0.6.0 pixi.toml addition | `pixi install --manifest-path <skill>/pixi.toml -e association`, then retry |
| `rarefaction.R Error in rarefy(counts_t, sample = d)` | vegan version drift: unnamed-vector or arg-name drift | F18 pattern (edna-agent round 4): name rarefy output explicitly; check `r-vegan` pin `>=2.7_2,<3` |

## Verification

- [ ] `<run_id>-report.md` has the **Methods Run & Cross-Method Comparison** banner as the first section after Run Summary — always present, even for a single-method run.
- [ ] Every reported number traces to `run_summary.json` or a specific output file.
- [ ] Every anomaly from SP2 (including any >2x cross-method divergence) is in the comparison section or Caveats.
- [ ] The narrative names the method(s) run and any major divergence in its first paragraph.
- [ ] The **rejection-audit table** (denominator reads, unclassified n/%, rejected-pool quality where computable) opens the comparison section.
- [ ] Every >2x divergence carries the **bracket + decomposition arithmetic** (reference delta (a→b), pooling delta (b→c)) — or an explicit statement that the two effects are confounded because only 2 methods ran.
- [ ] If Q&A ran and a transcript was requested, it's at `results/{run_id}/qa_transcript.md`.
- [ ] (v0.6.0) If the quantified comparison ran (SP5), its TSVs live under `results/{run_id}/classification_comparison/` and the Methods-Run banner cites them side by side — with no method's output merged into any other method's table.
- [ ] (v0.6.0) If DAA ran, Maaslin2 and ANCOM-BC results are reported side by side (never averaged, never a single merged DA list).

## Invariants

- Never write a report section from assumed data — read the actual files.
- Never omit the Methods Run & Cross-Method Comparison banner.
- **Never** silently resolve a cross-method disagreement by picking one number — report the spread and your best explanation (or say you can't fully explain it).
- Never claim a taxon was detected without reading the taxonomy file.
- Never compute diversity/DAA/correlation on the fly for a run that didn't include `consensus_idtaxa`.
- **Side by side, never averaged/merged (v0.6.0):** applies at every level — classification methods (compare_classifications.R outputs are diagnostics; canonical taxonomy stays the primary method's) AND differential-abundance methods (Maaslin2 and ANCOM-BC are both reported; disagreement is a robustness signal, not something to resolve by averaging).
