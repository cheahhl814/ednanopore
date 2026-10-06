# nf-edna-nanopore

**End-to-end Nanopore 16S eDNA metabarcoding pipeline — agent-driven, no Nextflow**

> v0.2.0 · Runs three classification methods by default: **readbased_minimap2**, **readbased_idtaxa**, **consensus_idtaxa**. No variant to pick — see "Why three methods" below.

---

## What it does

`nf-edna-nanopore` processes Oxford Nanopore (ONT/MinION/PromethION) 16S rRNA amplicon reads through a complete eDNA metabarcoding workflow: quality control, classification (three independent ways), decontamination, and (for the one method that produces representative sequences) diversity analysis and association testing.

It runs **three classification methods by default**, not a single selectable variant:

| Method | Error-corrects reads? | Reference | Species-level? | Script |
|---|---|---|---|---|
| **readbased_minimap2** | No (classifies raw trimmed reads) | RefSeq Targeted Loci (or similar) | Yes, where reference has species headers | `bin/run_readbased_minimap2.sh` |
| **readbased_idtaxa** | No | SILVA (DECIPHER pre-trained) | No — the pre-trained model has no species rank at all | `bin/run_readbased_idtaxa.sh` |
| **consensus_idtaxa** | Yes (cluster + medaka polish) | SILVA | No, same ceiling | `bin/run_consensus_idtaxa.sh` |

All three share the same QC stage (Chopper + cutadapt + NanoPlot).

### Why three methods, not one

v0.1.0 made the scientist pick exactly one of two mutually-exclusive "variants" at intake. That decision now looks like a mistake: a real cross-method comparison on this project's dataset found one phylum's abundance estimate ranging **3.6% → 9.4% → 19.3%** across the three methods, on identical samples. Each method has a different, known blind spot (RefSeq under-represents uncultured/`Candidatus` lineages; the SILVA IdTaxa model caps at genus; clustering can itself amplify a reference-driven signal). Running only one would have reported one of those three numbers with no way to know it was method-sensitive at all. v0.2.0 runs all three by default and treats large disagreements as findings to investigate, not noise to average away.

### When to use this skill

- You have **Nanopore-sequenced** 16S rRNA amplicon reads (partial ~350-600 bp or full-length ~1500 bp).
- You want taxonomy/abundance cross-validated across methods rather than trusting one classifier+reference combination.

### When NOT to use this skill

- Your reads are **Illumina** short reads → use `nf-edna`'s `16s.json` preset instead.
- Your reads are **not yet basecalled or demultiplexed** → do that first.
- Your marker is **not 16S** → not supported in v0.2.0.

---

## Pipeline architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                        nf-edna-nanopore                              │
│                                                                     │
│  ┌──────────┐                                                       │
│  │ preflight │  Gather params, validate inputs, write               │
│  │ (intake)  │  pipeline_state.json with GO/NO-GO verdict           │
│  └─────┬─────┘                                                       │
│        │                                                             │
│  ┌─────▼─────────────────────────────────────────────────────────┐  │
│  │                       run (agent-driven, no Nextflow)         │  │
│  │                                                               │  │
│  │   QC (shared) → run_qc.sh                                     │  │
│  │        │                                                      │  │
│  │        ├─→ run_readbased_minimap2.sh  (RefSeq, per-read)      │  │
│  │        ├─→ run_readbased_idtaxa.sh    (SILVA, per-read)       │  │
│  │        └─→ run_consensus_idtaxa.sh    (SILVA, clustered)      │  │
│  └───────────────────────────────────────────────────────────────┘  │
│        │                                                             │
│  ┌─────▼──────────┐                                                  │
│  │   interpret     │  report.md (incl. cross-method comparison)      │
│  │                 │  + narrative.md                                 │
│  └─────────────────┘                                                  │
│                                                                     │
│  ┌─────────────────┐                                                 │
│  │   reference-db  │  Catalog + download/build reference assets       │
│  └─────────────────┘                                                 │
└──────────────────────────────────────────────────────────────────────┘
```

Each of the three classification methods runs independently once QC is
done — they can be launched in parallel background jobs, in any order.

---

## Quick start

### Prerequisites

- **Pixi** (`curl -fsSL https://pixi.sh/install.sh | bash`) — manages per-stage tool environments under `runners/manual-runner/env/`
- **git**

No Nextflow, no Java — removed as dependencies in v0.2.0.

### 1. Prepare reference databases

Run the `reference-db/` sub-skill first:

| Method | Required assets | How to get them |
|---|---|---|
| `readbased_minimap2` | `ref_mmi` + `tax_lookup` TSV | `reference-db/` §1 (NCBI RefSeq Targeted Loci) |
| `readbased_idtaxa` + `consensus_idtaxa` | `idtaxa_model` (`.RData`/`.rds`, shared by both) | `reference-db/` §3 (SILVA DECIPHER IdTaxa) |

### 2. Run intake (preflight)

Invoke `preflight/edna-nanopore-intake`. Provide:
- Sample manifest (CSV: `sample-id,absolute-filepath` — single-end ONT only)
- Metadata TSV (must include `sample-id` + `is_negative` columns)
- Primer sequences (forward + reverse), amplicon length range
- Reference asset paths for whichever methods are in scope (default: all three)
- `medaka_model` (only needed if `consensus_idtaxa` is in scope — must match your flow cell chemistry)
- Grouping variable + reference level (only needed for `consensus_idtaxa`'s diversity/DAA stages)

Writes `results/{run_id}/{pipeline_state.json, params.json, manifest.tsv}`.

### 3. Run the pipeline

Invoke `run/edna-nanopore-run`, which shows and confirms each command before running it. Example (what it constructs):

```bash
bash runners/manual-runner/bin/run_qc.sh \
  results/{run_id}/manifest.tsv {input_data_dir} results/{run_id}/qc \
  "{primers_fwd}" "{primers_rev}"

bash runners/manual-runner/bin/run_readbased_minimap2.sh \
  results/{run_id}/manifest.tsv results/{run_id}/qc results/{run_id}/readbased_minimap2 \
  {ref_mmi} {tax_lookup} {metadata}

bash runners/manual-runner/bin/run_readbased_idtaxa.sh \
  results/{run_id}/manifest.tsv results/{run_id}/qc results/{run_id}/readbased_idtaxa \
  {idtaxa_model} {metadata}

bash runners/manual-runner/bin/run_consensus_idtaxa.sh \
  results/{run_id}/manifest.tsv results/{run_id}/qc results/{run_id}/consensus_idtaxa \
  {idtaxa_model} {metadata}
```

Each script's full argument list and defaults are documented in its own
header comment. `run_readbased_idtaxa.sh` and `run_consensus_idtaxa.sh`
are the slow ones — IdTaxa's classification call costs ~0.17-0.2
sec/sequence on a 64-core machine; `run_readbased_idtaxa.sh` defaults to
subsampling (10,000 reads/sample) for this reason.

### 4. Interpret results

The `interpret/edna-nanopore-interpret` sub-skill generates:
- `<run_id>-report.md` — Run Summary, **Methods Run & Cross-Method Comparison** (mandatory, always first), QC, Taxonomy Overview, Diversity/DAA/Correlation (`consensus_idtaxa` only), Caveats
- `narrative.md` — plain-language summary, names any major cross-method divergence up front

---

## Output structure

```
results/{run_id}/
├── pipeline_state.json          # Run state, methods in scope, verdict, completed stages
├── params.json                  # Merged run parameters
├── manifest.tsv                 # sample_id<TAB>fastq_filename (no header)
├── intake_evidence.txt          # Preflight evidence log
├── qc/                          # Chopper + cutadapt (shared across all 3 methods)
├── readbased_minimap2/          # taxonomy/ + asv_table/
├── readbased_idtaxa/            # taxonomy/ + asv_table/
├── consensus_idtaxa/            # cluster/ + asv_table/ + taxonomy/ (incl. agglomerated_data/)
├── run_summary.json
├── {run_id}-report.md
└── narrative.md
```

---

## Skill structure

```
nf-edna-nanopore/
├── SKILL.md                              # Router / orchestrator
├── README.md                             # This file
├── CHANGELOG.md                     # (project root) history of every fix that shaped v0.2.0's defaults
├── preflight/
│   └── edna-nanopore-intake/
│       └── SKILL.md                      # Validate inputs, write pipeline_state.json
├── run/
│   └── edna-nanopore-run/
│       └── SKILL.md                      # Run each bin/run_*.sh script, agent-driven
├── interpret/
│   └── edna-nanopore-interpret/
│       └── SKILL.md                      # Generate report + narrative + cross-method comparison
├── reference-db/
│   ├── SKILL.md                          # Catalog + download/build reference assets
│   ├── preflight/reference-db-preflight/SKILL.md
│   ├── run/reference-db-run/SKILL.md
│   ├── CATALOG_SECTION_KRAKEN2_16S.md
│   ├── CATALOG_SECTION_TARGETED_LOCI.md
│   └── bin/build_tax_lookup.py           # Build taxonomy lookup from NCBI (ref2taxid + rankedlineage.dmp)
└── runners/
    └── manual-runner/
        ├── defaults/
        │   └── 16s-nanopore.json         # Flexible 16S preset + validated per-method defaults
        ├── env/                          # Pixi per-stage environments
        │   ├── qc/pixi.toml
        │   ├── cluster/pixi.toml
        │   ├── classification/pixi.toml
        │   ├── association/pixi.toml
        │   ├── diversity/pixi.toml
        │   └── decontam/{pixi.toml, Manifest.toml, Project.toml}
        └── bin/
            ├── run_qc.sh                      # Stage 1 (shared)
            ├── run_readbased_minimap2.sh      # Method 1
            ├── run_readbased_idtaxa.sh        # Method 2
            ├── run_consensus_idtaxa.sh        # Method 3
            ├── cluster_graph.py               # Used by run_consensus_idtaxa.sh
            ├── medaka_polish_one.sh            # Used by run_consensus_idtaxa.sh
            ├── minimap2_lca.py
            ├── idtaxa_rds.R
            ├── filter_idtaxa_by_confidence.jl
            ├── merge_tables.R
            ├── filter_table.jl
            ├── decontam.jl
            ├── decontam_by_taxon.jl
            ├── agglomerate_data.R
            ├── alpha_diversity.R
            ├── beta_diversity.R
            ├── community_typing.R
            ├── differential_abundance.R
            ├── correlation_analysis.R
            └── root_tree.R
```

---

## The three methods in detail

### readbased_minimap2 (`bin/run_readbased_minimap2.sh`)

QC → minimap2 alignment + LCA against RefSeq-16S, per read, no clustering.
Species-level where the reference has species headers; every read is
counted independently (no clustering threshold to dilute rare taxa).
**Blind spot**: RefSeq's curated Targeted Loci collection under-represents
uncultured/`Candidatus` environmental lineages — verified case:
`Candidatus Solibacter`/`Koribacter`, zero usable RefSeq hits for either.

### readbased_idtaxa (`bin/run_readbased_idtaxa.sh`)

QC → DECIPHER IdTaxa + SILVA, per read, no clustering. Exists specifically
to isolate the reference-database effect from the clustering effect (run
alongside the other two to triangulate). Defaults to a 10,000-read/sample
subsample for runtime reasons — full-depth is possible but can take the
better part of a day on a large dataset.

### consensus_idtaxa (`bin/run_consensus_idtaxa.sh`)

QC → minimap2 self-map → yacrd chimera filter → greedy clustering →
medaka consensus polishing → DECIPHER IdTaxa + SILVA. The only method that
error-corrects reads before classification, and the only one producing
representative sequences (enabling diversity/DAA/correlation downstream).
**Blind spots**: genus is the resolution ceiling (same SILVA model as
`readbased_idtaxa`); cost scales with *compositional skew* within a
sample, not just read count (a sample dominated by one organism can make
the self-mapping step blow up combinatorially).

---

## Composability with other AiX-BIO skills

| Skill | When to chain |
|---|---|
| `reference-db` (this repo) | Run **before** the first nf-edna-nanopore run if you don't yet have reference assets |
| `nf-edna` | Reference for `idtaxa-training` if you want a custom-trained (non-SILVA) IdTaxa model |
| `edna-visualize` / `edna-gbif-publish` | `consensus_idtaxa` output only (the only method with rep-seqs) |

---

## Parameters

### Preset: `runners/manual-runner/defaults/16s-nanopore.json`

Validated defaults, each traceable to a specific finding in
`CHANGELOG.md`:

| Parameter | Default | Notes |
|---|---|---|
| `qc.min_length` | 450 | Raw-read floor (chopper) |
| `qc.min_length_trimmed` | 350 | **Separate** post-primer-trim floor — reusing the raw floor here rejected most correctly-trimmed inserts (Bug 29) |
| `qc.max_length` | 1600 | Override per amplicon class |
| `qc.primer_revcomp` | true | `cutadapt --revcomp` — without it, ~55-63% of genuine reverse-strand reads were silently discarded (Bug 28) |
| `readbased_minimap2.min_percent_identity` | 0.85 | Not the Illumina/wf-16s default of 0.97 — too strict for ONT |
| `readbased_idtaxa.subsample_n` | 10000 | Set to 0 to classify every read at full cost |
| `consensus.cluster_min_identity` | 0.95 | Distinct from `readbased_minimap2`'s 0.85 — different step, different meaning |
| `consensus.medaka_model` | `r1041_e82_400bps_sup_v5.0.0` | Must match your flow cell chemistry — no universal default |
| `*.idtaxa_threshold` | 60 | Matches `DECIPHER::IdTaxa()`'s own internal default — lowering a downstream filter below 60 is a no-op; the threshold must be passed into the `IdTaxa()` call itself to actually change |
| `*.decontam_threshold` | 0.1 | Ratio threshold (taxon-level) / p-value threshold (ASV-level), semantics differ by script |

---

## License

See individual files and third-party tool licenses. The pipeline code is by Cheah Hong Leong. Reference databases (NCBI RefSeq, SILVA, Kraken2) are subject to their respective terms — see `reference-db/SKILL.md` and the `CATALOG_SECTION_*.md` files for details.

---

## Author

**Cheah Hong Leong** · AiX-BIO

## Version

**0.2.0** — Nextflow removed; pipeline is now agent-driven (direct shell
invocation of `runners/manual-runner/bin/run_*.sh` scripts). Replaced the
v0.1.0 exclusive `consensus`/`read_based` variant choice with three
classification methods run by default (`readbased_minimap2`,
`readbased_idtaxa`, `consensus_idtaxa`), per a real cross-method
comparison that found substantial, informative divergence between them.
See `CHANGELOG.md` for the full history of fixes that shaped these
defaults.
