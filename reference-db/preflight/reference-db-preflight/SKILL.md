---
name: reference-db-preflight
description: Preflight validation for nf-edna-nanopore's reference-db sub-skill. Verifies (1) classifier mode confirmed (minimap2/kraken2/idtaxa), (2) disk space (≥ 2 GB, scaled to the chosen mode), (3) Internet connectivity to the canonical URL (HEAD request), (4) assets directory writable, (5) license accepted, (6) minimap2 available (minimap2 mode only) or DECIPHER + gdown available (idtaxa mode only — gdown is pip-only and not bundled; PEP-668 systems block a plain user install). Produces a GO / GO-WITH-WARNINGS / NO-GO verdict gate before any download or build command is invoked.
version: 0.3.0
updated: "2026-10-06"
triggers:
  - "reference-db preflight nanopore"
  - "validate 16S reference download"
  - "check disk for nanopore reference"
requires:
  - "curl (for HEAD requests)"
  - "Internet access to one of: ftp.ncbi.nlm.nih.gov, ont-open-data S3, genome-idx.s3.amazonaws.com, drive.google.com (idtaxa mode only)"
  - "minimap2 (for minimap2 mode's index-build check)"
  - "R ≥ 4.2 with DECIPHER (idtaxa mode only)"
  - "biodb-fetch sibling skill (idtaxa mode — the SILVA DECIPHER model is fetched via its `decipher` key; gdown is bundled in its env, so no venv workaround is needed)"
---

# Sub-Skill: reference-db-preflight (nf-edna-nanopore)

## Audience

1. **AI Coding Agents** — invoked by the parent `reference-db` orchestrator or directly. The agent must run all 6 stop points in order, write `preflight.md` + `preflight_evidence.json` + `preflight_verdict.txt`, and gate the run sub-skill on the verdict.
2. **Human Nanopore eDNA scientists** — read this document to understand what validation runs before a reference download/build starts.

## When to Use

Use this sub-skill **always** before invoking `run/reference-db-run`. Its verdict prevents downloading a Kraken2 DB the disk can't hold, or building a minimap2 index without `minimap2` installed.

**Do NOT use this sub-skill** for: downloading raw sequencing reads (use `read-qc-trimming`); the Illumina pipeline's reference (use `nf-edna/reference-db`).

## 0. Inputs / Outputs

### Inputs (gathered at invocation)

| Variable | Type | Required | Description |
| --- | --- | --- | --- |
| `classifier_mode` | enum | yes | `minimap2` (default) / `kraken2` / `idtaxa` |
| `reference_choice` | str | yes | Shorthand ID (e.g. `ncbi-targeted-loci-16s`, `16s-silva138-kraken2`, `ncbi-16s-18s-kraken2`, `silva-idtaxa`) |
| `assets_dir` | path | yes | Where the downloaded/built file(s) will be placed (typically `$HOME/data/nf-edna-nanopore/assets/`) |
| `build_required` | bool | no (auto-detected) | `true` for `minimap2` mode (FASTA → MMI build step) |

### Outputs

- `$RUN_DIR/preflight.md` — human-readable preflight report
- `$RUN_DIR/preflight_evidence.json` — machine-readable evidence (used by run sub-skill)
- `$RUN_DIR/preflight_verdict.txt` — single-word `GO` / `GO-WITH-WARNINGS` / `NO-GO`

## 0.5 Ask-User Stop Points

Each stop point follows the canonical **Evidence + Recommend + Options** pattern.

---

### SP1 — Classifier mode confirmed

> **Evidence**: I will check `classifier_mode ∈ {minimap2, kraken2, idtaxa}`, reading `pipeline_state.json.params.classifier` if present.
- ✅ PASS if: mode is one of the three supported
- ❌ FAIL if: mode is something else or unset with no `pipeline_state.json` to infer from

> **Recommend**: PASS → proceed to SP2. FAIL → ask the user, defaulting the recommendation to `minimap2` (the pipeline default).
>
> Options:
> - **(A) minimap2 — pipeline default (Recommended)**
> - (B) kraken2 — faster alt mode
> - (C) idtaxa — opt-in, Variant A (consensus) only
> - (D) Abort

**Auto-pick when**: `pipeline_state.json.params.classifier` is already set — use it without asking.

---

### SP2 — Disk space (scaled to mode)

> **Evidence**: I will `df -BG "$assets_dir"` and check `Avail` against the mode's requirement: `minimap2` ≥ 1 GB (FASTA + MMI, both small — NCBI Targeted Loci is tens of MB), `kraken2` ≥ 2 GB (largest catalog entry, SILVA-based, is ~300 MB, leave headroom), `idtaxa` ≥ 2 GB (SILVA .rdata is 299 MB).
- ✅ PASS if: sufficient free space for the chosen mode
- ⚠️ WARN if: within 500 MB of the threshold
- ❌ FAIL if: below the threshold

> **Recommend**: PASS → proceed to SP3. WARN → confirm. FAIL → free space or pick a different location.
>
> Options:
> - **(A) Sufficient space, proceed (Recommended)**
> - (B) I'll free up more disk — wait and re-run
> - (C) Use a different `assets_dir`
> - (D) Abort

**Auto-pick when**: space exceeds the threshold with ≥ 500 MB headroom — auto-pick (A).

---

### SP3 — Internet connectivity to canonical URL

> **Evidence**: I will `curl -s -o /dev/null -w "%{http_code}" -I "<URL>"` (HEAD request) against the catalog URL for the chosen mode — `ftp.ncbi.nlm.nih.gov` (minimap2), `genome-idx.s3.amazonaws.com` or `ont-open-data` S3 (kraken2), `drive.google.com` (idtaxa).
- ✅ PASS if: HTTP 200 or 302
- ⚠️ WARN if: HTTP 429 (rate-limited) — retry once with backoff
- ❌ FAIL if: timeout, no response, or HTTP 5xx

> **Recommend**: PASS → proceed to SP4. WARN → retry. FAIL → check network or pick an alternative source within the same catalog section (e.g. NCBI FTP vs. the EPI2ME S3 bundle for `minimap2` mode).
>
> Options:
> - **(A) URL is reachable, proceed (Recommended)**
> - (B) Retry (transient failure)
> - (C) Use an alternative source from the same catalog section
> - (D) Abort

**Auto-pick when**: HTTP 200 within 5 seconds — auto-pick (A).

---

### SP4 — Assets directory writable

> **Evidence**: I will `mkdir -p "$assets_dir/16s_$classifier_mode" && touch "$assets_dir/16s_$classifier_mode/.write_test"` and verify success.
- ✅ PASS if: directory created and writable
- ❌ FAIL if: cannot create or not writable

> **Recommend**: PASS → proceed to SP5. FAIL → ask for a writable path.
>
> Options:
> - **(A) Directory writable, proceed (Recommended)**
> - (B) I'll give you a different path
> - (C) Abort

**Auto-pick when**: directory writable — auto-pick (A).

---

### SP5 — License accepted

> **Evidence**: I will check the reference's license from the catalog: NCBI Targeted Loci = public domain; ONT open-data S3 bundles = public domain; Ben Langmead's 16S Greengenes/RDP indexes = free non-commercial; Ben Langmead's 16S SILVA index and the opt-in IdTaxa SILVA file = SILVA dual-license; GTDB = free academic/non-commercial.
- ✅ PASS if: license is public domain (NCBI / ONT bundles)
- ⚠️ WARN if: license is SILVA dual-license, free-non-commercial (Greengenes/RDP/GTDB) — surface the restriction
- ❌ FAIL if: user explicitly rejects the license

> **Recommend**: PASS → proceed to SP6. WARN → confirm. FAIL → pick a different source (e.g. switch from the SILVA-based Kraken2 index to the public-domain `ncbi_16s_18s` one).
>
> Options:
> - **(A) License is acceptable, proceed (Recommended for public-domain sources)**
> - (B) I accept the non-commercial / SILVA-license restriction — proceed
> - (C) Use a different source with a more permissive license
> - (D) Abort

**Auto-pick when**: license is public domain — auto-pick (A). For SILVA dual-license or non-commercial — surface the restriction and require explicit (B).

---

### SP6 — Mode-specific tool availability

> **Evidence**:
> - `minimap2` mode: `pixi run --manifest-path <skill-root>/pixi.toml -e cluster minimap2 --version` (the MMI build step needs `minimap2 -d`).
> - `kraken2` mode: no build step — extraction only (`tar -xzf`); this stop point auto-passes.
> - `idtaxa` mode: `pixi run --manifest-path <skill-root>/pixi.toml -e classification Rscript -e 'requireNamespace("DECIPHER", quietly=TRUE)'` **and** biodb-fetch deployed as a sibling skill (its pixi env ships gdown) (battle-tested 2026-08-19: `gdown` is a pip-only package, not bundled by pixi or the OS by default; on PEP-668-managed systems `pip install --user gdown` is blocked outright, so this check must run before SP2's download step, not after it fails).
- ✅ PASS if: the mode's required tool(s) are available
- ❌ FAIL if: missing

> **Recommend**: PASS → proceed to verdict. FAIL → install the missing tool. For `minimap2`/DECIPHER, install via the relevant `pixi.toml` (already declared — no new dependency needed). For `gdown` (idtaxa mode), create a throwaway venv (`python3 -m venv /tmp/gdown_env && /tmp/gdown_env/bin/pip install gdown`) since PEP 668 blocks a plain user install.
>
> Options:
> - **(A) Tool available, proceed (Recommended)**
> - (B) Install via pixi (`pixi install --manifest-path <env>/pixi.toml`), or via a venv for gdown
> - (C) Abort

**Auto-skip when**: `classifier_mode == "kraken2"` (no build/load step at preflight time).

**Auto-pick when**: tool check passes — auto-pick (A).

---

## 1. Verdict Gate

Same logic as `nf-edna/reference-db-preflight` §1 — count PASS/WARN/FAIL across the 6 stop points (SP6 counts as auto-pass when skipped) and write `GO` / `GO-WITH-WARNINGS` / `NO-GO` to `preflight_verdict.txt`.

**The run sub-skill will refuse to proceed unless `preflight_verdict.txt` contains `GO` or `GO-WITH-WARNINGS`.**

## 2. Troubleshooting — Signature library

| Signature in stderr / log | Likely cause | Suggested fix |
| --- | --- | --- |
| `curl: (6) Could not resolve host: ftp.ncbi.nlm.nih.gov` | No DNS / firewall / NCBI FTP outage | Retry, or switch to the EPI2ME S3 bundle (§1 catalog alternative) |
| `curl: (28) Connection timed out` on `ont-open-data.s3...` | S3 region routing hiccup | Retry with `--retry 3 --retry-delay 5`; both `s3-eu-west-1` and unregioned `s3.amazonaws.com` hostnames exist in the catalog — try the other |
| `minimap2: command not found` | Pixi env for `cluster` not yet resolved | `pixi install --manifest-path <skill-root>/pixi.toml` |
| `HTTP 403 Forbidden` on Google Drive (idtaxa mode) | Google Drive blocks bots | Use `gdown` (same fix as nf-edna's reference-db) |
| `tar: unexpected end of file` on a Kraken2 `.tgz` | Truncated download | Re-download with `curl -C -` to resume; verify size matches the catalog table |
| `pixi: r-decipher not found` (idtaxa mode) | pixi env for classification missing DECIPHER | `pixi add --manifest-path <skill-root>/pixi.toml -e classification bioconductor-decipher` (already declared — re-resolve the env) |

## 3. Related skills

- **`reference-db`** (parent) — invokes this sub-skill from SP0
- **`run/reference-db-run`** (sibling) — consumes this sub-skill's verdict
- **`nf-edna/reference-db-preflight`** — analogous preflight for the Illumina pipeline; template source for this file
- **`preflight/edna-nanopore-intake`** — chains here if a reference path is missing at intake

## Verification

- [ ] All 6 stop points resolved to PASS, WARN, or auto-skip (no unresolved FAIL)
- [ ] `preflight_verdict.txt` exists and contains exactly `GO` or `GO-WITH-WARNINGS`
- [ ] `preflight_evidence.json` exists with entries for the stop points that ran
- [ ] `preflight.md` was written and is human-readable

## Invariants

- **Never** invoke a download or `minimap2 -d` build command without first running this preflight and obtaining `GO` / `GO-WITH-WARNINGS`.
- **Never** modify a stop point's evidence-based thresholds without updating this SKILL.md and the run sub-skill's expectations.
- **Always** surface the license for the chosen source; require explicit acceptance for SILVA-dual-license or non-commercial-restricted files.
