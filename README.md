# Nanopore 16S eDNA Metabarcoding (agent-driven)

[![Version](https://img.shields.io/badge/version-0.3.0-blue)](#-installation)
[![Type](https://img.shields.io/badge/type-agent%20skill-blueviolet)](#-installation)
[![Built with](https://img.shields.io/badge/built%20with-bioinfo--skill--creator-orange)](https://github.com/cheahhl814/bioinfo-skill-creator)

[![Shape](https://img.shields.io/badge/shape-multi--tool%20pipeline-8A2BE2)](#-pipeline-overview)

End-to-end agent orchestration of Nanopore-sequenced bacterial/archaeal 16S rRNA eDNA metabarcoding. Runs three classification methods by default (readbased+minimap2/RefSeq, readbased+IdTaxa/SILVA, consensus+medaka-polish+IdTaxa/SILVA); no single method is sufficient for ONT data. Reference-database retrieval (RefSeq 16S, SILVA, tax lookups, IdTaxa training seed) is delegated to the biodb-fetch dependency skill.

**Repository**: https://github.com/cheahhl814/nf-edna-nanopore

> [!NOTE]
> Current version: **v0.3.0** (updated 2026-10-06).

## Contents

- [Installation](#-installation)
- [Usage](#-usage)
- [Pipeline overview](#-pipeline-overview)
- [Tools](#-tools)
- [Update check](#-update-check)
- [Repository layout](#-repository-layout)
- [Hard guarantees](#-hard-guarantees)
- [Provenance](#-provenance)

## 🚀 Installation

This is an **agent skill**, not a user-facing library. The recommended install path is to let your AI agent import it.

**Option A — give your agent this prompt (recommended):**

```text
Install the nf-edna-nanopore skill from
https://github.com/cheahhl814/nf-edna-nanopore —
clone it into your agent's skills directory (the path your agent watches
for skills) and run `pixi install` from that directory. Then read the
skill's SKILL.md to understand its phases and the Input/Output contract
for each. Confirm when the environment is ready.
```

**Option B — manual install:**

```bash
git clone https://github.com/cheahhl814/nf-edna-nanopore.git
cd nf-edna-nanopore
pixi install
```

> [!TIP]
> `pixi install` resolves every pinned tool from `pixi.toml` (channels: conda-forge, bioconda) into an isolated `.pixi/` environment — no system-wide installs, no version conflicts with other skills.

## 💡 Usage

The skill is designed to be driven by an AI agent: the agent reads the master `SKILL.md`, detects the current phase from the filesystem state of your run directory, and routes to the right sub-skill.

### Natural-language prompts that trigger the skill

```text
Nanopore 16S metabarcoding
ONT 16S amplicon
MinION 16S eDNA
long-read 16S classification
full-length 16S nanopore
```

### Manual phase execution

If you prefer to drive the phases yourself (or want to re-run a single phase):

```bash
# Set your run directory (all phase artifacts land here)
RUN_DIR=/path/to/run-dir

pixi run preflight   # Phase 1 — intake: validate inputs, write results/{run_id}/pipeline_state.json
pixi run run         # Phase 2 — runner scripts under runners/manual-runner/bin/ (after intake ≥ GO)
pixi run qc          # Phase 3 — interpret: report.md + narrative.md with cross-method comparison
pixi run debug       # On failure — interpret stderr via the sub-skill signature libraries
pixi run battle-test # Verify the skill's structural integrity
pixi run update-check # Compare deployed git SHA against upstream
```

> [!NOTE]
> The `pixi run preflight/run/qc` tasks in this skill's `pixi.toml` are conveniences that point at the same evidence chain the agent follows; the agent-driven path (reading `pipeline_state.json` stage state from `results/{run_id}/`) remains the primary mode — the runner scripts, not the pixi tasks, execute real pipeline stages.

> [!IMPORTANT]
> Each phase has an explicit **Inputs/Outputs contract** at the top of its sub-skill `SKILL.md`. If the upstream artifact is missing (e.g. you run `run` before `preflight` passed), the sub-skill refuses to proceed and tells you which phase to run first. Phases are gated on purpose — don't skip them.

## 🔬 Pipeline overview

The analysis follows a phased evidence chain. Each phase consumes the artifacts of the previous phase and gates progression with a Go/No-Go check.

| # | Phase | Goal | Sub-skill | Artifact produced |
|:--|:------|:-----|:----------|:------------------|
| **1** | `preflight` | Validate Nanopore 16S run inputs (primer pair, length windows, reference-asset paths, sample manifest) and resolve parameters for all three classification methods | `preflight/edna-nanopore-intake/` | `results/{run_id}/pipeline_state.json` |
| **2** | `run` | Execute the QC stage, then the three classification method scripts (minimap2/RefSeq, IdTaxa/SILVA, consensus+medaka+IdTaxa/SILVA), confirming each with the scientist | `run/edna-nanopore-run/` | `results/{run_id}/{method}/...` + updated `pipeline_state.json` + `run_summary.json` |
| **3** | `interpret` | Turn the method outputs into `report.md` + `narrative.md`, always including the mandatory cross-method comparison (large disagreements are findings, not noise) | `interpret/edna-nanopore-interpret/` | `results/{run_id}/<run_id>-report.md` |
| **4** | `reference-db` | Curate + locally build the classifier references (RefSeq MMI + tax TSV, Kraken2 16S DB, SILVA IdTaxa model) — downloads delegated to the `biodb-fetch` dependency skill | `reference-db/` | `$ASSETS_DIR/16s_{minimap2,kraken2,idtaxa}/...` + `run_summary.json` |

> [!TIP]
> Read each sub-skill's `SKILL.md` for the full procedure, its ask-user stop points, and its signature library (stderr pattern → cause → fix).

## 🧰 Tools

All tools are resolved from conda-forge/bioconda via the pinned `pixi.toml`.

| Tool | Version | Role |
|:-----|:--------|:-----|
| `chopper` | >=0.8.0,<0.9 | read quality/length filter |
| `cutadapt` | >=5.2,<6 | primer trimming |
| `nanoplot` | >=1.46.0,<2 | raw-read QC summary |
| `minimap2` | >=2.27,<3 | read aligner + LCA classifier input |
| `kraken2` | >=2.1.3,<3 | secondary classification sanity check |
| `seqtk` | >=1.5,<2 | sequence utilities |
| `medaka` | >=2.0.1,<3 | consensus polishing |
| `yacrd` | >=0.6.2,<0.7 | coverage gap detection |
| `biom-format` | >=2.1.17,<3 | BIOM table export |
| `samtools` | >=1.19,<2 | alignment utilities |
| `mafft` | >=7.526,<8 | multiple sequence alignment |
| `fasttree` | >=2.2.0,<3 | phylogenetic tree |
| `r-base` | 4.5.* | IdTaxa (DECIPHER)/diversity R runtime |
| `julia` | >=1.12.2,<1.13 | decontam scripts |
| `python` | >=3.11,<3.13 | cluster/QC python runtime |

Tool usage is grounded in the offline `docs-corpus/` snapshots (version-matched `--help`/`man` captures, upstream repo docs, and web docs as fallback) — the agent reads these instead of guessing flags.

## 🔄 Update check

Every skill built with [bioinfo-skill-creator](https://github.com/cheahhl814/bioinfo-skill-creator) ships a self-update check that compares the deployed git SHA against this upstream repo via `git fetch` — no GitHub API call, no extra dependencies.

```bash
pixi run update-check
```

| Verdict | Exit | Meaning |
|:--------|:-----|:--------|
| `UP-TO-DATE` | 0 | Local HEAD matches origin/HEAD |
| `LOCAL-AHEAD` | 0 | Unpushed local commits; no action needed |
| `BEHIND-BY-N` | 1 | Upstream is N commits ahead → re-pull/re-sync from this repo |
| `OFFLINE` | 2 | `git fetch` failed; informational only |
| `NO-ORIGIN` | 2 | No `origin` remote configured; informational only |

## 📁 Repository layout

```text
nf-edna-nanopore/
├── SKILL.md                 # Master orchestrator (router — start here)
├── README.md                # This file
├── pixi.toml                # Pinned tool environment (pixi install)
├── docs-corpus/             # Offline snapshots of upstream tool docs
│   └── chopper/
│   └── cutadapt/
│   └── nanoplot/
│   └── minimap2/
│   └── kraken2/
│   └── seqtk/
│   └── medaka/
│   └── yacrd/
│   └── biom-format/
│   └── samtools/
│   └── mafft/
│   └── fasttree/
│   └── r-base/
│   └── julia/
│   └── python/
├── preflight/            # Phase sub-skill
├── run/            # Phase sub-skill
├── interpret/            # Phase sub-skill
├── reference-db/            # Phase sub-skill
├── bin/
│   └── skill-update-check.py  # Self-update check (pixi run update-check)
└── bin/
    └── scaffold-render.py     # Reproducibility — re-render the skill from params.json
```

## 🔒 Hard guarantees

- **Filesystem evidence chain** — every phase emits the artifact the next phase consumes; the boundary between phases is the filesystem, not agent memory.
- **Docs-grounded tool usage** — tool flags come from `docs-corpus/`, never from the agent's memory.
- **Explicit stop points** — ambiguous decisions are surfaced to you as *Evidence + Recommend + Options*, not auto-picked.
- **Reproducible environments** — every tool is pinned in `pixi.toml` and resolved via pixi.

## 🚀 Nextflow runner

This skill does not currently ship a Nextflow runner. For cohort/HPC execution, wrap the `pixi run` tasks in a workflow scheduler of your choice.

## Provenance

Built with the [bioinfo-skill-creator](https://github.com/cheahhl814/bioinfo-skill-creator) meta-skill (v1.1.0), following the AiX-BIO skill convention (preflight → build → debug → battle-test evidence chain). Pattern adopted from:

- **BettaMt-agents** — https://github.com/cheahhl814/BettaMt-agents
- **bacterial-genome-analysis** — https://github.com/cheahhl814/bacterial-genome-analysis
- **amr-gene-screening** — https://github.com/cheahhl814/amr-gene-screening

## License

Released under the MIT License — see the license file in this repository for details.