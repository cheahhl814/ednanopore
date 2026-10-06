#!/usr/bin/env python3
"""Join an NCBI ref2taxid TSV against new_taxdump's rankedlineage.dmp to
produce the tax_lookup TSV that bin/minimap2_lca.py expects:
accession<TAB>full_lineage, where full_lineage is ';'-separated in
RANK_COLUMNS order (superkingdom;phylum;class;order;family;genus;species) —
see runners/nextflow-runner/bin/minimap2_lca.py:51.

Usage:
    build_tax_lookup.py ref2taxid.tsv rankedlineage.dmp tax_lookup.tsv

ref2taxid.tsv: accession<TAB>taxid (e.g. EPI2ME's ref2taxid.targloci.tsv).
rankedlineage.dmp: from NCBI's new_taxdump (pipe-delimited, trailing '\t|').

Diagnostic note (see nf-edna-nanopore's BUG_FIX_REPORT.md Bug 30): a prior,
architecturally different tax_lookup builder for this pipeline's RefSeq-16S
dataset silently lost phylum..family lineage for ~50-70% of reads, because
it walked names.dmp/nodes.dmp parent pointers by hand and those two files
can be out of sync for recently-added taxa (new species, or newly-renamed
higher ranks like 2021+ SeqCode bacterial phyla). This script instead joins
against NCBI's own precomputed rankedlineage.dmp, which is far less likely
to have that specific gap — but was not itself verified against a live
taxdump snapshot before this note was added (network access was withdrawn
mid-verification). What *is* fixed here is a blind spot in this script's own
diagnostics: the original empty_frac check only ever counted a row as bad
when the ENTIRE joined lineage string was empty, which cannot detect Bug
30's actual failure shape — a row with phylum/class blank but
family/genus/species still populated joins into a non-empty string and was
passed through silently. The per-rank completeness check below closes that
blind spot regardless of which failure mode (this join's own, or a future
one) causes it.
"""

import sys

RANK_COLS = ["superkingdom", "phylum", "class", "order", "family", "genus", "species"]


def load_rankedlineage(path):
    """taxid -> 'superkingdom;phylum;class;order;family;genus;species'."""
    lineage = {}
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            parts = line.rstrip("\n").rstrip("\t|").split("\t|\t")
            if len(parts) < 9:
                continue
            taxid, _name, species, genus, family, order, klass, phylum, superkingdom = parts[:9]
            species_full = f"{genus} {species}".strip() if species and genus else ""
            lineage[taxid] = ";".join(
                [superkingdom, phylum, klass, order, family, genus, species_full]
            )
    return lineage


def main():
    if len(sys.argv) != 4:
        sys.exit(f"Usage: {sys.argv[0]} ref2taxid.tsv rankedlineage.dmp tax_lookup.tsv")
    ref2taxid_path, rankedlineage_path, out_path = sys.argv[1:4]

    lineage = load_rankedlineage(rankedlineage_path)

    n_total = 0
    n_empty = 0
    # Per-rank non-blank counts, keyed by RANK_COLS index — catches partial
    # (not just total) lineage loss, e.g. phylum blank while genus/species
    # are still populated (see module docstring, Bug 30).
    n_rank_filled = [0] * len(RANK_COLS)
    with open(out_path, "w") as out, open(ref2taxid_path) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            acc, taxid = line.split("\t")
            full_lineage = lineage.get(taxid, "")
            n_total += 1
            if not full_lineage:
                n_empty += 1
            else:
                for i, val in enumerate(full_lineage.split(";")):
                    if val:
                        n_rank_filled[i] += 1
            out.write(f"{acc}\t{full_lineage}\n")

    empty_frac = (n_empty / n_total) if n_total else 0.0
    print(f"[build_tax_lookup] wrote {n_total} rows to {out_path} "
          f"({n_empty} empty lineages, {empty_frac:.1%})", file=sys.stderr)
    if empty_frac > 0.05:
        print("[build_tax_lookup] WARNING: >5% of accessions have no lineage — "
              "ref2taxid.tsv and rankedlineage.dmp may be from mismatched taxdump "
              "snapshot dates. Re-download both from the same EPI2ME bundle listing.",
              file=sys.stderr)

    print("[build_tax_lookup] per-rank resolution (fraction of all rows with that "
          "rank populated, including rows counted above as fully empty):", file=sys.stderr)
    for rank, filled in zip(RANK_COLS, n_rank_filled):
        frac = (filled / n_total) if n_total else 0.0
        print(f"  {rank:<13s} {filled:>8,} / {n_total:,} = {frac:.1%}", file=sys.stderr)
        if rank == "phylum" and frac < 0.95:
            print(f"[build_tax_lookup] WARNING: only {frac:.1%} of rows have phylum "
                  "resolved (<95%). This is the exact failure shape of Bug 30 "
                  "(names.dmp/nodes.dmp desync in a hand-walked lookup) — if it "
                  "recurs here, rankedlineage.dmp itself may have gaps for "
                  "recently-added taxa; check a sample of blank-phylum rows "
                  "against NCBI's live taxonomy browser before trusting this "
                  "output.", file=sys.stderr)


if __name__ == "__main__":
    main()
