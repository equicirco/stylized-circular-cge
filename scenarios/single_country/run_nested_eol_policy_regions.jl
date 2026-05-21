using StylizedCircularCGE

output_dir = joinpath(@__DIR__, "..", "..", "results", "single_country", "generated")
mkpath(output_dir)
execution_kwargs = experiment_execution_kwargs()

const MARKET_TOL = 1.0e-5
const TAX_TAU = [0.0, 0.10, 0.25, 0.50]
const SUPPORT_TAU = [-0.50, -0.25, -0.10, 0.0]
const SUPPORT_TOL = 1.0e-10
const LIFE_EXTENSION_ROUTES = (:REF, :REP, :REU)
const LIFE_EXTENSION_STRATEGIES = Dict(
    :REF => :refurbishment_support,
    :REP => :repair_support,
    :REU => :reuse_support,
)
const ROUTE_POLICY_FIELDS = Dict(
    :REF => :tau_route_ref,
    :REP => :tau_route_rep,
    :REU => :tau_route_reu,
)

function nested_eol_grid(mode::AbstractString)
    if mode == "screen"
        return (
            sigma_routes = [1.25, 2.0, 3.0],
            sigma_metal = [1.25, 3.0],
            sigma_eol = [0.5, 2.0, 4.0],
            eta_service = [0.5, 1.0, 1.5],
            metal_quality = [0.75, 0.95],
        )
    elseif mode == "route"
        return (
            sigma_routes = [1.25, 3.0],
            sigma_metal = [1.25, 3.0],
            sigma_eol = [0.5, 4.0],
            eta_service = [0.5, 1.5],
            metal_quality = [0.75, 0.95],
            metal_intensity_ref = [0.15, 0.35],
            metal_intensity_rep = [0.10, 0.25],
            yield_ref = [3.0, 5.0],
            yield_rep = [2.0, 4.0],
            yield_reu = [1.0, 2.0],
        )
    else
        error("Unknown JCGE_NESTED_EOL_GRID=$(mode). Use screen or route.")
    end
end

grid_mode = get(ENV, "JCGE_NESTED_EOL_GRID", "screen")
base_grid = nested_eol_grid(grid_mode)
group_fields = collect(keys(base_grid))

tax_specs = parameter_policy_grid(;
    policy_kind = :material,
    policy_target = :VMTL,
    tau = TAX_TAU,
    prefix = "nested-virgin-material-tax",
    base_grid...)

recycling_specs = parameter_policy_grid(;
    policy_kind = :eol,
    policy_target = :REC,
    tau = SUPPORT_TAU,
    prefix = "nested-recycling-support",
    base_grid...)

route_specs = Dict(route => parameter_policy_grid(;
        policy_kind = :route,
        policy_target = route,
        tau = SUPPORT_TAU,
        prefix = "nested-$(lowercase(String(route)))-support",
        base_grid...)
    for route in LIFE_EXTENSION_ROUTES)

tax_results = run_grid(tax_specs; closure = :fiscal, execution_kwargs...)
recycling_results = run_grid(recycling_specs; closure = :fiscal, execution_kwargs...)
route_results = Dict(route => run_grid(route_specs[route]; closure = :fiscal, execution_kwargs...)
                     for route in LIFE_EXTENSION_ROUTES)

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

function group_status_lookup(records, fields; reference_filter)
    rows = result_rows(records)
    lookup = Dict{Tuple,NamedTuple}()
    for key in sort(collect(Set(group_key(row, fields) for row in rows)); by = string)
        group_rows = [row for row in rows if group_key(row, fields) == key]
        valid_rows = [row for row in group_rows if is_valid_result_row(row)]
        reference_valid = any(reference_filter(row) for row in valid_rows)
        lookup[key] = (
            records = length(group_rows),
            valid_records = length(valid_rows),
            invalid_records = length(group_rows) - length(valid_rows),
            reference_valid = reference_valid,
            comparable_records = reference_valid ? length(valid_rows) : 0,
            complete = reference_valid && length(valid_rows) == length(group_rows),
        )
    end
    return lookup
end

tax_reference_filter = row -> row.tau_material_vmtl == 0.0
recycling_reference_filter = row -> row.tau_eol_rec == 0.0
route_reference_filter(route) = row -> getproperty(row, ROUTE_POLICY_FIELDS[route]) == 0.0

tax_comparable = comparable_records(tax_results, group_fields;
    reference_filter = tax_reference_filter)
recycling_comparable = comparable_records(recycling_results, group_fields;
    reference_filter = recycling_reference_filter)
route_comparable = Dict(route => comparable_records(route_results[route], group_fields;
        reference_filter = route_reference_filter(route))
    for route in LIFE_EXTENSION_ROUTES)

tax_comparison = compare_to_group_reference(tax_comparable, group_fields;
    reference_filter = tax_reference_filter)
recycling_comparison = compare_to_group_reference(recycling_comparable, group_fields;
    reference_filter = recycling_reference_filter)
route_comparison = Dict(route => compare_to_group_reference(route_comparable[route], group_fields;
        reference_filter = route_reference_filter(route))
    for route in LIFE_EXTENSION_ROUTES)

tax_frontier = material_saving_frontier(tax_comparison, :tau_material_vmtl;
    group_by = group_fields,
    allow_rebound = false,
    sense = :min)
recycling_frontier = frontier_rows(recycling_comparison;
    group_by = group_fields,
    select_by = :tau_eol_rec,
    predicate = row -> row.tau_eol_rec < 0.0 && row.material_saving && !row.rebound,
    sense = :absolute_min)
route_frontiers = Dict(route => frontier_rows(route_comparison[route];
        group_by = group_fields,
        select_by = ROUTE_POLICY_FIELDS[route],
        predicate = row -> getproperty(row, ROUTE_POLICY_FIELDS[route]) < 0.0 &&
                           row.material_saving && !row.rebound,
        sense = :absolute_min)
    for route in LIFE_EXTENSION_ROUTES)

function strategy_rows(rows, strategy::Symbol, policy_field::Symbol;
    strategy_family::Symbol,
    eol_route::Symbol = :none)
    return [
        merge((
                strategy = strategy,
                strategy_family = strategy_family,
                eol_route = eol_route,
                policy_field = policy_field,
                policy_value = getproperty(row, policy_field),
                policy_magnitude = abs(getproperty(row, policy_field)),
            ),
            row)
        for row in rows
    ]
end

tagged_tax_comparison = strategy_rows(tax_comparison, :virgin_material_tax, :tau_material_vmtl;
    strategy_family = :linear)
tagged_recycling_comparison = strategy_rows(recycling_comparison, :recycling_support, :tau_eol_rec;
    strategy_family = :recycling)
tagged_route_comparison = vcat([
    strategy_rows(route_comparison[route], LIFE_EXTENSION_STRATEGIES[route],
        ROUTE_POLICY_FIELDS[route];
        strategy_family = :life_extension,
        eol_route = route)
    for route in LIFE_EXTENSION_ROUTES
]...)

tagged_tax_frontier = strategy_rows(tax_frontier, :virgin_material_tax, :tau_material_vmtl;
    strategy_family = :linear)
tagged_recycling_frontier = strategy_rows(recycling_frontier, :recycling_support, :tau_eol_rec;
    strategy_family = :recycling)
tagged_route_frontiers = vcat([
    strategy_rows(route_frontiers[route], LIFE_EXTENSION_STRATEGIES[route],
        ROUTE_POLICY_FIELDS[route];
        strategy_family = :life_extension,
        eol_route = route)
    for route in LIFE_EXTENSION_ROUTES
]...)

comparison_rows = vcat(tagged_tax_comparison, tagged_recycling_comparison, tagged_route_comparison)
threshold_rows = vcat(tagged_tax_frontier, tagged_recycling_frontier, tagged_route_frontiers)

life_extension_family_thresholds = frontier_rows(tagged_route_frontiers;
    group_by = group_fields,
    select_by = :policy_magnitude,
    predicate = row -> true,
    sense = :min)

function support_efficiency_candidate(row)
    return row.strategy_family in (:life_extension, :recycling) &&
           row.support_cost > SUPPORT_TOL &&
           row.material_saving &&
           !row.rebound &&
           isfinite(row.virgin_saving_per_support_dollar)
end

support_efficiency_rows = frontier_rows(
    [row for row in comparison_rows if row.strategy_family in (:life_extension, :recycling)];
    group_by = group_fields,
    select_by = :virgin_saving_per_support_dollar,
    predicate = support_efficiency_candidate,
    sense = :max)

life_extension_support_efficiency_rows = frontier_rows(
    [row for row in tagged_route_comparison if row.strategy_family === :life_extension];
    group_by = group_fields,
    select_by = :virgin_saving_per_support_dollar,
    predicate = support_efficiency_candidate,
    sense = :max)

function frontier_lookup(rows, fields)
    lookup = Dict{Tuple,NamedTuple}()
    for row in rows
        key = group_key(row, fields)
        haskey(lookup, key) && error("Duplicate row for group $(key)")
        lookup[key] = row
    end
    return lookup
end

maybe_field(row::Nothing, field::Symbol) = NaN
maybe_field(row::NamedTuple, field::Symbol) =
    hasproperty(row, field) ? Float64(getproperty(row, field)) : NaN
maybe_symbol(row::Nothing, field::Symbol) = :none
maybe_symbol(row::NamedTuple, field::Symbol) = getproperty(row, field)

function choose_row(candidates, field::Symbol; sense::Symbol, finite::Bool = false)
    available = [(label, row) for (label, row) in candidates if row !== nothing]
    finite && (available = [(label, row) for (label, row) in available
                            if isfinite(maybe_field(row, field))])
    isempty(available) && return :none
    values = [maybe_field(row, field) for (_, row) in available]
    best =
        if sense === :min
            minimum(values)
        elseif sense === :max
            maximum(values)
        else
            error("Unknown comparison sense $(sense). Use :min or :max.")
        end
    winners = [label for (label, row) in available if isapprox(maybe_field(row, field), best;
        atol = 1.0e-12, rtol = 1.0e-12)]
    return length(winners) == 1 ? only(winners) : :tie
end

function family_region_label(linear_available::Bool, life_available::Bool,
    recycling_available::Bool)
    linear_available && life_available && recycling_available && return :all_available
    linear_available && life_available && return :linear_and_life_extension
    linear_available && recycling_available && return :linear_and_recycling
    life_available && recycling_available && return :life_extension_and_recycling
    linear_available && return :linear_only
    life_available && return :life_extension_only
    recycling_available && return :recycling_only
    return :none_available
end

function completeness_label(statuses)
    all(status.complete for status in statuses) && return :complete
    reference_count = count(status.reference_valid for status in statuses)
    reference_count == length(statuses) && return :partial_policy_rows
    reference_count == 0 && return :missing_all_references
    return :missing_some_references
end

function family_region_map(records, linear_frontier, life_frontier, recycling_frontier, fields;
    linear_status, recycling_status, route_status)
    linear_lookup = frontier_lookup(linear_frontier, fields)
    life_lookup = frontier_lookup(life_frontier, fields)
    recycling_lookup = frontier_lookup(recycling_frontier, fields)
    keys_all = sort(collect(Set(group_key(row, fields) for row in result_rows(records)));
        by = string)
    return [
        merge(
            NamedTuple{Tuple(fields)}(key),
            begin
                linear_row = get(linear_lookup, key, nothing)
                life_row = get(life_lookup, key, nothing)
                recycling_row = get(recycling_lookup, key, nothing)
                linear_available = linear_row !== nothing
                life_available = life_row !== nothing
                recycling_available = recycling_row !== nothing
                status_bundle = (linear_status[key], recycling_status[key],
                    route_status[:REF][key], route_status[:REP][key], route_status[:REU][key])
                candidates = [
                    (:linear, linear_row),
                    (:life_extension, life_row),
                    (:recycling, recycling_row),
                ]
                (
                    region = family_region_label(linear_available, life_available,
                        recycling_available),
                    region_quality = completeness_label(status_bundle),
                    linear_available = linear_available,
                    life_extension_available = life_available,
                    recycling_available = recycling_available,
                    life_extension_strategy = maybe_symbol(life_row, :strategy),
                    life_extension_route = maybe_symbol(life_row, :eol_route),
                    linear_threshold = maybe_field(linear_row, :policy_value),
                    life_extension_threshold = maybe_field(life_row, :policy_value),
                    recycling_threshold = maybe_field(recycling_row, :policy_value),
                    linear_threshold_magnitude = maybe_field(linear_row, :policy_magnitude),
                    life_extension_threshold_magnitude = maybe_field(life_row, :policy_magnitude),
                    recycling_threshold_magnitude = maybe_field(recycling_row, :policy_magnitude),
                    linear_pct_virgin_use = maybe_field(linear_row, :pct_virgin_use),
                    life_extension_pct_virgin_use = maybe_field(life_row, :pct_virgin_use),
                    recycling_pct_virgin_use = maybe_field(recycling_row, :pct_virgin_use),
                    linear_pct_toaster_service = maybe_field(linear_row, :pct_toaster_service),
                    life_extension_pct_toaster_service = maybe_field(life_row, :pct_toaster_service),
                    recycling_pct_toaster_service = maybe_field(recycling_row, :pct_toaster_service),
                    strongest_material_saving = choose_row(candidates, :pct_virgin_use; sense = :min),
                    lowest_service_loss = choose_row(candidates, :pct_toaster_service; sense = :max),
                    highest_government_net = choose_row(candidates, :government_net; sense = :max),
                    highest_support_efficiency =
                        choose_row([(:life_extension, life_row), (:recycling, recycling_row)],
                            :virgin_saving_per_support_dollar; sense = :max, finite = true),
                )
            end,
        )
        for key in keys_all
    ]
end

function within_eol_route_map(records, route_thresholds, route_efficiency, fields; route_status)
    threshold_lookup = Dict(route => frontier_lookup(
            [row for row in route_thresholds if row.eol_route === route], fields)
        for route in LIFE_EXTENSION_ROUTES)
    efficiency_lookup = frontier_lookup(route_efficiency, fields)
    keys_all = sort(collect(Set(group_key(row, fields) for row in result_rows(records)));
        by = string)
    return [
        merge(
            NamedTuple{Tuple(fields)}(key),
            begin
                ref_row = get(threshold_lookup[:REF], key, nothing)
                rep_row = get(threshold_lookup[:REP], key, nothing)
                reu_row = get(threshold_lookup[:REU], key, nothing)
                efficiency_row = get(efficiency_lookup, key, nothing)
                candidates = [(:REF, ref_row), (:REP, rep_row), (:REU, reu_row)]
                (
                    route_region_quality = completeness_label((
                        route_status[:REF][key],
                        route_status[:REP][key],
                        route_status[:REU][key],
                    )),
                    ref_available = ref_row !== nothing,
                    rep_available = rep_row !== nothing,
                    reu_available = reu_row !== nothing,
                    available_routes = count(row -> row !== nothing, (ref_row, rep_row, reu_row)),
                    weakest_support_route =
                        choose_row(candidates, :policy_magnitude; sense = :min),
                    strongest_material_saving_route =
                        choose_row(candidates, :pct_virgin_use; sense = :min),
                    lowest_service_loss_route =
                        choose_row(candidates, :pct_toaster_service; sense = :max),
                    best_support_efficiency_route = maybe_symbol(efficiency_row, :eol_route),
                    ref_threshold = maybe_field(ref_row, :policy_value),
                    rep_threshold = maybe_field(rep_row, :policy_value),
                    reu_threshold = maybe_field(reu_row, :policy_value),
                    ref_threshold_magnitude = maybe_field(ref_row, :policy_magnitude),
                    rep_threshold_magnitude = maybe_field(rep_row, :policy_magnitude),
                    reu_threshold_magnitude = maybe_field(reu_row, :policy_magnitude),
                    ref_pct_virgin_use = maybe_field(ref_row, :pct_virgin_use),
                    rep_pct_virgin_use = maybe_field(rep_row, :pct_virgin_use),
                    reu_pct_virgin_use = maybe_field(reu_row, :pct_virgin_use),
                    ref_pct_toaster_service = maybe_field(ref_row, :pct_toaster_service),
                    rep_pct_toaster_service = maybe_field(rep_row, :pct_toaster_service),
                    reu_pct_toaster_service = maybe_field(reu_row, :pct_toaster_service),
                    best_support_efficiency =
                        maybe_field(efficiency_row, :virgin_saving_per_support_dollar),
                )
            end,
        )
        for key in keys_all
    ]
end

function mean_field(rows, field::Symbol)
    isempty(rows) && return NaN
    return sum(Float64(getproperty(row, field)) for row in rows) / length(rows)
end

function finite_mean_field(rows, field::Symbol)
    values = [Float64(getproperty(row, field)) for row in rows
              if isfinite(Float64(getproperty(row, field)))]
    isempty(values) && return NaN
    return sum(values) / length(values)
end

function push_count_summary!(out, rows, subset::Symbol, dimension::Symbol, value_function)
    total = length(rows)
    total == 0 && return out
    values = sort(collect(Set(value_function(row) for row in rows)); by = string)
    for value in values
        n = count(row -> value_function(row) == value, rows)
        push!(out, (
            subset = subset,
            dimension = dimension,
            value = value,
            count = n,
            share = n / total,
        ))
    end
    return out
end

function family_region_summary(rows)
    out = NamedTuple[]
    push_count_summary!(out, rows, :all, :region, row -> row.region)
    push_count_summary!(out, rows, :all, :life_extension_route, row -> row.life_extension_route)
    push_count_summary!(out, rows, :all, :strongest_material_saving,
        row -> row.strongest_material_saving)
    push_count_summary!(out, rows, :all, :lowest_service_loss,
        row -> row.lowest_service_loss)
    push_count_summary!(out, rows, :all, :highest_support_efficiency,
        row -> row.highest_support_efficiency)
    return out
end

function within_eol_route_summary(rows)
    out = NamedTuple[]
    push_count_summary!(out, rows, :all, :available_routes, row -> row.available_routes)
    push_count_summary!(out, rows, :all, :weakest_support_route,
        row -> row.weakest_support_route)
    push_count_summary!(out, rows, :all, :strongest_material_saving_route,
        row -> row.strongest_material_saving_route)
    push_count_summary!(out, rows, :all, :lowest_service_loss_route,
        row -> row.lowest_service_loss_route)
    push_count_summary!(out, rows, :all, :best_support_efficiency_route,
        row -> row.best_support_efficiency_route)
    return out
end

function strategy_outcome_summary(rows)
    out = NamedTuple[]
    for strategy in sort(collect(Set(row.strategy for row in rows)); by = string)
        subset = [row for row in rows if row.strategy === strategy]
        push!(out, (
            strategy = strategy,
            strategy_family = first(subset).strategy_family,
            eol_route = first(subset).eol_route,
            count = length(subset),
            share = length(subset) / length(rows),
            mean_policy_magnitude = mean_field(subset, :policy_magnitude),
            material_saving_share = count(row -> row.material_saving, subset) / length(subset),
            rebound_share = count(row -> row.rebound, subset) / length(subset),
            mean_pct_virgin_use = mean_field(subset, :pct_virgin_use),
            mean_pct_toaster_service = mean_field(subset, :pct_toaster_service),
            mean_support_cost = mean_field(subset, :support_cost),
            mean_virgin_saving_per_support_dollar =
                finite_mean_field(subset, :virgin_saving_per_support_dollar),
        ))
    end
    return out
end

linear_status = group_status_lookup(tax_results, group_fields;
    reference_filter = tax_reference_filter)
recycling_status = group_status_lookup(recycling_results, group_fields;
    reference_filter = recycling_reference_filter)
route_status = Dict(route => group_status_lookup(route_results[route], group_fields;
        reference_filter = route_reference_filter(route))
    for route in LIFE_EXTENSION_ROUTES)

all_records = vcat(tax_results, recycling_results,
    [record for route in LIFE_EXTENSION_ROUTES for record in route_results[route]])

family_region_rows = family_region_map(all_records, tagged_tax_frontier,
    life_extension_family_thresholds, tagged_recycling_frontier, group_fields;
    linear_status = linear_status,
    recycling_status = recycling_status,
    route_status = route_status)

within_eol_rows = within_eol_route_map(all_records, tagged_route_frontiers,
    life_extension_support_efficiency_rows, group_fields;
    route_status = route_status)

run_summary = [(
    grid_mode = grid_mode,
    parameter_groups = length(tax_results) ÷ length(TAX_TAU),
    linear_experiments = length(tax_results),
    recycling_experiments = length(recycling_results),
    refurbishment_experiments = length(route_results[:REF]),
    repair_experiments = length(route_results[:REP]),
    reuse_experiments = length(route_results[:REU]),
    linear_thresholds = length(tagged_tax_frontier),
    recycling_thresholds = length(tagged_recycling_frontier),
    route_thresholds = length(tagged_route_frontiers),
    life_extension_family_thresholds = length(life_extension_family_thresholds),
    support_efficiency_groups = length(support_efficiency_rows),
    life_extension_support_efficiency_groups = length(life_extension_support_efficiency_rows),
    family_region_groups = length(family_region_rows),
    within_eol_groups = length(within_eol_rows),
)]

write_rows_csv(joinpath(output_dir, "nested_eol_linear_results.csv"), result_rows(tax_results))
write_rows_csv(joinpath(output_dir, "nested_eol_recycling_results.csv"),
    result_rows(recycling_results))
for route in LIFE_EXTENSION_ROUTES
    write_rows_csv(joinpath(output_dir, "nested_eol_$(lowercase(String(route)))_results.csv"),
        result_rows(route_results[route]))
end
write_rows_csv(joinpath(output_dir, "nested_eol_policy_comparisons.csv"), comparison_rows)
write_rows_csv(joinpath(output_dir, "nested_eol_policy_comparison_summary.csv"),
    strategy_outcome_summary(comparison_rows))
write_rows_csv(joinpath(output_dir, "nested_eol_policy_thresholds.csv"), threshold_rows)
write_rows_csv(joinpath(output_dir, "nested_eol_life_extension_thresholds.csv"),
    tagged_route_frontiers)
write_rows_csv(joinpath(output_dir, "nested_eol_life_extension_family_thresholds.csv"),
    life_extension_family_thresholds)
write_rows_csv(joinpath(output_dir, "nested_eol_support_efficiency.csv"),
    support_efficiency_rows)
write_rows_csv(joinpath(output_dir, "nested_eol_life_extension_support_efficiency.csv"),
    life_extension_support_efficiency_rows)
write_rows_csv(joinpath(output_dir, "nested_eol_family_region_map.csv"), family_region_rows)
write_rows_csv(joinpath(output_dir, "nested_eol_family_region_summary.csv"),
    family_region_summary(family_region_rows))
write_rows_csv(joinpath(output_dir, "nested_eol_within_route_map.csv"), within_eol_rows)
write_rows_csv(joinpath(output_dir, "nested_eol_within_route_summary.csv"),
    within_eol_route_summary(within_eol_rows))
write_rows_csv(joinpath(output_dir, "nested_eol_run_summary.csv"), run_summary)

println("Nested EOL grid mode: $(grid_mode)")
println("Parameter groups: $(first(run_summary).parameter_groups)")
println("Linear thresholds: $(length(tagged_tax_frontier))")
println("Recycling thresholds: $(length(tagged_recycling_frontier))")
println("Life-extension route thresholds: $(length(tagged_route_frontiers))")
println("Life-extension family thresholds: $(length(life_extension_family_thresholds))")
println("Support-efficiency groups: $(length(support_efficiency_rows))")
println("Family region summary:")
for row in family_region_summary(family_region_rows)
    println("  $(row.subset) / $(row.dimension) / $(row.value): " *
            "count=$(row.count), share=$(row.share)")
end
println("Within life-extension route summary:")
for row in within_eol_route_summary(within_eol_rows)
    println("  $(row.subset) / $(row.dimension) / $(row.value): " *
            "count=$(row.count), share=$(row.share)")
end
