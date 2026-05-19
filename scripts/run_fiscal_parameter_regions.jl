using StylizedCircularCGE

output_dir = joinpath(@__DIR__, "..", "outputs")
mkpath(output_dir)
execution_kwargs = experiment_execution_kwargs()

grid_mode = get(ENV, "JCGE_REGION_GRID", "screen")

base_grid =
    if grid_mode == "screen"
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
        error("Unknown JCGE_REGION_GRID=$(grid_mode). Use screen or full.")
    end

group_fields = collect(keys(base_grid))

tax_specs = parameter_policy_grid(;
    policy_kind = :material,
    policy_target = :VMTL,
    tau = [0.0, 0.10, 0.25, 0.50],
    prefix = "region-virgin-material-tax",
    base_grid...)

support_specs = parameter_policy_grid(;
    policy_kind = :route,
    policy_target = :REF,
    tau = [-0.50, -0.25, -0.10, 0.0],
    prefix = "region-refurbishment-support",
    base_grid...)

recycling_specs = parameter_policy_grid(;
    policy_kind = :eol,
    policy_target = :REC,
    tau = [-0.50, -0.25, -0.10, 0.0],
    prefix = "region-recycling-support",
    base_grid...)

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

pairwise_frontier_comparison = vcat(
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

function mean_field(rows, field::Symbol)
    isempty(rows) && return NaN
    return sum(Float64(getproperty(row, field)) for row in rows) / length(rows)
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
                share = length(subset) / length(rows),
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

function parameter_mechanism_summary(rows, parameters)
    out = NamedTuple[]
    for strategy in sort(collect(Set(row.strategy for row in rows)); by = string)
        strategy_rows = [row for row in rows if row.strategy === strategy]
        for parameter in parameters
            levels = sort(collect(Set(getproperty(row, parameter) for row in strategy_rows)))
            for level in levels
                level_rows = [row for row in strategy_rows if getproperty(row, parameter) == level]
                mechanisms = sort(collect(Set(row.mechanism for row in level_rows)); by = string)
                for mechanism in mechanisms
                    subset = [row for row in level_rows if row.mechanism === mechanism]
                    push!(out, (
                        strategy = strategy,
                        parameter = parameter,
                        level = level,
                        mechanism = mechanism,
                        count = length(subset),
                        share_within_level = length(subset) / length(level_rows),
                        mean_pct_virgin_use = mean_field(subset, :pct_virgin_use),
                        mean_pct_toaster_service = mean_field(subset, :pct_toaster_service),
                        mean_government_net = mean_field(subset, :government_net),
                    ))
                end
            end
        end
    end
    return out
end

function status_summary(records, strategy::Symbol)
    rows = result_rows(records)
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
    rows = result_rows(records)
    valid_rows = [row for row in rows if is_valid_result_row(row)]
    comparable_rows = result_rows(comparable)
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

function threshold_availability(row)
    row.left_available && row.right_available && return :both_available
    row.left_available && return Symbol(string(row.left_strategy), "_only")
    row.right_available && return Symbol(string(row.right_strategy), "_only")
    return :neither_available
end

function region_label(tax_available::Bool, support_available::Bool, recycling_available::Bool)
    tax_available && support_available && recycling_available && return :all_available
    tax_available && support_available && return :virgin_material_tax_and_refurbishment_support
    tax_available && recycling_available && return :virgin_material_tax_and_recycling_support
    support_available && recycling_available && return :refurbishment_support_and_recycling_support
    tax_available && return :virgin_material_tax_only
    support_available && return :refurbishment_support_only
    recycling_available && return :recycling_support_only
    return :none_available
end

function frontier_lookup(rows, fields)
    lookup = Dict{Tuple,NamedTuple}()
    for row in rows
        key = group_key(row, fields)
        haskey(lookup, key) && error("Duplicate frontier row for group $(key)")
        lookup[key] = row
    end
    return lookup
end

maybe_field(row::Nothing, field::Symbol) = NaN
maybe_field(row::NamedTuple, field::Symbol) = Float64(getproperty(row, field))

function classify_region_quality(tax_status, support_status, recycling_status)
    tax_status.complete && support_status.complete && recycling_status.complete && return :complete
    reference_count = count((tax_status.reference_valid, support_status.reference_valid,
        recycling_status.reference_valid))
    reference_count == 3 && return :partial_policy_rows
    reference_count == 0 && return :missing_all_references
    return :missing_some_references
end

function choose_strategy(tax_row, support_row, recycling_row, field::Symbol; sense::Symbol)
    candidates = [
        (:virgin_material_tax, tax_row),
        (:refurbishment_support, support_row),
        (:recycling_support, recycling_row),
    ]
    available = [(label, row) for (label, row) in candidates if row !== nothing]
    isempty(available) && return :none

    if sense === :min
        best = minimum(getproperty(row, field) for (_, row) in available)
        winners = [label for (label, row) in available if isapprox(getproperty(row, field), best;
            atol = 1.0e-12, rtol = 1.0e-12)]
        return length(winners) == 1 ? only(winners) : :tie
    elseif sense === :max
        best = maximum(getproperty(row, field) for (_, row) in available)
        winners = [label for (label, row) in available if isapprox(getproperty(row, field), best;
            atol = 1.0e-12, rtol = 1.0e-12)]
        return length(winners) == 1 ? only(winners) : :tie
    end
    error("Unknown comparison sense $(sense). Use :min or :max.")
end

function policy_region_map(records, tax_frontier, support_frontier, recycling_frontier, fields;
    tax_status, support_status, recycling_status)
    tax_lookup = frontier_lookup(tax_frontier, fields)
    support_lookup = frontier_lookup(support_frontier, fields)
    recycling_lookup = frontier_lookup(recycling_frontier, fields)
    keys_all = sort(collect(Set(group_key(row, fields) for row in result_rows(records)));
        by = string)
    return [
        merge(
            NamedTuple{Tuple(fields)}(key),
            begin
                tax_row = get(tax_lookup, key, nothing)
                support_row = get(support_lookup, key, nothing)
                recycling_row = get(recycling_lookup, key, nothing)
                tax_available = tax_row !== nothing
                support_available = support_row !== nothing
                recycling_available = recycling_row !== nothing
                tax_stats = tax_status[key]
                support_stats = support_status[key]
                recycling_stats = recycling_status[key]
                (
                    region = region_label(tax_available, support_available, recycling_available),
                    region_quality = classify_region_quality(tax_stats, support_stats, recycling_stats),
                    tax_available = tax_available,
                    support_available = support_available,
                    recycling_available = recycling_available,
                    tax_reference_valid = tax_stats.reference_valid,
                    support_reference_valid = support_stats.reference_valid,
                    recycling_reference_valid = recycling_stats.reference_valid,
                    tax_complete = tax_stats.complete,
                    support_complete = support_stats.complete,
                    recycling_complete = recycling_stats.complete,
                    tax_records = tax_stats.records,
                    support_records = support_stats.records,
                    recycling_records = recycling_stats.records,
                    tax_valid_records = tax_stats.valid_records,
                    support_valid_records = support_stats.valid_records,
                    recycling_valid_records = recycling_stats.valid_records,
                    tax_invalid_records = tax_stats.invalid_records,
                    support_invalid_records = support_stats.invalid_records,
                    recycling_invalid_records = recycling_stats.invalid_records,
                    tax_comparable_records = tax_stats.comparable_records,
                    support_comparable_records = support_stats.comparable_records,
                    recycling_comparable_records = recycling_stats.comparable_records,
                    tax_threshold = maybe_field(tax_row, :tau_material_vmtl),
                    support_threshold = maybe_field(support_row, :tau_route_ref),
                    recycling_threshold = maybe_field(recycling_row, :tau_eol_rec),
                    tax_threshold_magnitude = abs(maybe_field(tax_row, :tau_material_vmtl)),
                    support_threshold_magnitude = abs(maybe_field(support_row, :tau_route_ref)),
                    recycling_threshold_magnitude = abs(maybe_field(recycling_row, :tau_eol_rec)),
                    tax_pct_virgin_use = maybe_field(tax_row, :pct_virgin_use),
                    support_pct_virgin_use = maybe_field(support_row, :pct_virgin_use),
                    recycling_pct_virgin_use = maybe_field(recycling_row, :pct_virgin_use),
                    tax_pct_toaster_service = maybe_field(tax_row, :pct_toaster_service),
                    support_pct_toaster_service = maybe_field(support_row, :pct_toaster_service),
                    recycling_pct_toaster_service = maybe_field(recycling_row, :pct_toaster_service),
                    tax_government_net = maybe_field(tax_row, :government_net),
                    support_government_net = maybe_field(support_row, :government_net),
                    recycling_government_net = maybe_field(recycling_row, :government_net),
                    stronger_material_saving = choose_strategy(tax_row, support_row, recycling_row,
                        :pct_virgin_use; sense = :min),
                    lower_service_loss = choose_strategy(tax_row, support_row, recycling_row,
                        :pct_toaster_service; sense = :max),
                    higher_government_net = choose_strategy(tax_row, support_row, recycling_row,
                        :government_net; sense = :max),
                )
            end,
        )
        for key in keys_all
    ]
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

function policy_region_summary(rows)
    out = NamedTuple[]
    push_count_summary!(out, rows, :all, :region, row -> row.region)
    push_count_summary!(out, rows, :all, :region_quality, row -> row.region_quality)
    push_count_summary!(out, rows, :all, :stronger_material_saving,
        row -> row.stronger_material_saving)
    push_count_summary!(out, rows, :all, :lower_service_loss,
        row -> row.lower_service_loss)
    push_count_summary!(out, rows, :all, :higher_government_net,
        row -> row.higher_government_net)

    multiple = [row for row in rows if count((row.tax_available, row.support_available,
                row.recycling_available)) >= 2]
    push_count_summary!(out, multiple, :multiple_available, :stronger_material_saving,
        row -> row.stronger_material_saving)
    push_count_summary!(out, multiple, :multiple_available, :lower_service_loss,
        row -> row.lower_service_loss)
    push_count_summary!(out, multiple, :multiple_available, :higher_government_net,
        row -> row.higher_government_net)

    all_three = [row for row in rows if row.region === :all_available]
    push_count_summary!(out, all_three, :all_available, :stronger_material_saving,
        row -> row.stronger_material_saving)
    push_count_summary!(out, all_three, :all_available, :lower_service_loss,
        row -> row.lower_service_loss)
    push_count_summary!(out, all_three, :all_available, :higher_government_net,
        row -> row.higher_government_net)
    return out
end

function policy_region_quality_summary(rows)
    out = NamedTuple[]
    total = length(rows)
    regions = sort(collect(Set(row.region for row in rows)); by = string)
    qualities = sort(collect(Set(row.region_quality for row in rows)); by = string)
    for region in regions
        region_rows = [row for row in rows if row.region === region]
        region_total = length(region_rows)
        for quality in qualities
            quality_rows = [row for row in rows if row.region_quality === quality]
            subset = [row for row in region_rows if row.region_quality === quality]
            isempty(subset) && continue
            quality_total = length(quality_rows)
            push!(out, (
                region = region,
                region_quality = quality,
                count = length(subset),
                share = length(subset) / total,
                share_within_region = length(subset) / region_total,
                share_within_quality = length(subset) / quality_total,
            ))
        end
    end
    return out
end

function push_parameter_count_summary!(out, rows, parameter::Symbol, level,
    subset::Symbol, dimension::Symbol, value_function)
    total = length(rows)
    total == 0 && return out
    values = sort(collect(Set(value_function(row) for row in rows)); by = string)
    for value in values
        n = count(row -> value_function(row) == value, rows)
        push!(out, (
            parameter = parameter,
            level = level,
            subset = subset,
            dimension = dimension,
            value = value,
            count = n,
            share = n / total,
        ))
    end
    return out
end

function policy_region_parameter_summary(rows, parameters)
    out = NamedTuple[]
    for parameter in parameters
        levels = sort(collect(Set(getproperty(row, parameter) for row in rows)))
        for level in levels
            level_rows = [row for row in rows if getproperty(row, parameter) == level]
            push_parameter_count_summary!(out, level_rows, parameter, level,
                :all, :region, row -> row.region)
            push_parameter_count_summary!(out, level_rows, parameter, level,
                :all, :region_quality, row -> row.region_quality)

            multiple = [row for row in level_rows if count((row.tax_available,
                        row.support_available, row.recycling_available)) >= 2]
            push_parameter_count_summary!(out, multiple, parameter, level,
                :multiple_available, :stronger_material_saving, row -> row.stronger_material_saving)
            push_parameter_count_summary!(out, multiple, parameter, level,
                :multiple_available, :lower_service_loss, row -> row.lower_service_loss)
            push_parameter_count_summary!(out, multiple, parameter, level,
                :multiple_available, :higher_government_net, row -> row.higher_government_net)

            all_three = [row for row in level_rows if row.region === :all_available]
            push_parameter_count_summary!(out, all_three, parameter, level,
                :all_available, :stronger_material_saving, row -> row.stronger_material_saving)
            push_parameter_count_summary!(out, all_three, parameter, level,
                :all_available, :lower_service_loss, row -> row.lower_service_loss)
            push_parameter_count_summary!(out, all_three, parameter, level,
                :all_available, :higher_government_net, row -> row.higher_government_net)
        end
    end
    return out
end

function push_two_way_count_summary!(out, rows, x_parameter::Symbol, x_level,
    y_parameter::Symbol, y_level, subset::Symbol, dimension::Symbol, value_function)
    total = length(rows)
    total == 0 && return out
    values = sort(collect(Set(value_function(row) for row in rows)); by = string)
    for value in values
        n = count(row -> value_function(row) == value, rows)
        push!(out, (
            x_parameter = x_parameter,
            x_level = x_level,
            y_parameter = y_parameter,
            y_level = y_level,
            subset = subset,
            dimension = dimension,
            value = value,
            count = n,
            share = n / total,
        ))
    end
    return out
end

function policy_region_two_way_summary(rows, x_parameter::Symbol, y_parameter::Symbol)
    out = NamedTuple[]
    x_levels = sort(collect(Set(getproperty(row, x_parameter) for row in rows)))
    y_levels = sort(collect(Set(getproperty(row, y_parameter) for row in rows)))
    for x_level in x_levels, y_level in y_levels
        cell_rows = [
            row for row in rows
            if getproperty(row, x_parameter) == x_level &&
               getproperty(row, y_parameter) == y_level
        ]
        push_two_way_count_summary!(out, cell_rows, x_parameter, x_level,
            y_parameter, y_level, :all, :region, row -> row.region)
        push_two_way_count_summary!(out, cell_rows, x_parameter, x_level,
            y_parameter, y_level, :all, :region_quality, row -> row.region_quality)

        multiple = [row for row in cell_rows if count((row.tax_available,
                    row.support_available, row.recycling_available)) >= 2]
        push_two_way_count_summary!(out, multiple, x_parameter, x_level,
            y_parameter, y_level, :multiple_available, :stronger_material_saving,
            row -> row.stronger_material_saving)
        push_two_way_count_summary!(out, multiple, x_parameter, x_level,
            y_parameter, y_level, :multiple_available, :lower_service_loss,
            row -> row.lower_service_loss)
        push_two_way_count_summary!(out, multiple, x_parameter, x_level,
            y_parameter, y_level, :multiple_available, :higher_government_net,
            row -> row.higher_government_net)

        all_three = [row for row in cell_rows if row.region === :all_available]
        push_two_way_count_summary!(out, all_three, x_parameter, x_level,
            y_parameter, y_level, :all_available, :stronger_material_saving,
            row -> row.stronger_material_saving)
        push_two_way_count_summary!(out, all_three, x_parameter, x_level,
            y_parameter, y_level, :all_available, :lower_service_loss,
            row -> row.lower_service_loss)
        push_two_way_count_summary!(out, all_three, x_parameter, x_level,
            y_parameter, y_level, :all_available, :higher_government_net,
            row -> row.higher_government_net)
    end
    return out
end

function paired_threshold_summary(rows)
    out = NamedTuple[]
    push_count_summary!(out, rows, :all, :threshold_availability, threshold_availability)
    push_count_summary!(out, rows, :all, :stronger_material_saving,
        row -> row.stronger_material_saving)
    push_count_summary!(out, rows, :all, :lower_service_loss,
        row -> row.lower_service_loss)
    push_count_summary!(out, rows, :all, :higher_government_net,
        row -> row.higher_government_net)

    both = [row for row in rows if row.left_available && row.right_available]
    push_count_summary!(out, both, :both_available, :stronger_material_saving,
        row -> row.stronger_material_saving)
    push_count_summary!(out, both, :both_available, :lower_service_loss,
        row -> row.lower_service_loss)
    push_count_summary!(out, both, :both_available, :higher_government_net,
        row -> row.higher_government_net)
    return out
end

function paired_threshold_pair_summary(rows)
    out = NamedTuple[]
    pairs = sort(collect(Set(row.pair for row in rows)); by = string)
    for pair in pairs
        subset = [row for row in rows if row.pair === pair]
        append!(out, [merge((pair = pair,), row) for row in paired_threshold_summary(subset)])
    end
    return out
end

function paired_threshold_parameter_summary(rows, parameters)
    out = NamedTuple[]
    for parameter in parameters
        levels = sort(collect(Set(getproperty(row, parameter) for row in rows)))
        for level in levels
            level_rows = [row for row in rows if getproperty(row, parameter) == level]
            total = length(level_rows)
            total == 0 && continue

            availability_values = sort(collect(Set(threshold_availability(row)
                        for row in level_rows)); by = string)
            for value in availability_values
                n = count(row -> threshold_availability(row) == value, level_rows)
                push!(out, (
                    parameter = parameter,
                    level = level,
                    subset = :all,
                    dimension = :threshold_availability,
                    value = value,
                    count = n,
                    share = n / total,
                ))
            end

            both = [row for row in level_rows if row.left_available && row.right_available]
            both_total = length(both)
            both_total == 0 && continue
            for dimension in (:stronger_material_saving, :lower_service_loss, :higher_government_net)
                values = sort(collect(Set(getproperty(row, dimension) for row in both)); by = string)
                for value in values
                    n = count(row -> getproperty(row, dimension) == value, both)
                    push!(out, (
                        parameter = parameter,
                        level = level,
                        subset = :both_available,
                        dimension = dimension,
                        value = value,
                        count = n,
                        share = n / both_total,
                    ))
                end
            end
        end
    end
    return out
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
tax_status = group_status_lookup(tax_results, group_fields;
    reference_filter = tax_reference_filter)
support_status = group_status_lookup(support_results, group_fields;
    reference_filter = support_reference_filter)
recycling_status = group_status_lookup(recycling_results, group_fields;
    reference_filter = recycling_reference_filter)
region_rows = policy_region_map(vcat(tax_results, support_results, recycling_results),
    tax_frontier, support_frontier, recycling_frontier, group_fields;
    tax_status = tax_status,
    support_status = support_status,
    recycling_status = recycling_status)

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
    pairwise_threshold_groups = length(pairwise_frontier_comparison),
    policy_region_groups = length(region_rows),
)]

write_rows_csv(joinpath(output_dir, "fiscal_parameter_region_tax_results.csv"),
    result_rows(tax_results))
write_rows_csv(joinpath(output_dir, "fiscal_parameter_region_refurbishment_results.csv"),
    result_rows(support_results))
write_rows_csv(joinpath(output_dir, "fiscal_parameter_region_recycling_results.csv"),
    result_rows(recycling_results))
write_rows_csv(joinpath(output_dir, "fiscal_parameter_regions.csv"), comparison_rows)
write_rows_csv(joinpath(output_dir, "fiscal_parameter_region_mechanisms.csv"),
    mechanism_summary(comparison_rows))
write_rows_csv(joinpath(output_dir, "fiscal_parameter_region_parameter_mechanisms.csv"),
    parameter_mechanism_summary(comparison_rows, group_fields))
write_rows_csv(joinpath(output_dir, "fiscal_parameter_region_run_summary.csv"), run_summary)
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
if !isempty(threshold_rows)
    write_rows_csv(joinpath(output_dir, "fiscal_parameter_region_thresholds.csv"), threshold_rows)
    write_rows_csv(joinpath(output_dir, "fiscal_parameter_region_threshold_mechanisms.csv"),
        mechanism_summary(threshold_rows))
end
if !isempty(pairwise_frontier_comparison)
    write_rows_csv(joinpath(output_dir, "fiscal_parameter_region_paired_thresholds.csv"),
        pairwise_frontier_comparison)
    write_rows_csv(joinpath(output_dir, "fiscal_parameter_region_paired_threshold_summary.csv"),
        paired_threshold_summary(pairwise_frontier_comparison))
    write_rows_csv(joinpath(output_dir, "fiscal_parameter_region_paired_threshold_pair_summary.csv"),
        paired_threshold_pair_summary(pairwise_frontier_comparison))
    write_rows_csv(joinpath(output_dir, "fiscal_parameter_region_paired_threshold_parameter_summary.csv"),
        paired_threshold_parameter_summary(pairwise_frontier_comparison, group_fields))
end
write_rows_csv(joinpath(output_dir, "fiscal_parameter_region_map.csv"), region_rows)
write_rows_csv(joinpath(output_dir, "fiscal_parameter_region_map_summary.csv"),
    policy_region_summary(region_rows))
write_rows_csv(joinpath(output_dir, "fiscal_parameter_region_map_quality_summary.csv"),
    policy_region_quality_summary(region_rows))
write_rows_csv(joinpath(output_dir, "fiscal_parameter_region_map_parameter_summary.csv"),
    policy_region_parameter_summary(region_rows, group_fields))
write_rows_csv(joinpath(output_dir, "fiscal_parameter_region_map_eol_service_summary.csv"),
    policy_region_two_way_summary(region_rows, :sigma_eol, :eta_service))

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
println("Pairwise threshold groups: $(length(pairwise_frontier_comparison))")
println("Policy region groups: $(length(region_rows))")
println("Policy region summary:")
for row in policy_region_summary(region_rows)
    println("  $(row.subset) / $(row.dimension) / $(row.value): " *
            "count=$(row.count), share=$(row.share)")
end
if !isempty(pairwise_frontier_comparison)
    println("Paired threshold summary:")
    for row in paired_threshold_summary(pairwise_frontier_comparison)
        println("  $(row.subset) / $(row.dimension) / $(row.value): " *
                "count=$(row.count), share=$(row.share)")
    end
end
println("Mechanisms across all comparison rows:")
for row in mechanism_summary(comparison_rows)
    println("  $(row.strategy) / $(row.mechanism): count=$(row.count), share=$(row.share)")
end
