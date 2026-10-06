# Catalog — non-16S markers (18S / 12S / COI / ITS) — v0.5.0

> Companion to `SKILL.md` §1–3 (16S). Curation here; **download execution is
> delegated to biodb-fetch** (see `SKILL.md` §0.6): retrieval keys, md5,
> manifest.tsv contract, license gating (`midori2`/`bold` refuse without
> `--i-accept-license`), Google-Drive-via-gdown. After each fetch, resolve the
> content-addressed store path from the manifest rows, then do local building
> (MMI, tax_lookup, IdTaxa training chaining) in this skill.

## Marker → source → retrieval routing

| Marker | Canonical source | biodb-fetch key + command | Size | License | Local build step |
| --- | --- | --- | --- | --- | --- |
| 18S (full + V9) | SILVA SSU 138.2 (18S subset of the same release) | `silva` (or `url` for a pinned SILVA 18S FASTA) | ~100–300 MB | SILVA dual-license | `minimap2 -d` MMI (`-x map-ont`) + tax TSV |
| 18S (full + V9) | PR2 (protist-focused; broader euk per-branch) | `pr2` | ~100 MB | CC-BY | idem |
| 18S (IdTaxa) | DECIPHER pre-trained SILVA SSU r138.2 — **the stock model covers BOTH 16S and 18S** | `decipher --drive-id 1w3wdSCpSihntWkbP_zvXz7r3s-tNB8DV` (same file as §3) | 299 MB RDX3 (XZ) | SILVA dual-license | place in `$ASSETS_DIR/16s_idtaxa/` (shared) and point `idtaxa_model` at it |
| 12S | MitoHelper / MitoFish reference set (Zenodo, v42 Nov2025) | `mitohelper --doi-id 17602902 --file-url <record-file-url>` | ~100s MB | open | MMI + tax TSV |
| COI | MIDORI2 (LINC or LONG), mature mitochondrial curations | `midori2 --i-accept-license` | ~100s MB | **CC-BY-NC** — gated | MMI + tax TSV |
| COI | BOLD REST API, per-taxon COI pulls (targeted studies) | `bold --taxon <TAXON>` | per-taxon | BOLD terms | MMI + tax TSV; IdTaxa opt-in needs custom training |
| ITS | UNITE v10.2+ (PlutoF, DOI 10.15156/BIO/2483911) | `unite --version 10.2 --taxon_group fungi --type static --file-url <pinned-url>` | ~300 MB | CC-BY-SH terms | MMI + tax TSV |
| any | DECIPHER custom IdTaxa training (12S/COI/ITS — no stock model) | fetch reference FASTA via the keys above, then chain to **`nf-edna/idtaxa-training`** | — | inherits fetched source | trained `.rds` in `$ASSETS_DIR/<marker>_idtaxa/` |

## Classifier-mode defaults per marker (from the marker presets)

- **16S / 18S**: three-method default set applies (minimap2-LCA + IdTaxa on
  stock SILVA SSU + consensus). 18S uses the same pre-trained IdTaxa model —
  do NOT retrain for 18S.
- **12S / COI / ITS**: default classifier is **minimap2-LCA** against the
  fetched reference; IdTaxa is opt-in only behind a custom-trained model.
  The consensus method's `classifier` field in the marker presets reflects
  this (`minimap2`).

## License gates (script level, executed by biodb-fetch)

`midori2` (CC-BY-NC) and `bold` (data terms) refuse to download without
`--i-accept-license` — the preflight SP5 license check here just surfaces
the same note earlier. CC-BY / open entries (UNITE, PR2, MitoHelper, SILVA)
auto-proceed.

## EPI2ME/wf-16s note

The `ncbi_16s_18s` ONT bundle (§1/§2) actually covers 18S too (its name says
so) — for a fast first-look 18S run the same EPI2ME ref2taxid/taxdump join
trick applies. It is a small DB though; for production 18S prefer SILVA/PR2.