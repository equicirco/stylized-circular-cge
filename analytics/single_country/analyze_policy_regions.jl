using CSV
using Statistics
using StylizedCircularCGE

const ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const GENERATED_DIR = joinpath(ROOT, "results", "single_country", "generated")
const ANALYTICS_DIR = joinpath(ROOT, "results", "single_country", "analytics")

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

const SUPPORT_STRATEGIES = ("refurbishment_support", "recycling_support")
const POLICY_STRATEGIES = ("virgin_material_tax", "refurbishment_support", "recycling_support")

function read_rows(filename::AbstractString)
    path = joinpath(GENERATED_DIR, filename)
    isfile(path) || error("Missing generated input: $(path)")
    return collect(CSV.File(path; normalizenames = true))
end

as_string(value) = ismissing(value) ? "" : String(value)
as_float(value) = ismissing(value) ? NaN : Float64(value)
as_bool(value) = !ismissing(value) && Bool(value)

function finite_mean(rows, field::Symbol)
    values = [as_float(getproperty(row, field)) for row in rows]
    finite = filter(isfinite, values)
    isempty(finite) && return NaN
    return mean(finite)
end

function finite_max(rows, field::Symbol)
    values = [as_float(getproperty(row, field)) for row in rows]
    finite = filter(isfinite, values)
    isempty(finite) && return NaN
    return maximum(finite)
end

function count_where(rows, predicate)
    count(predicate, rows)
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
    return sort(unique(as_float(getproperty(row, field)) for row in rows if !ismissing(getproperty(row, field))))
end

function rows_at_level(rows, field::Symbol, level)
    return [row for row in rows if !ismissing(getproperty(row, field)) &&
            as_float(getproperty(row, field)) == Float64(level)]
end

function rows_for_strategy(rows, strategy::AbstractString)
    return [row for row in rows if as_string(row.strategy) == strategy]
end

function top_key(counts::Dict{String,Int})
    isempty(counts) && return ("none", 0)
    ordered = sort(collect(counts); by = pair -> (-pair.second, pair.first))
    return first(ordered)
end

function share(count, total)
    total == 0 && return NaN
    return count / total
end

function finite_values(rows, field::Symbol)
    return filter(isfinite, [as_float(getproperty(row, field)) for row in rows])
end

function finite_min(rows, field::Symbol)
    values = finite_values(rows, field)
    isempty(values) && return NaN
    return minimum(values)
end

function bool_share(rows, field::Symbol)
    isempty(rows) && return NaN
    return count_where(rows, row -> as_bool(getproperty(row, field))) / length(rows)
end

function policy_rows(rows)
    return [row for row in rows if as_float(row.policy_magnitude) > 1.0e-10]
end

function fmt_share(value)
    isfinite(value) || return "not available"
    return "$(round(100.0 * value; digits = 1))%"
end

function strategy_count_string(counts)
    parts = ["$(key)=$(counts[key])" for key in sort(collect(keys(counts)))]
    return join(parts, "; ")
end

function headline_rows(run_summary, region_rows, support_efficiency_rows)
    run = first(run_summary)
    total_groups = Int(run.parameter_groups)
    support_counts = count_by_string(support_efficiency_rows, :strategy)
    region_counts = count_by_string(region_rows, :region)
    quality_counts = count_by_string(region_rows, :region_quality)

    rows = NamedTuple[]
    function push_metric!(metric, count; denominator = total_groups)
        push!(rows, (
            metric = metric,
            count = Int(count),
            share = share(Int(count), Int(denominator)),
        ))
    end

    push_metric!("parameter_groups", total_groups)
    push_metric!("complete_region_groups", get(quality_counts, "complete", 0))
    push_metric!("partial_or_missing_region_groups", total_groups - get(quality_counts, "complete", 0))
    push_metric!("tax_threshold_groups", Int(run.tax_thresholds))
    push_metric!("refurbishment_threshold_groups", Int(run.support_thresholds))
    push_metric!("recycling_threshold_groups", Int(run.recycling_thresholds))
    push_metric!("support_efficiency_candidate_groups", length(support_efficiency_rows))
    push_metric!("support_efficiency_refurbishment_best",
        get(support_counts, "refurbishment_support", 0);
        denominator = max(length(support_efficiency_rows), 1))
    push_metric!("support_efficiency_recycling_best",
        get(support_counts, "recycling_support", 0);
        denominator = max(length(support_efficiency_rows), 1))
    for region in sort(collect(keys(region_counts)))
        push_metric!("region_$(region)", region_counts[region])
    end
    return rows
end

function support_strategy_summary(region_rows, support_efficiency_rows)
    total_groups = length(region_rows)
    candidate_groups = length(support_efficiency_rows)
    return [
        begin
            subset = rows_for_strategy(support_efficiency_rows, strategy)
            (
                strategy = strategy,
                count = length(subset),
                share_of_support_candidates = share(length(subset), candidate_groups),
                share_of_all_parameter_groups = share(length(subset), total_groups),
                mean_policy_magnitude = finite_mean(subset, :policy_magnitude),
                mean_support_cost = finite_mean(subset, :support_cost),
                mean_virgin_saving = finite_mean(subset, :virgin_saving),
                mean_virgin_saving_per_support_dollar =
                    finite_mean(subset, :virgin_saving_per_support_dollar),
                max_virgin_saving_per_support_dollar =
                    finite_max(subset, :virgin_saving_per_support_dollar),
                mean_service_loss_per_support_dollar =
                    finite_mean(subset, :service_loss_per_support_dollar),
                mean_pct_virgin_use = finite_mean(subset, :pct_virgin_use),
                mean_pct_toaster_service = finite_mean(subset, :pct_toaster_service),
            )
        end
        for strategy in SUPPORT_STRATEGIES
    ]
end

function support_parameter_rules(region_rows, support_efficiency_rows)
    out = NamedTuple[]
    for parameter in PARAMETER_FIELDS
        for level in level_values(region_rows, parameter)
            all_level = rows_at_level(region_rows, parameter, level)
            support_level = rows_at_level(support_efficiency_rows, parameter, level)
            counts = count_by_string(support_level, :strategy)
            dominant, dominant_count = top_key(counts)
            dominant_rows = dominant == "none" ? [] : rows_for_strategy(support_level, dominant)
            candidate_count = length(support_level)
            push!(out, (
                parameter = String(parameter),
                level = Float64(level),
                total_groups = length(all_level),
                candidate_groups = candidate_count,
                candidate_share_of_level = share(candidate_count, length(all_level)),
                dominant_strategy = dominant,
                dominant_count = dominant_count,
                dominant_share_of_candidates = share(dominant_count, candidate_count),
                refurbishment_count = get(counts, "refurbishment_support", 0),
                refurbishment_share_of_candidates =
                    share(get(counts, "refurbishment_support", 0), candidate_count),
                recycling_count = get(counts, "recycling_support", 0),
                recycling_share_of_candidates =
                    share(get(counts, "recycling_support", 0), candidate_count),
                dominant_mean_virgin_saving_per_support_dollar =
                    finite_mean(dominant_rows, :virgin_saving_per_support_dollar),
                dominant_mean_service_loss_per_support_dollar =
                    finite_mean(dominant_rows, :service_loss_per_support_dollar),
                dominant_mean_pct_toaster_service =
                    finite_mean(dominant_rows, :pct_toaster_service),
            ))
        end
    end
    return out
end

function support_eol_service_rules(region_rows, support_efficiency_rows)
    out = NamedTuple[]
    for sigma_eol in level_values(region_rows, :sigma_eol)
        for eta_service in level_values(region_rows, :eta_service)
            all_cell = [
                row for row in region_rows
                if as_float(row.sigma_eol) == sigma_eol &&
                   as_float(row.eta_service) == eta_service
            ]
            support_cell = [
                row for row in support_efficiency_rows
                if as_float(row.sigma_eol) == sigma_eol &&
                   as_float(row.eta_service) == eta_service
            ]
            counts = count_by_string(support_cell, :strategy)
            dominant, dominant_count = top_key(counts)
            dominant_rows = dominant == "none" ? [] : rows_for_strategy(support_cell, dominant)
            candidate_count = length(support_cell)
            push!(out, (
                sigma_eol = sigma_eol,
                eta_service = eta_service,
                total_groups = length(all_cell),
                candidate_groups = candidate_count,
                candidate_share_of_cell = share(candidate_count, length(all_cell)),
                dominant_strategy = dominant,
                dominant_count = dominant_count,
                dominant_share_of_candidates = share(dominant_count, candidate_count),
                refurbishment_count = get(counts, "refurbishment_support", 0),
                recycling_count = get(counts, "recycling_support", 0),
                dominant_mean_virgin_saving_per_support_dollar =
                    finite_mean(dominant_rows, :virgin_saving_per_support_dollar),
                dominant_mean_service_loss_per_support_dollar =
                    finite_mean(dominant_rows, :service_loss_per_support_dollar),
            ))
        end
    end
    return out
end

function policy_region_parameter_rules(region_rows)
    out = NamedTuple[]
    for parameter in PARAMETER_FIELDS
        for level in level_values(region_rows, parameter)
            subset = rows_at_level(region_rows, parameter, level)
            region_counts = count_by_string(subset, :region)
            top_region, top_region_count = top_key(region_counts)
            total = length(subset)
            push!(out, (
                parameter = String(parameter),
                level = Float64(level),
                total_groups = total,
                complete_groups = count_where(subset, row -> as_string(row.region_quality) == "complete"),
                top_region = top_region,
                top_region_count = top_region_count,
                top_region_share = share(top_region_count, total),
                tax_available_share = share(count_where(subset, row -> as_bool(row.tax_available)), total),
                refurbishment_available_share =
                    share(count_where(subset, row -> as_bool(row.support_available)), total),
                recycling_available_share =
                    share(count_where(subset, row -> as_bool(row.recycling_available)), total),
                all_available_share =
                    share(get(region_counts, "all_available", 0), total),
                none_available_share =
                    share(get(region_counts, "none_available", 0), total),
            ))
        end
    end
    return out
end

function mechanism_strategy_summary(comparison_rows)
    out = NamedTuple[]
    strategies = sort(collect(keys(count_by_string(comparison_rows, :strategy))))
    for strategy in strategies
        strategy_rows = rows_for_strategy(comparison_rows, strategy)
        total = length(strategy_rows)
        mechanisms = sort(collect(keys(count_by_string(strategy_rows, :mechanism))))
        for mechanism in mechanisms
            subset = [row for row in strategy_rows if as_string(row.mechanism) == mechanism]
            push!(out, (
                strategy = strategy,
                mechanism = mechanism,
                count = length(subset),
                share_within_strategy = share(length(subset), total),
                material_saving_share = share(count_where(subset, row -> as_bool(row.material_saving)),
                    length(subset)),
                rebound_share = share(count_where(subset, row -> as_bool(row.rebound)),
                    length(subset)),
                mean_pct_virgin_use = finite_mean(subset, :pct_virgin_use),
                mean_pct_toaster_service = finite_mean(subset, :pct_toaster_service),
                mean_virgin_saving_per_support_dollar =
                    finite_mean(subset, :virgin_saving_per_support_dollar),
            ))
        end
    end
    return out
end

function support_efficiency_claim_candidates(region_rows, support_efficiency_rows)
    out = NamedTuple[]
    total_groups = length(region_rows)
    support_counts = count_by_string(support_efficiency_rows, :strategy)
    for strategy in SUPPORT_STRATEGIES
        count = get(support_counts, strategy, 0)
        share_of_candidates = share(count, length(support_efficiency_rows))
        subset = rows_for_strategy(support_efficiency_rows, strategy)
        push!(out, (
            claim_group = "support_efficiency_overall",
            condition = "all support-efficient groups",
            claim = "$(strategy) is best in $(fmt_share(share_of_candidates)) of support-efficient groups",
            evidence_count = count,
            evidence_total = length(support_efficiency_rows),
            evidence_share = share_of_candidates,
            strategy = strategy,
            region = "",
            mean_virgin_saving_per_support_dollar =
                finite_mean(subset, :virgin_saving_per_support_dollar),
            mean_service_loss_per_support_dollar =
                finite_mean(subset, :service_loss_per_support_dollar),
            mean_pct_virgin_use = finite_mean(subset, :pct_virgin_use),
            mean_pct_toaster_service = finite_mean(subset, :pct_toaster_service),
        ))
    end

    for row in support_parameter_rules(region_rows, support_efficiency_rows)
        row.candidate_groups == 0 && continue
        condition = "$(row.parameter)=$(row.level)"
        push!(out, (
            claim_group = "support_efficiency_parameter_level",
            condition = condition,
            claim = "$(row.dominant_strategy) is the most frequent support-efficient strategy when $(condition)",
            evidence_count = row.dominant_count,
            evidence_total = row.candidate_groups,
            evidence_share = row.dominant_share_of_candidates,
            strategy = row.dominant_strategy,
            region = "",
            mean_virgin_saving_per_support_dollar =
                row.dominant_mean_virgin_saving_per_support_dollar,
            mean_service_loss_per_support_dollar =
                row.dominant_mean_service_loss_per_support_dollar,
            mean_pct_virgin_use = NaN,
            mean_pct_toaster_service = row.dominant_mean_pct_toaster_service,
        ))
    end

    for row in support_eol_service_rules(region_rows, support_efficiency_rows)
        row.candidate_groups == 0 && continue
        condition = "sigma_eol=$(row.sigma_eol), eta_service=$(row.eta_service)"
        push!(out, (
            claim_group = "support_efficiency_eol_service_cell",
            condition = condition,
            claim = "$(row.dominant_strategy) is the most frequent support-efficient strategy when $(condition)",
            evidence_count = row.dominant_count,
            evidence_total = row.candidate_groups,
            evidence_share = row.dominant_share_of_candidates,
            strategy = row.dominant_strategy,
            region = "",
            mean_virgin_saving_per_support_dollar =
                row.dominant_mean_virgin_saving_per_support_dollar,
            mean_service_loss_per_support_dollar =
                row.dominant_mean_service_loss_per_support_dollar,
            mean_pct_virgin_use = NaN,
            mean_pct_toaster_service = NaN,
        ))
    end

    for row in policy_region_parameter_rules(region_rows)
        condition = "$(row.parameter)=$(row.level)"
        push!(out, (
            claim_group = "policy_availability_parameter_level",
            condition = condition,
            claim = "$(row.top_region) is the most frequent availability region when $(condition)",
            evidence_count = row.top_region_count,
            evidence_total = row.total_groups,
            evidence_share = row.top_region_share,
            strategy = "",
            region = row.top_region,
            mean_virgin_saving_per_support_dollar = NaN,
            mean_service_loss_per_support_dollar = NaN,
            mean_pct_virgin_use = NaN,
            mean_pct_toaster_service = NaN,
        ))
    end

    push!(out, (
        claim_group = "coverage",
        condition = "full parameter grid",
        claim = "$(length(support_efficiency_rows)) of $(total_groups) parameter groups have a support-efficient material-saving policy without rebound",
        evidence_count = length(support_efficiency_rows),
        evidence_total = total_groups,
        evidence_share = share(length(support_efficiency_rows), total_groups),
        strategy = "",
        region = "",
        mean_virgin_saving_per_support_dollar = NaN,
        mean_service_loss_per_support_dollar = NaN,
        mean_pct_virgin_use = NaN,
        mean_pct_toaster_service = NaN,
    ))
    return out
end

function dominant_direction(expansion_share, contraction_share)
    if expansion_share >= contraction_share
        return ("expansion", expansion_share)
    end
    return ("contraction", contraction_share)
end

function distributional_activity_direction_rules(activity_rows)
    return [
        begin
            direction, direction_share =
                dominant_direction(as_float(row.expansion_share), as_float(row.contraction_share))
            (
                strategy = as_string(row.strategy),
                dimension = "activity_output",
                activity = as_string(row.activity),
                component = as_string(row.component),
                dominant_direction = direction,
                dominant_direction_share = direction_share,
                expansion_share = as_float(row.expansion_share),
                contraction_share = as_float(row.contraction_share),
                mean_delta_output = as_float(row.mean_delta_output),
                mean_pct_output = as_float(row.mean_pct_output),
                mean_delta_activity_share = as_float(row.mean_delta_activity_share),
                mean_delta_factor_use_share = as_float(row.mean_delta_factor_use_share),
                count = Int(row.count),
            )
        end
        for row in activity_rows
    ]
end

function distributional_factor_direction_rules(factor_rows)
    return [
        begin
            direction, direction_share =
                dominant_direction(as_float(row.expansion_share), as_float(row.contraction_share))
            (
                strategy = as_string(row.strategy),
                dimension = "factor_use",
                factor = as_string(row.factor),
                activity = as_string(row.activity),
                component = as_string(row.component),
                dominant_direction = direction,
                dominant_direction_share = direction_share,
                expansion_share = as_float(row.expansion_share),
                contraction_share = as_float(row.contraction_share),
                mean_delta_factor_use = as_float(row.mean_delta_factor_use),
                mean_pct_factor_use = as_float(row.mean_pct_factor_use),
                mean_delta_factor_allocation_share =
                    as_float(row.mean_delta_factor_allocation_share),
                count = Int(row.count),
            )
        end
        for row in factor_rows
    ]
end

function comparability_metric_definitions()
    return [
        (
            metric = "virgin_saving_per_support_dollar",
            applies_to = "refurbishment_support; recycling_support",
            role = "primary support-efficiency metric",
            interpretation = "material saving per unit of explicit subsidy outlay; compare together with service_loss_per_support_dollar",
        ),
        (
            metric = "virgin_saving_per_revenue_dollar",
            applies_to = "virgin_material_tax",
            role = "primary tax-efficiency metric",
            interpretation = "material saving per unit of fiscal revenue; not directly equivalent to a subsidy cost without a revenue-use assumption",
        ),
        (
            metric = "virgin_saving_per_fiscal_cost_dollar",
            applies_to = "support instruments with net fiscal cost",
            role = "cross-check for net-cost policies",
            interpretation = "same numerator as support efficiency, with net government cost in the denominator",
        ),
        (
            metric = "policy threshold without rebound",
            applies_to = "all instruments",
            role = "cross-instrument availability metric",
            interpretation = "smallest tested policy magnitude that reduces virgin material use without increasing service demand",
        ),
        (
            metric = "service_loss_per_support_dollar",
            applies_to = "refurbishment_support; recycling_support",
            role = "tradeoff diagnostic",
            interpretation = "service contraction per unit of subsidy outlay; used to distinguish circular substitution from demand contraction",
        ),
    ]
end

function strategy_comparability_summary(rows, scope::AbstractString)
    out = NamedTuple[]
    for strategy in POLICY_STRATEGIES
        subset = rows_for_strategy(rows, strategy)
        isempty(subset) && continue
        push!(out, (
            scope = scope,
            strategy = strategy,
            count = length(subset),
            material_saving_share =
                share(count_where(subset, row -> as_bool(row.material_saving)), length(subset)),
            rebound_share =
                share(count_where(subset, row -> as_bool(row.rebound)), length(subset)),
            mean_policy_magnitude = finite_mean(subset, :policy_magnitude),
            min_policy_magnitude = finite_min(subset, :policy_magnitude),
            mean_virgin_saving = finite_mean(subset, :virgin_saving),
            mean_pct_virgin_use = finite_mean(subset, :pct_virgin_use),
            mean_pct_toaster_service = finite_mean(subset, :pct_toaster_service),
            mean_support_cost = finite_mean(subset, :support_cost),
            mean_fiscal_cost = finite_mean(subset, :fiscal_cost),
            mean_revenue_gain = finite_mean(subset, :revenue_gain),
            mean_government_net = finite_mean(subset, :government_net),
            mean_virgin_saving_per_support_dollar =
                finite_mean(subset, :virgin_saving_per_support_dollar),
            mean_virgin_saving_per_fiscal_cost_dollar =
                finite_mean(subset, :virgin_saving_per_fiscal_cost_dollar),
            mean_virgin_saving_per_revenue_dollar =
                finite_mean(subset, :virgin_saving_per_revenue_dollar),
            mean_service_loss_per_support_dollar =
                finite_mean(subset, :service_loss_per_support_dollar),
        ))
    end
    return out
end

function comparability_summary(comparison_rows, threshold_rows, support_efficiency_rows)
    non_reference = policy_rows(comparison_rows)
    return vcat(
        strategy_comparability_summary(non_reference, "all_nonzero_policy_rows"),
        strategy_comparability_summary(threshold_rows, "first_material_saving_without_rebound_thresholds"),
        strategy_comparability_summary(support_efficiency_rows, "best_support_efficiency_groups"),
    )
end

function pairwise_comparability_summary(paired_rows)
    out = NamedTuple[]
    criteria = (
        :stronger_material_saving,
        :lower_service_loss,
        :higher_government_net,
        :higher_support_efficiency,
        :higher_fiscal_cost_efficiency,
        :higher_revenue_efficiency,
    )
    for pair in sort(collect(keys(count_by_string(paired_rows, :pair))))
        pair_rows = [row for row in paired_rows if as_string(row.pair) == pair]
        subsets = (
            (label = "all_pair_rows", rows = pair_rows),
            (label = "both_available", rows = [row for row in pair_rows
                                               if as_bool(row.left_available) &&
                                                  as_bool(row.right_available)]),
        )
        for subset in subsets
            isempty(subset.rows) && continue
            for criterion in criteria
                counts = count_by_string(subset.rows, criterion)
                for winner in sort(collect(keys(counts)))
                    push!(out, (
                        pair = pair,
                        subset = subset.label,
                        criterion = String(criterion),
                        winner = winner,
                        count = counts[winner],
                        share = share(counts[winner], length(subset.rows)),
                    ))
                end
            end
        end
    end
    return out
end

function parameter_group_support_rows(region_rows, support_efficiency_rows)
    support_by_key = Dict{Tuple,Any}()
    for row in support_efficiency_rows
        support_by_key[Tuple(as_float(getproperty(row, field)) for field in PARAMETER_FIELDS)] = row
    end
    return [
        begin
            key = Tuple(as_float(getproperty(row, field)) for field in PARAMETER_FIELDS)
            support = get(support_by_key, key, nothing)
            strategy = support === nothing ? "" : as_string(support.strategy)
            merge(
                NamedTuple{PARAMETER_FIELDS}(key),
                (
                    tax_available = as_bool(row.tax_available) ? 1.0 : 0.0,
                    refurbishment_available = as_bool(row.support_available) ? 1.0 : 0.0,
                    recycling_available = as_bool(row.recycling_available) ? 1.0 : 0.0,
                    multiple_available =
                        count((as_bool(row.tax_available), as_bool(row.support_available),
                            as_bool(row.recycling_available))) >= 2 ? 1.0 : 0.0,
                    none_available = as_string(row.region) == "none_available" ? 1.0 : 0.0,
                    support_efficiency_candidate = support === nothing ? 0.0 : 1.0,
                    refurbishment_support_best =
                        strategy == "refurbishment_support" ? 1.0 : 0.0,
                    recycling_support_best =
                        strategy == "recycling_support" ? 1.0 : 0.0,
                    support_virgin_saving_per_support_dollar =
                        support === nothing ? NaN :
                        as_float(support.virgin_saving_per_support_dollar),
                    support_service_loss_per_support_dollar =
                        support === nothing ? NaN :
                        as_float(support.service_loss_per_support_dollar),
                ),
            )
        end
        for row in region_rows
    ]
end

function row_numeric(row, field::Symbol)
    value = getproperty(row, field)
    ismissing(value) && return NaN
    value isa Bool && return value ? 1.0 : 0.0
    return Float64(value)
end

function parameter_sensitivity_rankings(rows, parameters, outcomes)
    raw = NamedTuple[]
    for outcome in outcomes
        for parameter in parameters
            levels = sort(collect(Set(row_numeric(row, parameter) for row in rows)))
            level_means = [
                begin
                    subset = [row for row in rows if row_numeric(row, parameter) == level]
                    values = filter(isfinite, [row_numeric(row, outcome) for row in subset])
                    (level = level, mean = isempty(values) ? NaN : mean(values))
                end
                for level in levels
            ]
            finite_levels = [row for row in level_means if isfinite(row.mean)]
            isempty(finite_levels) && continue
            means = [row.mean for row in finite_levels]
            min_index = argmin(means)
            max_index = argmax(means)
            push!(raw, (
                outcome = String(outcome),
                parameter = String(parameter),
                levels = length(finite_levels),
                mean_min = means[min_index],
                mean_min_level = finite_levels[min_index].level,
                mean_max = means[max_index],
                mean_max_level = finite_levels[max_index].level,
                effect_range = means[max_index] - means[min_index],
                abs_effect_range = abs(means[max_index] - means[min_index]),
            ))
        end
    end

    ranked = NamedTuple[]
    for outcome in sort(collect(Set(row.outcome for row in raw)))
        subset = sort([row for row in raw if row.outcome == outcome];
            by = row -> (-row.abs_effect_range, row.parameter))
        for (rank, row) in enumerate(subset)
            push!(ranked, merge((rank = rank,), row))
        end
    end
    return ranked
end

run_summary = read_rows("fiscal_parameter_region_run_summary.csv")
region_rows = read_rows("fiscal_parameter_region_map.csv")
comparison_rows = read_rows("fiscal_parameter_regions.csv")
support_efficiency_rows = read_rows("fiscal_parameter_region_support_efficiency.csv")
threshold_rows = read_rows("fiscal_parameter_region_thresholds.csv")
paired_threshold_rows = read_rows("fiscal_parameter_region_paired_thresholds.csv")

activity_strategy_summary =
    distributional_activity_summary(comparison_rows; group_by = [:strategy])
factor_strategy_summary =
    distributional_factor_summary(comparison_rows; group_by = [:strategy])
activity_support_efficiency_summary =
    distributional_activity_summary(support_efficiency_rows; group_by = [:strategy])
factor_support_efficiency_summary =
    distributional_factor_summary(support_efficiency_rows; group_by = [:strategy])
parameter_support_rows = parameter_group_support_rows(region_rows, support_efficiency_rows)

sensitivity_outcomes = (
    :tax_available,
    :refurbishment_available,
    :recycling_available,
    :multiple_available,
    :none_available,
    :support_efficiency_candidate,
    :refurbishment_support_best,
    :recycling_support_best,
    :support_virgin_saving_per_support_dollar,
    :support_service_loss_per_support_dollar,
)

outputs = (
    single_country_headline = headline_rows(run_summary, region_rows, support_efficiency_rows),
    policy_region_claim_candidates =
        support_efficiency_claim_candidates(region_rows, support_efficiency_rows),
    support_efficiency_strategy_summary =
        support_strategy_summary(region_rows, support_efficiency_rows),
    support_efficiency_parameter_rules =
        support_parameter_rules(region_rows, support_efficiency_rows),
    support_efficiency_eol_service_rules =
        support_eol_service_rules(region_rows, support_efficiency_rows),
    policy_region_parameter_rules =
        policy_region_parameter_rules(region_rows),
    mechanism_strategy_summary =
        mechanism_strategy_summary(comparison_rows),
    distributional_activity_strategy_summary = activity_strategy_summary,
    distributional_factor_strategy_summary = factor_strategy_summary,
    distributional_activity_support_efficiency_summary = activity_support_efficiency_summary,
    distributional_factor_support_efficiency_summary = factor_support_efficiency_summary,
    distributional_activity_direction_rules =
        distributional_activity_direction_rules(activity_strategy_summary),
    distributional_factor_direction_rules =
        distributional_factor_direction_rules(factor_strategy_summary),
    distributional_activity_support_efficiency_direction_rules =
        distributional_activity_direction_rules(activity_support_efficiency_summary),
    distributional_factor_support_efficiency_direction_rules =
        distributional_factor_direction_rules(factor_support_efficiency_summary),
    comparability_metric_definitions = comparability_metric_definitions(),
    comparability_strategy_summary =
        comparability_summary(comparison_rows, threshold_rows, support_efficiency_rows),
    comparability_pairwise_summary =
        pairwise_comparability_summary(paired_threshold_rows),
    parameter_sensitivity_rankings =
        parameter_sensitivity_rankings(parameter_support_rows, PARAMETER_FIELDS,
            sensitivity_outcomes),
)

for (name, rows) in pairs(outputs)
    write_rows_csv(joinpath(ANALYTICS_DIR, "$(name).csv"), rows)
end

println("Wrote single-country analytics to $(ANALYTICS_DIR)")
println("Support-efficiency candidate groups: $(length(support_efficiency_rows))")
for row in outputs.support_efficiency_strategy_summary
    println("  $(row.strategy): count=$(row.count), " *
            "share_of_candidates=$(row.share_of_support_candidates), " *
            "mean_saving_per_support=$(row.mean_virgin_saving_per_support_dollar)")
end
