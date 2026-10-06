# Marker presets (`defaults/`)

One JSON preset per marker. The intake sub-skill resolves `marker` to one of
these files (case-insensitive, hyphen-normalized: `"18S-V9"` → `18s-v9.json`;
`"16S"` matches the original `16s-nanopore.json`), then applies run-time
overrides and writes the result into `results/{run_id}/pipeline_state.json`.

| Preset | Marker | Length window defaults | Kingdoms | Local reference building | Retrieval (biodb-fetch key) |
| --- | --- | --- | --- | --- | --- |
| `16s-nanopore.json` | 16S (partial or full-length) | 450–1600 bp (set at intake: ~600 bp V3-V4 or 1400–1700 bp full-length) | Bacteria, Archaea | minimap2 MMI (+ tax TSV) / kraken2 16S DB / IdTaxa SILVA SSU | `url`, `silva`, `decipher` |
| `18s-full.json` | 18S near/full-length | 1700–1850 bp (panel run plan) | Eukaryota | minimap2 MMI (+ tax TSV) / IdTaxa SILVA SSU (same pre-trained model covers 16S+18S) | `silva`, `pr2` |
| `18s-v9.json` | 18S-V9 short fragment (e.g. Euka02, nano18S) | 120–200 bp (panel run plan) | Eukaryota | same as 18s-full | `silva`, `pr2` |
| `12s.json` | 12S (e.g. MiFish-U / MiFish-L primers) | 180–260 bp (panel run plan) | Vertebrata (Eukaryota) | minimap2 MMI (+ tax TSV) — IdTaxa opt-in after custom training | `mitohelper` (MitoFish/MitoHelper Zenodo) |
| `coi.json` | COI | 260–450 bp (panel run plan) | Eukaryota (Metazoa) | minimap2 MMI (+ tax TSV) — IdTaxa opt-in after custom training | `midori2` (CC-BY-NC — script refuses without `--i-accept-license`) or `bold` (per-taxon API) |
| `its.json` | ITS (Fungi/others) | set at intake (highly variable, ~150–1000 bp) | Fungi (or target clade) | minimap2 MMI (+ tax TSV) | `unite` (PlutoF DOI-pinned) |

## Field conventions

- `qc.primers_fwd` / `qc.primers_rev` are **empty strings in every preset** —
  the canonical primer sequences are a per-run input confirmed at intake SP2
  against your lab protocol; presets deliberately do not hard-code them.
- The `readbased_idtaxa` / `consensus` blocks inherit the battle-tested 16S
  values (`idtaxa_threshold: 60`, `cluster_min_identity: 0.95`,
  `qc.min_length_trimmed` floor, `decontam_threshold: 0.1`); override
  per-marker where the preset says so.
- `ref_db.key` names are the retrieval keys of the **biodb-fetch** dependency
  skill (see `reference-db/SKILL.md` §0.6 for the full delegation contract and
  manifest.tsv handling).
- Markers whose taxonomy is GBIF-publishable at species level (12S fish,
  COI) carry `geocurate: true` (mirrors nf-edna's presets); 16S/18S do not.

## Adding a new marker

Copy an existing preset as `defaults/<marker>.json`, set the length window +
kingdoms + reference `ref_db.key`, and leave primers empty. Intake picks it
up automatically — no sub-skill code changes needed. This is how the
6-marker panel (16S-full, 18S-full, 18S-V9/Euka02, 12S-MiFish, COI) was
supported from v0.5.0.