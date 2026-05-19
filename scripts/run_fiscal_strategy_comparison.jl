using StylizedCircularCGE

output_dir = joinpath(@__DIR__, "..", "outputs")
mkpath(output_dir)
execution_kwargs = experiment_execution_kwargs()

group_fields = [:sigma_routes, :sigma_eol, :eta_service]
sigma_routes = [1.25, 2.0, 3.0]
sigma_eol = [0.5, 2.0, 4.0]
eta_service = [0.5, 1.0, 1.5]

tax_specs = parameter_policy_grid(;
    policy_kind = :material,
    policy_target = :VMTL,
    tau = [0.0, 0.10, 0.25, 0.50],
    sigma_routes = sigma_routes,
    sigma_eol = sigma_eol,
    eta_service = eta_service,
    prefix = "compare-virgin-material-tax",
)

support_specs = parameter_policy_grid(;
    policy_kind = :route,
    policy_target = :REF,
    tau = [-0.50, -0.25, -0.10, 0.0],
    sigma_routes = sigma_routes,
    sigma_eol = sigma_eol,
    eta_service = eta_service,
    prefix = "compare-refurbishment-support",
)

recycling_specs = parameter_policy_grid(;
    policy_kind = :eol,
    policy_target = :REC,
    tau = [-0.50, -0.25, -0.10, 0.0],
    sigma_routes = sigma_routes,
    sigma_eol = sigma_eol,
    eta_service = eta_service,
    prefix = "compare-recycling-support",
)

tax_results = run_grid(tax_specs; closure = :fiscal, execution_kwargs...)
support_results = run_grid(support_specs; closure = :fiscal, execution_kwargs...)
recycling_results = run_grid(recycling_specs; closure = :fiscal, execution_kwargs...)

const MARKET_TOL = 1.0e-5

function group_key(row, fields)
    return Tuple(getproperty(row, field) for field in fields)
end

function is_valid_result_row(row)
    return string(row.status) == "LOCALLY_SOLVED" &&
           row.closure === :fiscal &&
           row.max_abs_market_residual <= MARKET_TOL
end

function comparable_records(records, fields; reference_filter)
    valid_pairs = [
        (record = record, row = result_row(record))
        for record in records
        if is_valid_result_row(result_row(record))
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

tax_comparison = compare_to_group_reference(tax_comparable, group_fields;
    reference_filter = tax_reference_filter)
support_comparison = compare_to_group_reference(support_comparable, group_fields;
    reference_filter = support_reference_filter)
recycling_comparison = compare_to_group_reference(recycling_comparable, group_fields;
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

tax_refurbishment_comparison = compare_frontiers(tax_frontier, support_frontier;
    group_by = group_fields,
    left_label = :virgin_material_tax,
    right_label = :refurbishment_support,
    left_policy = :tau_material_vmtl,
    right_policy = :tau_route_ref)

tax_recycling_comparison = compare_frontiers(tax_frontier, recycling_frontier;
    group_by = group_fields,
    left_label = :virgin_material_tax,
    right_label = :recycling_support,
    left_policy = :tau_material_vmtl,
    right_policy = :tau_eol_rec)

refurbishment_recycling_comparison = compare_frontiers(support_frontier, recycling_frontier;
    group_by = group_fields,
    left_label = :refurbishment_support,
    right_label = :recycling_support,
    left_policy = :tau_route_ref,
    right_policy = :tau_eol_rec)

function pair_rows(rows, pair::Symbol)
    return [merge((pair = pair,), row) for row in rows]
end

frontier_comparison = vcat(
    pair_rows(tax_refurbishment_comparison, :virgin_material_tax_vs_refurbishment_support),
    pair_rows(tax_recycling_comparison, :virgin_material_tax_vs_recycling_support),
    pair_rows(refurbishment_recycling_comparison, :refurbishment_support_vs_recycling_support),
)

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

function count_by(rows, field::Symbol)
    counts = Dict{Any,Int}()
    for row in rows
        key = getproperty(row, field)
        counts[key] = get(counts, key, 0) + 1
    end
    return counts
end

function mean_field(rows, field::Symbol)
    isempty(rows) && return NaN
    return sum(Float64(getproperty(row, field)) for row in rows) / length(rows)
end

function channel_summary(rows, strategy::Symbol)
    subset = [row for row in rows if row.strategy === strategy]
    return (
        strategy = strategy,
        count = length(subset),
        mean_delta_route_new = mean_field(subset, :delta_route_new),
        mean_delta_route_ref = mean_field(subset, :delta_route_ref),
        mean_delta_route_rep = mean_field(subset, :delta_route_rep),
        mean_delta_route_reu = mean_field(subset, :delta_route_reu),
        mean_delta_eol_ref = mean_field(subset, :delta_eol_ref),
        mean_delta_eol_rec = mean_field(subset, :delta_eol_rec),
        mean_delta_virgin_use_new = mean_field(subset, :delta_virgin_use_new),
        mean_delta_virgin_use_ref = mean_field(subset, :delta_virgin_use_ref),
        mean_delta_virgin_use_rep = mean_field(subset, :delta_virgin_use_rep),
        mean_pct_virgin_use = mean_field(subset, :pct_virgin_use),
        mean_pct_toaster_service = mean_field(subset, :pct_toaster_service),
        mean_government_net = mean_field(subset, :government_net),
    )
end

function mechanism_summary(rows)
    keys = sort(collect(Set((row.strategy, row.mechanism) for row in rows)); by = string)
    return [
        begin
            strategy, mechanism = key
            subset = [row for row in rows if row.strategy === strategy && row.mechanism === mechanism]
            (
                strategy = strategy,
                mechanism = mechanism,
                count = length(subset),
                mean_pct_virgin_use = mean_field(subset, :pct_virgin_use),
                mean_pct_toaster_service = mean_field(subset, :pct_toaster_service),
                mean_government_net = mean_field(subset, :government_net),
                mean_delta_route_new = mean_field(subset, :delta_route_new),
                mean_delta_route_ref = mean_field(subset, :delta_route_ref),
                mean_delta_eol_ref = mean_field(subset, :delta_eol_ref),
                mean_delta_virgin_use_new = mean_field(subset, :delta_virgin_use_new),
                mean_delta_virgin_use_ref = mean_field(subset, :delta_virgin_use_ref),
            )
        end
        for key in keys
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

write_rows_csv(joinpath(output_dir, "fiscal_strategy_comparison.csv"), comparison_rows)
write_rows_csv(joinpath(output_dir, "fiscal_strategy_comparison_mechanisms.csv"),
    mechanism_summary(comparison_rows))
if !isempty(threshold_rows)
    write_rows_csv(joinpath(output_dir, "fiscal_strategy_comparison_thresholds.csv"), threshold_rows)
    write_rows_csv(joinpath(output_dir, "fiscal_strategy_comparison_channel_summary.csv"),
        [channel_summary(threshold_rows, :virgin_material_tax),
            channel_summary(threshold_rows, :refurbishment_support),
            channel_summary(threshold_rows, :recycling_support)])
    write_rows_csv(joinpath(output_dir, "fiscal_strategy_comparison_threshold_mechanisms.csv"),
        mechanism_summary(threshold_rows))
end
if !isempty(frontier_comparison)
    write_rows_csv(joinpath(output_dir, "fiscal_strategy_comparison_paired_thresholds.csv"),
        frontier_comparison)
end

println("Ran $(length(tax_results)) virgin-material tax experiments")
println("Ran $(length(support_results)) refurbishment-support experiments")
println("Ran $(length(recycling_results)) recycling-support experiments")
println("Comparable tax experiments: $(length(tax_comparable))")
println("Comparable refurbishment-support experiments: $(length(support_comparable))")
println("Comparable recycling-support experiments: $(length(recycling_comparable))")
println("Tax material-saving thresholds without rebound: $(length(tax_frontier))")
println("Support material-saving thresholds without rebound: $(length(support_frontier))")
println("Recycling material-saving thresholds without rebound: $(length(recycling_frontier))")
println("Paired threshold groups: $(length(frontier_comparison))")
println("Stronger material saving at threshold: $(count_by(frontier_comparison, :stronger_material_saving))")
println("Lower service loss at threshold: $(count_by(frontier_comparison, :lower_service_loss))")
println("Higher government net at threshold: $(count_by(frontier_comparison, :higher_government_net))")
println("Mechanisms across all comparison rows:")
for row in mechanism_summary(comparison_rows)
    println("  $(row.strategy) / $(row.mechanism): count=$(row.count)")
end
if !isempty(threshold_rows)
    println("Channel summary at no-rebound material-saving thresholds:")
    for row in [channel_summary(threshold_rows, :virgin_material_tax),
        channel_summary(threshold_rows, :refurbishment_support),
        channel_summary(threshold_rows, :recycling_support)]
        println(
            "  $(row.strategy): mean_pct_virgin_use=$(row.mean_pct_virgin_use), " *
            "mean_pct_toaster_service=$(row.mean_pct_toaster_service), " *
            "mean_delta_route_new=$(row.mean_delta_route_new), " *
            "mean_delta_route_ref=$(row.mean_delta_route_ref), " *
            "mean_government_net=$(row.mean_government_net)",
        )
    end
end
