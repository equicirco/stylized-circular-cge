"""
StylizedCircularCGE defines the account sets, model code, experiment utilities,
and result analytics for stylized circular-economy CGE experiments built with
the JCGE framework.
"""
module StylizedCircularCGE

using Ipopt
using JCGECore
using JCGERuntime
using JuMP

const RuntimeExperiments = JCGERuntime.Experiments

export FACTORS, MATERIALS, ROUTES, EOL_USES, GOODS, INSTITUTIONS
export PolicyWedges, zero_policy, single_wedge, with_wedge
export ProductProfile, default_product_profile, profile_parameters, profile_benchmark
export profile_experiment, product_profile_grid, product_parameter_grid
export ExperimentSpec, with_parameter, parameter_grid, run_experiment, run_grid
export policy_grid, parameter_policy_grid
export experiment_execution_kwargs
export accounts, default_parameters, synthetic_sam, sam_balance, synthetic_benchmark
export model, baseline, fiscal_model, fiscal_baseline, decentralized_model, decentralized_baseline
export scenario, solve
export indicators, benchmark_residuals, result_row, result_rows
export closed_economy_residuals
export closed_economy_failures, assert_closed_economy_results
export compare_to_reference, compare_to_group_reference
export classify_regime, regime_counts, classify_mechanism, mechanism_counts
export summarize_comparison, best_material_savers
export frontier_rows, material_saving_frontier
export compare_frontiers, sensitivity_screen
export summary_row, write_rows_csv, write_experiment_bundle
export datadir

include("single_country/core.jl")
include("single_country/model.jl")
include("single_country/scenarios.jl")
include("single_country/results.jl")
include("single_country/analytics.jl")
include("single_country/io.jl")

include("two_country/model.jl")

end
