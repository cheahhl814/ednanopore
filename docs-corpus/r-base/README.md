# r-base — docs-corpus index

R 4.5.x runtime for IdTaxa (DECIPHER), diversity (vegan/ape/iNEXT-style), association and community-typing R scripts.

- cli-reference.md (primary, `Rscript --help` / `R --help` capture on this machine)
- Key library usage (IdTaxa): `bioconductor-decipher` in the `classification` env — the IdTaxa training/classification workflow used by `reference-db/` and `bin/idtaxa_rds.R`. Flag-level ground truth belongs to DECIPHER itself, not r-base; consult the DECIPHER vignette `learnTaxonomy` when tuning.
