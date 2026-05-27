using CSV
using Statistics
using StylizedCircularCGE

const ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const GENERATED_DIR = joinpath(ROOT, "results", "two_country", "generated")
const ANALYTICS_DIR = joinpath(ROOT, "results", "two_country", "analytics")

mkpath(ANALYTICS_DIR)

const PARAMETER_FIELDS = (
    :sigma_routes,
    :sigma_metal,
    :sigma_eol,
    :eta_service,
    :metal_quality,
    :metal_intensity_ref,
    :yield_ref,
)

const POLICY_STRATEGIES = (
    "virgin_material_tax",
    "refurbishment_support",
    "recycling_support",
)

const SUPPORT_STRATEGIES = (
    "refurbishment_support",
    "recycling_support",
)

const UPSTREAM_CONTRACTION_TRANSMISSIONS = Set((
    "upstream_contraction_with_circular_expansion",
    "upstream_contraction_with_service_contraction",
    "upstream_contraction_material_saving",
))

function read_rows(filename::AbstractString)
    path = joinpath(GENERATED_DIR, filename)
    isfile(path) || error("Missing generated input: $(path)")
    return collect(CSV.File(path; normalizenames = true))
end

as_string(value) = ismissing(value) ? "" : string(value)
as_float(value) = ismissing(value) ? NaN : Float64(value)
function as_bool(value)
    ismissing(value) && return false
    value isa Bool && return value
    text = lowercase(strip(string(value)))
    return text in ("true", "1", "yes")
end

function share(count, total)
    total == 0 && return NaN
    return count / total
end

function count_where(rows, predicate)
    return count(predicate, rows)
end

function finite_values(rows, field::Symbol)
    return filter(isfinite, [as_float(getproperty(row, field)) for row in rows])
end

function finite_mean(rows, field::Symbol)
    values = finite_values(rows, field)
    isempty(values) && return NaN
    return mean(values)
end

function finite_median(rows, field::Symbol)
    values = finite_values(rows, field)
    isempty(values) && return NaN
    return median(values)
end

function finite_quantile(rows, field::Symbol, q::Real)
    values = finite_values(rows, field)
    isempty(values) && return NaN
    return quantile(values, q)
end

function finite_min(rows, field::Symbol)
    values = finite_values(rows, field)
    isempty(values) && return NaN
    return minimum(values)
end

function finite_max(rows, field::Symbol)
    values = finite_values(rows, field)
    isempty(values) && return NaN
    return maximum(values)
end

function signed_share(rows, field::Symbol, sign::Symbol; tol::Real = 1.0e-8)
    isempty(rows) && return NaN
    if sign === :positive
        return count(row -> as_float(getproperty(row, field)) > tol, rows) / length(rows)
    elseif sign === :negative
        return count(row -> as_float(getproperty(row, field)) < -tol, rows) / length(rows)
    end
    error("Unknown sign $(sign)")
end

function bool_share(rows, field::Symbol)
    isempty(rows) && return NaN
    return count(row -> as_bool(getproperty(row, field)), rows) / length(rows)
end

function count_by_string(rows, field::Symbol)
    counts = Dict{String,Int}()
    for row in rows
        key = as_string(getproperty(row, field))
        counts[key] = get(counts, key, 0) + 1
    end
    return counts
end

function level_values(rows, field::Symbol)
    return sort(unique(as_float(getproperty(row, field)) for row in rows
        if !ismissing(getproperty(row, field))))
end

function rows_at_level(rows, field::Symbol, level)
    return [row for row in rows if !ismissing(getproperty(row, field)) &&
            as_float(getproperty(row, field)) == Float64(level)]
end

function rows_for_strategy(rows, strategy::AbstractString)
    return [row for row in rows if as_string(row.strategy) == strategy]
end

function rows_for_transmission(rows, transmission::AbstractString)
    return [row for row in rows if as_string(row.transmission) == transmission]
end

function dominant_count(counts::Dict{String,Int})
    isempty(counts) && return ("none", 0)
    ordered = sort(collect(counts); by = pair -> (-pair.second, pair.first))
    first_pair = first(ordered)
    return (first_pair.first, first_pair.second)
end

function metric_row(metric::AbstractString, value; denominator = nothing)
    count_value = value isa Integer ? Int(value) : NaN
    numeric_value = value isa Number ? Float64(value) : NaN
    return (
        metric = metric,
        value = numeric_value,
        count = count_value,
        share = denominator === nothing ? NaN : share(Int(value), Int(denominator)),
    )
end

function headline_rows(run_summary, comparison_rows, threshold_rows, support_efficiency_rows)
    run = first(run_summary)
    total = length(comparison_rows)
    rows = NamedTuple[
        metric_row("parameter_groups", Int(run.parameter_groups)),
        metric_row("comparison_rows", total),
        metric_row("material_saving_rows",
            count_where(comparison_rows, row -> as_bool(row.material_saving)); denominator = total),
        metric_row("material_saving_without_rebound",
            count_where(comparison_rows, row -> as_bool(row.material_saving) && !as_bool(row.rebound));
            denominator = total),
        metric_row("rebound_rows",
            count_where(comparison_rows, row -> as_bool(row.rebound)); denominator = total),
        metric_row("threshold_rows", length(threshold_rows)),
        metric_row("support_efficiency_groups", length(support_efficiency_rows)),
    ]

    for strategy in POLICY_STRATEGIES
        subset = rows_for_strategy(comparison_rows, strategy)
        push!(rows, metric_row("$(strategy)_comparison_rows", length(subset)))
        push!(rows, metric_row("$(strategy)_material_saving_rows",
            count_where(subset, row -> as_bool(row.material_saving)); denominator = length(subset)))
        threshold_subset = rows_for_strategy(threshold_rows, strategy)
        push!(rows, metric_row("$(strategy)_threshold_rows", length(threshold_subset)))
    end

    transmission_counts = count_by_string(comparison_rows, :transmission)
    for transmission in sort(collect(keys(transmission_counts)))
        push!(rows, metric_row("transmission_$(transmission)",
            transmission_counts[transmission]; denominator = total))
    end
    return rows
end

function strategy_summary(comparison_rows)
    out = NamedTuple[]
    for strategy in POLICY_STRATEGIES
        subset = rows_for_strategy(comparison_rows, strategy)
        isempty(subset) && continue
        push!(out, (
            strategy = strategy,
            count = length(subset),
            material_saving_share = bool_share(subset, :material_saving),
            rebound_share = bool_share(subset, :rebound),
            upstream_contraction_share =
                count(row -> as_string(row.transmission) in UPSTREAM_CONTRACTION_TRANSMISSIONS,
                    subset) / length(subset),
            mean_pct_virgin_use = finite_mean(subset, :pct_virgin_use),
            mean_pct_toaster_service = finite_mean(subset, :pct_toaster_service),
            mean_pct_virgin_metal_m = finite_mean(subset, :pct_virgin_metal_m),
            mean_upstream_output_reduction_m =
                finite_mean(subset, :upstream_output_reduction_m),
            mean_upstream_factor_reduction_m =
                finite_mean(subset, :upstream_factor_reduction_m),
            mean_circular_activity_gain_c =
                finite_mean(subset, :circular_activity_gain_c),
            mean_government_net = finite_mean(subset, :government_net),
            mean_support_cost = finite_mean(subset, :support_cost),
            mean_virgin_saving_per_support_dollar =
                finite_mean(subset, :virgin_saving_per_support_dollar),
        ))
    end
    return out
end

function transmission_strategy_summary(comparison_rows)
    out = NamedTuple[]
    for strategy in POLICY_STRATEGIES
        strategy_rows = rows_for_strategy(comparison_rows, strategy)
        isempty(strategy_rows) && continue
        transmissions = sort(collect(keys(count_by_string(strategy_rows, :transmission))))
        for transmission in transmissions
            subset = rows_for_transmission(strategy_rows, transmission)
            push!(out, (
                strategy = strategy,
                transmission = transmission,
                count = length(subset),
                share_within_strategy = length(subset) / length(strategy_rows),
                material_saving_share = bool_share(subset, :material_saving),
                rebound_share = bool_share(subset, :rebound),
                mean_pct_virgin_use = finite_mean(subset, :pct_virgin_use),
                mean_pct_toaster_service = finite_mean(subset, :pct_toaster_service),
                mean_upstream_output_reduction_m =
                    finite_mean(subset, :upstream_output_reduction_m),
                mean_upstream_factor_reduction_m =
                    finite_mean(subset, :upstream_factor_reduction_m),
                mean_circular_activity_gain_c =
                    finite_mean(subset, :circular_activity_gain_c),
                mean_virgin_saving_per_support_dollar =
                    finite_mean(subset, :virgin_saving_per_support_dollar),
            ))
        end
    end
    return out
end

function mechanism_transmission_summary(comparison_rows)
    out = NamedTuple[]
    keys = sort(collect(Set((as_string(row.strategy), as_string(row.mechanism),
                    as_string(row.transmission)) for row in comparison_rows)); by = string)
    for (strategy, mechanism, transmission) in keys
        strategy_rows = rows_for_strategy(comparison_rows, strategy)
        subset = [
            row for row in strategy_rows
            if as_string(row.mechanism) == mechanism &&
               as_string(row.transmission) == transmission
        ]
        push!(out, (
            strategy = strategy,
            mechanism = mechanism,
            transmission = transmission,
            count = length(subset),
            share_within_strategy = length(subset) / length(strategy_rows),
            mean_pct_virgin_use = finite_mean(subset, :pct_virgin_use),
            mean_pct_toaster_service = finite_mean(subset, :pct_toaster_service),
            mean_upstream_output_reduction_m =
                finite_mean(subset, :upstream_output_reduction_m),
            mean_circular_activity_gain_c =
                finite_mean(subset, :circular_activity_gain_c),
        ))
    end
    return out
end

function transmission_parameter_rules(comparison_rows)
    out = NamedTuple[]
    for strategy in POLICY_STRATEGIES
        strategy_rows = rows_for_strategy(comparison_rows, strategy)
        for parameter in PARAMETER_FIELDS
            for level in level_values(strategy_rows, parameter)
                subset = rows_at_level(strategy_rows, parameter, level)
                counts = count_by_string(subset, :transmission)
                dominant, dominant_n = dominant_count(counts)
                push!(out, (
                    strategy = strategy,
                    parameter = String(parameter),
                    level = level,
                    count = length(subset),
                    dominant_transmission = dominant,
                    dominant_count = dominant_n,
                    dominant_share = share(dominant_n, length(subset)),
                    material_saving_share = bool_share(subset, :material_saving),
                    rebound_share = bool_share(subset, :rebound),
                    upstream_contraction_share =
                        count(row -> as_string(row.transmission) in
                                     UPSTREAM_CONTRACTION_TRANSMISSIONS, subset) / length(subset),
                    mean_pct_virgin_use = finite_mean(subset, :pct_virgin_use),
                    mean_pct_toaster_service = finite_mean(subset, :pct_toaster_service),
                    mean_upstream_output_reduction_m =
                        finite_mean(subset, :upstream_output_reduction_m),
                    mean_circular_activity_gain_c =
                        finite_mean(subset, :circular_activity_gain_c),
                ))
            end
        end
    end
    return out
end

function transmission_eol_service_rules(comparison_rows)
    out = NamedTuple[]
    for strategy in POLICY_STRATEGIES
        strategy_rows = rows_for_strategy(comparison_rows, strategy)
        for sigma_eol in level_values(strategy_rows, :sigma_eol)
            for eta_service in level_values(strategy_rows, :eta_service)
                subset = [
                    row for row in strategy_rows
                    if as_float(row.sigma_eol) == sigma_eol &&
                       as_float(row.eta_service) == eta_service
                ]
                isempty(subset) && continue
                counts = count_by_string(subset, :transmission)
                dominant, dominant_n = dominant_count(counts)
                push!(out, (
                    strategy = strategy,
                    sigma_eol = sigma_eol,
                    eta_service = eta_service,
                    count = length(subset),
                    dominant_transmission = dominant,
                    dominant_share = share(dominant_n, length(subset)),
                    material_saving_share = bool_share(subset, :material_saving),
                    rebound_share = bool_share(subset, :rebound),
                    upstream_contraction_share =
                        count(row -> as_string(row.transmission) in
                                     UPSTREAM_CONTRACTION_TRANSMISSIONS, subset) / length(subset),
                    mean_pct_virgin_use = finite_mean(subset, :pct_virgin_use),
                    mean_pct_toaster_service = finite_mean(subset, :pct_toaster_service),
                    mean_upstream_output_reduction_m =
                        finite_mean(subset, :upstream_output_reduction_m),
                    mean_circular_activity_gain_c =
                        finite_mean(subset, :circular_activity_gain_c),
                ))
            end
        end
    end
    return out
end

function support_efficiency_strategy_summary(rows)
    out = NamedTuple[]
    total = length(rows)
    total == 0 && return out
    for strategy in SUPPORT_STRATEGIES
        subset = rows_for_strategy(rows, strategy)
        isempty(subset) && continue
        push!(out, (
            strategy = strategy,
            count = length(subset),
            share_of_support_efficiency_groups = length(subset) / total,
            mean_policy_magnitude = finite_mean(subset, :policy_magnitude),
            mean_support_cost = finite_mean(subset, :support_cost),
            mean_virgin_saving = finite_mean(subset, :virgin_saving),
            mean_virgin_saving_per_support_dollar =
                finite_mean(subset, :virgin_saving_per_support_dollar),
            max_virgin_saving_per_support_dollar =
                finite_max(subset, :virgin_saving_per_support_dollar),
            mean_service_loss_per_support_dollar =
                finite_mean(subset, :service_loss_per_support_dollar),
            mean_upstream_output_reduction_m =
                finite_mean(subset, :upstream_output_reduction_m),
            mean_circular_activity_gain_c =
                finite_mean(subset, :circular_activity_gain_c),
        ))
    end
    return out
end

function support_efficiency_parameter_rules(rows)
    out = NamedTuple[]
    for parameter in PARAMETER_FIELDS
        for level in level_values(rows, parameter)
            level_rows = rows_at_level(rows, parameter, level)
            counts = count_by_string(level_rows, :strategy)
            dominant, dominant_n = dominant_count(counts)
            push!(out, (
                parameter = String(parameter),
                level = level,
                count = length(level_rows),
                dominant_support_strategy = dominant,
                dominant_count = dominant_n,
                dominant_share = share(dominant_n, length(level_rows)),
                refurbishment_count = get(counts, "refurbishment_support", 0),
                recycling_count = get(counts, "recycling_support", 0),
                mean_virgin_saving_per_support_dollar =
                    finite_mean(level_rows, :virgin_saving_per_support_dollar),
                mean_service_loss_per_support_dollar =
                    finite_mean(level_rows, :service_loss_per_support_dollar),
                mean_upstream_output_reduction_m =
                    finite_mean(level_rows, :upstream_output_reduction_m),
                mean_circular_activity_gain_c =
                    finite_mean(level_rows, :circular_activity_gain_c),
            ))
        end
    end
    return out
end

const COUNTRY_ACTIVITY_SPECS = (
    (country = :M, component = :bread_m, field = :delta_activity_brd_m,
        pct = :pct_activity_brd_m),
    (country = :M, component = :virgin_material_m, field = :delta_activity_vmtl_m,
        pct = :pct_activity_vmtl_m),
    (country = :C, component = :bread_c, field = :delta_activity_brd_c,
        pct = :pct_activity_brd_c),
    (country = :C, component = :recycled_material_c, field = :delta_activity_rmtl_c,
        pct = :pct_activity_rmtl_c),
    (country = :C, component = :new_production_c, field = :delta_activity_new_c,
        pct = :pct_activity_new_c),
    (country = :C, component = :refurbishment_c, field = :delta_activity_ref_c,
        pct = :pct_activity_ref_c),
    (country = :C, component = :repair_c, field = :delta_activity_rep_c,
        pct = :pct_activity_rep_c),
    (country = :C, component = :reuse_c, field = :delta_activity_reu_c,
        pct = :pct_activity_reu_c),
)

const COUNTRY_FACTOR_SPECS = (
    (country = :M, component = :factor_total_m, field = :delta_factor_m_total,
        pct = :pct_factor_m_total),
    (country = :M, component = :labor_m, field = :delta_factor_lab_m,
        pct = :pct_factor_lab_m),
    (country = :M, component = :capital_m, field = :delta_factor_cap_m,
        pct = :pct_factor_cap_m),
    (country = :M, component = :virgin_material_factor_m,
        field = :delta_activity_factor_vmtl_m, pct = :pct_activity_factor_vmtl_m),
    (country = :C, component = :factor_total_c, field = :delta_factor_c_total,
        pct = :pct_factor_c_total),
    (country = :C, component = :labor_c, field = :delta_factor_lab_c,
        pct = :pct_factor_lab_c),
    (country = :C, component = :capital_c, field = :delta_factor_cap_c,
        pct = :pct_factor_cap_c),
    (country = :C, component = :recycling_factor_c,
        field = :delta_activity_factor_rmtl_c, pct = :pct_activity_factor_rmtl_c),
    (country = :C, component = :refurbishment_factor_c,
        field = :delta_activity_factor_ref_c, pct = :pct_activity_factor_ref_c),
    (country = :C, component = :repair_factor_c,
        field = :delta_activity_factor_rep_c, pct = :pct_activity_factor_rep_c),
    (country = :C, component = :reuse_factor_c,
        field = :delta_activity_factor_reu_c, pct = :pct_activity_factor_reu_c),
)

const MATERIAL_SAVING_TRANSMISSION_SPECS = (
    (side = :C, family = :material, component = :virgin_imports,
        field = :delta_virgin_imports_c, pct = :pct_virgin_imports_c),
    (side = :C, family = :material, component = :recycled_metal_output,
        field = :delta_recycled_metal_c, pct = :pct_recycled_metal_c),
    (side = :C, family = :material, component = :recycled_metal_use,
        field = :delta_recycled_use_c, pct = :pct_recycled_use_c),
    (side = :C, family = :eol_allocation, component = :recycling_share,
        field = :delta_rec_share, pct = nothing),
    (side = :C, family = :eol_allocation, component = :refurbishment_share,
        field = :delta_ref_share, pct = nothing),
    (side = :C, family = :activity, component = :new_production,
        field = :delta_activity_new_c, pct = :pct_activity_new_c),
    (side = :C, family = :activity, component = :refurbishment,
        field = :delta_activity_ref_c, pct = :pct_activity_ref_c),
    (side = :C, family = :activity, component = :repair,
        field = :delta_activity_rep_c, pct = :pct_activity_rep_c),
    (side = :C, family = :activity, component = :reuse,
        field = :delta_activity_reu_c, pct = :pct_activity_reu_c),
    (side = :C, family = :service, component = :toaster_service,
        field = :delta_toaster_service, pct = :pct_toaster_service),
    (side = :M, family = :material, component = :virgin_metal_output,
        field = :delta_virgin_metal_m, pct = :pct_virgin_metal_m),
    (side = :M, family = :activity, component = :virgin_metal_activity,
        field = :delta_activity_vmtl_m, pct = :pct_activity_vmtl_m),
    (side = :M, family = :factor, component = :total_factor_use,
        field = :delta_factor_m_total, pct = :pct_factor_m_total),
    (side = :M, family = :factor, component = :virgin_metal_factor_use,
        field = :delta_activity_factor_vmtl_m, pct = :pct_activity_factor_vmtl_m),
)

function material_saving_rows(rows)
    return [
        row for row in rows
        if as_string(row.status) == "LOCALLY_SOLVED" &&
           abs(as_float(row.policy_value)) > 1.0e-12 &&
           as_bool(row.material_saving)
    ]
end

function material_saving_transmission_set(rows)
    out = NamedTuple[]
    for row in material_saving_rows(rows)
        push!(out, (
            strategy = as_string(row.strategy),
            policy_field = as_string(row.policy_field),
            policy_value = as_float(row.policy_value),
            sigma_routes = as_float(row.sigma_routes),
            sigma_metal = as_float(row.sigma_metal),
            sigma_eol = as_float(row.sigma_eol),
            eta_service = as_float(row.eta_service),
            metal_quality = as_float(row.metal_quality),
            metal_intensity_ref = as_float(row.metal_intensity_ref),
            yield_ref = as_float(row.yield_ref),
            pct_virgin_imports_c = as_float(row.pct_virgin_imports_c),
            pct_recycled_metal_c = as_float(row.pct_recycled_metal_c),
            delta_rec_share = as_float(row.delta_rec_share),
            delta_ref_share = as_float(row.delta_ref_share),
            pct_activity_new_c = as_float(row.pct_activity_new_c),
            pct_activity_ref_c = as_float(row.pct_activity_ref_c),
            pct_activity_rep_c = as_float(row.pct_activity_rep_c),
            pct_activity_reu_c = as_float(row.pct_activity_reu_c),
            pct_toaster_service = as_float(row.pct_toaster_service),
            pct_virgin_metal_m = as_float(row.pct_virgin_metal_m),
            pct_activity_vmtl_m = as_float(row.pct_activity_vmtl_m),
            pct_factor_m_total = as_float(row.pct_factor_m_total),
            pct_activity_factor_vmtl_m = as_float(row.pct_activity_factor_vmtl_m),
            mechanism = as_string(row.mechanism),
            transmission = as_string(row.transmission),
        ))
    end
    return out
end

function material_saving_transmission_summary(rows)
    savers = material_saving_rows(rows)
    out = NamedTuple[]
    for strategy in POLICY_STRATEGIES
        strategy_rows = rows_for_strategy(savers, strategy)
        isempty(strategy_rows) && continue
        for spec in MATERIAL_SAVING_TRANSMISSION_SPECS
            push!(out, (
                strategy = strategy,
                side = spec.side,
                family = spec.family,
                component = spec.component,
                count = length(strategy_rows),
                median_delta = finite_median(strategy_rows, spec.field),
                q25_delta = finite_quantile(strategy_rows, spec.field, 0.25),
                q75_delta = finite_quantile(strategy_rows, spec.field, 0.75),
                median_pct = spec.pct === nothing ? NaN :
                             finite_median(strategy_rows, spec.pct),
                q25_pct = spec.pct === nothing ? NaN :
                          finite_quantile(strategy_rows, spec.pct, 0.25),
                q75_pct = spec.pct === nothing ? NaN :
                          finite_quantile(strategy_rows, spec.pct, 0.75),
                expansion_share = signed_share(strategy_rows, spec.field, :positive),
                contraction_share = signed_share(strategy_rows, spec.field, :negative),
            ))
        end
    end
    return out
end

function material_saving_transmission_sign_patterns(rows)
    savers = material_saving_rows(rows)
    predicates = (
        (pattern = :new_production_contracts,
            test = row -> as_float(row.delta_activity_new_c) < -1.0e-8),
        (pattern = :refurbishment_output_expands,
            test = row -> as_float(row.delta_activity_ref_c) > 1.0e-8),
        (pattern = :recycled_metal_output_expands,
            test = row -> as_float(row.delta_recycled_metal_c) > 1.0e-8),
        (pattern = :recycling_share_expands,
            test = row -> as_float(row.delta_rec_share) > 1.0e-8),
        (pattern = :m_virgin_metal_output_contracts,
            test = row -> as_float(row.delta_virgin_metal_m) < -1.0e-8),
        (pattern = :m_total_factor_use_contracts,
            test = row -> as_float(row.delta_factor_m_total) < -1.0e-8),
        (pattern = :toaster_service_contracts,
            test = row -> as_float(row.delta_toaster_service) < -1.0e-8),
        (pattern = :toaster_service_expands,
            test = row -> as_float(row.delta_toaster_service) > 1.0e-8),
    )
    out = NamedTuple[]
    for strategy in POLICY_STRATEGIES
        strategy_rows = rows_for_strategy(savers, strategy)
        isempty(strategy_rows) && continue
        for pred in predicates
            n = count(pred.test, strategy_rows)
            push!(out, (
                strategy = strategy,
                pattern = pred.pattern,
                count = n,
                share_within_material_saving = n / length(strategy_rows),
                material_saving_rows = length(strategy_rows),
            ))
        end
    end
    return out
end

function country_distribution_summary(rows, specs, dimension::Symbol; group_by::Symbol = :strategy)
    out = NamedTuple[]
    groups = sort(collect(Set(as_string(getproperty(row, group_by)) for row in rows)); by = string)
    for group in groups
        group_rows = [row for row in rows if as_string(getproperty(row, group_by)) == group]
        for spec in specs
            push!(out, (
                group_by = String(group_by),
                group = group,
                dimension = dimension,
                country = spec.country,
                component = spec.component,
                count = length(group_rows),
                mean_delta = finite_mean(group_rows, spec.field),
                mean_pct = finite_mean(group_rows, spec.pct),
                expansion_share = signed_share(group_rows, spec.field, :positive),
                contraction_share = signed_share(group_rows, spec.field, :negative),
            ))
        end
    end
    return out
end

function claim_candidate_rows(run_summary, comparison_rows, threshold_rows, support_efficiency_rows)
    run = first(run_summary)
    total = length(comparison_rows)
    claims = NamedTuple[]
    push!(claims, (
        claim = "The full two-country grid gives broad solved/comparable coverage.",
        evidence_metric = "comparison_rows",
        value = Float64(total),
        count = total,
        share = total / (3 * Float64(run.parameter_groups) * 4),
        note = "Rows are filtered to solved and market-closing cases with a valid reference.",
    ))
    push!(claims, (
        claim = "Material savings usually imply upstream contraction in the resource country.",
        evidence_metric = "upstream_contraction_share_among_material_savers",
        value = begin
            savers = [row for row in comparison_rows if as_bool(row.material_saving)]
            share(count(row -> as_string(row.transmission) in UPSTREAM_CONTRACTION_TRANSMISSIONS,
                    savers), length(savers))
        end,
        count = count_where(comparison_rows, row -> as_bool(row.material_saving)),
        share = begin
            savers = [row for row in comparison_rows if as_bool(row.material_saving)]
            share(count(row -> as_string(row.transmission) in UPSTREAM_CONTRACTION_TRANSMISSIONS,
                    savers), length(savers))
        end,
        note = "This is upstream transmission through virgin-metal demand, not relocation.",
    ))
    push!(claims, (
        claim = "Support-efficiency candidates are split between refurbishment and recycling support.",
        evidence_metric = "support_efficiency_groups",
        value = Float64(length(support_efficiency_rows)),
        count = length(support_efficiency_rows),
        share = share(length(support_efficiency_rows), Int(run.parameter_groups)),
        note = "Rows are best support instruments by virgin saving per support dollar.",
    ))
    push!(claims, (
        claim = "Threshold availability differs across the three policy instruments.",
        evidence_metric = "threshold_rows",
        value = Float64(length(threshold_rows)),
        count = length(threshold_rows),
        share = share(length(threshold_rows), 3 * Int(run.parameter_groups)),
        note = "Thresholds require material saving without rebound.",
    ))
    return claims
end

run_summary = read_rows("fiscal_parameter_region_run_summary.csv")
comparison_rows = read_rows("fiscal_parameter_regions.csv")
threshold_rows = read_rows("fiscal_parameter_region_thresholds.csv")
support_efficiency_rows = read_rows("fiscal_parameter_region_support_efficiency.csv")

outputs = Dict(
    "two_country_headline" =>
        headline_rows(run_summary, comparison_rows, threshold_rows, support_efficiency_rows),
    "strategy_summary" =>
        strategy_summary(comparison_rows),
    "transmission_strategy_summary" =>
        transmission_strategy_summary(comparison_rows),
    "mechanism_transmission_summary" =>
        mechanism_transmission_summary(comparison_rows),
    "material_saving_transmission_set" =>
        material_saving_transmission_set(comparison_rows),
    "material_saving_transmission_summary" =>
        material_saving_transmission_summary(comparison_rows),
    "material_saving_transmission_sign_patterns" =>
        material_saving_transmission_sign_patterns(comparison_rows),
    "transmission_parameter_rules" =>
        transmission_parameter_rules(comparison_rows),
    "transmission_eol_service_rules" =>
        transmission_eol_service_rules(comparison_rows),
    "support_efficiency_strategy_summary" =>
        support_efficiency_strategy_summary(support_efficiency_rows),
    "support_efficiency_parameter_rules" =>
        support_efficiency_parameter_rules(support_efficiency_rows),
    "distributional_activity_strategy_summary" =>
        country_distribution_summary(comparison_rows, COUNTRY_ACTIVITY_SPECS,
            :country_activity_output; group_by = :strategy),
    "distributional_factor_strategy_summary" =>
        country_distribution_summary(comparison_rows, COUNTRY_FACTOR_SPECS,
            :country_factor_use; group_by = :strategy),
    "distributional_activity_transmission_summary" =>
        country_distribution_summary(comparison_rows, COUNTRY_ACTIVITY_SPECS,
            :country_activity_output; group_by = :transmission),
    "distributional_factor_transmission_summary" =>
        country_distribution_summary(comparison_rows, COUNTRY_FACTOR_SPECS,
            :country_factor_use; group_by = :transmission),
    "policy_region_claim_candidates" =>
        claim_candidate_rows(run_summary, comparison_rows, threshold_rows, support_efficiency_rows),
)

for name in sort(collect(keys(outputs)))
    rows = outputs[name]
    isempty(rows) && continue
    write_rows_csv(joinpath(ANALYTICS_DIR, "$(name).csv"), rows)
end

println("Wrote two-country analytics to $(ANALYTICS_DIR)")
println("Comparison rows: $(length(comparison_rows))")
println("Threshold rows: $(length(threshold_rows))")
println("Support-efficiency rows: $(length(support_efficiency_rows))")
