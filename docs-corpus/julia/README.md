# julia — docs-corpus index

Julia ≥1.12 runtime for the decontam scripts (`bin/decontam.jl`, `bin/decontam_by_taxon.jl`). Packages are declared in the sibling `Project.toml` (ArgParse, CSV, DataFrames, FASTX, HypothesisTests, Statistics) and instantiated on env activation via the `instantiate-julia-deps` pixi task.

- cli-reference.md (primary, `julia --help` capture)
