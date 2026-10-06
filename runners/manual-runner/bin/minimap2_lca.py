#!/usr/bin/env python3

# minimap2_lca.py
#
# Maps a query FASTA (polished consensus seqs or raw ONT reads) to a
# pre-built 16S reference MMI via minimap2 (ONT preset `map-ont`), parses
# the PAF/SAM output, applies a lowest-common-ancestor (LCA) resolution
# across multi-mapping hits passing --min-percent-identity and
# --min-ref-coverage thresholds, and writes:
#
#   --output_classification  : TSV shaped exactly like nf-edna's
#                              idtaxa_classification.tsv (SequenceID +
#                              rank columns: superkingdom, phylum, class,
#                              order, family, genus, species) plus a
#                              trailing `confidence` column populated
#                              with the best-hit %identity (simple proxy;
#                              see --confidence-basis below).
#   --output_confidence     : TSV shaped exactly like nf-edna's
#                              idtaxa_confidence.tsv (SequenceID +
#                              numeric rank columns). This is the file
#                              `filter_idtaxa_by_confidence.jl` reads,
#                              so the existing nf-edna confidence filter
#                              is reused unmodified — just interpreting
#                              percent-identity instead of bootstrap
#                              confidence.
#
# LCA strategy: per query, collect all reference accessions passing the
# thresholds. Resolve each accession to its full lineage string via the
# taxonomy TSV. The LCA is the longest prefix shared by all lineages.
# This matches the wf-16s default behaviour at
# https://github.com/epi2me-labs/wf-16s and the conventional
# kmer/LCA pattern used by Kraken2 / MEGAN LCA mode.
#
# Design intent: deliberately simple and auditable. We are NOT trying to
# recreate MEGAN6's full LCA algorithm (which uses score-binning and
# covers many edge cases). We are trying to give ednanopore the
# same downstream contract (taxonomy_table + confidence TSV) so the rest
# of nf-edna's stack (agglomerate_data.R, filter_idtaxa_by_confidence.jl,
# diversity, association) keeps working without modification.

import argparse
import csv
import gzip
import os
import subprocess
import sys
from collections import defaultdict

# Rank column order MUST match idtaxa_rds.R exactly so the downstream
# filter_idtaxa_by_confidence.jl can read both files by column name.
RANK_COLUMNS = ["superkingdom", "phylum", "class", "order", "family", "genus", "species"]

# Confidence column shown in the classification TSV; the value placed
# here is the best-hit percent identity (a stand-in for IdTaxa's
# bootstrap confidence). See --confidence-basis.
CONFIDENCE_COLUMN = "confidence"


def parse_args():
    p = argparse.ArgumentParser(
        description="minimap2 alignment + simple LCA classification against a 16S reference.",
    )
    p.add_argument("--query_fasta", required=True,
                   help="Query sequences (polished consensus OR raw reads) in FASTA format.")
    p.add_argument("--ref_mmi", required=True,
                   help="Pre-built minimap2 reference index (.mmi). Typically NCBI RefSeq Targeted Loci 16S.")
    p.add_argument("--tax_lookup", required=True,
                   help="Taxonomy TSV: accession<TAB>full_lineage. Full lineage is ';' separated ranks.")
    p.add_argument("--min_percent_identity", type=float, default=0.97,
                   help="Minimum percent identity (0-1) to keep a hit. Default 0.97 (wf-16s default).")
    p.add_argument("--min_ref_coverage", type=float, default=0.80,
                   help="Minimum reference coverage fraction (0-1) to keep a hit. Default 0.80.")
    p.add_argument("--top_n_hits", type=int, default=10,
                   help="Per-query, keep up to this many hits after thresholding (LCA input bound).")
    p.add_argument("--minimap2_extra_args", default="",
                   help="Extra args to pass to minimap2 verbatim (advanced).")
    p.add_argument("--confidence_basis", default="best_pct_identity",
                   choices=["best_pct_identity", "mean_pct_identity"],
                   help="How to populate the `confidence` column. Default 'best_pct_identity'.")
    p.add_argument("--output_classification", required=True,
                   help="Output TSV with SequenceID + ranks + confidence.")
    p.add_argument("--output_confidence", required=True,
                   help="Output TSV with SequenceID + rank columns (numeric) for filter_idtaxa_by_confidence.jl.")
    return p.parse_args()


def iter_query_ids(query_path):
    """Collect all query sequence IDs from a FASTA or FASTQ file, gzip or
    plain. Variant A feeds this polished consensus FASTA (plain); Variant B
    feeds it raw QC'd reads as gzip-compressed FASTQ — both must work so
    unmapped queries still get a dense "unclassified" row in the output.
    """
    opener = gzip.open if query_path.endswith(".gz") else open
    ids = set()
    with opener(query_path, "rt") as fh:
        first_char = None
        for line in fh:
            if first_char is None:
                stripped = line.strip()
                if not stripped:
                    continue
                first_char = stripped[0]
                if first_char not in (">", "@"):
                    sys.exit(f"Unrecognized query format in {query_path}: "
                             f"first non-blank line starts with {first_char!r}, expected '>' (FASTA) or '@' (FASTQ)")
            if first_char == ">" and line.startswith(">"):
                ids.add(line[1:].split()[0].strip())
        if first_char == "@":
            # FASTQ has no reliable single-character record delimiter to
            # scan line-by-line (quality lines can start with '@'), so
            # re-read in fixed 4-line records instead.
            ids = set()
            with opener(query_path, "rt") as fh2:
                for i, line in enumerate(fh2):
                    if i % 4 == 0:
                        if not line.startswith("@"):
                            sys.exit(f"Malformed FASTQ record at line {i+1} of {query_path}")
                        ids.add(line[1:].split()[0].strip())
    return ids


def run_minimap2(query_fasta, ref_mmi, extra_args):
    """Run minimap2 with ONT preset `map-ont`, emit PAF to stdout."""
    # Use -a for SAM (easier to parse the optional fields). SAM also lets
    # us read CIGAR for ref-coverage which PAF exposes less directly.
    cmd = ["minimap2", "-ax", "map-ont", "--secondary=no"]
    # WF-16s uses `--secondary=no` to suppress secondary alignments so
    # we get one canonical hit per query; that's a cleaner LCA input.
    # (User can override via --minimap2_extra_args.)
    if extra_args.strip():
        cmd.extend(extra_args.split())
    cmd.extend([ref_mmi, query_fasta])
    proc = subprocess.run(cmd, capture_output=True, text=True, check=True)
    return proc.stdout


def parse_sam(sam_text):
    """Yield dicts of fields we need: qname, flag, refname, pct_identity, ref_coverage."""
    header_seen = False
    for line in sam_text.splitlines():
        if not line:
            continue
        if line.startswith("@"):
            header_seen = True
            continue
        if not header_seen:
            continue
        cols = line.split("\t")
        if len(cols) < 11:
            continue
        flag = int(cols[1])
        refname = cols[2]
        if refname == "*" or (flag & 4):
            # unmapped
            continue
        qname = cols[0]
        try:
            mapq = int(cols[4])
        except ValueError:
            mapq = 0
        # Parse NM (edit distance) and alignment block from CIGAR + SEQ for pct identity.
        # Use NM tag if present, else fall back to CIGAR M/=/X count.
        nm = None
        for opt in cols[11:]:
            if opt.startswith("NM:i:"):
                try:
                    nm = int(opt[5:])
                except ValueError:
                    nm = None
                break
        # Compute alignment length from CIGAR (sum of M/=/X/I/D)
        cigar = cols[5]
        aln_len = 0
        query_aln_len = 0   # query bases consumed by the alignment (M/=/X/I)
        query_total_len = 0 # full query length incl. soft-clips (M/=/X/I/S)
        num = ""
        for ch in cigar:
            if ch.isdigit():
                num += ch
            else:
                try:
                    n = int(num) if num else 0
                except ValueError:
                    n = 0
                num = ""
                if ch in ("M", "=", "X", "I", "D"):
                    aln_len += n
                if ch in ("M", "=", "X", "I"):
                    query_aln_len += n
                    query_total_len += n
                elif ch == "S":
                    query_total_len += n
        if nm is None:
            # Fallback: use CIGAR M/=/X as proxy for mismatches+ matches;
            # without NM we cannot compute exact identity, so use mapq as a
            # rough proxy. Conservative — mark identity as unknown.
            nm = max(0, aln_len - mapq)
        if aln_len == 0:
            continue
        # pct identity = 1 - (edit distance / alignment length)
        pct_identity = max(0.0, 1.0 - (nm / aln_len))
        # coverage = fraction of the QUERY (read/amplicon) that aligned.
        # We deliberately measure query coverage, not reference coverage:
        # queries here are short V3-V4 amplicons (~450-750bp) mapped
        # against full-length 16S reference genes (~1400-1500bp), so a
        # correct amplicon alignment only ever covers ~30% of the
        # reference — reference-coverage would reject every real hit.
        if query_total_len <= 0:
            ref_coverage = 1.0  # best-effort if CIGAR unavailable
        else:
            ref_coverage = query_aln_len / query_total_len
        yield {
            "qname": qname,
            "refname": refname,
            "pct_identity": pct_identity,
            "ref_coverage": ref_coverage,
            "aln_len": aln_len,
            "mapq": mapq,
            "nm": nm,
        }


def load_taxonomy(tax_lookup_path):
    """Return dict {acc: list_of_taxa_strings_per_rank}.
    Each lineage is split by ';' into ranks matching RANK_COLUMNS order.
    Extra ranks beyond RANK_COLUMNS are tolerated; missing ranks become ''.
    Lineages may also use 'rank: taxon' format (e.g. SILVA headers); we
    normalise to plain taxon names when possible.
    """
    tax = {}
    with open(tax_lookup_path, newline="") as fh:
        reader = csv.reader(fh, delimiter="\t")
        for row in reader:
            if len(row) < 2:
                continue
            acc = row[0].strip()
            lineage_str = ";".join(row[1:]).strip()
            # Split and strip "rank: " prefixes if present. Keep blank
            # leading fields (e.g. ";;;;;Genus;species") so each element
            # stays aligned to its RANK_COLUMNS position — dropping them
            # would left-shift genus/species into superkingdom/phylum.
            parts = [p.strip() for p in lineage_str.split(";")]
            cleaned = []
            for p in parts:
                # If the segment is like "domain: Bacteria" keep just the taxon.
                # Be conservative: only strip if it looks like a known rank prefix.
                if ":" in p and p.split(":", 1)[0].lower() in (
                    "root", "rootrank", "domain", "superkingdom", "kingdom",
                    "phylum", "class", "order", "family", "genus", "species",
                ):
                    cleaned.append(p.split(":", 1)[1].strip())
                else:
                    cleaned.append(p)
            tax[acc] = cleaned
    return tax


def lineage_to_rank_dict(lineage_list):
    """Map a list of taxon names (in canonical order) to a dict of RANK_COLUMNS."""
    out = {r: "" for r in RANK_COLUMNS}
    # We treat the first element as superkingdom if the lineage string
    # starts at that rank (NCBI/SILVA convention). If lineage has fewer
    # ranks than RANK_COLUMNS, pad with ''. If more, ignore trailing
    # (e.g. strain-level).
    for i, taxon in enumerate(lineage_list):
        if i >= len(RANK_COLUMNS):
            break
        out[RANK_COLUMNS[i]] = taxon
    return out


def lca(lineages):
    """Compute lowest common ancestor across a set of lineages (lists of taxa).

    Returns the longest common prefix. If the lineages diverge at the
    very first rank, the LCA is empty (all empty strings).
    """
    if not lineages:
        return []
    if len(lineages) == 1:
        return list(lineages[0])
    # Index-wise compare: check rank i consistently across all lineages
    # (not lineages[i][i], which walked diagonally across different hits).
    lca_list = []
    for i in range(min(len(l) for l in lineages)):
        first = lineages[0][i]
        if all(i < len(l) and l[i] == first for l in lineages):
            lca_list.append(first)
        else:
            break
    return lca_list


def write_classification_tsv(path, rows):
    """rows: list of dicts {SequenceID, ranks..., confidence}."""
    header = ["SequenceID"] + RANK_COLUMNS + [CONFIDENCE_COLUMN]
    with open(path, "w", newline="") as fh:
        w = csv.writer(fh, delimiter="\t")
        w.writerow(header)
        for r in rows:
            w.writerow([r["SequenceID"]] + [r.get(rc, "") for rc in RANK_COLUMNS] +
                       [f"{r.get('confidence', 0.0):.4f}"])


def write_confidence_tsv(path, rows):
    """rows: list of dicts {SequenceID, ranks..., confidence}.

    Shape mirrors idtaxa_confidence.tsv: numeric values per rank column,
    so filter_idtaxa_by_confidence.jl can read it unchanged. We put the
    best-hit pct identity in each rank column for ranks that were
    assigned at the LCA, and NA for ranks that weren't reached.

    IMPORTANT: filter_idtaxa_by_confidence.jl's --threshold is a
    PERCENTAGE (0-100, default 60 — see nf-edna's idtaxa_threshold).
    `confidence` here is a 0.0-1.0 fraction (pct identity), so it must be
    scaled by 100 before writing, or every row fails "confidence <
    threshold" and gets wiped to NA regardless of match quality.
    """
    header = ["SequenceID"] + RANK_COLUMNS
    with open(path, "w", newline="") as fh:
        w = csv.writer(fh, delimiter="\t")
        w.writerow(header)
        for r in rows:
            row_out = [r["SequenceID"]]
            for rc in RANK_COLUMNS:
                # If the rank was assigned (non-empty) put the confidence
                # (pct identity, scaled to 0-100), else 'NA'. This mimics
                # IdTaxa's per-rank confidence: NA means the rank wasn't
                # reached.
                val = r.get(rc, "")
                if val and val != "":
                    row_out.append(f"{r.get('confidence', 0.0) * 100:.4f}")
                else:
                    row_out.append("NA")
            w.writerow(row_out)


def main():
    args = parse_args()

    if not os.path.exists(args.query_fasta):
        sys.exit(f"Query FASTA not found: {args.query_fasta}")
    if not os.path.exists(args.ref_mmi):
        sys.exit(f"Reference MMI not found: {args.ref_mmi}")
    if not os.path.exists(args.tax_lookup):
        sys.exit(f"Taxonomy lookup not found: {args.tax_lookup}")

    print(f"[minimap2_lca] Mapping {args.query_fasta} -> {args.ref_mmi}", file=sys.stderr)
    sam_text = run_minimap2(args.query_fasta, args.ref_mmi, args.minimap2_extra_args)
    print(f"[minimap2_lca] Loading taxonomy from {args.tax_lookup}", file=sys.stderr)
    taxonomy = load_taxonomy(args.tax_lookup)

    # Group hits per query, threshold, sort by identity desc, take top-N.
    per_query = defaultdict(list)
    for hit in parse_sam(sam_text):
        if hit["pct_identity"] < args.min_percent_identity:
            continue
        if hit["ref_coverage"] < args.min_ref_coverage:
            continue
        per_query[hit["qname"]].append(hit)

    rows = []
    # Collect all query IDs (even unmapped) so output is dense.
    query_ids = iter_query_ids(args.query_fasta)
    for q in sorted(query_ids):
        hits = per_query.get(q, [])
        hits.sort(key=lambda h: (-h["pct_identity"], -h["ref_coverage"]))
        hits = hits[: args.top_n_hits]
        if not hits:
            # Unclassified — emit row with NA ranks.
            row = {"SequenceID": q, "confidence": 0.0}
            for rc in RANK_COLUMNS:
                row[rc] = ""
            rows.append(row)
            continue
        # Resolve each hit's accession to its lineage, run LCA.
        lineages = []
        for h in hits:
            acc = h["refname"]
            if acc in taxonomy:
                lineages.append(taxonomy[acc])
            else:
                # Reference not in lookup — skip from LCA but still keep hit info.
                continue
        if not lineages:
            row = {"SequenceID": q, "confidence": hits[0]["pct_identity"]}
            for rc in RANK_COLUMNS:
                row[rc] = ""
            rows.append(row)
            continue
        lca_lineage = lca(lineages)
        rank_dict = lineage_to_rank_dict(lca_lineage)
        # Confidence = best-hit identity (default) or mean.
        if args.confidence_basis == "best_pct_identity":
            conf = hits[0]["pct_identity"]
        else:
            conf = sum(h["pct_identity"] for h in hits) / len(hits)
        row = {"SequenceID": q, "confidence": conf}
        row.update(rank_dict)
        rows.append(row)

    # Filter rank rows for the confidence TSV — confidence is per-rank
    # only for ranks the LCA reached. (Implementation detail: the row
    # dict already encodes this via presence/absence of the rank string.)
    write_classification_tsv(args.output_classification, rows)
    write_confidence_tsv(args.output_confidence, rows)
    print(f"[minimap2_lca] Wrote {len(rows)} rows to {args.output_classification}", file=sys.stderr)
    print(f"[minimap2_lca] Wrote {len(rows)} rows to {args.output_confidence}", file=sys.stderr)


if __name__ == "__main__":
    main()