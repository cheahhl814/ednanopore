---
name: edna-nanopore-intake
description: "Validate Nanopore (ONT/MinION/PromethION) 16S rRNA eDNA metabarcoding run inputs and write the initial pipeline_state.json with a GO / GO-WITH-WARNINGS / NO-GO verdict. Resolves a `pipeline_variant` choice (consensus | read_based) plus run-time primer/length/classifier-mode/medaka-model inputs, then computes 7 evidence items (variant, manifest schema, sample-count parity, metadata completeness, classifier-mode inputs, tool availability, disk space). The single flexible `params/16s-nanopore.json` preset covers both partial-region (~600 bp) and near-full-length (~1500 bp) amplicons — `min_length` / `max_length` are run-time params, not hardcoded presets. Refuses to write a GO verdict if any required tool or input is missing. The downstream `run/edna-nanopore-run` sub-skill refuses to execute without verdict ≥ GO-WITH-WARNINGS. Has 8 explicit ask-user stop points (SP1–SP8) that fire only when evidence is ambiguous. Triggers: 'new Nanopore 16S run', 'ONT 16S intake', 'MinION eDNA intake', 'start nf-edna-nanopore', 'long-read 16S eDNA pipeline', '16S Nanopore intake', 'eDNA Nanopore parameters'."
version: 0.1.0
updated: "2026-08-19"
triggers:
  - "new Nanopore 16S run"
  - "ONT 16S intake"
  - "MinION eDNA intake"
  - "start nf-edna-nanopore"
  - "long-read 16S eDNA pipeline"
  - "16S Nanopore intake"
  - "eDNA Nanopore parameters"
---

# edna-nanopore-intake

> **v0.1.0.** Initial version. Adds the canonical BettaMt / `bettamt-preflight` structure (§0 Inputs/Outputs contract, §0.5 Ask-User Stop Points with Evidence + Recommend + Options, §Troubleshooting — Signature library, GO / GO-WITH-WARNINGS / NO-GO verdict gate). Mirrors `skills/nf-edna/preflight/edna-intake/SKILL.md` with the Nanopore-specific deviations called out in the design spec at `docs/superpowers/specs/2026-08-19-nf-edna-nanopore-design.md`: the new `pipeline_variant` SP (SP1), per-run primer/length resolution (SP3), classifier-mode-dependent reference inputs (SP4), and Variant-A-only `medaka_model` prompt (SP5).

## Audience

This skill serves two simultaneous audiences:

- **AI Coding Agents** — triggered by the phrases above. The agent must run all seven evidence collection steps (variant, manifest schema, sample-count parity, metadata completeness, classifier-mode inputs, tool availability, disk space), then write `pipeline_state.json` with the `verdict` field set. `run/edna-nanopore-run` will refuse to execute if `verdict < GO-WITH-WARNINGS`.
- **Human Nanopore eDNA scientists** — read this document as a workflow guide. The `## When to Use` / `## Do NOT use` sections and the `## Invariants` list at the bottom explain *why* each step exists and what guarantees the intake makes.

## When to Use This Skill

Use this skill when you need to:

- Start a **new Nanopore 16S metabarcoding run** — partial-region (~600 bp, e.g. V3-V4 on MinION) or near/full-length (~1500 bp, e.g. 27F-1492R on PromethION).
- **Resume** an interrupted run (the skill detects `pipeline_state.json` and offers continue-vs-restart).
- **Pick the analysis strategy** (`consensus` vs `read_based`) before any compute is committed.
- Validate that all input files (manifest, metadata, reference assets, FASTQ paths) exist and have the expected schema **before** committing compute to a Nextflow run.
- Get a machine-readable `pipeline_state.json` that `run/edna-nanopore-run` reads without re-deriving choices.

## Do NOT use this skill

- If you have **Illumina** short reads — use `nf-edna`'s `16s.json` preset instead; its NGmerge / UNOISE3 / IdTaxa chain is calibrated for Illumina's error profile, not ONT.
- If your marker is **not 16S** — this skill is 16S-only in v0.1.0.
- If you have **raw ONT reads that have not been basecalled + demultiplexed** — do that first (Guppy / Dorado + qcat / ONT's `guppy_barcoder`); this skill's QC stage handles primer trimming + quality/length filtering, not basecalling or demultiplexing.
- If you want to **run the pipeline immediately** — this skill only writes the intake state; invoke `run/edna-nanopore-run` after.
- If you want to **interpret already-completed results** — invoke `interpret/edna-nanopore-interpret` instead.

## 0. Inputs / Outputs contract

### Inputs (consumed)

| Path / source | Required? | Notes |
| --- | --- | --- |
| `pipeline_variant` (consensus \| read_based) | yes | Resolved in SP1. Drives which `main-*.nf` is launched and which reference assets are needed downstream. |
| User-provided primer pair (`primers_fwd`, `primers_rev`) | yes | Resolved in SP3. Used by `qc.nf` cutadapt step. |
| User-provided amplicon length range (`min_length`, `max_length`) | yes | Resolved in SP3. Single flexible preset covers both partial (~600 bp) and full-length (~1500 bp) — these are *run-time*, not marker-file-level, params. |
| Classifier mode (`minimap2` \| `kraken2` \| `idtaxa`) | yes | Resolved in SP4. `idtaxa` is consensus-variant-only; `minimap2` and `kraken2` work for both variants. |
| Reference assets (mode-dependent — see SP4) | yes | `minimap2` mode: `ref_mmi` + `tax_lookup`; `kraken2` mode: `kraken2_db`; `idtaxa` mode (consensus only): `idtaxa_model`. |
| `medaka_model` (consensus variant only) | yes (when variant=consensus) | Resolved in SP5. Chemistry-dependent — there is no universal default. |
| Path to sample manifest (CSV / TSV) | yes | Validated in Step 3.1. Single-end (ONT) only — `sample-id,absolute-filepath`. |
| Path to metadata TSV | yes | Validated in Step 3.2. Must contain `is_negative` column for decontam. |
| `results/{run_id}/pipeline_state.json` | conditional | If present → resume path (Step 2); otherwise new run (Step 3+). |

### Outputs (produced)

| Path | Format | Owner | Notes |
| --- | --- | --- | --- |
| `results/{run_id}/pipeline_state.json` | JSON | this skill | **Machine contract for `run/edna-nanopore-run`.** Includes `run_id`, `pipeline: "nf-edna-nanopore"`, `pipeline_variant`, `marker`, `verdict` (GO / GO-WITH-WARNINGS / NO-GO), `completed_stages`, `last_stage`, `params_used`, `outputs`. The `verdict` field is the gate `run/edna-nanopore-run` reads. |
| `results/{run_id}/params.json` | JSON | this skill | **Full parameter file for `nextflow run -params-file`.** Merged on top of the flexible preset `runners/nextflow-runner/params/16s-nanopore.json` so user overrides win. |
| `results/{run_id}/intake_evidence.txt` | text | this skill | Raw evidence output (file-existence checks, line counts, column-name parses, `which nextflow`, `df -h`) — kept for debugging. |

### Verdict gate

| Verdict | Meaning | Downstream behaviour |
| --- | --- | --- |
| `GO` | All evidence items pass with no warnings | `run/edna-nanopore-run` proceeds without prompts |
| `GO-WITH-WARNINGS` | All evidence items pass with ≤ 1 warning | `run/edna-nanopore-run` proceeds after one confirmation prompt |
| `NO-GO` | Any evidence item fails | `run/edna-nanopore-run` refuses to execute; route to the failing evidence item for remediation |

## 0.5 Ask-User Stop Points

This sub-skill has **8 stop points** (SP1–SP8). Each fires only when the evidence is ambiguous. The format is **Evidence + Recommend + Options**. If the evidence is unambiguous, the agent auto-picks the default and proceeds silently.

### SP1 — Pipeline variant ambiguous

| Trigger | Evidence check | Action |
| --- | --- | --- |
| User did not name a variant (no "consensus", "read_based", "ASV", "cluster", "wf-16s-style", "no clustering" cues in the initial brief) | Variant cannot be auto-picked | Ask: "Which pipeline variant do you want? Pick: (A) **consensus** (default — Variant A: cluster + medaka-polish reads into ASV-like rep-seqs, then classify; required for phylogenetic diversity, sequence-based decontam, geocuration, GBIF publishing), (B) **read_based** (Variant B: classify every read directly, mirrors ONT's `wf-16s`; faster, no clustering-parameter sensitivity, but no rep-seqs → no phylogenetic diversity, taxon-based decontam only, no geocuration/edna-visualize/edna-gbif-publish in v1), (C) I'll tell you now" |
| User explicitly named a variant in the initial brief ("consensus", "ASV", "cluster", "rep-seqs" → `consensus`; "read-based", "per-read", "wf-16s", "no clustering" → `read_based`) | Variant is unambiguous | Auto-pick. No ask. |
| User named a downstream need that only one variant supports (decontam-by-sequence, phylogenetic diversity / UniFrac, geocuration, GBIF publishing, edna-visualize) → forces `consensus` | Downstream requirement forces the variant | Auto-pick `consensus`. No ask. |

**Default recommendation: `consensus`** (more downstream chaining options; matches nf-edna's ASV-style contract; required for any publication-grade downstream work).

### SP2 — Marker gene ambiguous

| Trigger | Evidence check | Action |
| --- | --- | --- |
| User did not say "16S" and the pipeline-variant choice + dataset description don't pin marker=16S | This skill is 16S-only in v0.1.0 | Ask: "nf-edna-nanopore v0.1.0 is 16S-only. Pick: (A) your data is 16S — proceed, (B) it's a different marker (this skill doesn't support it; consider extending or using a different skill), (C) abort" |

**Auto-pick when**: user names 16S in the initial brief or it is unambiguous from the dataset (ONT bacterial 16S amplicon library). Default: 16S.

### SP3 — Primer / amplicon length ambiguous

| Trigger | Evidence check | Action |
| --- | --- | --- |
| `primers_fwd` and/or `primers_rev` not provided | cutadapt cannot trim | Ask: "What are your forward and reverse primer sequences? (e.g., 27F = `AGAGTTTGATCCTGGCTCAG`, 1492R = `TACGGYTACCTTGTTACGACTT` for full-length; 341F/806R for V3-V4 partial). Paste both, orientation matters." |
| `min_length` / `max_length` not provided AND amplicon size class cannot be inferred from the primer pair | chopper + cutadapt need bounds | Ask: "What is the expected amplicon length range (min and max bp, primers included)? Default suggestions: **partial-region** (e.g. V3-V4, MiFish-style): 350–600 bp; **full-length** (27F-1492R): 1400–1700 bp; **near-full-length** (e.g. 8F-1518R): 1200–1700 bp. Pick: (A) partial — 350–600, (B) full-length — 1400–1700, (C) I'll give exact min/max, (D) abort" |
| Primer pair provided but does not contain standard 16S motifs (e.g. not 27F/1492R, 341F/806R, 515F/806R, etc.) AND length range provided | Length-range is still derivable from the user's stated amplicon class | Auto-pick the length range from the primer-pair length estimate if computable, otherwise ask for explicit min/max. |

**Auto-pick when**: user provides both primers AND a min/max range in the initial brief. Default for missing length range: 350–1600 bp (the preset default), with `GO-WITH-WARNINGS` flag noting the range was not user-confirmed.

### SP4 — Classifier mode + reference-asset inputs ambiguous

| Trigger | Evidence check | Action |
| --- | --- | --- |
| `params.classifier` not set (default is `minimap2`, but user may want alt) AND user did not mention a preference | Default applies | Ask only if the user mentions "kraken", "k-mer", "idtaxa", "DECIPHER" — otherwise auto-pick `minimap2`. If asked: "Which classifier mode? Pick: (A) **minimap2** (default — mirrors ONT's `wf-16s`; needs `ref_mmi` + `tax_lookup`), (B) **kraken2** (fast k-mer alt; needs `kraken2_db`), (C) **idtaxa** (opt-in DECIPHER::IdTaxa — *consensus variant only*; needs `idtaxa_model`; bootstrap confidence degrades on ONT reads), (D) abort" |
| `classifier == "minimap2"` AND (`ref_mmi` missing OR `tax_lookup` missing) | minimap2 cannot run | Ask: "`classifier: minimap2` requires a 16S reference MMI + taxonomy lookup TSV. Pick: (A) I'll give you the paths now, (B) switch to `kraken2` (needs a `kraken2_db`), (C) abort" |
| `classifier == "kraken2"` AND `kraken2_db` missing | kraken2 cannot run | Ask: "`classifier: kraken2` requires a Kraken2 DB directory. Pick: (A) I'll give you the path now, (B) switch to `minimap2` (needs `ref_mmi` + `tax_lookup`), (C) abort" |
| `classifier == "idtaxa"` AND `pipeline_variant == "read_based"` | Incompatible (IdTaxa needs polished consensus; raw noisy reads are unreliable) | Ask: "`classifier: idtaxa` is consensus-variant-only (needs polished consensus sequences, not raw noisy ONT reads). Pick: (A) switch `pipeline_variant` to `consensus` (recommended), (B) switch `classifier` to `minimap2`, (C) switch `classifier` to `kraken2`, (D) abort" |
| `classifier == "idtaxa"` AND `idtaxa_model` missing | IdTaxa needs a trained model | Ask: "`classifier: idtaxa` requires a pre-trained `.rds` model. Pick: (A) I'll give you the path, (B) train one with `idtaxa-training` (chain to that sub-skill), (C) switch `classifier` to `minimap2`, (D) abort" |

**Auto-pick when**: `params.classifier` is already set in the initial brief and the corresponding reference-asset paths are also provided. Default: `minimap2` if user says nothing.

### SP5 — `medaka_model` missing (consensus variant only)

| Trigger | Evidence check | Action |
| --- | --- | --- |
| `pipeline_variant == "consensus"` AND `medaka_model` is empty / unset | Variant A's polishing step needs the chemistry-correct model | Ask: "`medaka_model` is required for the consensus variant and must match your flow cell chemistry + basecaller mode (e.g. `r1041_e82_400bps_sup_v5.0.0` for R10.4.1 / 400 bps / super-accuracy). Pick: (A) I'll give you the exact model name now, (B) switch `pipeline_variant` to `read_based` (no polishing required), (C) abort" |
| `pipeline_variant == "read_based"` AND `medaka_model` is empty | Variant B doesn't use medaka | Auto-pick — ignore empty `medaka_model`. No ask. |

**Auto-pick when**: `pipeline_variant == "read_based"`. Default for consensus: **must** be asked — there is no universal default (different chemistry + basecaller modes use different models).

### SP6 — Manifest schema unparseable

| Trigger | Evidence check | Action |
| --- | --- | --- |
| Manifest filename lacks `.csv` / `.tsv` extension, OR first line has neither `sample-id,absolute-filepath` (SE — required for ONT) nor the PE header | Schema is ambiguous | Ask: "I see manifest at `<path>` but can't infer the column schema. Note: ONT is single-read only — there is no R1/R2. Pick: (A) it's CSV SE with `sample-id,absolute-filepath`, (B) it's TSV — I'll paste the first 3 lines now, (C) abort" |

**Auto-pick when**: filename ends in `.csv` AND first line contains `sample-id,absolute-filepath`; OR filename ends in `.tsv` and the same column names appear tab-separated. No ask.

### SP7 — Negative-control column missing in metadata

| Trigger | Evidence check | Action |
| --- | --- | --- |
| Metadata TSV has no `is_negative` column (or equivalent boolean) | Decontam (sequence-based for consensus; taxon-based for read_based) will silently disable | Ask: "Metadata has no `is_negative` column. Decontam needs to know which samples are negative controls. Pick: (A) add an `is_negative` column with TRUE/FALSE for each sample (recommended), (B) run without decontam (skip blank filtering — risk of reagent contamination), (C) abort" |

**Auto-pick when**: metadata has `is_negative` column with at least one TRUE row. No ask.

### SP8 — Disk space low

| Trigger | Evidence check | Action |
| --- | --- | --- |
| Free space at `results/` < 10 GB | Nextflow `work/` may run out | Ask: "Only `<X> GB` free where `results/` will live. Nanopore runs (especially consensus variant + medaka polishing) typically need ≥ 20 GB of intermediate work. Pick: (A) free up disk by clearing intermediate files (recommended), (B) move `results/` to a larger disk — I'll give you the new path, (C) abort" |

**Auto-pick when**: free space ≥ 50 GB (silent go). 10–50 GB → `GO-WITH-WARNINGS` with one prompt (no ask — the warning is enough). < 10 GB → `NO-GO` unless overridden.

### Operating rule

> **Auto-pick when the evidence is unambiguous; ask when the agent genuinely cannot decide.** When asking, present the evidence first, then the recommendation, then 2–4 concrete options. Do not ask "what do you want?" — ask "I see X, recommend Y, which one of A/B/C?"

## Description

You are the intake agent for a Nanopore 16S eDNA metabarcoding analysis. Your job is to gather every parameter needed to run the pipeline, validate that all required files exist, and write the initial `pipeline_state.json` with the verdict gate set. You never assume defaults silently — every parameter is either provided by the scientist or explicitly asked for.

The design follows `preflight/edna-intake` exactly: every recommendation is cited back to a measured piece of evidence. The agent does not invent parameters — it computes them. The Nanopore-specific deviations (variant choice, per-run primer/length, classifier-mode-dependent reference assets, Variant-A-only `medaka_model`) are explicitly added stop points SP1 / SP3 / SP4 / SP5 above.

## Prerequisites

- **Environment**: pixi env with `python ≥ 3.10`, `pyyaml`, `git`. The sub-skill does NOT need any bioinformatics tools.
- **Upstream evidence**: optionally `results/{run_id}/pipeline_state.json` (resume path).
- **User-provided inputs** (gather once, at the top):
  - `pipeline_variant` (consensus | read_based) — SP1
  - Marker (always 16S for this skill — SP2)
  - Forward + reverse primer sequences — SP3
  - Amplicon length range (`min_length`, `max_length`) — SP3
  - Classifier mode (`minimap2` | `kraken2` | `idtaxa`) + matching reference-asset paths — SP4
  - `medaka_model` (consensus variant only) — SP5
  - Sample manifest path (CSV / TSV) — SP6
  - Metadata TSV path — SP7
  - Grouping variable for diversity/association (consensus variant only)
  - Reference level for DAA (consensus variant only)
  - Decontam threshold (default 0.1)
  - Kingdom filter (default `Bacteria,Archaea`)
  - Optional: `run_id` (if not provided, generated in Step 9)

## Procedure

The procedure has **three phases**: (1) gather inputs (with SP1–SP5 stop points), (2) compute evidence (seven items, see SP6–SP8), (3) write outputs.

### Step 1 — Determine pipeline variant and marker (SP1, SP2)

Ask if not already stated:

> "Which pipeline variant do you want? (A) **consensus** (default) — cluster + medaka-polish reads into ASV-like rep-seqs, then classify; required for phylogenetic diversity, sequence-based decontam, geocuration, GBIF publishing. (B) **read_based** — classify every read directly, mirrors ONT's `wf-16s`; faster, no clustering-parameter sensitivity, but no rep-seqs.
>
> Note: the only marker supported in v0.1.0 is 16S. If your data is from a different marker, this skill doesn't apply."

If the user has named a downstream need that only one variant supports (decontam-by-sequence, phylogenetic diversity / UniFrac, geocuration, GBIF publishing, edna-visualize) → force `consensus` (SP1 auto-pick).

If the user mentions "Illumina" or "short reads" → STOP — this is the wrong skill; redirect to `nf-edna`.

### Step 2 — Resume path (if run_id provided)

Read `results/{run_id}/pipeline_state.json`. Report:

- Which stages are already complete (`completed_stages`)
- Which stages remain
- Which `pipeline_variant` was used (consensus vs read_based)
- What parameters were used
- What the previous `verdict` was

Ask: "Do you want to continue from where this left off, or start over? Note: changing `pipeline_variant` mid-run requires starting over with a new `run_id`."

If continuing: skip to Step 9 (confirm and write).
If starting over: proceed from Step 3 with a new `run_id`.

### Step 3 — Validate required files

Ask for the following, one at a time if not already provided. After each answer, check that the file/path exists using the Read tool or Bash.

1. **Manifest CSV** — path to sample manifest. ONT is single-read only. Required columns:

   ```
   sample-id,absolute-filepath
   ```

   After receiving path: read the first 3 lines and confirm sample count and column names. This is evidence item **E2** (manifest schema, SP6).

2. **Metadata TSV** — path to sample metadata. Must contain at minimum a `sample-id` column. Ask the scientist to confirm the column used for grouping (e.g. `treatment`, `site`). Also check for `is_negative` column (evidence item **E4**, SP7).

3. **Reference assets** (mode-dependent — see SP4):
   - **minimap2 mode (default)**: `ref_mmi` (pre-built 16S reference minimap2 index, e.g. NCBI RefSeq Targeted Loci) + `tax_lookup` (accession → lineage TSV).
   - **kraken2 mode**: `kraken2_db` (Kraken2 16S DB directory).
   - **idtaxa mode (consensus variant only)**: `idtaxa_model` (DECIPHER IdTaxa `trainingSet` RDS, produced by `idtaxa-training`).

### Step 4 — Elicit biological parameters

Ask each question below only if the answer has not already been provided. Ask one at a time.

**a) Primer sequences**

> "What are your forward and reverse primer sequences?
> - Full-length 16S (27F-1492R): forward = `AGAGTTTGATCCTGGCTCAG`, reverse = `TACGGYTACCTTGTTACGACTT`
> - V3-V4 partial (341F-806R): forward = `CCTACGGGNGGCWGCAG`, reverse = `GACTACNVGGGTWTCTAATCC`
> - V4 partial (515F-806R): forward = `GTGCCAGCMGCCGCGGTAA`, reverse = `GGACTACHVGGGTWTCTAATCC`"

**b) Amplicon length range**

> "What is the expected amplicon length range (min and max bp, primers included)?
> Defaults:
> - Partial (~V3-V4 / V4): **350–600 bp**
> - Near-full-length (e.g. 8F-1518R): **1200–1700 bp**
> - Full-length (27F-1492R): **1400–1700 bp**
>
> Note: partial and full-length are both '16S' for this skill — just different `min_length`/`max_length` (run-time params, not separate marker files)."

**c) medaka_model (consensus variant only — SP5)**

Only ask if `pipeline_variant == "consensus"`:

> "Which `medaka_model` should the polishing step use? It must match your flow cell chemistry + basecaller mode. Common examples:
> - R10.4.1 / 400 bps / super-accuracy: `r1041_e82_400bps_sup_v5.0.0`
> - R10.4.1 / 400 bps / fast: `r1041_e82_400bps_fast_v5.0.0`
> - R9.4.1 / 260 bps / high-accuracy: `r941_min_high_g360`
>
> Find yours with `medaka tools list_models` or at https://github.com/nanoporetech/medaka."

If `pipeline_variant == "read_based"`: skip this question — Variant B doesn't use medaka.

**d) Grouping variable** (consensus variant only)

> "What column in your metadata file should be used to group samples for diversity and association analyses? (e.g., `treatment`, `site`, `depth`)"

If `pipeline_variant == "read_based"`: skip — Variant B does not run diversity/association in v1.

**e) Reference level** (consensus variant only)

> "What is the reference/control group level for differential abundance analysis? (e.g., `control`, `baseline`)"

**f) Decontam threshold**

> "What threshold should be used for decontamination? This is the maximum ratio of neg-control mean relative abundance to true-sample mean relative abundance (Variant B) or the p-value threshold (Variant A) before flagging. Default is 0.1.
>
> Note: Variant A uses `bin/decontam.jl` (sequence-keyed, ASV-level prevalence); Variant B uses `bin/decontam_by_taxon.jl` (taxon-level mean-rel-abundance ratio). The threshold semantics differ — confirm with the variant's bin/ script."

**g) Kingdom filter**

Confirm the appropriate kingdom filter (already set by the marker preset, override only if the scientist's experiment differs):

> "Kingdom filter default for 16S: `Bacteria,Archaea`. Override only if your experiment specifically excludes one of these (e.g. exclude Archaea for a host-associated microbiome study)."

### Step 5 — Optional parameters

Ask these only if the scientist indicates they want to customise:

- Number of community clusters for beta diversity (default: auto-determined)
- DAA taxonomic level (default: `Genus`)
- Top N taxa to plot in differential abundance (default: 20)
- Classifier thresholds: `minimap2_min_pct_identity` (default 0.97), `minimap2_min_ref_coverage` (default 0.8), `idtaxa_threshold` (default 60, only when `classifier == "idtaxa"`)
- Clustering thresholds: `cluster_min_identity` (default 0.85), `cluster_min_coverage_fraction` (default 0.8), `yacrd_min_coverage` (default 0.4), `yacrd_min_length` (default 100)

### Step 6 — Tool and disk checks (evidence items E6 + E7)

Before confirming, run the two background checks that don't depend on user input:

```bash
# E6: tool availability
which nextflow && nextflow -version | head -1
which pixi && pixi --version

# E7: disk space at the path that will hold results/
df -h "$(dirname results/{run_id})"
```

If `which nextflow` or `which pixi` fails → trigger SP-equivalent failure (analogous to nf-edna's SP5): ask user to install or provide a path. If free space < 10 GB → trigger SP8.

### Step 7 — Compute evidence + emit verdict

Append each evidence item to `results/{run_id}/intake_evidence.txt`:

| Code | Evidence item | Pass criterion | Verdict impact |
| --- | --- | --- | --- |
| **E1** | Pipeline variant selected | One of `consensus` \| `read_based` | Required for `GO` |
| **E2** | Manifest schema valid | SP6 auto-pick succeeded (SE-only with `sample-id,absolute-filepath`) | Required for `GO` |
| **E3** | Sample-count parity | Manifest row count == distinct FASTQ path count | Required for `GO` |
| **E4** | Metadata completeness | `sample-id` + `is_negative` columns present | `GO-WITH-WARNINGS` if `is_negative` missing; `NO-GO` if `sample-id` missing |
| **E5** | Classifier-mode reference assets valid | All paths supplied for the chosen mode exist and are non-empty | Required for `GO` (per SP4) |
| **E6** | Tool availability | `nextflow` + `pixi` on PATH, versions parse | Required for `GO` |
| **E7** | Disk space | Free at `results/` ≥ 10 GB | `GO-WITH-WARNINGS` for 10–50 GB; `NO-GO` below 10 GB |

Compute the overall verdict:

```text
if any evidence item is "NO-GO"  → verdict = "NO-GO"
elif any item is "GO-WITH-WARNINGS" → verdict = "GO-WITH-WARNINGS"
else → verdict = "GO"
```

### Step 8 — Confirm all parameters

Display a summary table of all collected parameters and ask for confirmation:

```
Run ID:             {run_id}
Pipeline:           nf-edna-nanopore
Variant:            {pipeline_variant}  ({main-*.nf entry point})
Marker:             {marker}
Manifest:           {input_manifest}  ({N} samples, SE)
Metadata:           {metadata}  (grouping: {grouping_variable}, neg: {is_negative})
Classifier:         {classifier}
  → reference:      {ref_mmi or kraken2_db or idtaxa_model}
Primers fwd:        {primers_fwd}
Primers rev:        {primers_rev}
Length range:       {min_length}–{max_length} bp
Kingdoms:           {kingdoms}
Medaka model:       {medaka_model}  (consensus variant only)
Reference level:    {reference_level}  (consensus variant only)
DAA level:          {daa_level}  (consensus variant only)
Decontam thresh:    {decontam_threshold}

Evidence:
  E1 variant         ✓ {pipeline_variant}
  E2 manifest        ✓ SE, {N} samples
  E3 sample parity   ✓ {M} manifest rows, {N} FASTQ files
  E4 metadata        ✓ / ⚠ / �  (neg col: {yes/no/missing})
  E5 classifier refs ✓ / �  ({mode}: {paths})
  E6 tools           ✓ nextflow {ver} pixi {ver}
  E7 disk space      ✓ / ⚠ / ✗  ({free_gb} GB free)

Overall verdict: {GO / GO-WITH-WARNINGS / NO-GO}
```

Ask: "Does this look correct? Type 'yes' to proceed, correct any parameter, or address any NO-GO items."

### Step 9 — Write outputs

Once confirmed:

1. **Generate `run_id`**: `16s-nanopore-{YYYYMMDD}-{short_descriptor}`
   - Ask for a short descriptor (e.g. site name, experiment ID): "What short label should identify this run? (e.g., `siteA`, `batch2`)"
   - To avoid ambiguity when comparing the two variants on the same dataset, suggest appending `_consensus` / `_readbased` to the descriptor.

2. **Write `results/{run_id}/pipeline_state.json`** with the verdict gate field:

```json
{
  "run_id": "{run_id}",
  "pipeline": "nf-edna-nanopore",
  "pipeline_variant": "consensus | read_based",
  "marker": "16S",
  "verdict": "GO | GO-WITH-WARNINGS | NO-GO",
  "completed_stages": [],
  "last_stage": "intake",
  "evidence": {
    "E1_pipeline_variant": "pass | warn | fail",
    "E2_manifest_schema": "pass | warn | fail",
    "E3_sample_count_parity": "pass | warn | fail",
    "E4_metadata_completeness": "pass | warn | fail",
    "E5_classifier_refs": "pass | warn | fail",
    "E6_tool_availability": "pass | warn | fail",
    "E7_disk_space": "pass | warn | fail"
  },
  "params_used": {
    "input_manifest": "...",
    "primers_fwd": "...",
    "primers_rev": "...",
    "min_length": ...,
    "max_length": ...,
    "kingdoms": "...",
    "classifier": "...",
    "pipeline_variant": "..."
  },
  "outputs": {}
}
```

   Use the Write tool. Create the `results/{run_id}/` directory first if it doesn't exist.

3. **Write `results/{run_id}/params.json`** — full parameter file for `nextflow run -params-file`:

   This file is merged on top of the preset (`runners/nextflow-runner/params/16s-nanopore.json`) — only include values here that differ from the preset, plus the always-required run-specific fields below. Variant-specific fields are conditional (e.g. `medaka_model` is only meaningful for `consensus`):

```json
{
  "run_id": "{run_id}",
  "results_dir": "results",
  "pipeline_variant": "consensus | read_based",
  "input_manifest": "...",
  "metadata": "...",
  "marker": "16S",
  "classifier": "minimap2 | kraken2 | idtaxa",
  "ref_mmi": "...",
  "tax_lookup": "...",
  "kraken2_db": "",
  "idtaxa_model": "",
  "primers_fwd": "...",
  "primers_rev": "...",
  "min_length": ...,
  "max_length": ...,
  "min_qual": 10,
  "kingdoms": "Bacteria,Archaea",
  "medaka_model": "...",          // consensus only
  "decontam_threshold": 0.1,
  "neg_col": "is_negative",
  "filter_condition": "is_negative == false",
  "grouping_variable": "...",     // consensus only
  "reference_level": "...",       // consensus only
  "daa_level": "Genus",           // consensus only
  "correlation_level": "Genus",   // consensus only
  "num_clusters": "",             // consensus only
  "metadata_numeric_variables": "",
  "minimap2_min_pct_identity": 0.97,
  "minimap2_min_ref_coverage": 0.8,
  "idtaxa_threshold": 60,
  "cluster_min_identity": 0.85,
  "cluster_min_coverage_fraction": 0.8,
  "yacrd_min_coverage": 0.4,
  "yacrd_min_length": 100,
  "geocurate": false,
  "top_n_taxa_plot": 20,
  "target_ranks": "Phylum,Family,Genus"
}
```

### Step 10 — Hand off

Tell the scientist:

> "Intake complete. Run ID: `{run_id}`. Variant: `{pipeline_variant}` → entry point `main-{variant}.nf`. Verdict: `{GO / GO-WITH-WARNINGS / NO-GO}`.
>
> To execute the pipeline: `run/edna-nanopore-run`
> To run a specific stage only, invoke `run/edna-nanopore-run` and specify the stage when prompted."

## Troubleshooting — Signature library

| Signature in stderr / log | Likely cause | Suggested fix |
| --- | --- | --- |
| `Manifest has fewer samples than expected` | FASTQ files weren't all uploaded, or paths in manifest point to a different directory | `ls -la $(dirname <first-FASTpath>)`; cross-reference manifest paths with actual files |
| `Metadata 'is_negative' column missing — decontam will silently disable` | User skipped SP7 or the metadata CSV was exported without the negative-control flag | Re-export metadata with `is_negative=TRUE/FALSE` per sample, or accept `GO-WITH-WARNINGS` and skip decontam |
| `Primer sequence contains ambiguous bases that cutadapt can't parse` | IUPAC codes in user-supplied primers are non-standard, or the primer was pasted with whitespace | Trim whitespace; verify IUPAC codes against `cutadapt --help` (it accepts A/C/G/T/N + W/S/R/Y/K/M/B/D/H/V) |
| `nextflow: command not found` | Nextflow not on PATH | `curl -s https://get.nextflow.io \| bash && mv nextflow ~/bin/` (or any directory on PATH) |
| `pixi: command not found` | Pixi not on PATH | `curl -fsSL https://pixi.sh/install.sh \| bash` then re-source `~/.bashrc` |
| `No space left on device` while resolving per-stage pixi env | First-run pixi env resolution can take 1–3 GB per stage | Free ≥ 20 GB before intake (consensus variant + medaka polishing is heavier than nf-edna), or move `results/` to a larger disk |
| `classifier: idtaxa requested but pipeline_variant is read_based` | Incompatible — IdTaxa needs polished consensus, raw noisy reads are unreliable | Re-run intake with `pipeline_variant: consensus`, or switch `classifier` to `minimap2`/`kraken2` |
| `medaka_model is empty and pipeline_variant is consensus` | Variant A's polishing step requires a chemistry-correct model | Run `medaka tools list_models` and provide the model name matching your flow cell + basecaller mode |
| `Metadata 'grouping_variable' has only 1 unique value` | All samples have the same `treatment`/`site`/etc. label (consensus variant only) | Diversity and DAA analyses will be uninformative; either expand the metadata or accept that only the QC + classify stages are meaningful for this run |
| `Kraken2 DB not found at <path>` | `kraken2_db` path is wrong, or DB was built with a different k-mer length than `kraken2` expects | Verify with `kraken2-inspect --db <path> \| head`; rebuild DB if the k-mer length in the inspect output doesn't match your classifier invocation |

## Verification

- [ ] `results/{run_id}/pipeline_state.json` exists with `verdict` set to one of `GO` / `GO-WITH-WARNINGS` / `NO-GO`.
- [ ] `results/{run_id}/pipeline_state.json.pipeline_variant` is one of `consensus` / `read_based`.
- [ ] `results/{run_id}/params.json` exists and merges cleanly on top of `runners/nextflow-runner/params/16s-nanopore.json` (no missing required keys).
- [ ] `results/{run_id}/intake_evidence.txt` exists with all 7 evidence items recorded.
- [ ] The downstream `run/edna-nanopore-run` sub-skill accepts the run (verdict ≥ `GO-WITH-WARNINGS`) OR refuses with a clear pointer to the failing evidence item.

## Invariants

- Never silently assume a default. Every parameter is either given or asked.
- Validate every file path before accepting it. If a file does not exist, say so and ask again.
- If the manifest references FASTQ paths, spot-check that at least one exists.
- Never proceed to Step 9 (write) without explicit confirmation in Step 8.
- The verdict gate is **never** overridden silently — if SP1–SP8 would emit `NO-GO`, ask the user before writing `NO-GO` to `pipeline_state.json`.
- `pipeline_variant` is set **once** at intake and is not re-asked on later invocations. Changing variants requires a new `run_id`.
- `medaka_model` (consensus variant) has **no universal default** — every consensus-variant run must supply one explicitly.
