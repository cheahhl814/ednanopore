#!/usr/bin/env python3
"""nf-edna-nanopore test fixtures (v0.3.0).

Writes tiny deterministic input fixtures + MANIFEST.tsv into <outdir>.
Consumed by battle-test check #12 (data fixtures + execution canary).

Rules (battle-test contract): Python stdlib only, fixed seed, gzip written
with mtime=0 and no embedded filename, sha256 taken over DECOMPRESSED bytes.
Two runs into two directories must produce byte-identical files.

Usage: python3 make_fixtures.py <outdir>
"""

from __future__ import annotations

import gzip
import hashlib
import io
import random
import sys
from pathlib import Path

SEED = 20261005
GENERATED_BY = f"make_fixtures.py seed={SEED}"

# Rendered from params.json at build time.
TOOLS = ["chopper", "cutadapt", "nanoplot", "minimap2", "kraken2", "seqtk", "medaka", "yacrd", "biom-format", "samtools", "mafft", "fasttree", "r-base", "julia", "python"]
DECLARED_FORMATS = ["fastq"]

# ponytail: hand-kept tool→format map; unknown tools fall back to all formats.
# Add a tool here (or declare params.json: input_formats) when it's missing.
TOOL_FORMATS = {
    "seqkit": {"fasta", "fastq"}, "fastp": {"fastq"}, "fastqc": {"fastq"},
    "trimmomatic": {"fastq"}, "cutadapt": {"fastq"}, "multiqc": {"fastq"},
    "bwa": {"fasta", "fastq"}, "bwa-mem2": {"fasta", "fastq"},
    "bowtie2": {"fasta", "fastq"}, "hisat2": {"fasta", "fastq"},
    "minimap2": {"fasta", "fastq"}, "samtools": {"fasta"},
    "spades": {"fastq"}, "megahit": {"fastq"}, "flye": {"fastq"},
    "kraken2": {"fastq"}, "salmon": {"fasta", "fastq"},
    "stringtie": {"gff"}, "gffcompare": {"gff"}, "gffread": {"gff", "fasta"},
    "agat": {"gff"}, "bedtools": {"gff", "fasta"}, "prokka": {"fasta"},
    "bakta": {"fasta"}, "barrnap": {"fasta"}, "blast": {"fasta"},
    "diamond": {"fasta"}, "mafft": {"fasta"}, "muscle": {"fasta"},
    "iqtree": {"fasta"}, "raxml-ng": {"fasta"}, "quast": {"fasta"},
    "checkm2": {"fasta"}, "abricate": {"fasta"}, "amrfinderplus": {"fasta"},
}
ALL_FORMATS = ("fasta", "fastq", "gff")


def wanted_formats() -> list[str]:
    fmts = set(DECLARED_FORMATS)
    for tool in TOOLS:
        fmts |= TOOL_FORMATS.get(tool, set())
    fmts &= set(ALL_FORMATS)
    return sorted(fmts) if fmts else list(ALL_FORMATS)


def reference() -> list[tuple[str, str]]:
    rng = random.Random(f"{SEED}:ref")  # shared by fasta + fastq so reads map back
    return [(name, "".join(rng.choice("ACGT") for _ in range(n)))
            for name, n in (("seq1", 300), ("seq2", 180))]


def fasta(rng: random.Random) -> bytes:
    return "".join(f">{n} fixture\n{s}\n" for n, s in reference()).encode()


def fastq(rng: random.Random) -> bytes:
    ref = reference()  # reads sampled from the FASTA fixture
    out = io.StringIO()
    for i in range(100):
        name, seq = ref[i % len(ref)]
        start = rng.randrange(0, len(seq) - 50)
        read = seq[start:start + 50]
        qual = "".join(chr(33 + rng.randint(25, 40)) for _ in read)
        out.write(f"@read{i + 1} {name}:{start + 1}\n{read}\n+\n{qual}\n")
    return out.getvalue().encode()


def gff(rng: random.Random) -> bytes:
    rows = [
        ("seq1", "fixture", "gene", 21, 260, ".", "+", ".", "ID=gene1;Name=fix1"),
        ("seq1", "fixture", "mRNA", 21, 260, ".", "+", ".", "ID=mrna1;Parent=gene1"),
        ("seq1", "fixture", "exon", 21, 260, ".", "+", ".", "ID=exon1;Parent=mrna1"),
    ]
    body = "".join("\t".join(map(str, r)) + "\n" for r in rows)
    return ("##gff-version 3\n##sequence-region seq1 1 300\n" + body).encode()


# format -> (filename, builder, gzip?)
FIXTURES = {
    "fasta": ("ref.fasta", fasta, False),
    "fastq": ("reads.fastq.gz", fastq, True),
    "gff": ("annot.gff3", gff, False),
}


def write(path: Path, data: bytes, gz: bool) -> None:
    if not gz:
        path.write_bytes(data)
        return
    buf = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", fileobj=buf, mtime=0) as fh:
        fh.write(data)
    path.write_bytes(buf.getvalue())


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    outdir = Path(argv[1])
    outdir.mkdir(parents=True, exist_ok=True)
    rows = ["file\tformat\tsha256\tgenerated-by"]
    for fmt in wanted_formats():
        fname, build, gz = FIXTURES[fmt]
        data = build(random.Random(f"{SEED}:{fmt}"))  # per-format stream: adding a format never shifts others
        write(outdir / fname, data, gz)
        rows.append(f"{fname}\t{fmt}\t{hashlib.sha256(data).hexdigest()}\t{GENERATED_BY}")
        print(f"OK: {fname} ({fmt}, {len(data)} bytes decompressed)")
    (outdir / "MANIFEST.tsv").write_text("\n".join(rows) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))