using StylizedCircularCGE

output_dir = joinpath(@__DIR__, "..", "..", "results", "two_country", "generated")
mkpath(output_dir)
execution_kwargs = experiment_execution_kwargs()

grid_mode = get(ENV, "JCGE_REGION_GRID", "screen")

base_grid =
    if grid_mode == "tiny"
        (
            sigma_routes = [2.0],
            sigma_metal = [2.0],
            sigma_eol = [2.0],
            eta_service = [1.0],
            metal_quality = [0.85],
            metal_intensity_ref = [0.25],
            yield_ref = [4.0],
        )
    elseif grid_mode == "screen"
        (
            sigma_routes = [1.25, 2.0, 3.0],
            sigma_metal = [1.25, 3.0],
            sigma_eol = [0.5, 2.0, 4.0],
            eta_service = [0.5, 1.0, 1.5],
            metal_quality = [0.75, 0.95],
            metal_intensity_ref = [0.15, 0.35],
            yield_ref = [3.0, 5.0],
        )
    elseif grid_mode == "full"
        (
            sigma_routes = [1.25, 2.0, 3.0],
            sigma_metal = [1.25, 2.0, 3.0],
            sigma_eol = [0.5, 2.0, 4.0],
            eta_service = [0.5, 1.0, 1.5],
            metal_quality = [0.75, 0.85, 0.95],
            metal_intensity_ref = [0.15, 0.25, 0.35],
            yield_ref = [3.0, 4.0, 5.0],
        )
    else
        error("Unknown JCGE_REGION_GRID=$(grid_mode). Use tiny, screen, or full.")
    end

group_fields = collect(keys(base_grid))

tax_specs = two_country_parameter_policy_grid(;
    policy_kind = :material,
    policy_target = :VMTL,
    tau = [0.0, 0.10, 0.25, 0.50],
    prefix = "two-country-region-virgin-material-tax",
    base_grid...)

support_specs = two_country_parameter_policy_grid(;
    policy_kind = :route,
    policy_target = :REF,
    tau = [-0.50, -0.25, -0.10, 0.0],
    prefix = "two-country-region-refurbishment-support",
    base_grid...)

recycling_specs = two_country_parameter_policy_grid(;
    policy_kind = :eol,
    policy_target = :REC,
    tau = [-0.50, -0.25, -0.10, 0.0],
    prefix = "two-country-region-recycling-support",
    base_grid...)

tax_results = run_two_country_grid(tax_specs; execution_kwargs...)
support_results = run_two_country_grid(support_specs; execution_kwargs...)
recycling_results = run_two_country_grid(recycling_specs; execution_kwargs...)

const MARKET_TOL = 1.0e-5

function group_key(row, fields)
    return Tuple(getproperty(row, field) for field in fields)
end

function is_valid_result_row(row)
    return string(row.status) == "LOCALLY_SOLVED" &&
           row.closure === :two_country_fiscal &&
           row.max_abs_market_residual <= MARKET_TOL
end

function comparable_records(records, fields; reference_filter)
    valid_pairs = [
        (record = record, row = two_country_result_row(record))
        for record in records
        if is_valid_result_row(two_country_result_row(record))
    ]
    reference_keys = Set(group_key(pair.row, fields) for pair in valid_pairs if reference_filter(pair.row))
    return [pair.record for pair in valid_pairs if group_key(pair.row, fields) in reference_keys]
end

tax_reference_filter = row -> row.tau_material_vmtl == 0.0
support_reference_filter = row -> row.tau_route_ref == 0.0
recycling_reference_filter = row -> row.tau_eol_rec == 0.0

tax_comparable = comparable_records(tax_results, group_fields;
    reference_filter = tax_reference_filter)
support_comparable = comparable_records(support_results, group_fields;
    reference_filter = support_reference_filter)
recycling_comparable = comparable_records(recycling_results, group_fields;
    reference_filter = recycling_reference_filter)

tax_comparison = compare_two_country_to_group_reference(tax_comparable, group_fields;
    reference_filter = tax_reference_filter)
support_comparison = compare_two_country_to_group_reference(support_comparable, group_fields;
    reference_filter = support_reference_filter)
recycling_comparison = compare_two_country_to_group_reference(recycling_comparable, group_fields;
    reference_filter = recycling_reference_filter)

tax_frontier = material_saving_frontier(tax_comparison, :tau_material_vmtl;
    group_by = group_fields,
    allow_rebound = false,
    sense = :min)
support_frontier = frontier_rows(support_comparison;
    group_by = group_fields,
    select_by = :tau_route_ref,
    predicate = row -> row.tau_route_ref < 0.0 && row.material_saving && !row.rebound,
    sense = :absolute_min)
recycling_frontier = frontier_rows(recycling_comparison;
    group_by = group_fields,
    select_by = :tau_eol_rec,
    predicate = row -> row.tau_eol_rec < 0.0 && row.material_saving && !row.rebound,
    sense = :absolute_min)

function strategy_rows(rows, strategy::Symbol, policy_field::Symbol)
    return [
        merge((
                strategy = strategy,
                policy_field = policy_field,
                policy_value = getproperty(row, policy_field),
                policy_magnitude = abs(getproperty(row, policy_field)),
            ),
            row)
        for row in rows
    ]
end

function mean_field(rows, field::Symbol)
    isempty(rows) && return NaN
    return sum(Float64(getproperty(row, field)) for row in rows) / length(rows)
end

function mean_finite_field(rows, field::Symbol)
    values = [Float64(getproperty(row, field)) for row in rows
              if isfinite(Float64(getproperty(row, field)))]
    isempty(values) && return NaN
    return sum(values) / length(values)
end

function count_by(rows, field::Symbol)
    counts = Dict{Any,Int}()
    for row in rows
        key = getproperty(row, field)
        counts[key] = get(counts, key, 0) + 1
    end
    return counts
end

namedtuple_vector(rows) = NamedTuple[row for row in rows]

function grouped_count_summary(rows, group_field::Symbol, value_field::Symbol)
    keys = sort(collect(Set((getproperty(row, group_field), getproperty(row, value_field))
                for row in rows)); by = string)
    return [
        begin
            group, value = key
            group_rows = [row for row in rows if getproperty(row, group_field) == group]
            subset = [row for row in group_rows if getproperty(row, value_field) == value]
            (
                group_field = group_field,
                group = group,
                value_field = value_field,
                value = value,
                count = length(subset),
                share = length(subset) / length(group_rows),
                mean_pct_virgin_use = mean_field(subset, :pct_virgin_use),
                mean_pct_toaster_service = mean_field(subset, :pct_toaster_service),
                mean_upstream_output_reduction_m =
                    mean_field(subset, :upstream_output_reduction_m),
                mean_circular_activity_gain_c =
                    mean_field(subset, :circular_activity_gain_c),
                mean_virgin_saving_per_support_dollar =
                    mean_finite_field(subset, :virgin_saving_per_support_dollar),
            )
        end
        for key in keys
    ]
end

function status_summary(records, strategy::Symbol)
    rows = two_country_result_rows(records)
    keys = sort(collect(Set(row.status for row in rows)); by = string)
    return [
        begin
            subset = [row for row in rows if row.status == key]
            (
                strategy = strategy,
                status = key,
                count = length(subset),
                max_abs_market_residual = maximum(row.max_abs_market_residual for row in subset),
            )
        end
        for key in keys
    ]
end

function coverage_summary(records, comparable, strategy::Symbol, fields; reference_filter)
    rows = two_country_result_rows(records)
    valid_rows = [row for row in rows if is_valid_result_row(row)]
    comparable_rows = two_country_result_rows(comparable)
    all_groups = Set(group_key(row, fields) for row in rows)
    valid_groups = Set(group_key(row, fields) for row in valid_rows)
    valid_reference_groups = Set(group_key(row, fields) for row in valid_rows if reference_filter(row))
    comparable_groups = Set(group_key(row, fields) for row in comparable_rows)
    return (
        strategy = strategy,
        records = length(rows),
        parameter_groups = length(all_groups),
        valid_records = length(valid_rows),
        invalid_records = length(rows) - length(valid_rows),
        valid_groups = length(valid_groups),
        valid_reference_groups = length(valid_reference_groups),
        comparable_records = length(comparable_rows),
        comparable_groups = length(comparable_groups),
        max_abs_market_residual = maximum(row.max_abs_market_residual for row in rows),
    )
end

const SUPPORT_TOL = 1.0e-10
const SUPPORT_STRATEGIES = (:refurbishment_support, :recycling_support)

function support_efficiency_candidate(row)
    return row.strategy in SUPPORT_STRATEGIES &&
           row.support_cost > SUPPORT_TOL &&
           row.material_saving &&
           !row.rebound &&
           isfinite(row.virgin_saving_per_support_dollar)
end

function support_efficiency_summary(rows)
    strategies = sort(collect(Set(row.strategy for row in rows)); by = string)
    return [
        begin
            subset = [row for row in rows if row.strategy === strategy]
            (
                strategy = strategy,
                count = length(subset),
                share = length(subset) / length(rows),
                mean_policy_magnitude = mean_field(subset, :policy_magnitude),
                mean_support_cost = mean_field(subset, :support_cost),
                mean_virgin_saving = mean_field(subset, :virgin_saving),
                mean_virgin_saving_per_support_dollar =
                    mean_finite_field(subset, :virgin_saving_per_support_dollar),
                mean_service_loss_per_support_dollar =
                    mean_finite_field(subset, :service_loss_per_support_dollar),
                mean_upstream_output_reduction_m =
                    mean_field(subset, :upstream_output_reduction_m),
                mean_circular_activity_gain_c =
                    mean_field(subset, :circular_activity_gain_c),
            )
        end
        for strategy in strategies
    ]
end

comparison_rows = vcat(
    strategy_rows(tax_comparison, :virgin_material_tax, :tau_material_vmtl),
    strategy_rows(support_comparison, :refurbishment_support, :tau_route_ref),
    strategy_rows(recycling_comparison, :recycling_support, :tau_eol_rec),
)
threshold_rows = vcat(
    strategy_rows(tax_frontier, :virgin_material_tax, :tau_material_vmtl),
    strategy_rows(support_frontier, :refurbishment_support, :tau_route_ref),
    strategy_rows(recycling_frontier, :recycling_support, :tau_eol_rec),
)
support_efficiency_rows = frontier_rows(comparison_rows;
    group_by = group_fields,
    select_by = :virgin_saving_per_support_dollar,
    predicate = support_efficiency_candidate,
    sense = :max)

run_summary = [(
    grid_mode = grid_mode,
    parameter_groups = length(tax_results) ÷ 4,
    tax_experiments = length(tax_results),
    support_experiments = length(support_results),
    recycling_experiments = length(recycling_results),
    tax_comparable_experiments = length(tax_comparable),
    support_comparable_experiments = length(support_comparable),
    recycling_comparable_experiments = length(recycling_comparable),
    comparison_rows = length(comparison_rows),
    tax_thresholds = length(tax_frontier),
    support_thresholds = length(support_frontier),
    recycling_thresholds = length(recycling_frontier),
    support_efficiency_groups = length(support_efficiency_rows),
)]

write_rows_csv(joinpath(output_dir, "fiscal_parameter_region_tax_results.csv"),
    two_country_result_rows(tax_results))
write_rows_csv(joinpath(output_dir, "fiscal_parameter_region_refurbishment_results.csv"),
    two_country_result_rows(support_results))
write_rows_csv(joinpath(output_dir, "fiscal_parameter_region_recycling_results.csv"),
    two_country_result_rows(recycling_results))
write_rows_csv(joinpath(output_dir, "fiscal_parameter_regions.csv"), comparison_rows)
write_rows_csv(joinpath(output_dir, "fiscal_parameter_region_run_summary.csv"), run_summary)
write_rows_csv(joinpath(output_dir, "fiscal_parameter_region_summary.csv"),
    [two_country_summary_row(summarize_two_country_comparison(comparison_rows))])
write_rows_csv(joinpath(output_dir, "fiscal_parameter_region_strategy_mechanisms.csv"),
    grouped_count_summary(comparison_rows, :strategy, :mechanism))
write_rows_csv(joinpath(output_dir, "fiscal_parameter_region_strategy_transmissions.csv"),
    grouped_count_summary(comparison_rows, :strategy, :transmission))
write_rows_csv(joinpath(output_dir, "fiscal_parameter_region_coverage.csv"),
    [coverage_summary(tax_results, tax_comparable, :virgin_material_tax, group_fields;
            reference_filter = tax_reference_filter),
        coverage_summary(support_results, support_comparable, :refurbishment_support, group_fields;
            reference_filter = support_reference_filter),
        coverage_summary(recycling_results, recycling_comparable, :recycling_support, group_fields;
            reference_filter = recycling_reference_filter)])
write_rows_csv(joinpath(output_dir, "fiscal_parameter_region_status.csv"),
    vcat(status_summary(tax_results, :virgin_material_tax),
        status_summary(support_results, :refurbishment_support),
        status_summary(recycling_results, :recycling_support)))
write_rows_csv(joinpath(output_dir, "fiscal_parameter_region_activity_distribution.csv"),
    two_country_distributional_activity_summary(comparison_rows; group_by = [:strategy]))
write_rows_csv(joinpath(output_dir, "fiscal_parameter_region_factor_distribution.csv"),
    two_country_distributional_factor_summary(comparison_rows; group_by = [:strategy]))
write_rows_csv(joinpath(output_dir, "fiscal_parameter_region_transmission_activity_distribution.csv"),
    two_country_distributional_activity_summary(comparison_rows; group_by = [:transmission]))
write_rows_csv(joinpath(output_dir, "fiscal_parameter_region_transmission_factor_distribution.csv"),
    two_country_distributional_factor_summary(comparison_rows; group_by = [:transmission]))

if !isempty(threshold_rows)
    write_rows_csv(joinpath(output_dir, "fiscal_parameter_region_thresholds.csv"),
        namedtuple_vector(threshold_rows))
    write_rows_csv(joinpath(output_dir, "fiscal_parameter_region_threshold_transmissions.csv"),
        namedtuple_vector(grouped_count_summary(threshold_rows, :strategy, :transmission)))
end
if !isempty(support_efficiency_rows)
    write_rows_csv(joinpath(output_dir, "fiscal_parameter_region_support_efficiency.csv"),
        namedtuple_vector(support_efficiency_rows))
    write_rows_csv(joinpath(output_dir, "fiscal_parameter_region_support_efficiency_summary.csv"),
        namedtuple_vector(support_efficiency_summary(support_efficiency_rows)))
end

println("Grid mode: $(grid_mode)")
println("Parameter groups: $(length(tax_results) ÷ 4)")
println("Ran $(length(tax_results)) virgin-material tax experiments")
println("Ran $(length(support_results)) refurbishment-support experiments")
println("Ran $(length(recycling_results)) recycling-support experiments")
println("Comparable tax experiments: $(length(tax_comparable))")
println("Comparable refurbishment-support experiments: $(length(support_comparable))")
println("Comparable recycling-support experiments: $(length(recycling_comparable))")
println("Tax material-saving thresholds without rebound: $(length(tax_frontier))")
println("Support material-saving thresholds without rebound: $(length(support_frontier))")
println("Recycling material-saving thresholds without rebound: $(length(recycling_frontier))")
println("Best support-efficiency groups: $(length(support_efficiency_rows))")
println("Mechanisms by strategy: $(count_by(comparison_rows, :mechanism))")
println("Transmissions by strategy: $(count_by(comparison_rows, :transmission))")
println("Wrote two-country generated results to $(output_dir)")
