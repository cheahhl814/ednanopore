---
name: edna-nanopore-interpret
description: "Turn nf-edna-nanopore pipeline outputs (consensus OR read_based variant) into a structured Markdown report and deep dive navigation plan, a plain-language narrative summary, and an interactive Q&A session. The report template explicitly states which `pipeline_variant` was used and, if `read_based`, lists its documented limitations (no phylogenetic diversity/UniFrac, no sequence-based decontam — taxon-based instead, no geocuration/edna-visualize/edna-gbif-publish chaining in v0.1.0) so a reader of the report is never surprised by missing sections. Refuses to interpret if upstream pipeline_state.json.completed_stages lacks `classify`. Has 4 explicit ask-user stop points (SP1–SP4) that fire only when evidence is ambiguous. Triggers: 'interpret Nanopore 16S results', 'ONT 16S report', 'summarize Nanopore run', 'MinION 16S Results section', 'eDNA Nanopore diversity interpretation', 'eDNA Nanopore differential abundance'."
version: 0.1.0
updated: "2026-08-19"
triggers:
  - "interpret Nanopore 16S results"
  - "ONT 16S report"
  - "summarize Nanopore run"
  - "MinION 16S Results section"
  - "eDNA Nanopore diversity interpretation"
  - "eDNA Nanopore differential abundance"
---

# edna-nanopore-interpret

> **v0.1.0.** Initial version. Adds the canonical BettaMt structure (§0 Inputs/Outputs contract, §0.5 Ask-User Stop Points with Evidence + Recommend + Options, §Troubleshooting — Signature library). Mirrors `skills/nf-edna/interpret/edna-interpret/SKILL.md` with the Nanopore-specific deviations: the report template has a mandatory **Pipeline Variant & Limitations** section that always names which variant produced the report and, for `read_based`, enumerates the documented v0.1.0 limitations so the reader is never surprised by missing sections. The procedure body (Steps 1–5 below) is otherwise unchanged from nf-edna's interpret sub-skill — only the variant-aware report scaffolding and the Stage-2b anomaly scan additions for Variant B are new.

## Audience

This skill serves two simultaneous audiences:

- **AI Coding Agents** — triggered by the phrases above. The agent must read `pipeline_state.json.completed_stages` and enforce the gate (SP1), run the variant-aware anomaly scan (SP2), and write `<run_id>-report.md` grounded in real data from `run_summary.json` — never invent findings.
- **Human Nanopore eDNA scientists** — read this document as a workflow guide. The `## When to Use` / `## Do NOT use` sections explain *why* classification must complete first, *why* the variant + limitations banner is surfaced at the top of the report (not buried in Caveats), and *why* the Q&A answers must be grounded in the actual files for this run.

## When to Use This Skill

Use this skill when you need to:

- **Interpret a completed Nanopore 16S run** (classification stage has run, optionally diversity + association for consensus variant).
- **Generate a structured `<run_id>-report.md`** with Run Summary, Pipeline Variant & Limitations, QC, Taxonomy Overview, Diversity (consensus only), DAA (consensus only), Correlation (consensus only), and Caveats sections.
- **Generate a plain-language narrative** suitable for a manuscript Results-section draft.
- **Enter an interactive Q&A session** with the scientist about the run's findings.

## Do NOT use this skill

- If `pipeline_state.json.completed_stages` does **not** contain `classify` (SP1 hard-stop). The report cannot be written without classified reads.
- If you only want to **look at raw output files** without interpretation — use `Read` / `Bash` directly.
- If you want to **re-run the pipeline** — invoke `run/edna-nanopore-run` instead.
- If the run is still **in progress** — wait for the pipeline to reach the final stage for the chosen variant (`association` for consensus; `decontam` for read_based; or at minimum `classify`).
- If your data is **Illumina** short reads — use `nf-edna`'s `interpret/edna-interpret` instead.

## 0. Inputs / Outputs contract

### Inputs (consumed)

| Path                                   | Source                                                              | Required?   | Notes                                                                                                                                                                                                                                                                |
| -------------------------------------- | ------------------------------------------------------------------- | ----------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `results/{run_id}/pipeline_state.json` | `run/edna-nanopore-run`                                              | yes         | `completed_stages` must include `classify` (SP1 gate). Used for `run_id`, `pipeline`, `pipeline_variant`, `marker`, `classifier`, `params_used`, `outputs`, `limitations` (variant B only).                                                                          |
| `results/{run_id}/run_summary.json`    | `run/edna-nanopore-run` Step 8                                       | yes         | Compact, LLM-loadable summary. In v0.1.0 this is a metadata-only summary (file-presence flags + variant + classifier + stage list); per-stage numeric summaries will land with the future `bin/summarise_run.py`. Falls back to reading per-stage output files directly. |
| `results/{run_id}/{stage}_output/...`  | Nextflow pipeline                                                   | conditional | Read on-demand for detail not captured in the summary (per-sample counts, full taxonomy tables, individual PDFs, raw decontam summary TSV).                                                                                                                          |

### Outputs (produced)

| Path                                  | Format       | Owner      | Notes                                                                                                                                                                       |
| ------------------------------------- | ------------ | ---------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `results/{run_id}/{run_id}-report.md` | Markdown     | this skill | The structured report (Step 3). Sections: Run Summary, **Pipeline Variant & Limitations** (mandatory), QC Summary, Taxonomy Overview, Alpha Diversity (consensus only), Beta Diversity (consensus only), Differential Abundance (consensus only), Correlation Analysis (consensus only), Caveats. For `read_based`, the diversity/DAA/correlation sections are replaced with a single "Diversity / Association: not produced (Variant B v0.1.0 limitation)" note that links to the limitations banner. |
| `results/{run_id}/narrative.md`       | Markdown     | this skill | A 2–3 paragraph plain-language summary suitable for a manuscript Results-section draft (Step 4). Variant-aware — explicitly names the variant and its caveats.                                                                          |
| (no on-disk output for Q&A)           | conversation | this skill | Q&A answers are given in-line; the scientist's questions are not persisted unless the user asks for a transcript (Step 5).                                                                                                                  |

### Verdict gate enforcement

Before reading any output, **read `pipeline_state.json.completed_stages`**. If `classify` is not present → SP1 fires (refuse to proceed; suggest running `run/edna-nanopore-run` to completion).

## 0.5 Ask-User Stop Points

This sub-skill has **4 stop points** (SP1–SP4). Each fires only when the evidence is ambiguous. The format is **Evidence + Recommend + Options**.

### SP1 — Stage-completeness gate

| Trigger                                                 | Evidence check         | Action                                                                                                                                                                                                                                                                                          |
| ------------------------------------------------------- | ---------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `pipeline_state.json.completed_stages` lacks `classify` | Required stage missing | Hard-stop: "Classification has not run yet for this run (`completed_stages` = `<list>`). I can only interpret results from the classify stage onwards. Run `run/edna-nanopore-run` to complete classification first, or I can describe what the QC outputs show so far — would you like that?" |

**Auto-pick when**: `classify ∈ completed_stages`. No ask.

### SP2 — Anomaly severity

| Trigger                                                                                                                                                                                                                                                                                | Evidence check                                                   | Action                                                                                                                                                                                                                                                                                                                  |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| One or more anomalies found in Step 2b scan: zero classified reads/taxa, empty taxonomy table, very low read counts, missing expected output files, blank contamination in the shared negatives, no decontam filtering despite contaminated blanks (variant A) OR no neg-control-derived taxa flagged (variant B), consensus-variant run without rep-seqs in `outputs`, read_based-variant run with `diversity`/`association` outputs present (suspicious — these should not exist for v0.1.0) | The report would mislead if these are silently buried in Caveats | Ask: "I detected `<N>` anomalies before writing the report (listed below). Pick: (A) **proceed** with interpretation, surfacing each anomaly prominently in Caveats (recommended), (B) **investigate first** — tell me which anomaly to dig into, (C) **abort** until upstream stages re-run\n\nAnomalies:\n- `<list>`" |

**Auto-pick when**: zero anomalies detected. No ask.

### SP3 — Report-scope ambiguity

| Trigger                                                                                                                                                                                                                                                       | Evidence check                                                                                                                       | Action                                                                                                                                                                                                                                                                                                            |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| For `pipeline_variant == consensus`: `completed_stages` contains `classify` but not `diversity` and not `association`; OR scientist asks "summarize what we have so far" mid-pipeline                                                                          | Partial run; not all sections can be written                                                                                         | Ask: "Consensus run is partially complete (`<list>`). Pick: (A) write the report sections for the stages that exist and mark the missing stages as 'Output unavailable' in each section (recommended), (B) write only the QC + Taxonomy sections (skip Diversity/DAA/Correlation), (C) wait until more stages complete"     |
| For `pipeline_variant == read_based`: scientist asks for diversity/DAA/correlation interpretation                                                                                                | Variant B v0.1.0 does not produce those outputs                                                                                     | Ask: "This is a `read_based` (Variant B) run. Diversity, DAA, and Correlation are **not produced** by Variant B in v0.1.0 (documented limitation — no rep-seqs means no phylogenetic tree, so the shared diversity/association modules are not reusable as-is). Pick: (A) write a Variant-B-shaped report (QC + Taxonomy + Caveats noting the limitations, recommended), (B) re-run the same data with `pipeline_variant: consensus` if you need diversity/DAA/correlation, (C) abort" |

**Auto-pick when**: for consensus — `diversity ∈ completed_stages` AND `association ∈ completed_stages` (full run); for read_based — `decontam ∈ completed_stages` (full Variant B run). No ask.

### SP4 — Q&A termination

| Trigger                                                                                | Evidence check                          | Action                                                                                                                                                                                                                                                                                                                                      |
| -------------------------------------------------------------------------------------- | --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Scientist signals completion ("thanks", "done", "exit", or no follow-up for ≥ 3 turns) | The session has reached its natural end | No ask needed for the response itself, but: when the Q&A mode terminates, **ask** one final clarification: "Before I close this interpretation session: pick (A) **save the Q&A transcript** to `results/{run_id}/qa_transcript.md`, (B) **discard** the transcript, (C) keep the report as-is and add the transcript inline to the report" |

**Auto-pick when**: scientist is mid-Q&A. No ask (the Q&A itself is the conversation).

### Operating rule

> **Auto-pick when the evidence is unambiguous; ask when the agent genuinely cannot decide.** When asking, present the evidence first, then the recommendation, then 2–4 concrete options. Do not ask "what do you want?" — ask "I see X, recommend Y, which one of A/B/C?"

## Description

You are the interpretation agent for a Nanopore 16S eDNA metabarcoding analysis. You turn pipeline output files into scientific understanding — a structured report (with a mandatory variant + limitations banner so readers aren't surprised by missing sections), a narrative summary suitable for a draft Results section, and an interactive Q&A session where the scientist can ask follow-up questions.

## Prerequisites

- **Environment**: pixi env with `python ≥ 3.10` (for the inline `run_summary.json` generator if it wasn't already produced by `run/edna-nanopore-run` Step 8).
- **Upstream evidence**: `results/{run_id}/pipeline_state.json` with `classify ∈ completed_stages` (SP1), and `results/{run_id}/run_summary.json`.
- **User-provided inputs**: `run_id`.

## Procedure

### Step 1 — Locate the run + enforce gate (SP1)

Ask if not already stated:

> "What is the `run_id` for the run you want to interpret?"

Read `results/{run_id}/pipeline_state.json`. **Enforce SP1**: `classify` must be in `completed_stages`. If only `qc` is complete:

> "Classification has not run yet for this run. I can only interpret results from the classify stage onwards. Run `run/edna-nanopore-run` to complete classification first, or I can describe what the QC outputs show so far — would you like that?"

Also extract the run's `pipeline_variant` and `limitations` (Variant B only). These drive the variant-aware report template (Step 3) and the SP3 scope question.

### Step 2 — Load run summary

Check for `results/{run_id}/run_summary.json`. If it exists, read it — it is the primary data source for all subsequent steps and avoids re-reading every individual output file.

If it does not exist, generate it by invoking the inline snippet from `run/edna-nanopore-run` Step 8 (or copy that snippet into a one-shot Bash call). In v0.1.0 the summary is metadata-only (run identity + file-presence flags); the per-stage numeric summaries (per-sample read counts, taxonomy breakdowns, diversity metrics) are still read directly from per-stage output files until a Nanopore-specific `bin/summarise_run.py` lands.

### Step 2b — Anomaly scan (before writing the report; SP2 trigger)

Before writing anything, scan for anomalies. Use `run_summary.json` where possible; otherwise read per-stage output files directly. If any are found, **SP2 fires** (ask user before proceeding) — do NOT silently bury anomalies in Caveats:

- **Zero classified reads/taxa**: for consensus — `asv_table/feature-table_renamed.tsv` is empty or has 0 rows after header; for read_based — `taxonomy/taxon_abundance.tsv` is empty or has only `__unclassified__` rows.
- **Empty taxonomy**: `taxonomy/{classifier}_classification.tsv` has no classified sequences (all rows have empty rank columns).
- **Missing expected output files**: for each path listed in `pipeline_state.json` `outputs`, check that the file exists on disk using the actual `results/{run_id}/` directory. The stored paths in `outputs` may be stale (pointing to a different machine's home directory) — do not trust them literally; verify by navigating relative to the current results directory instead.
- **Very low read counts**: any sample with < 100 trimmed reads in the QC output (exclude blank samples).
- **Blank contamination**: read `metadata` rows where `is_negative == TRUE` and cross-reference the trimmed-read counts. If a blank sample has more reads than one or more biological samples — flag this prominently. Also check `taxonomy/decontam_summary.tsv` (consensus) or `taxonomy/decontam_summary.tsv` (read_based) — if no taxa were flagged despite contaminated blanks, flag for human review. **Important**: the same `is_negative` rows are shared across all biological samples; contamination findings apply to the run as a whole, not a specific site.
- **Consensus-variant run without rep-seqs in `outputs`**: if `pipeline_variant == "consensus"` but `outputs.rep_seqs` is missing or the file does not exist, this is unexpected — consensus variant must produce rep-seqs by construction. Flag for investigation.
- **Read-based-variant run with `diversity`/`association` outputs present**: if `pipeline_variant == "read_based"` but `outputs.diversity` or `outputs.association` exist, this is unexpected — those stages should not have run for Variant B in v0.1.0. Flag for investigation (could be a state-file corruption or a manual Nextflow invocation outside the skill).
- **No decontam filtering despite contaminated blanks (consensus)**: if `asv_table/decontam_summary.tsv` exists, check whether any ASVs with high prevalence in negative controls (> 30%) and zero prevalence in true samples were NOT flagged as contaminants — this may indicate overly permissive decontam thresholds.
- **No decontam filtering despite contaminated blanks (read_based)**: if `taxonomy/decontam_summary.tsv` exists, check whether any taxa with `Contaminant_Status == Yes` were identified. If the file exists but no taxa were flagged despite contaminated blanks, the `decontam_threshold` may be too permissive (note: Variant B's threshold is a ratio, not a p-value — semantics differ from Variant A).

### Step 3 — Mode 1: Structured report

Write `results/{run_id}/{run_id}-report.md` with the following sections. The first section (Pipeline Variant & Limitations) is **mandatory** and must always be present — it tells the reader up-front which variant produced the report and what to expect (or not expect) in the sections that follow.

### Run Summary

From `pipeline_state.json`:

- Pipeline (`nf-edna-nanopore`) and marker gene (`16S`)
- `pipeline_variant` (`consensus` | `read_based`)
- Classifier mode (`minimap2` | `kraken2` | `idtaxa`)
- Run ID
- Parameters used (primers, length range, kingdoms, medaka_model for consensus)
- Number of samples (count entries in the manifest)
- Completed stages

### Pipeline Variant & Limitations (mandatory banner)

This section is always written and always first after Run Summary. It uses `pipeline_state.json.pipeline_variant` and `pipeline_state.json.limitations` (the latter is set by `main-readbased.nf`'s `WRITE_STATE` process and preserved across stage updates):

```markdown
## Pipeline Variant & Limitations

This run used the **`{pipeline_variant}`** variant of nf-edna-nanopore.

**Variant A — consensus**: per-read clustering + medaka polishing into ASV-like
representative sequences, then classification and downstream diversity/association.
```

Or, for Variant B:

```markdown
## Pipeline Variant & Limitations

This run used the **`read_based`** variant of nf-edna-nanopore. Per the design spec
at `docs/superpowers/specs/2026-08-19-nf-edna-nanopore-design.md`, Variant B in v0.1.0
has the following documented limitations:

1. **No phylogenetic diversity / UniFrac** — there is no rep-seq per feature, so
   the shared `diversity.nf` / `alpha_diversity.R` / `beta_diversity.R` modules
   (which hard-require `--input_tree`) cannot be reused as-is. Non-phylogenetic
   diversity metrics are a documented fast-follow, not built in v0.1.0.
2. **Decontam is taxon-based, not sequence-based** — `bin/decontam_by_taxon.jl`
   flags taxa whose mean relative abundance in negative controls exceeds that in
   true samples (ratio ≥ `decontam_threshold`), rather than the ASV-level
   prevalence-based Fisher's exact test that `bin/decontam.jl` runs.
3. **No geocuration, edna-visualize, or edna-gbif-publish chaining in v0.1.0** —
   those downstream skills assume per-feature representative sequences
   (geocuration and edna-visualize anchor figures on rep-seqs; edna-gbif-publish
   emits Darwin Core `ASV` records). Documented as an explicit limitation, not
   silently skipped.

If you need diversity, DAA, correlation analysis, or downstream chaining, re-run
the same data with `pipeline_variant: consensus` (Variant A).
```

This banner must be the first thing the reader sees after Run Summary — not buried in Caveats — so a downstream manuscript author is never surprised by a missing section.

### QC Summary

Use per-sample trimmed read counts from `qc/trimmed/{sample}/{sample}.trimmed.fastq.gz`. If `run_summary.json` is unavailable, count reads directly:

```bash
zcat qc/trimmed/{sample}/{sample}.trimmed.fastq.gz | wc -l
# divide by 4
```

Also surface NanoPlot pre/post-trim summaries from `qc/nanoplot/{sample}/raw_nanoplot/NanoStats.txt` and `qc/nanoplot/{sample}/trimmed_nanoplot/NanoStats.txt` if present (these are text-readable summaries).

Report:

- Trimmed read counts per sample (exclude blank samples)
- Blank read counts and any blank contamination warnings from `run_summary.json`
- Any samples with notably low post-trimming counts (< 1,000 reads)
- Number of samples that passed trimming
- NanoPlot pre/post mean read length + quality (median Q-score, N50) — these are the primary ONT QC signals

### Taxonomy Overview

From `run_summary.json` and the per-classifier taxonomy file:

- For **consensus variant**: classify per rep-seq; show `asv_counts` raw → decontam → filtered progression; classification rates per rank (if classifier emits per-rank confidence, report); top taxa by total reads at each available agglomerated rank.
- For **read_based variant**: classify per read; show `taxon_abundance_table.tsv` row count + sample-level read counts per top taxon; classification rates per rank (from `minimap2_lca_classification.tsv` / `kraken2_classification.tsv`); top taxa by total reads per lineage.
- Cross-cutting: top 5 most abundant taxa at the finest available rank; dominant kingdom/phylum/class composition; fraction of reads unclassified.

Available ranks vary by pipeline: 16S Nanopore runs typically have phylum/family/genus (and species when classifier resolution supports it). Report whatever ranks are actually produced — do not assume rank columns exist.

Note: ONT indel errors may cause rank-misassignment at low-confidence ranks (species especially). Interpret at genus level for safety unless the classifier reports high per-rank confidence.

### Alpha Diversity *(consensus variant only)*

From `diversity/alpha/alpha_diversity_metrics.tsv`:

- Key metrics present (columns in the file; typically: Observed, Shannon, Faith's PD)
- Range and mean across samples (exclude blanks by sample name)
- Notable patterns: are groups different? Are any samples outliers?

If variant is `read_based`: this section is replaced by a single sentence: "**Alpha diversity: not produced.** Variant B (`read_based`) does not run diversity analysis in v0.1.0 — see the Pipeline Variant & Limitations banner above. The shared `alpha_diversity.R` requires `--input_tree`, which Variant B cannot provide (no rep-seqs)."

If the consensus run did not complete the diversity stage: note "Output unavailable" and link to the missing stage in `pipeline_state.json.completed_stages`.

### Beta Diversity *(consensus variant only)*

From `run_summary.json` `beta_diversity` (consensus only):

- `permanova`: PERMANOVA results per dissimilarity metric (R², F, p-value). These come from `diversity/beta/permanova_results.tsv`, which is published.
- `community_typing`: per-sample cluster assignments from `diversity/beta/sample_clusters.tsv`, which is published and readable as a plain TSV (columns: `SampleID`, `Cluster`).
- `available_outputs`: list of PDF files present

PDF files (cannot be read directly — describe by filename):

- `pcoa_bray_curtis.pdf` — Bray-Curtis dissimilarity PCoA (composition + abundance)
- `pcoa_aitchison.pdf` — Aitchison distance PCoA (log-ratio, compositional)
- `pcoa_jaccard.pdf` — Jaccard dissimilarity PCoA (presence/absence)
- `heatmap_bray_curtis.pdf` — sample-by-sample dissimilarity heatmap
- `community_typing_plots.pdf` — cluster assignments visualised

Report PERMANOVA R² and p-values per metric, and which cluster each sample belongs to. If all samples cluster together (single cluster), flag this — it may indicate insufficient group structure or too few samples.

Note: `community_typing.rds` is a binary R object not directly readable. Use `sample_clusters.tsv` instead for cluster assignments.

If variant is `read_based`: this section is replaced by a single sentence: "**Beta diversity: not produced.** Variant B (`read_based`) does not run beta diversity analysis in v0.1.0 — see the Pipeline Variant & Limitations banner above."

If the consensus run did not complete the diversity stage: note "Output unavailable".

### Differential Abundance *(consensus variant only)*

From `association/differential_abundance/differential_abundance_results.tsv`:

- Number of significantly differentially abundant taxa (rows where `qval` < 0.05)
- Top taxa by effect size (`coef` column, absolute value)
- Direction of enrichment per group (`value` column shows which group is enriched)
- The metadata variable tested (`metadata` column — this is the grouping variable used in the analysis)

If variant is `read_based`: this section is replaced by: "**Differential abundance: not produced.** Variant B (`read_based`) does not run DAA in v0.1.0 — see the Pipeline Variant & Limitations banner above."

If the consensus run did not complete the association stage: note "Output unavailable".

### Correlation Analysis *(consensus variant only)*

From `association/correlation/` — check which rank subdirectories are present (e.g. `correlation_analysis_genus/`, `correlation_analysis_family/`). For each:

**Taxon–environment correlations** (`feature_metadata_correlations_{rank}.tsv`):

- Columns: Feature, Metadata_Variable, Correlation, P_value, Q_value
- Report the top 5 strongest significant correlations (Q_value < 0.05) between taxa and environmental variables
- Note which environmental variables were tested

**Taxon–taxon co-occurrence** (`feature_feature_correlations_{rank}.tsv`):

- Report notable significant co-occurrence or mutual exclusion pairs (Q_value < 0.05, excluding self-correlations)
- Limit to top 5 strongest pairs

Heatmap PDFs in this directory show the same data visually — list them by filename.

If variant is `read_based`: this section is replaced by: "**Correlation analysis: not produced.** Variant B (`read_based`) does not run correlation analysis in v0.1.0 — see the Pipeline Variant & Limitations banner above."

If the consensus run did not complete the association stage: note "Output unavailable".

### Caveats

List any anomalies flagged in SP2, plus:

- Stages that did not run
- Whether `asv_table/decontam_summary.tsv` (consensus) or `taxonomy/decontam_summary.tsv` (read_based) exists; if absent, note that decontam details are unavailable and only feature/taxon count differences can be reported
- Blank contamination: cross-reference the trimmed read counts for `is_negative == TRUE` rows; if any blank has more reads than biological samples, note which blanks and that downstream results may be confounded
- Any taxa that could not be classified below a high rank: use the classification TSV — any rank with < 50% classified warrants mention
- ONT-specific: a non-trivial fraction of reads may be classified only to family or order due to indel errors in the 16S region; note this as an expected characteristic of ONT amplicon data, not a failure
- medaka_model choice (consensus only): if a non-default model was used, note it; polishing quality is sensitive to this choice
- Any R/statistical warnings visible in association output

---

Marker-aware interpretation guidelines (consensus variant):

**16S runs (consensus):**

- Higher diversity expected (hundreds to thousands of ASVs)
- Interpret at genus level (finest typically available after ONT polishing)
- Frame dominant taxa in functional guild terms: nitrifiers, sulfate reducers, fermenters, phototrophs
- Note if Archaea are present and their proportion
- Compare ASV counts to expected: ONT polishing tends to reduce raw-read count by 10-100× but increase per-ASV quality; do not flag low ASV counts as failure without checking the polished-read retention rate first

**16S runs (read_based):**

- Lower per-feature resolution (taxa, not ASVs)
- Interpret at genus or family level (finest rank the classifier reports with confidence)
- Frame dominant taxa in ecological guild terms (same as consensus)
- Higher fraction of unclassified reads is expected — ONT indel errors degrade k-mer/LCA matches; report the unclassified fraction in Caveats
- Do not interpret per-ASV diversity (Variant B has no rep-seqs)

---

After writing all sections, confirm to the scientist:

> "Report written to `results/{run_id}/{run_id}-report.md`."

### Step 4 — Mode 2: Narrative summary

Write a 2–3 paragraph plain-language summary of the findings, suitable for a draft Results section of a scientific paper. Append it to `results/{run_id}/{run_id}-report.md` under a `## Narrative Summary` heading and also print it to the terminal.

The narrative should:

- State what was sequenced (ONT platform, chemistry, basecaller mode if known — surface from `params.json.medaka_model` for consensus runs), how many samples, and what marker gene
- **Name the pipeline variant (`consensus` or `read_based`) in the first sentence** so a manuscript reviewer is never surprised
- Summarise the key biological findings (dominant taxa, diversity patterns, significant associations if consensus)
- For Variant B runs: explicitly note that phylogenetic diversity, UniFrac, DAA, correlation, geocuration, and edna-gbif-publish outputs were not produced in this run (and are documented v0.1.0 limitations, not analytical failures)
- Mention any important caveats or limitations
- Use past tense, passive voice where conventional ("reads were trimmed", "ASVs were classified")
- Avoid pipeline-specific jargon (say "amplicon variants" not "ASVs" if writing for a general audience; for Variant B say "taxa" instead)

### Step 5 — Mode 3: Interactive Q&A

After the report is written, enter Q&A mode:

> "The report is complete. Ask me any follow-up questions about the results — for example:
>
> - Which taxa drive the separation between groups?
> - Is the low read count in sample X a problem?
> - What functional roles do the dominant taxa likely have?
> - Are there any taxa that suggest contamination?
> - Which environmental variables correlate most strongly with community composition?
>
> Note: if this is a `read_based` run, diversity/DAA/correlation questions will be answered with 'not produced — Variant B v0.1.0 limitation' (see the Pipeline Variant & Limitations banner)."

For each question:

1. Identify which output file(s) are relevant
2. Read those files
3. Answer based on actual data, not assumptions
4. If the answer requires a file that is missing or empty, say so explicitly
5. If the question is about diversity/DAA/correlation on a Variant B run, point back to the Pipeline Variant & Limitations banner — do not invent findings

Stay in Q&A mode until the scientist signals they are done (e.g., "thanks", "done", "exit") — at which point SP4 fires (Q&A termination ask).

## Troubleshooting — Signature library

| Signature in stderr / log                                                            | Likely cause                                                                                                                                         | Suggested fix                                                                                                                                                                                                                                                                                                                                                                                                           |
| ------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `run_summary.json missing`                                                           | `run/edna-nanopore-run` Step 8 was skipped or failed                                                                                                | Re-run the inline snippet from `run/edna-nanopore-run` Step 8 (or copy it into a one-shot Bash call), then re-invoke this skill                                                                                                                                                                                                                                                                                       |
| `pipeline_state.json.pipeline_variant is missing or unrecognized`                    | State file predates v0.1.0 (when `pipeline_variant` was added) or was corrupted                                                                     | Re-run `preflight/edna-nanopore-intake` to regenerate the state with the variant field set, OR add `pipeline_variant` to `pipeline_state.json` manually after confirming which entry script was used                                                                                                                                                                                                                |
| `expected output files missing (e.g., pcoa_bray_curtis.pdf)` — consensus run         | Diversity stage did not run, or crashed mid-output                                                                                                  | Check `pipeline_state.json.completed_stages`; if `diversity` missing, invoke `run/edna-nanopore-run` to complete it                                                                                                                                                                                                                                                                                                    |
| `expected output files missing (e.g., pcoa_bray_curtis.pdf)` — read_based run        | Expected — Variant B does not run diversity in v0.1.0. Don't flag this as an anomaly.                                                                | None — surface in the Pipeline Variant & Limitations banner (already standard for Variant B reports)                                                                                                                                                                                                                                                                                                                   |
| `top_taxa table is empty at finest rank`                                             | All features/taxa were filtered out at that agglomeration rank (low confidence, or low prevalence)                                                  | Fall back to the next coarser rank (genus → family → class → phylum); mention the fallback in Caveats                                                                                                                                                                                                                                                                                                                   |
| `classification_rates: 0% at species rank`                                           | ONT indel errors dropped all species-level assignments; expected for ONT data                                                                       | Note in Caveats; interpret at genus level instead. This is normal for Nanopore 16S.                                                                                                                                                                                                                                                                                                                                    |
| `blank contamination, scientist asks "which site is affected?"`                      | The shared `is_negative == TRUE` rows are shared across all biological samples — `decontam.jl` (variant A) and `decontam_by_taxon.jl` (variant B) both use them as a global pool, not per-site | Do NOT attribute contamination to a single site. Say: "The negative controls are shared across all biological samples for this run, so any contamination finding applies to the run as a whole, not a specific site. To investigate site-specific contamination, additional per-site blanks would be needed." Reference `pipeline_state.json.shared_negatives` if present.                                                                          |
| **`Outputs paths in pipeline_state.json point to a different machine's home directory`** | State file was generated on a different machine and rsynced                                                                                       | Do NOT trust the `outputs` paths literally; navigate relative to the current `results/{run_id}/` instead                                                                                                                                                                                                                                                                                                                |
| `Q&A answer requires a file that doesn't exist or is empty`                          | The scientist asked about an output that was never produced                                                                                         | Say so explicitly; do not invent findings. For Variant B, this is especially common for diversity/DAA/correlation questions — point back to the Pipeline Variant & Limitations banner.                                                                                                                                                                                                                              |
| `pipeline_state.json.limitations is empty but pipeline_variant is read_based`         | `WRITE_STATE` in `main-readbased.nf` did not populate the field (or was bypassed)                                                                   | Manually add the `limitations` array from the design spec §"Variant B" to `pipeline_state.json` and re-run this skill                                                                                                                                                                                                                                                                                                  |
| **`Scientist asks for diversity/DAA/correlation on a read_based run`**               | Variant B v0.1.0 does not produce those outputs                                                                                                     | Do NOT attempt to compute them on the fly. Point back to the Pipeline Variant & Limitations banner and recommend re-running with `pipeline_variant: consensus` if those analyses are required.                                                                                                                                                                                                                       |
| **`Scientist asks to chain to edna-visualize or edna-gbif-publish on a read_based run`** | Variant B has no rep-seqs, so those downstream skills cannot anchor figures/Darwin Core records                                                  | Same — point to the banner; recommend `pipeline_variant: consensus` if downstream chaining is required.                                                                                                                                                                                                                                                                                                              |

## Verification

- [ ] `results/{run_id}/{run_id}-report.md` exists with the **Pipeline Variant & Limitations** banner as the first section after Run Summary (mandatory — never absent).
- [ ] Every reported number in the report can be traced to `run_summary.json` or a specific output file in `results/{run_id}/`.
- [ ] Every anomaly flagged in SP2 is mentioned in the Caveats section.
- [ ] For `read_based` runs, the diversity/DAA/correlation sections explicitly state "not produced — Variant B v0.1.0 limitation" and link to the banner.
- [ ] The narrative summary is appended under `## Narrative Summary` heading and names the pipeline variant in its first sentence.
- [ ] If Q&A mode ran, the transcript (if saved per SP4) is at `results/{run_id}/qa_transcript.md`.

## Invariants

- Never write a report section based on assumed data. Read the actual output files.
- If an expected output file is missing or empty, flag it as a Caveats item and do not silently skip the section — write "Output unavailable: {reason}" in that section.
- **Never** omit the Pipeline Variant & Limitations banner. It is the first section after Run Summary and must always be present, even for `consensus` runs (where it states the variant identity and notes that all downstream stages are available).
- Never claim a taxon was detected without reading the taxonomy file.
- Do not assume which agglomerated rank files exist — always list the directory first.
- The Q&A answers must be grounded in the actual files for this run. Do not speculate beyond what the data shows.
- **Never** attempt to compute diversity/DAA/correlation on-the-fly for a `read_based` run. Point to the banner and recommend `pipeline_variant: consensus`.
- **Never** interpret before the SP1 stage-completeness gate has passed.
