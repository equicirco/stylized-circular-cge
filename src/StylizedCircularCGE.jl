"""
StylizedCircularCGE defines the account sets, model code, experiment utilities,
and result analytics for stylized circular-economy CGE experiments built with
the JCGE framework.
"""
module StylizedCircularCGE

using Ipopt
using JCGECalibrate
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
export CalibrationSet, load_calibration_set, default_calibration_set
export calibration_parameters, calibration_stock0, calibration_value
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
export distributional_activity_summary, distributional_factor_summary
export summary_row, write_rows_csv, write_experiment_bundle
export datadir
export TWO_COUNTRIES, TWO_COUNTRY_ACCOUNTS
export TWO_COUNTRY_PRODUCTION_ACTIVITIES, TWO_COUNTRY_FACTORS
export two_country_sam, two_country_sam_balance, aggregate_two_country_sam
export two_country_benchmark, two_country_fiscal_model, two_country_fiscal_baseline
export two_country_indicators, two_country_closed_economy_residuals
export two_country_benchmark_residuals
export two_country_experiment, two_country_parameter_grid, two_country_policy_grid
export two_country_parameter_policy_grid, run_two_country_experiment, run_two_country_grid
export two_country_result_row, two_country_result_rows
export two_country_closed_economy_failures, assert_two_country_closed_economy_results
export compare_two_country_to_reference, compare_two_country_to_group_reference
export classify_two_country_transmission, two_country_transmission_counts
export summarize_two_country_comparison, two_country_summary_row
export two_country_distributional_activity_summary, two_country_distributional_factor_summary
export write_two_country_experiment_bundle

include("single_country/core.jl")
include("two_country/core.jl")
include("common/calibration.jl")
include("common/ast.jl")
include("common/circular_policy.jl")
include("single_country/blocks.jl")
include("single_country/model.jl")
include("single_country/scenarios.jl")
include("single_country/results.jl")
include("single_country/analytics.jl")
include("single_country/io.jl")

include("two_country/blocks.jl")
include("two_country/model.jl")
include("two_country/scenarios.jl")
include("two_country/results.jl")
include("two_country/analytics.jl")
include("two_country/io.jl")

end
