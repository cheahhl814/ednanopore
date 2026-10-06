# Changelog

## v0.5.0 — Multi-marker: 18S, 12S, COI, ITS join 16S (other domains, not just Bacteria)

**First-class multi-marker support.** v0.4.0's skill was bacterial/archaeal
16S-only (the intake SP2 gate hard-checked marker == '16S'). v0.5.0
generalizes to per-marker presets, seeded by the 6-marker panel run plan
(16S-full 1400-1700, 18S-full 1700-1850, 18S-V9/Euka02 120-200,
12S-MiFish 180-260, COI 260-450).

### What changed

- **Per-marker presets** (`runners/manual-runner/defaults/`): new
  `18s-full.json`, `18s-v9.json`, `12s.json`, `coi.json`, `its.json`
  alongside the untouched battle-tested `16s-nanopore.json`. Each carries
  length-window defaults, kingdoms, per-method tuning inherited from the
  16S values, the biodb-fetch retrieval key for its references, and
  _deliberately empty_ primer fields (primers are a per-run intake input,
  confirmed against the lab protocol — presets do not hard-code them).
  Adding a marker is now data-only: drop a preset file, no sub-skill code
  changes.
- **Intake**: SP2 generalizes from the 16S-only gate to marker normalization +
  preset discovery; new SP2b offers scaffolding a preset for an unlisted
  marker; SP3's reference messaging is marker-aware. `pipeline_state.json`
  now records the resolved `marker_preset` path.
- **reference-db**: new §4 + `CATALOG_SECTION_NON16S.md` — 18S via SILVA/PR2,
  12S via MitoHelper/MitoFish (biodb-fetch `mitohelper`), COI via MIDORI2
  (CC-BY-NC, license-gated at the script) or BOLD (per-taxon API), ITS via
  UNITE (biodb-fetch `unite`); all retrieval executes through biodb-fetch's
  manifest.tsv contract. IdTaxa notes: the stock SILVA SSU r138.2 pre-trained
  model covers 16S AND 18S (no retraining); 12S/COI/ITS have NO stock model —
  IdTaxa is opt-in behind custom training via `nf-edna/idtaxa-training`, and
  minimap2-LCA is the default classifier for those markers (encoded in
  `consensus.classifier` per preset).
- **Classifier-method honesty**: for 12S/COI/ITS the "three methods by
  default" rule adapts — readbased_minimap2 + consensus(by minimap2-LCA) run
  by default; readbased_idtaxa runs only after a custom model is trained.
  The cross-method comparison in the report flags whichever methods ran.

## v0.4.0 — Renamed to ednanopore (Nextflow-free name)


The skill no longer uses Nextflow (removed in v0.2.0), so the `nf-` prefix
was misleading — within this skill tree `nf-` denotes Nextflow pipelines
(e.g. `nf-skill`, the `nf-edna` Illumina sibling). All names fused:

| Old | New |
| --- | --- |
| `nf-edna-nanopore` (skill + repo) | **`ednanopore`** (github.com/cheahhl814/ednanopore) |
| `preflight/edna-nanopore-intake/` | `preflight/ednanopore-intake/` |
| `run/edna-nanopore-run/` | `run/ednanopore-run/` |
| `interpret/edna-nanopore-interpret/` | `interpret/ednanopore-interpret/` |

GitHub redirects the old repo URL automatically; this checkout re-pointed
`origin` explicitly. The sibling `nf-edna` (Nextflow, Illumina, 4-marker)
and `reference-db` (`ednanopore/reference-db`) keep their names — `ednanopore`
now slots into the `edna-*` family (`edna-visualize`, `edna-gbif-publish`)
and leaves room to grow beyond 16S later via presets, not new skills.
No pipeline-behavior change of any kind — this is a naming release only.

## v0.3.0 — Rebuilt on bioinfo-skill-creator v1.4.0 standard; biodb-fetch wired in


**Structural rebuild, no pipeline-behavior change.** v0.2.0's agent-manual,
three-methods-by-default design is preserved; this release brings the skill
up to the bioinfo-skill-creator v1.4.0 structural standard and wires the
[biodb-fetch](https://github.com/cheahhl814/biodb-fetch) dependency skill in
for reference-database retrieval.

### biodb-fetch is now the retrieval layer

`reference-db/` had its own raw `curl` + ad-hoc-gdown-venv download commands,
with no md5, no retries, and no retrieval manifest. v0.3.0 delegates every
download to biodb-fetch's `run/markers-reference` module
(`scripts/marker_refs.py`), which executes fetches under the manifest.tsv
contract (md5, bytes, retrieval_date, contract_version), handles
Google-Drive-via-gdown inside its own pixi env (the PEP-668 venv workaround
is gone), gates non-commercial sources (`midori2`, `bold`) on
`--i-accept-license`, and deduplicates against its content-addressed store.
Division of responsibilities after the rebuild:

| Concern | Owner |
| --- | --- |
| Which URL / which version / which license | `reference-db/` (curation, unchanged) |
| Download execution, md5, retries, manifest rows | `biodb-fetch` (`scripts/marker_refs.py` / `ncbi_fetch.py`) |
| Local index building: `minimap2 -d`, `tax_lookup.tsv` join, IdTaxa model placement | `reference-db/` (unchanged) |

If biodb-fetch is not deployed as a sibling skill, the reference-db preflight
now stops instead of falling back to raw `curl` — the fallback path predates
v0.3.0 and drops the manifest contract.

### Single root pixi.toml (v1.4.0 convention)

The six per-stage manifests (`runners/manual-runner/env/*/pixi.toml`) are
consolidated into **one root `pixi.toml`** with `[feature.<env>]` entries
(`qc`, `classification`, `cluster`, `diversity`, `decontam`, `association`),
`[environments]` blocks, and the `update-check` task. All five runner
scripts and the reference-db docs now invoke
`pixi run --manifest-path <skill-root>/pixi.toml -e <env>`. The per-env
`.toml` files are removed from the tree (recoverable from git history);
the decontam env's Julia `Project.toml`/`Manifest.toml` files remain in place,
pointed at via `[feature.decontam.activation]`.

### Other v1.4.0 standard additions

- `bin/skill-update-check.py` — `pixi run update-check` diffs the deployed
  git SHA against upstream via `git fetch`; no GitHub API call.
- `docs-corpus/` — offline per-tool docs snapshots for all 12 conda tools
  (version-matched `--help`/`man` captures where locally installed; upstream
  GitHub READMEs otherwise).
- `test-data/make_fixtures.py` + `MANIFEST.tsv` — deterministic stdlib-only
  fixtures (fixed seed, gzip `mtime=0`, sha256 over decompressed bytes).
- README.md re-rendered from the v1.4.0 template (GFM, admonitions, no
  machine-specific paths), and `preflight.md` / `preflight_evidence.txt` /
  `params.json` recorded from this rebuild's preflight audit.

## v0.2.0 — Nextflow removed; three classification methods by default

**Breaking change.** v0.1.0 made the scientist pick exactly one of two
mutually-exclusive pipeline "variants" (`consensus` / `read_based`) at
intake, and ran the whole pipeline through a Nextflow DSL2 orchestrator.
v0.2.0 removes both of those design choices, based on real-world
operational experience running this pipeline end-to-end on a Nanopore 16S
eDNA dataset.

### Nextflow removed — the pipeline is now agent-driven

After 27 distinct correctness bugs were found and fixed in the Nextflow
orchestrator (channel-pairing hazards, Groovy string-interpolation
escaping bugs, a PAF tag that minimap2 never emits, non-unique cluster
IDs across samples, BIOM "ghost rows," and more — see the bug list
below), every actual production run of this pipeline had already moved
to direct shell invocation of the same underlying tool scripts, bypassing
the orchestrator entirely. v0.2.0 formalizes that as the only supported
execution mode: an agent (human or AI) invokes the scripts under
`runners/manual-runner/bin/run_*.sh` directly, one stage at a time,
confirming each command before running it. No Nextflow, no Java
dependency, no `-params-file` chain to construct.

### Three classification methods by default, not one variant

A real cross-method comparison on Nanopore 16S eDNA data found that a
single phylum's relative-abundance estimate ranged from 3.6% to 9.4% to
19.3% depending on which classifier+reference combination was used on
*identical* input reads. Picking one method up front (as v0.1.0 required)
would have reported one of those three numbers with no way to know the
result was method-sensitive at all. v0.2.0 runs classification three
ways by default:

| Method | Error-corrects reads? | Reference | Species-level? |
|---|---|---|---|
| `readbased_minimap2` | No | RefSeq Targeted Loci (or similar) | Yes, where reference has species headers |
| `readbased_idtaxa` | No | SILVA (DECIPHER pre-trained) | No — the pre-trained model has no species rank in its training hierarchy at all |
| `consensus_idtaxa` | Yes (cluster + medaka polish) | SILVA | No, same ceiling |

Each has a different, known blind spot (see `run/ednanopore-run/SKILL.md`'s
"Why three methods, not one"). The `interpret` sub-skill's report now has
a mandatory "Methods Run & Cross-Method Comparison" section instead of a
"Pipeline Variant & Limitations" banner, and surfaces any >2x
disagreement between methods as a finding to investigate rather than
silently resolving it to one number.

### QC fixes that materially changed output volume

- **`cutadapt --revcomp` added** to the forward-primer trimming step.
  Nanopore reads are not consistently oriented; without `--revcomp`,
  `cutadapt -g <primer> --discard-untrimmed` silently discarded ~55-63%
  of genuine reverse-strand amplicon reads in every prior run.
- **A separate post-trim length floor** (`qc.min_length_trimmed`,
  default 350bp) distinct from the raw-read floor (`qc.min_length`,
  default 450bp). Reusing the raw-read floor after primer trimming
  rejected most correctly-trimmed inserts, since trimming removes
  ~30-60bp. Combined with the `--revcomp` fix, per-sample read survival
  through QC rose from ~3% to ~60% on the validating dataset.

### Reference-lookup fix: `names.dmp`/`nodes.dmp` desync

The RefSeq-based classifier's taxonomy lookup builder originally resolved
a species' taxid via NCBI's `names.dmp`, then walked that taxid's own
ancestor chain through `nodes.dmp`'s parent pointers. `names.dmp` and
`nodes.dmp` are not always in sync for recently-added taxa (new species,
or recently-renamed higher ranks like the 2021+ bacterial phylum
renaming) — many taxids exist in one file but not the other, silently
breaking the ancestor walk. Rewrote the builder to resolve each ancestor
**name** independently via `fullnamelineage.dmp` (NCBI's precomputed
full-name lineage chain), plus synonym- and `Candidatus`-prefix fallback
lookups for renamed/uncultured species. On the validating dataset,
phylum-resolved reads rose from 49.7% to 99.97%.

Also added: a per-rank completeness diagnostic to `reference-db/bin/build_tax_lookup.py`
(the `rankedlineage.dmp`-based builder) — the previous diagnostic only
flagged a row as bad when its *entire* lineage string was empty, which
cannot detect a partial loss (e.g. phylum blank while genus/species are
still populated). The new check reports per-rank resolution percentages
and warns if phylum resolution drops below 95%.

### Other correctness fixes rolled into v0.2.0's defaults

- `cluster_graph.py`'s identity check read a PAF tag (`nm:i:`) that
  minimap2's default output never emits, causing it to fall back to a
  crude formula that rejected almost every real overlap. Fixed to parse
  the `dv:f:` tag minimap2 actually writes.
- Cluster IDs were not unique across samples (`cluster_0` from sample A
  and sample B were indistinguishable strings), causing the per-sample
  merge step to silently fabricate cross-sample chimeric "ASVs." Fixed by
  prefixing every cluster ID with its sample ID from the moment it's
  generated.
- The BIOM table included a row for every candidate cluster, even ones
  `medaka` never successfully polished — pure count with no sequence and
  no possible taxonomy. Fixed to only include clusters with a matching
  file in the polished-consensus directory.
- `minimap2_min_pct_identity` defaulted to 0.97 (an Illumina/`wf-16s`
  value) — too strict for ONT's higher per-base error rate. Changed
  default to 0.85.
- `cluster_min_identity` (the *consensus clustering* threshold — distinct
  from the above) validated at 0.95 for this dataset's chemistry.
- `IdTaxa()`'s own internal confidence `threshold` default is 60; the
  separate downstream `filter_idtaxa_by_confidence.jl` step is a no-op at
  that same value, since IdTaxa never records a confidence score below
  its own threshold in the first place. Documented explicitly so a future
  user doesn't waste time tuning the wrong knob.

## v0.1.0 — Initial release

Two pipeline variants (`consensus` + `read_based`), three classifier
modes (`minimap2` / `kraken2` / `idtaxa`), full QC → classify →
decontam/diversity/association chain for the consensus variant, QC →
classify → taxon-decontam for the read-based variant. Nextflow DSL2
orchestrated.
