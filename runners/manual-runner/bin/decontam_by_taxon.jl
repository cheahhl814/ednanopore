#!/usr/bin/env julia

# decontam_by_taxon.jl
#
# Variant B taxon-based decontam. Mirrors decontam.jl's prevalence-based
# frequency method, but keyed on taxon labels (the Variant B equivalent
# of ASV sequences) since Variant B has no per-feature rep-seqs.
#
# Logic: for each unique lineage (concatenation of the 7 rank columns),
# compare its *mean relative abundance* in negative-control samples to
# its mean relative abundance in true samples. If the neg-control mean
# exceeds the true-sample mean by more than `--threshold`, flag the taxon
# as a likely contaminant and drop it from the cleaned abundance table.
#
# This is intentionally simpler than decontam.jl (which uses Fisher's
# exact test on a presence/absence contingency table). The rationale:
# Variant B's "feature" is a coarse lineage label, not a single ASV
# sequence — the per-taxon cell counts are much higher, so the Fisher
# exact test would always be significant. Mean-relative-abundance
# comparison is more interpretable for this coarser unit.
#
# CLI style intentionally mirrors nf-edna's bin/decontam.jl and
# bin/filter_table.jl for consistency (ArgParse, --input/output pairs,
# missingstring handling).

using ArgParse
using CSV
using DataFrames

RANK_COLUMNS = ["superkingdom", "phylum", "class", "order", "family", "genus", "species"]

function parse_commandline()
    s = ArgParseSettings(
        description = "Variant B taxon-based decontam. Flags taxa whose mean relative abundance in negative controls exceeds that in true samples.",
    )

    @add_arg_table! s begin
        "--taxon_table"
            help = "Path to the taxon abundance table TSV. First N columns are the 7 rank columns (superkingdom..species); remaining columns are sample counts."
            required = true
            arg_type = String
        "--metadata"
            help = "Path to the sample metadata TSV (sample IDs as first column)."
            required = true
            arg_type = String
        "--neg_control_column"
            help = "Column name in metadata indicating negative controls (e.g. 'is_negative')."
            required = true
            arg_type = String
        "--threshold"
            help = "Minimum ratio of neg-control mean relative abundance to true-sample mean relative abundance to flag a taxon as a contaminant (default 1.0 = 'more abundant in negs than in trues')."
            required = true
            arg_type = Float64
        "--output_cleaned_table"
            help = "Output path for the cleaned taxon abundance table."
            required = true
            arg_type = String
        "--output_contaminants_summary"
            help = "Output path for the contaminants summary TSV."
            required = true
            arg_type = String
    end

    return parse_args(s)
end

function main()
    args = parse_commandline()

    println("Loading taxon abundance table: ", args["taxon_table"])
    table_df = CSV.read(args["taxon_table"], DataFrame, delim='\t')
    # First 7 columns are rank labels; remaining columns are sample counts.
    if ncol(table_df) < length(RANK_COLUMNS) + 1
        error("Taxon table must have at least $(length(RANK_COLUMNS)+1) columns (7 rank columns + 1 sample).")
    end
    # Sanity check rank column names (case-insensitive match for robustness).
    rank_names = names(table_df)[1:length(RANK_COLUMNS)]
    for (i, expected) in enumerate(RANK_COLUMNS)
        if lowercase(rank_names[i]) != expected
            println("Warning: column $(i) is named '$(rank_names[i])', expected '$(expected)'. Proceeding anyway.")
        end
    end

    println("Loading metadata: ", args["metadata"])
    metadata_df = CSV.read(args["metadata"], DataFrame, delim='\t')
    sample_id_col = names(metadata_df)[1]

    sample_cols = names(table_df)[length(RANK_COLUMNS)+1:end]
    common_samples = intersect(sample_cols, metadata_df[!, sample_id_col])
    if isempty(common_samples)
        error("No common sample IDs found between taxon table and metadata.")
    end
    metadata_df = filter(row -> row[sample_id_col] in common_samples, metadata_df)
    table_df = table_df[!, vcat(rank_names, common_samples)]

    println("Identifying negative control samples using column: ", args["neg_control_column"])
    neg_col = args["neg_control_column"]
    if !hasproperty(metadata_df, Symbol(neg_col))
        error("Negative control column '$neg_col' not found in metadata.")
    end
    vals = lowercase.(string.(metadata_df[!, Symbol(neg_col)]))
    is_neg_control_mask = (vals .== "true") .| (vals .== "t") .| (vals .== "1")
    neg_control_samples = metadata_df[is_neg_control_mask, sample_id_col]
    true_samples = metadata_df[.!is_neg_control_mask, sample_id_col]

    if isempty(neg_control_samples)
        error("No negative control samples identified.")
    end
    if isempty(true_samples)
        error("No true (non-negative control) samples identified. Cannot perform decontamination.")
    end

    println("Performing taxon-based decontamination with threshold: ", args["threshold"])
    threshold = args["threshold"]

    # Convert sample columns to numeric.
    for col in common_samples
        table_df[!, col] = allowmissing(table_df[!, col])
        table_df[!, col] = coalesce.(table_df[!, col], 0)
        if !(eltype(table_df[!, col]) <: Number)
            table_df[!, col] = parse.(Float64, string.(table_df[!, col]))
        end
    end

    # Compute per-sample total read count (column sums) for relative abundance.
    sample_totals = Dict(col => sum(table_df[!, col]) for col in common_samples)

    # Build a stable lineage label per taxon (join non-empty ranks with ';').
    function lineage_label(row)
        parts = [string(row[r]) for r in rank_names if !ismissing(row[r]) && !isempty(string(row[r]))]
        return isempty(parts) ? "__unclassified__" : join(parts, ";")
    end

    contaminant_results = DataFrame(
        Lineage = String[],
        NegControl_MeanRelAbundance = Float64[],
        TrueSample_MeanRelAbundance = Float64[],
        Ratio = Float64[],
        Contaminant_Status = String[],
    )
    identified_contaminants = String[]

    for taxon_row in eachrow(table_df)
        label = lineage_label(taxon_row)
        # Mean relative abundance in neg controls.
        rel_neg = Float64[]
        for s in neg_control_samples
            tot = get(sample_totals, s, 0)
            tot > 0 || continue
            push!(rel_neg, taxon_row[s] / tot)
        end
        rel_true = Float64[]
        for s in true_samples
            tot = get(sample_totals, s, 0)
            tot > 0 || continue
            push!(rel_true, taxon_row[s] / tot)
        end
        mean_neg  = isempty(rel_neg)  ? 0.0 : sum(rel_neg)  / length(rel_neg)
        mean_true = isempty(rel_true) ? 0.0 : sum(rel_true) / length(rel_true)
        # Ratio: neg / true. Guard against div-by-zero: when true = 0 and
        # neg > 0, ratio is effectively infinite; cap at a large number so
        # the threshold comparison behaves intuitively.
        ratio = if mean_true > 0.0
            mean_neg / mean_true
        elseif mean_neg > 0.0
            Inf
        else
            0.0
        end
        is_contam = (ratio >= threshold) && (mean_neg > 0.0)
        status = is_contam ? "Yes" : "No"
        push!(contaminant_results, (label, mean_neg, mean_true, ratio, status))
        if is_contam
            push!(identified_contaminants, label)
        end
    end

    println("Identified $(length(identified_contaminants)) contaminant taxa.")

    # Cleaned table: drop taxa whose lineage label is in identified_contaminants.
    cleaned_df = filter(row -> !(lineage_label(row) in identified_contaminants), table_df)
    # Also drop neg-control columns from the cleaned output (matches decontam.jl).
    sample_cols_keep = setdiff(common_samples, neg_control_samples)
    cleaned_df = cleaned_df[!, vcat(rank_names, sample_cols_keep)]

    println("Writing cleaned taxon table to: ", args["output_cleaned_table"])
    CSV.write(args["output_cleaned_table"], cleaned_df, delim='\t', missingstring="NA")

    println("Writing contaminants summary to: ", args["output_contaminants_summary"])
    CSV.write(args["output_contaminants_summary"], contaminant_results, delim='\t', missingstring="NA")

    println("Decontam_by_taxon finished successfully.")
end

main()