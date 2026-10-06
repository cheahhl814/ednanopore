# Catalog Section: NCBI RefSeq Targeted Loci 16S → MMI + tax_lookup TSV

> **For:** `ednanopore` (16S Nanopore eDNA, `bin/minimap2_lca.py`).
> **Default classifier.** `modules/classify_consensus.nf` and `modules/classify_reads.nf` both invoke `bin/minimap2_lca.py --ref_mmi <mmi> --tax_lookup <tsv>`. The `tax_lookup` TSV is `accession<TAB>full_lineage` where `full_lineage` is `;`-separated in `RANK_COLUMNS = superkingdom,phylum,class,order,family,genus,species` order (see `bin/minimap2_lca.py:51`).
> **Mirrors the approach of** Oxford Nanopore's [`wf-16s`](https://github.com/epi2me-labs/wf-16s) default `ncbi_16s_18s` DB ([docs/07_pipeline_overview.md](https://github.com/epi2me-labs/wf-16s/blob/master/docs/07_pipeline_overview.md) — references [NCBI RefSeq Targeted Loci](https://www.ncbi.nlm.nih.gov/refseq/targetedloci/)).

## 1.X NCBI RefSeq Targeted Loci — 16S (Bacteria + Archaea)

NCBI RefSeq Targeted Loci is the canonical 16S rRNA reference for bacterial + archaeal type-material sequences. Underlying source: [NCBI RefSeq Targeted Loci project](https://www.ncbi.nlm.nih.gov/refseq/targetedloci/), BioProject [PRJNA33175](https://ncbi.nlm.nih.gov/bioproject/?term=33175) (Bacteria) + [PRJNA33317](https://ncbi.nlm.nih.gov/bioproject/?term=33317) (Archaea). License: **public domain** (US Government work, per [NCBI data usage policies](https://www.ncbi.nlm.nih.gov/home/about/policies/)).

### Reference FASTA (raw, no auth)

| Domain | File | URL | Size (last mod 2026-08-18) |
|---|---|---|---|
| Bacteria | `bacteria.16SrRNA.fna.gz` | `https://ftp.ncbi.nlm.nih.gov/refseq/TargetedLoci/Bacteria/bacteria.16SrRNA.fna.gz` | 7.7 MB |
| Archaea  | `archaea.16SrRNA.fna.gz`  | `https://ftp.ncbi.nlm.nih.gov/refseq/TargetedLoci/Archaea/archaea.16SrRNA.fna.gz` | 294 KB |

Listing: `https://ftp.ncbi.nlm.nih.gov/refseq/TargetedLoci/{Bacteria,Archaea}/`. Cadence: ~monthly (last updated 2026-08-18).

### EPI2ME pre-built bundle (matches wf-16s exactly)

Oxford Nanopore re-bundles the NCBI FASTA + accession→taxid + taxdump on S3 (no auth, no registration — used by wf-16s):

```bash
REF_FASTA="https://ont-open-data.s3-eu-west-1.amazonaws.com/workflow-databases/wf-metagenomics-dbs/ncbi_16s_18s/ncbi_targeted_loci_16s_18s.fna"  # 16S + 18S combined, public
REF2TAXID="https://ont-open-data.s3-eu-west-1.amazonaws.com/workflow-databases/wf-metagenomics-dbs/ncbi_16s_18s/ref2taxid.targloci.tsv"  # accession<TAB>NCBI_taxid
TAX_DUMP="https://ont-open-data.s3-eu-west-1.amazonaws.com/workflow-databases/wf-metagenomics-dbs/ncbi_16s_18s/new_taxdump_2025-01-01.zip"  # contains rankedlineage.dmp
```

URLs from wf-metagenomics [`nextflow.config`](https://github.com/epi2me-labs/wf-metagenomics/blob/master/nextflow.config) `database_sets.ncbi_16s_18s` block. `ref2taxid.targloci.tsv` is accession<TAB>NCBI_taxid (numeric); expand to lineage via `taxdump/rankedlineage.dmp` (step c below).

### Building the MMI + tax_lookup pair

```bash
# (a) download FASTA (Bacteria + Archaea, raw path)
curl -L -o 16S_refseq.fna.gz \
  https://ftp.ncbi.nlm.nih.gov/refseq/TargetedLoci/Bacteria/bacteria.16SrRNA.fna.gz
curl -L -o 16S_refseq_archaea.fna.gz \
  https://ftp.ncbi.nlm.nih.gov/refseq/TargetedLoci/Archaea/archaea.16SrRNA.fna.gz
zcat 16S_refseq.fna.gz 16S_refseq_archaea.fna.gz > 16S_refseq.fna

# (b) build minimap2 index
minimap2 -d 16S_refseq.mmi -x map-ont 16S_refseq.fna

# (c) build tax_lookup TSV (accession<TAB>full_lineage)
#     Easiest: use the EPI2ME bundle's ref2taxid.targloci.tsv + new_taxdump rankedlineage.dmp,
#     since the raw NCBI FTP only ships FASTA (no companion accession<->taxid map).
curl -L -o ref2taxid.tsv https://ont-open-data.s3-eu-west-1.amazonaws.com/workflow-databases/wf-metagenomics-dbs/ncbi_16s_18s/ref2taxid.targloci.tsv
curl -L -o new_taxdump_2025-01-01.zip https://ont-open-data.s3-eu-west-1.amazonaws.com/workflow-databases/wf-metagenomics-dbs/ncbi_16s_18s/new_taxdump_2025-01-01.zip
unzip -o new_taxdump_2025-01-01.zip -d taxdump/

python3 - <<'PY'
# join ref2taxid + rankedlineage.dmp -> accession<TAB>superkingdom;phylum;...;species
# rankedlineage.dmp columns (pipe-tab delimited, trailing \t|):
#   taxid | taxname | species | genus | family | order | class | phylum | superkingdom | subspecies | no_rank ... | ...
rankedlineage = {}
with open("taxdump/rankedlineage.dmp") as f:
    for line in f:
        parts = line.rstrip("\n").rstrip("\t|").split("\t|\t")
        if len(parts) < 9: continue
        taxid, _, sp, g, fm, o, c, ph, sk = parts[:9]
        sp_full = f"{g} {sp}".strip() if sp and g else ""
        rankedlineage[taxid] = ";".join([sk, ph, c, o, fm, g, sp_full])
with open("tax_lookup.tsv", "w") as out, open("ref2taxid.tsv") as f:
    for line in f:
        acc, taxid = line.rstrip("\n").split("\t")
        out.write(f"{acc}\t{rankedlineage.get(taxid, '')}\n")
PY
```

### `datasets` CLI — not a clean fit

NCBI's [`datasets`](https://www.ncbi.nlm.nih.gov/datasets/docs/v2/reference-docs/command-line/datasets/) CLI is geared at genomes/genes/orthologs/viruses; it does not query the Targeted Loci sub-project ([docs](https://www.ncbi.nlm.nih.gov/refseq/targetedloci/)). For 16S, **FTP** (above) or the **EPI2ME pre-built bundle** are the operative routes — eutils/efetch would require per-accession lookups for ~20 k records and is much slower. Recommendation: use the FTP + EPI2ME ref2taxid + taxdump trio shown above.

## 1.X+1 GTDB — alternative (bacterial 16S only)

[GTDB](https://gtdb.ecogenomic.org/downloads) (e.g. r226, April 2025) is a free, more taxonomically-current alternative for **bacterial 16S only** (no archaea). Canonical files: `https://data.gtdb.ecogenomic.org/releases/release226/226.0/bac120_taxonomy_r226.tsv` (97.8 MB; `accession<TAB>gtdb_taxonomy`) paired with bacterial SSU FASTAs in `genomic_files_all/`. License: free for academic/non-commercial use ([GTDB license](https://gtdb.ecogenomic.org/about)). Annual cadence (r226 = April 2025; r232 = April 2026). Useful when NCBI-taxonomy feels out of date for bacteria; not a drop-in for `ncbi_16s_18s` (no archaea).
