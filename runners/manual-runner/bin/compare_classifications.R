#!/usr/bin/env Rscript

# compare_classifications.R — cross-method comparison for ednanopore (v0.6.0).
# Ported from edna-agent v1.3.3's compare_classifications.R and extended with a
# lineage-abundance mode, because ednanopore's three methods live in different
# ID spaces:
#
#   - readbased_minimap2 and readbased_idtaxa classify the SAME trimmed reads
#     (per-sample classification TSVs: SequenceID + 7 rank columns, identical
#     shape by contract — minimap2_lca.py mirrors idtaxa_rds.R) → per_read mode
#     works directly on shared SequenceIDs.
#   - consensus_idtaxa classifies polished cluster consensuses (ASV/cluster
#     IDs, a different namespace) → it can only be compared at the
#     abundance-table level (abundance mode).
#
# THE RULE (carried over from the Maaslin2/ANCOM-BC precedent): the canonical
# taxonomy always stays the PRIMARY method's output — outputs here are
# side-by-side diagnostics, NEVER merged or averaged into one table.
#
# Usage — two modes:
#
#   pixi run --manifest-path <skill>/pixi.toml -e classification Rscript \
#     bin/compare_classifications.R \
#     --mode per_read \
#     --classifications minimap2=<TAX>/<s>.minimap2_lca_classification.tsv \
#                       idtaxa=<TAX>/<s>.idtaxa_classification.tsv \
#     --output_pairwise <out>/per_read_pairwise.tsv \
#     --output_concordance <out>/per_read_concordance.tsv
#
#   pixi run --manifest-path <skill>/pixi.toml -e classification Rscript \
#     bin/compare_classifications.R --mode abundance \
#     --taxon_tables minimap2=lineage_table=<TAX>/decontam_taxon_abundance.tsv \
#                    idtaxa=lineage_table=<TAX>/decontam_taxon_abundance.tsv \
#                    consensus=rank_table:genus=<ASVDIR>/../taxonomy/agglomerated_data/genus_counts.tsv \
#     --output_pairwise <out>/abundance_pairwise.tsv \
#     --output_table <out>/abundance_side_by_side.tsv \
#     --ranks phylum,class,family,genus
#
# Requires: argparse, data.table (env classification).

suppressPackageStartupMessages({
    library(argparse)
    library(data.table)
})

RANKS <- c("superkingdom", "phylum", "class", "order", "family", "genus", "species")
RANK_PREFIX <- c("k__" = "superkingdom", "superkingdom__" = "superkingdom",
                 "p__" = "phylum", "c__" = "class", "o__" = "order",
                 "f__" = "family", "g__" = "genus", "s__" = "species")

parser <- ArgumentParser(description = 'Compare ednanopore classification methods (per-read agreement and/or lineage-abundance tables). Side by side, never merged.')
parser$add_argument('--mode', type = 'character', required = TRUE, choices = c('per_read', 'abundance'),
                    help = 'per_read: compare classification TSVs sharing SequenceIDs. abundance: compare lineage/sample tables.')
parser$add_argument('--classifications', nargs = '+', type = 'character', default = NULL,
                    help = 'per_read mode: name=path classification TSVs (SequenceID + rank columns).')
parser$add_argument('--taxon_tables', nargs = '+', type = 'character', default = NULL,
                    help = 'abundance mode: name=<kind>[:<rank>]=path where kind is lineage_table or rank_table.')
parser$add_argument('--ranks', nargs = '+', type = 'character', default = c('phylum', 'class', 'family', 'genus'),
                    help = 'abundance mode: ranks to compare (default phylum,class,family,genus).')
parser$add_argument('--output_pairwise', required = TRUE, help = 'Output pairwise-agreement TSV.')
parser$add_argument('--output_concordance', default = NULL, help = 'per_read mode: output per-SequenceID concordance TSV.')
parser$add_argument('--output_table', default = NULL, help = 'abundance mode: output side-by-side rel-abundance TSV.')
parser$add_argument('--divergence_fold', type = 'double', default = 2.0,
                    help = 'abundance mode: fold ratio above which a taxon is flagged (default 2, the interpret skill threshold).')
parser$add_argument('--flag_min_rel', type = 'double', default = 0.01,
                    help = 'abundance mode: a flagged taxon must reach this rel abundance in at least one method to count (default 0.01).')
parser$add_argument('--unassigned_labels', nargs = '+', default = c('NA', 'NA/NA', 'unassigned', 'unclassified', 'Ungrouped', ''),
                    help = 'Values treated as unassigned / no-rank across methods.')
args <- parser$parse_args()

is_unassigned <- function(x) x %in% c(args$unassigned_labels, NA) | is.na(x) | x == ""

if (args$mode == "per_read") {

    # ---------------- per_read mode (direct port of edna-agent v1.3.3) ---------
    if (is.null(args$classifications) || length(args$classifications) < 2) {
        stop("per_read mode needs >= 2 --classifications name=path entries.")
    }
    parse_one <- function(spec) {
        parts <- strsplit(spec, "=", fixed = TRUE)[[1]]
        if (length(parts) != 2) stop(paste0("--classifications entries must be name=path, got: ", spec))
        list(name = parts[[1]], path = parts[[2]])
    }
    specs <- lapply(args$classifications, parse_one)

    tables <- lapply(specs, function(sp) {
        dt <- fread(sp$path, sep = "\t", header = TRUE, data.table = FALSE, stringsAsFactors = FALSE, na.strings = NULL)
        if (!"SequenceID" %in% names(dt)) stop(paste0(sp$path, ": missing SequenceID column."))
        for (c in setdiff(names(dt), "SequenceID")) dt[[c]] <- as.character(dt[[c]])
        dt
    })
    names(tables) <- vapply(specs, `[[`, "", "name")
    rank_cols <- Reduce(intersect, lapply(tables, names))
    rank_cols <- setdiff(rank_cols, "SequenceID")
    if (length(rank_cols) == 0) stop("The classification files share no rank columns.")
    ids_all <- Reduce(intersect, lapply(tables, function(dt) dt$SequenceID))
    message(paste("Comparing", length(tables), "methods over", length(ids_all),
                  "shared SequenceIDs at ranks:", paste(rank_cols, collapse = ",")))
    if (length(ids_all) == 0) stop("No common SequenceIDs — are the files from the same query set (same sample, same trimmed reads)?")

    # --- Pairwise rank agreement ---
    pairs <- combn(names(tables), 2, simplify = FALSE)
    rows <- list()
    for (p in pairs) {
        ta <- match(ids_all, tables[[p[1]]]$SequenceID)
        tb <- match(ids_all, tables[[p[2]]]$SequenceID)
        a <- tables[[p[1]]][ta, match(rank_cols, names(tables[[p[1]]])), drop = FALSE]
        b <- tables[[p[2]]][tb, match(rank_cols, names(tables[[p[2]]])), drop = FALSE]
        for (rc in rank_cols) {
            va <- a[[rc]]; vb <- b[[rc]]
            both_assigned <- !is_unassigned(va) & !is_unassigned(vb)
            agree <- both_assigned & va == vb
            one_assigned <- xor(!is_unassigned(va), !is_unassigned(vb))
            rows[[length(rows) + 1L]] <- data.frame(
                method_1 = p[1], method_2 = p[2], rank = rc,
                n_shared = length(ids_all),
                n_both_assigned = sum(both_assigned),
                n_agree = sum(agree),
                agreement_pct_of_both = if (sum(both_assigned) > 0) round(100 * sum(agree) / sum(both_assigned), 1) else NA,
                n_one_assigned = sum(one_assigned),
                n_disagree = sum(both_assigned & !agree),
                stringsAsFactors = FALSE)
        }
    }
    agreement_df <- rbindlist(rows, use.names = TRUE)
    fwrite(agreement_df, file = args$output_pairwise, sep = "\t", quote = FALSE)

    # --- Per-SequenceID concordance profile ---
    if (!is.null(args$output_concordance)) {
        col_of <- function(nm, rc) as.character(tables[[nm]][match(ids_all, tables[[nm]]$SequenceID), rc])
        con_rows <- list()
        for (rc in rank_cols) {
            mvals <- do.call(cbind, lapply(names(tables), function(nm) col_of(nm, rc)))  # ids x methods
            unn <- matrix(is_unassigned(as.vector(mvals)), nrow = nrow(mvals))          # explicit dims (apply-transpose trap)
            n_assigned <- rowSums(unn == FALSE)
            concur <- rep(NA_real_, length(ids_all))
            for (i in which(n_assigned >= 2)) {
                v <- mvals[i, ][!unn[i, ]]
                concur[i] <- as.integer(length(unique(v)) == 1)
            }
            sel <- n_assigned >= 2 & !is.na(concur)
            if (any(sel)) con_rows[[length(con_rows) + 1L]] <- data.frame(
                SequenceID = ids_all, rank = rc,
                n_methods_assigned = as.integer(n_assigned),
                concordant = concur, stringsAsFactors = FALSE)[sel, , drop = FALSE]
        }
        concordance_df <- if (length(con_rows)) rbindlist(con_rows, use.names = TRUE) else
            data.frame(SequenceID = character(), rank = character(),
                       n_methods_assigned = integer(), concordant = integer())
        fwrite(concordance_df, file = args$output_concordance, sep = "\t", quote = FALSE)
    }

    # --- console summary ---
    for (rc in rank_cols) {
        m <- agreement_df[agreement_df$rank == rc, , drop = FALSE]
        for (i in seq_len(nrow(m))) {
            message(sprintf("%s vs %s @ %s: both-assigned %d/%d, agree %s%%, one-sided %d, disagree %d",
                            m$method_1[i], m$method_2[i], rc, m$n_both_assigned[i], m$n_shared[i],
                            ifelse(is.na(m$agreement_pct_of_both[i]), "NA", m$agreement_pct_of_both[i]),
                            m$n_one_assigned[i], m$n_disagree[i]))
        }
        if (!is.null(args$output_concordance) && nrow(concordance_df)) {
            sel <- concordance_df[concordance_df$rank == rc, , drop = FALSE]
            if (nrow(sel) > 0) message(sprintf("concordant multi-method assignments @ %s: %d/%d (%s%%)",
                                               rc, sum(sel$concordant), nrow(sel), round(100 * mean(sel$concordant), 1)))
        }
    }

} else {

    # ---------------- abundance mode -------------------------------------------
    if (is.null(args$taxon_tables) || length(args$taxon_tables) < 2) {
        stop("abundance mode needs >= 2 --taxon_tables name=kind[:rank]=path entries.")
    }
    parse_spec <- function(spec) {
        # name=kind[:rank]=path — only kind 'rank_table' carries :<rank>
        neq <- gregexpr("=", spec, fixed = TRUE)[[1]]
        if (length(neq) < 2 || neq[1] == -1) stop(paste0("--taxon_tables entries must be name=kind[:rank]=path, got: ", spec))
        sep2 <- neq[length(neq)]
        path <- substring(spec, sep2 + 1)
        head <- substr(spec, 1, sep2 - 1)
        sep1 <- regexpr("=", head, fixed = TRUE)
        name <- substr(head, 1, sep1 - 1)
        kindfield <- substr(head, sep1 + 1, nchar(head))
        kind_parts <- strsplit(kindfield, ":", fixed = TRUE)[[1]]
        if (length(kind_parts) == 1) {
            list(name = name, kind = kind_parts[1], rank = NA_character_, path = path)
        } else if (length(kind_parts) == 2) {
            list(name = name, kind = kind_parts[1], rank = kind_parts[2], path = path)
        } else stop(paste0("--taxon_tables entries must be name=kind[:rank]=path, got: ", spec))
    }
    specs <- lapply(args$taxon_tables, parse_spec)

    strip_rank_prefix <- function(x) {
        # strip "p__", "superkingdom: " style prefixes
        x <- sub("^[a-z]+__", "", x)
        x <- sub("^[A-Za-z]+:[[:space:]]*", "", x)
        trimws(x)
    }

    # method -> list of rank -> taxon -> total count
    build_rank_counts <- function(sp) {
        dt <- fread(sp$path, sep = "\t", header = TRUE, data.table = FALSE, check.names = FALSE, fill = TRUE)
        if (nrow(dt) == 0) stop(paste0(sp$path, ": table has 0 data rows."))
        first_col <- names(dt)[1]
        sample_cols <- names(dt)[-1]
        if (length(sample_cols) == 0) stop(paste0(sp$path, ": no sample columns."))
        cnt <- as.matrix(dt[, sample_cols, drop = FALSE])
        mode(cnt) <- "numeric"
        if (sp$kind == "lineage_table") {
            lin <- as.character(dt[[first_col]])
            tax_map <- setNames(vector("list", length(RANKS)), RANKS)
            for (r in RANKS) tax_map[[r]] <- new.env(hash = TRUE)
            for (i in seq_along(lin)) {
                parts <- strsplit(lin[i], ";", fixed = TRUE)[[1]]
                parts <- trimws(parts); parts <- strip_rank_prefix(parts)
                parts <- parts[nzchar(parts) & !is_unassigned(parts)]
                if (length(parts) == 0) next
                # positional mapping into RANKS (first element = superkingdom)
                for (j in seq_along(parts)) {
                    if (j > length(RANKS)) break
                    tx <- parts[j]
                    ev <- tax_map[[RANKS[j]]]
                    ev[[tx]] <- if (is.null(ev[[tx]])) {
                        as.numeric(cnt[i, , drop = FALSE])
                    } else { ev[[tx]] + cnt[i, ] }
                }
            }
            lapply(tax_map, function(ev) as.list(ev))
        } else if (sp$kind == "rank_table") {
            if (is.na(sp$rank) || !sp$rank %in% RANKS) {
                stop(paste0("rank_table spec needs a valid rank (got: ", sp$rank, "). Valid: ", paste(RANKS, collapse = ",")))
            }
            tx <- strip_rank_prefix(as.character(dt[[first_col]]))
            tx <- tx[nzchar(tx) & !is_unassigned(tx)]
            agg <- do.call(rbind, lapply(split(seq_along(tx), tx), function(idx) colSums(cnt[idx, , drop = FALSE])))
            agg <- as.matrix(agg)
            if (ncol(agg) != length(sample_cols)) agg <- matrix(agg, nrow = nrow(agg), ncol = length(sample_cols))
            l_k <- list()
            for (i in seq_len(nrow(agg))) l_k[[rownames(agg)[i]]] <- agg[i, ]
            setNames(list(l_k), sp$rank)
        } else stop(paste0("Unknown kind: ", sp$kind, " (use lineage_table or rank_table:<rank>)"))
    }

    methods <- lapply(specs, build_rank_counts)
    names(methods) <- vapply(specs, `[[`, "", "name")
    m_names <- names(methods)
    ranks_to_cmp <- intersect(args$ranks, unique(unlist(lapply(methods, names))))
    if (length(ranks_to_cmp) == 0) stop("No common ranks to compare across --taxon_tables.")

    pair_rows <- list(); side_rows <- list()
    for (p in combn(m_names, 2, simplify = FALSE)) {
        for (rk in ranks_to_cmp) {
            a <- methods[[p[1]]][[rk]]; b <- methods[[p[2]]][[rk]]
            if (is.null(a) || is.null(b)) next
            # each store maps taxon -> per-sample count vector; totals per taxon,
            # then relative abundance within each method's own total (methods
            # classify different unit counts — reads vs polished ASVs — so
            # normalizing to each method's own sum is the meaningful comparison)
            a_tot <- sapply(names(a), function(t) sum(a[[t]]))
            b_tot <- sapply(names(b), function(t) sum(b[[t]]))
            a_rel <- if (sum(a_tot) > 0) a_tot / sum(a_tot) else a_tot
            b_rel <- if (sum(b_tot) > 0) b_tot / sum(b_tot) else b_tot
            all_tx <- union(names(a), names(b))
            a_v <- vapply(all_tx, function(t) if (t %in% names(a_rel)) a_rel[[t]] else 0, 0)
            b_v <- vapply(all_tx, function(t) if (t %in% names(b_rel)) b_rel[[t]] else 0, 0)
            both <- a_v > 0 & b_v > 0
            inter <- sum(both); union_n <- sum(a_v > 0 | b_v > 0)
            jacc <- if (union_n > 0) round(inter / union_n, 3) else NA
            ratio <- ifelse(b_v > 0, a_v / b_v, Inf)
            flagged <- (a_v >= args$flag_min_rel | b_v >= args$flag_min_rel) & pmin(ratio, 1 / ratio) < (1 / args$divergence_fold)
            pair_rows[[length(pair_rows) + 1L]] <- data.frame(
                method_1 = p[1], method_2 = p[2], rank = rk,
                n_taxa_method_1 = length(a), n_taxa_method_2 = length(b),
                n_shared = inter, n_union = union_n, jaccard = jacc,
                median_fold_ratio_both = if (inter > 0) round(stats::median(ratio[both]), 2) else NA,
                correlation_spearman = if (inter > 1) round(stats::cor(a_v[both], b_v[both], method = "spearman"), 3) else NA,
                n_divergent_gt2x = sum(flagged),
                stringsAsFactors = FALSE)
            if (!is.null(args$output_table)) {
                ord <- order(pmax(a_v, b_v), decreasing = TRUE)
                top <- ord[seq_len(min(length(all_tx), 30))]
                if (length(top) > 0) side_rows[[length(side_rows) + 1L]] <- data.frame(
                    rank = rk, taxon = all_tx[top],
                    rel_abund_method_1 = round(a_v[top], 6),
                    rel_abund_method_2 = round(b_v[top], 6),
                    method_1 = p[1], method_2 = p[2],
                    fold_ratio = ifelse(is.finite(ratio[top]), round(ratio[top], 2), "inf"),
                    flagged_gt2x = flagged[top], stringsAsFactors = FALSE)
            }
        }
    }
    pairwise_df <- rbindlist(pair_rows, use.names = TRUE)
    fwrite(pairwise_df, file = args$output_pairwise, sep = "\t", quote = FALSE)
    if (!is.null(args$output_table) && length(side_rows)) {
        fwrite(rbindlist(side_rows, use.names = TRUE), file = args$output_table, sep = "\t", quote = FALSE)
    }
    for (i in seq_len(nrow(pairwise_df))) {
        message(sprintf("%s vs %s @ %s: shared %d/%d/%d taxa (J=%.2f), median fold %.2fx, spearman %s, flagged >%sx: %d",
                        pairwise_df$method_1[i], pairwise_df$method_2[i], pairwise_df$rank[i],
                        pairwise_df$n_shared[i], pairwise_df$n_taxa_method_1[i], pairwise_df$n_taxa_method_2[i],
                        ifelse(is.na(pairwise_df$jaccard[i]), 0, pairwise_df$jaccard[i]),
                        ifelse(is.na(pairwise_df$median_fold_ratio_both[i]), 0, pairwise_df$median_fold_ratio_both[i]),
                        ifelse(is.na(pairwise_df$correlation_spearman[i]), "NA", pairwise_df$correlation_spearman[i]),
                        args$divergence_fold, pairwise_df$n_divergent_gt2x[i]))
    }
}

message("Cross-method comparison complete — canonical (primary) method outputs untouched; cite these files as side-by-side evidence only. Never merge methods into one taxonomy table.")
