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
"""

import sys


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
            out.write(f"{acc}\t{full_lineage}\n")

    empty_frac = (n_empty / n_total) if n_total else 0.0
    print(f"[build_tax_lookup] wrote {n_total} rows to {out_path} "
          f"({n_empty} empty lineages, {empty_frac:.1%})", file=sys.stderr)
    if empty_frac > 0.05:
        print("[build_tax_lookup] WARNING: >5% of accessions have no lineage — "
              "ref2taxid.tsv and rankedlineage.dmp may be from mismatched taxdump "
              "snapshot dates. Re-download both from the same EPI2ME bundle listing.",
              file=sys.stderr)


if __name__ == "__main__":
    main()
