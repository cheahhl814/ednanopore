# nf-edna-nanopore

**End-to-end Nanopore 16S eDNA metabarcoding pipeline — agent-orchestrated via Nextflow DSL2**

> v0.1.0 · Two selectable pipeline variants: **consensus** (cluster → medaka-polish → classify) and **read_based** (classify every read directly).

---

## What it does

`nf-edna-nanopore` processes Oxford Nanopore (ONT/MinION/PromethION) 16S rRNA amplicon reads through a complete eDNA metabarcoding workflow: quality control, classification, and (for the consensus variant) decontamination, diversity analysis, and association testing.

It ships **two pipeline variants** selectable at intake:

| Variant | Entry point | Stages | Best for |
|---|---|---|---|
| **consensus** (default) | `main-consensus.nf` | QC → cluster → decontam → classify → diversity → association | Publication-grade work: ASV-like rep-seqs, phylogenetic diversity, sequence-based decontam, geocuration, GBIF publishing |
| **read_based** | `main-readbased.nf` | QC → classify → decontam (taxon-level) | Quick screening, very high sample counts, or when clustering-parameter sensitivity is a concern |

Both variants share the same **QC module** (Chopper + cutadapt + NanoPlot) and **classification** step; they diverge at the clustering/denoising stage.

### When to use this skill

- You have **Nanopore-sequenced** 16S rRNA amplicon reads (partial ~350–600 bp or full-length ~1500 bp).
- You want ASVs/taxonomy/diversity from ONT data.
- You want to **compare** consensus vs. read-based classification on the same dataset.

### When NOT to use this skill

- Your reads are **Illumina** short reads → use `nf-edna`'s `16s.json` preset instead.
- Your reads are **not yet basecalled or demultiplexed** → do that first.
- Your marker is **not 16S** → not supported in v0.1.0.

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
│  │                       run                                     │  │
│  │                                                               │  │
│  │   ┌─── Variant A: consensus ───────────────────────────┐      │  │
│  │   │  QC → cluster → decontam → classify → diversity   │      │  │
│  │   │                                     → association  │      │  │
│  │   └────────────────────────────────────────────────────┘      │  │
│  │                                                               │  │
│  │   ┌─── Variant B: read_based ──────────────────────────┐      │  │
│  │   │  QC → classify → decontam (taxon-level)            │      │  │
│  │   └────────────────────────────────────────────────────┘      │  │
│  └───────────────────────────────────────────────────────────────┘  │
│        │                                                             │
│  ┌─────▼──────────┐                                                  │
│  │   interpret     │  Generate report.md + narrative.md              │
│  └─────────────────┘                                                  │
│                                                                     │
│  ┌─────────────────┐                                                 │
│  │   reference-db  │  Catalog + download/build reference assets       │
│  └─────────────────┘                                                 │
└──────────────────────────────────────────────────────────────────────┘
```

---

## Quick start

### Prerequisites

- **Nextflow ≥ 23.10.0** (DSL2-compatible release; `nextflow.config` requires `!>=24.04.0`)
- **Pixi** — manages per-stage tool environments (`pixi install` in the runner directory)
- **git**

### 1. Prepare reference databases

Run the `reference-db/` sub-skill first to download/build the classifier reference assets:

| Classifier mode | Required assets | How to get them |
|---|---|---|
| `minimap2` (default) | `ref_mmi` + `tax_lookup` TSV | `reference-db/` §1 (NCBI RefSeq Targeted Loci) |
| `kraken2` | `kraken2_db` directory | `reference-db/` §2 (pre-built Kraken2 16S) |
| `idtaxa` (consensus variant only) | `idtaxa_model` RDS | `reference-db/` §3 (SILVA DECIPHER IdTaxa) |

### 2. Run intake (preflight)

```bash
# The agent reads your manifest, metadata, and parameters,
# validates everything, and writes pipeline_state.json
# with a GO / GO-WITH-WARNINGS / NO-GO verdict.
```

Provide:
- Sample manifest (CSV: `sample-id,absolute-filepath` — single-end ONT only)
- Metadata TSV (must include `sample-id` + `is_negative` columns)
- Primer sequences (forward + reverse)
- Amplicon length range (`min_length`, `max_length`)
- Classifier mode + reference asset paths
- `medaka_model` (consensus variant only — must match your flow cell chemistry)
- Grouping variable + reference level (consensus variant only)

### 3. Run the pipeline

```bash
# Variant A (consensus):
nextflow run runners/nextflow-runner/main-consensus.nf \
  -params-file runners/nextflow-runner/params/16s-nanopore.json \
  -params-file results/{run_id}/params.json \
  -c runners/nextflow-runner/nextflow.config

# Variant B (read_based):
nextflow run runners/nextflow-runner/main-readbased.nf \
  -params-file runners/nextflow-runner/params/16s-nanopore.json \
  -params-file results/{run_id}/params.json \
  -c runners/nextflow-runner/nextflow.config
```

### 4. Interpret results

The `interpret/edna-nanopore-interpret` sub-skill generates:
- `<run_id>-report.md` — structured report with QC, taxonomy, diversity (consensus only), association (consensus only)
- `narrative.md` — plain-language summary suitable for a manuscript Results section

---

## Output structure

```
results/{run_id}/
├── pipeline_state.json              # Run state, variant, verdict, completed stages
├── run.log
├── params.json                      # Merged run parameters
├── intake_evidence.txt              # Preflight evidence log
├── qc_output/                       # Chopper + cutadapt + NanoPlot
├── cluster_output/                   # Variant A only: minimap2 selfmap + yacrd + medaka
├── asv_table/                       # Variant A only: feature table + rep-seqs
├── taxonomy/                         # Classification results (both variants)
├── diversity_output/                 # Variant A only (v1)
├── association_output/                # Variant A only (v1)
├── run_summary.json
├── {run_id}-report.md
└── narrative.md
```

---

## Skill structure

This repository is a **meta-skill** (AiX-BIO convention) — a router that delegates to sub-skills:

```
nf-edna-nanopore/
├── SKILL.md                              # Router / orchestrator
├── README.md                             # This file
├── preflight/
│   └── edna-nanopore-intake/
│       └── SKILL.md                      # Validate inputs, write pipeline_state.json
├── run/
│   └── edna-nanopore-run/
│       └── SKILL.md                      # Execute the correct Nextflow variant
├── interpret/
│   └── edna-nanopore-interpret/
│       └── SKILL.md                      # Generate report + narrative
├── reference-db/
│   ├── SKILL.md                          # Catalog + download/build reference assets
│   ├── preflight/
│   │   └── reference-db-preflight/
│   │       └── SKILL.md                  # Validate reference DB inputs
│   ├── run/
│   │   └── reference-db-run/
│   │       └── SKILL.md                  # Build/download reference DBs
│   ├── CATALOG_SECTION_KRAKEN2_16S.md
│   ├── CATALOG_SECTION_TARGETED_LOCI.md
│   └── bin/
│       └── build_tax_lookup.py           # Build taxonomy lookup from NCBI
└── runners/
    └── nextflow-runner/
        ├── main-consensus.nf             # Variant A entry point
        ├── main-readbased.nf            # Variant B entry point
        ├── nextflow.config              # Pipeline configuration
        ├── params/
        │   └── 16s-nanopore.json         # Flexible 16S preset (350–1600 bp)
        ├── modules/
        │   ├── qc.nf                    # Chopper + cutadapt + NanoPlot
        │   ├── cluster_consensus.nf     # minimap2 selfmap + yacrd + medaka
        │   ├── merge_decontam.nf        # ASV table merge + decontam
        │   ├── classify_consensus.nf    # Classify polished consensus seqs
        │   ├── classify_reads.nf        # Classify every read (Variant B)
        │   ├── diversity.nf             # Alpha + beta diversity
        │   └── association.nf           # Differential abundance + correlation
        ├── env/                          # Pixi per-stage environments
        │   ├── qc/pixi.toml
        │   ├── cluster/pixi.toml
        │   ├── classification/pixi.toml
        │   ├── association/pixi.toml
        │   ├── diversity/pixi.toml
        │   └── decontam/
        │       ├── pixi.toml
        │       ├── Manifest.toml
        │       └── Project.toml
        └── bin/                          # Helper scripts
            ├── minimap2_lca.py
            ├── merge_tables.R
            ├── filter_table.jl
            ├── decontam.jl
            ├── decontam_by_taxon.jl
            ├── filter_idtaxa_by_confidence.jl
            ├── idtaxa_rds.R
            ├── alpha_diversity.R
            ├── beta_diversity.R
            ├── community_typing.R
            ├── differential_abundance.R
            ├── correlation_analysis.R
            ├── agglomerate_data.R
            └── root_tree.R
```

---

## Pipeline variants in detail

### Variant A — consensus (`main-consensus.nf`)

1. **QC** — Chopper (quality + length filtering) → cutadapt (primer trimming) → NanoPlot
2. **Cluster** — minimap2 self-map → yacrd (detect chimeras) → medaka consensus polishing → ASV-like feature table + representative sequences
3. **Decontam** — sequence-keyed prevalence decontam (reuses nf-edna's `decontam.jl`)
4. **Classify** — minimap2-LCA / kraken2 / idtaxa against the chosen reference
5. **Diversity** — alpha + beta diversity (reuses nf-edna's `diversity.nf`)
6. **Association** — differential abundance + correlation (reuses nf-edna's `association.nf`)

### Variant B — read_based (`main-readbased.nf`)

1. **QC** — same Chopper + cutadapt + NanoPlot
2. **Classify** — every read classified directly (no clustering)
3. **Decontam** — taxon-level mean-relative-abundance decontam (`decontam_by_taxon.jl`)

**Variant B limitations (v0.1.0):** no representative sequences → no phylogenetic diversity/UniFrac, no sequence-based decontam, no geocuration, no edna-visualize/edna-gbif-publish chaining.

---

## Classifiers

| Mode | Input | Speed | Notes |
|---|---|---|---|
| `minimap2` (default) | `ref_mmi` + `tax_lookup` TSV | Moderate | LCA assignment; mirrors ONT's `wf-16s`; works for both variants |
| `kraken2` | `kraken2_db` directory | Fast | K-mer based; works for both variants |
| `idtaxa` | `idtaxa_model` RDS | Moderate | DECIPHER IdTaxa; **consensus variant only** (needs polished sequences) |

---

## Composability with other AiX-BIO skills

| Skill | When to chain |
|---|---|
| `reference-db` (this repo) | Run **before** the first nf-edna-nanopore run if you don't yet have classifier reference assets |
| `nf-edna` | Reference for reused downstream modules (diversity, association, decontam, agglomerate). Also for IdTaxa model training if the opt-in mode needs a custom model |
| `edna-visualize` | Variant A only, after interpret |
| `edna-gbif-publish` | Variant A only, after interpret |

---

## Parameters

### Preset: `params/16s-nanopore.json`

The single flexible 16S preset covers both partial (~600 bp) and near-full-length (~1500 bp) amplicons — `min_length` and `max_length` are **run-time parameters**, not separate preset files:

| Parameter | Default | Notes |
|---|---|---|
| `marker` | `16S` | Only marker in v0.1.0 |
| `min_length` | 350 | Override at intake for your amplicon |
| `max_length` | 1600 | Override at intake for your amplicon |
| `min_qual` | 10 | Chopper quality threshold |
| `kingdoms` | `Bacteria,Archaea` | Kingdom filter |
| `classifier` | `minimap2` | `minimap2` / `kraken2` / `idtaxa` |
| `pipeline_variant` | `consensus` | `consensus` / `read_based` |
| `medaka_model` | `r1041_e82_400bps_sup_v5.0.0` | Consensus variant only; must match flow cell chemistry |
| `cluster_min_identity` | 0.85 | Consensus: clustering threshold |
| `cluster_min_coverage_fraction` | 0.8 | Consensus: clustering coverage |
| `yacrd_min_coverage` | 0.4 | Consensus: yacrd chimera filter |
| `minimap2_min_pct_identity` | 0.97 | Classification identity threshold |
| `minimap2_min_ref_coverage` | 0.8 | Classification reference coverage |
| `idtaxa_threshold` | 60 | IdTaxa bootstrap confidence (consensus + idtaxa only) |
| `decontam_threshold` | 0.1 | Decontam prevalence/ratio threshold |

---

## License

See individual files and third-party tool licenses. The pipeline code is by Cheah Hong Leong. Reference databases (NCBI RefSeq, SILVA, Kraken2) are subject to their respective terms — see `reference-db/SKILL.md` and the `CATALOG_SECTION_*.md` files for details.

---

## Author

**Cheah Hong Leong** · AiX-BIO

## Version

**0.1.0** — Initial release. Two pipeline variants (consensus + read_based), three classifier modes (minimap2 / kraken2 / idtaxa), full QC → classify → decontam/diversity/association chain for Variant A, QC → classify → taxon-decontam for Variant B.