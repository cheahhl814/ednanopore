import sys, gzip, collections, itertools

paf_file, reads_file, out_tsv, out_dir, cov_frac, min_id, sample_id = sys.argv[1:8]
cov_frac = float(cov_frac); min_id = float(min_id)

# Load read lengths from the (gzipped) fastq of clean reads
lengths = {}
opener = gzip.open if reads_file.endswith('.gz') else open
with opener(reads_file, 'rt') as f:
    for i, line in enumerate(f):
        if i % 4 == 0:
            hdr = line.strip().lstrip('@').split()[0]
        if i % 4 == 1:
            lengths[hdr] = len(line.strip())

# Build overlap graph from PAF: cross-read alignments only (skip the
# trivial diagonal self-hit each read has against itself).
adj = collections.defaultdict(set)
with open(paf_file) as f:
    for line in f:
        p = line.rstrip('\n').split('\t')
        if len(p) < 12: continue
        q, qlen, qs, qe = p[0], int(p[1]), int(p[2]), int(p[3])
        t, tlen, ts, te = p[5], int(p[6]), int(p[7]), int(p[8])
        if q == t: continue  # skip trivial self-alignment
        if qlen == 0 or tlen == 0: continue
        aln_len = max(qe - qs, te - ts)
        frac_q  = aln_len / qlen
        frac_t  = aln_len / tlen
        if frac_q < cov_frac or frac_t < cov_frac: continue
        # minimap2's default PAF output never emits an nm:i: tag (that
        # requires -c/--cs); it emits dv:f: (approximate per-base
        # divergence) instead. identity = 1 - divergence.
        dv = None
        for field in p[12:]:
            if field.startswith('dv:f:'):
                try:
                    dv = float(field[5:])
                except ValueError:
                    dv = None
                break
        if dv is None:
            ident = 1.0 - (min(qlen, tlen) * 0.15 / aln_len)  # conservative ONT fallback
        else:
            ident = 1.0 - dv
        if ident < min_id: continue
        adj[q].add(t)
        if q != t:
            adj[t].add(q)

# Union-find connected components
parent = {}
def find(x):
    parent.setdefault(x, x)
    while parent[x] != x:
        parent[x] = parent[parent[x]]
        x = parent[x]
    return x
def union(a, b):
    ra, rb = find(a), find(b)
    if ra != rb: parent[ra] = rb

nodes = set(lengths) | set(adj)
for n in nodes: parent.setdefault(n, n)
for a, bs in adj.items():
    for b in bs: union(a, b)

comp = collections.defaultdict(list)
for n in nodes:
    comp[find(n)].append(n)

import os
os.makedirs(out_dir, exist_ok=True)
with open(out_tsv, 'w') as f:
    for cid, (_, members) in enumerate(
        sorted(comp.items(), key=lambda kv: -len(kv[1]))
    ):
        if len(members) < 2: continue  # singletons go to singleton bin
        # Cluster IDs must be globally unique across samples: merge_tables.R
        # joins per-sample ASV tables by this exact ID string, and every
        # sample's cluster_graph run independently restarts numbering at 0.
        # Without the sample prefix, "cluster_0" from different samples
        # silently collide into one fabricated ASV during the merge.
        cluster_id = f"{sample_id}_cluster_{cid}"
        f.write(f"{cluster_id}\t{len(members)}\t{','.join(sorted(members))}\n")
        # per-cluster reads file for medaka
        with open(f"{out_dir}/{cluster_id}.txt", 'w') as cf:
            cf.write('\n'.join(sorted(members)) + '\n')
