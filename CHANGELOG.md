# Changelog

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

Each has a different, known blind spot (see `run/edna-nanopore-run/SKILL.md`'s
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
