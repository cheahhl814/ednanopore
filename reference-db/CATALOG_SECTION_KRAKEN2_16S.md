## Kraken2 — 16S rRNA pre-built databases

For `params.classifier: "kraken2"` mode in `modules/classify_consensus.nf` and `modules/classify_reads.nf`. A valid Kraken2 DB directory needs `hash.k2d`, `opts.k2d`, `taxo.k2d` (plus `database{50..1000}mers.kmer_distrib` for Bracken). All entries below are pre-built and ready as `kraken2 --db <dir>`.

### 1. Ben Langmead's Kraken2 + Bracken 16S RNA indexes

Host page: https://benlangmead.github.io/aws-indexes/k2 (section "Kraken2 + Bracken 16s RNA"). All four below share build date **2020-03-26** — this collection is frozen, not refreshed alongside the Standard/PlusPF cadence. License mirrors each source DB.

- **16S Greengenes 13.5** — 72 MB — `https://genome-idx.s3.amazonaws.com/kraken/16S_Greengenes13.5_20200326.tgz`
- **16S RDP 11.5** — 172 MB — `https://genome-idx.s3.amazonaws.com/kraken/16S_RDP11.5_20200326.tgz`
- **16S Silva 132** — 117 MB — `https://genome-idx.s3.amazonaws.com/kraken/16S_Silva132_20200326.tgz`
- **16S Silva 138** — 112 MB — `https://genome-idx.s3.amazonaws.com/kraken/16S_Silva138_20200326.tgz`

After extraction each archive yields a single subdirectory (`16S_SILVA138_k2db/`, etc.); point `params.kraken2_db` at that subdirectory. Built k=35, l=31, s=7; Bracken 50/75/100/150/200/250/300-mers included.

### 2. ONT wf-16s default (`--classifier kraken2`)

ONT's `wf-16s` (https://github.com/epi2me-labs/wf-16s) supports `--classifier kraken2`. Default `database_set = "ncbi_16s_18s"` (NCBI RefSeq Targeted Loci 16S + 18S SSU, taxonomy 2025-01-01). Source: `wf-16s/nextflow.config` line 53 + `database_sets` map lines 54-67.

- `ncbi_16s_18s` (default) — NCBI RefSeq Targeted Loci archaeal/bacterial/fungal 16S + 18S SSU — 8.6 MB — updated 2026-01-21 — `https://ont-open-data.s3.amazonaws.com/workflow-databases/wf-metagenomics-dbs/ncbi_16s_18s/ncbi_targeted_loci_kraken2.tar.gz`
- `ncbi_16s_18s_28s_ITS` — adds 28S LSU + ITS — larger — updated 2026-01-21 — `…/ncbi_16s_18s_28s_ITS/ncbi_16s_18s_28s_ITS_kraken2.tar.gz`
- `SILVA_138_1` — SILVA 138.1 SSU (Kraken2-built) — 297 MB — updated 2026-01-21 — `…/SILVA_138_1/kraken2.tar.gz`
- `Greengenes2_plus` — Greengenes2 2024.09 + GTDB r226 supplements — varies — `…/Greengenes2_plus/kraken2.tar.gz`

These extract to a **top-level** DB dir (no subdirectory wrap). The default ships `database1000mers.kmer_distrib` so Bracken `--read-length 1000` matches.

### 3. Recommended default + download

**Recommended**: `16S Silva 138` from Langmead's set — most current SILVA in any 16S-targeted pre-built index, 112 MB, k=35/l=31/s=7, Bracken 50–300-mers included. SILVA dual-license (free non-commercial; commercial requires SILVA license).

```bash
mkdir -p assets/kraken2_dbs && cd assets/kraken2_dbs
curl -L -o 16S_Silva138.tgz \
  https://genome-idx.s3.amazonaws.com/kraken/16S_Silva138_20200326.tgz
tar -xzf 16S_Silva138.tgz
# Resulting dir: assets/kraken2_dbs/16S_SILVA138_k2db/
# params.json: "kraken2_db": "assets/kraken2_dbs/16S_SILVA138_k2db"
```

Alternative (ONT wf-16s default, more recent taxonomy):

```bash
mkdir -p assets/kraken2_dbs/ncbi_16s_18s && cd assets/kraken2_dbs/ncbi_16s_18s
curl -L -o ncbi_targeted_loci_kraken2.tar.gz \
  https://ont-open-data.s3.amazonaws.com/workflow-databases/wf-metagenomics-dbs/ncbi_16s_18s/ncbi_targeted_loci_kraken2.tar.gz
tar -xzf ncbi_targeted_loci_kraken2.tar.gz
# Top-level DB (no subdir wrap). params.json:
# "kraken2_db": "assets/kraken2_dbs/ncbi_16s_18s"
```

### 4. Cadence + license

| | Langmead 16S set | wf-16s NCBI Targeted Loci |
|---|---|---|
| Last build | **2020-03-26** (frozen) | **2026-01-21** (rebuilt with wf-16s releases) |
| Refresh cadence | None | Tied to wf-16s releases |
| License | Mirrors source (SILVA dual-license; Greengenes/RDP free non-commercial) | NCBI public domain |
| Recommended v0.1.0 | `16S_Silva138_20200326.tgz` | `ncbi_16s_18s` (tax 2025-01-01) |

### 5. Custom-build fallback

For a more current reference than the Langmead 16S set, use `kraken2-build` + `bracken-build` (https://github.com/DerrickWood/kraken2/wiki/Manual#building-a-standard-kraken-2-database — out of scope here):

```bash
kraken2-build --download-library bacteria --download-library archaea \
              --db my_custom_16s --use-names --threads 8
kraken2-build --build --db my_custom_16s --threads 8
bracken-build -d my_custom_16s -t 8 -k 35 -l 150   # Bracken for read length 150
```

For NCBI Targeted Loci, pass the FASTA from https://www.ncbi.nlm.nih.gov/refseq/targetedloci/ as `--custom-fasta`. RAM- and disk-intensive (≥ 50 GB scratch, ≥ 32 GB RAM).
