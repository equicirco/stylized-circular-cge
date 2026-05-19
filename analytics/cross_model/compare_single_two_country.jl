using CSV
using Statistics
using StylizedCircularCGE

const ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const SINGLE_GENERATED_DIR = joinpath(ROOT, "results", "single_country", "generated")
const TWO_GENERATED_DIR = joinpath(ROOT, "results", "two_country", "generated")
const TWO_ANALYTICS_DIR = joinpath(ROOT, "results", "two_country", "analytics")
const OUTPUT_DIR = joinpath(ROOT, "results", "cross_model", "analytics")

mkpath(OUTPUT_DIR)

const STRATEGY_FILES = (
    (strategy = :virgin_material_tax, file = "fiscal_parameter_region_tax_results.csv"),
    (strategy = :refurbishment_support, file = "fiscal_parameter_region_refurbishment_results.csv"),
    (strategy = :recycling_support, file = "fiscal_parameter_region_recycling_results.csv"),
)

const STRATEGIES = (:virgin_material_tax, :refurbishment_support, :recycling_support)
const PARAMETER_FIELDS = (
    :sigma_routes,
    :sigma_metal,
    :sigma_eol,
    :eta_service,
    :metal_quality,
    :metal_intensity_ref,
    :yield_ref,
)

const MARKET_TOL = 1.0e-5

function read_rows(dir::AbstractString, filename::AbstractString)
    path = joinpath(dir, filename)
    isfile(path) || error("Missing input: $(path)")
    return collect(CSV.File(path; normalizenames = true))
end

as_string(value) = ismissing(value) ? "" : string(value)
as_float(value) = ismissing(value) ? NaN : Float64(value)
function as_bool(value)
    ismissing(value) && return false
    value isa Bool && return value
    return lowercase(strip(string(value))) in ("true", "1", "yes")
end

function share(count, total)
    total == 0 && return NaN
    return count / total
end

function finite_values(rows, field::Symbol)
    return filter(isfinite, [as_float(getproperty(row, field)) for row in rows
        if hasproperty(row, field)])
end

function finite_mean(rows, field::Symbol)
    values = finite_values(rows, field)
    isempty(values) && return NaN
    return mean(values)
end

function finite_max(rows, field::Symbol)
    values = finite_values(rows, field)
    isempty(values) && return NaN
    return maximum(values)
end

function count_by_string(rows, field::Symbol)
    counts = Dict{String,Int}()
    for row in rows
        key = as_string(getproperty(row, field))
        counts[key] = get(counts, key, 0) + 1
    end
    return counts
end

function dominant_count(counts::Dict{String,Int})
    isempty(counts) && return ("none", 0)
    ordered = sort(collect(counts); by = pair -> (-pair.second, pair.first))
    pair = first(ordered)
    return (pair.first, pair.second)
end

function rows_for_strategy(rows, strategy::Symbol)
    return [row for row in rows if Symbol(as_string(row.strategy)) === strategy]
end

function is_valid_raw_row(row, model::Symbol)
    expected_closure = model === :single_country ? "fiscal" : "two_country_fiscal"
    return as_string(row.status) == "LOCALLY_SOLVED" &&
           as_string(row.closure) == expected_closure &&
           as_float(row.max_abs_market_residual) <= MARKET_TOL
end

function model_generated_dir(model::Symbol)
    model === :single_country && return SINGLE_GENERATED_DIR
    model === :two_country && return TWO_GENERATED_DIR
    error("Unknown model $(model)")
end

function comparison_rows(model::Symbol)
    return read_rows(model_generated_dir(model), "fiscal_parameter_regions.csv")
end

function threshold_rows(model::Symbol)
    return read_rows(model_generated_dir(model), "fiscal_parameter_region_thresholds.csv")
end

function coverage_rows(model::Symbol)
    return read_rows(model_generated_dir(model), "fiscal_parameter_region_coverage.csv")
end

function status_rows(model::Symbol)
    return read_rows(model_generated_dir(model), "fiscal_parameter_region_status.csv")
end

function raw_strategy_rows(model::Symbol, strategy::Symbol)
    spec = only(filter(s -> s.strategy === strategy, STRATEGY_FILES))
    return read_rows(model_generated_dir(model), spec.file)
end

function strategy_model_summary(model::Symbol, rows, thresholds)
    out = NamedTuple[]
    for strategy in STRATEGIES
        subset = rows_for_strategy(rows, strategy)
        threshold_subset = rows_for_strategy(thresholds, strategy)
        isempty(subset) && continue
        mechanisms = count_by_string(subset, :mechanism)
        dominant_mechanism, dominant_mechanism_count = dominant_count(mechanisms)
        transmission =
            if model === :two_country
                counts = count_by_string(subset, :transmission)
                dominant, n = dominant_count(counts)
                (dominant = dominant, count = n)
            else
                (dominant = "", count = 0)
            end
        push!(out, (
            model = model,
            strategy = strategy,
            comparison_rows = length(subset),
            threshold_rows = length(threshold_subset),
            threshold_share_of_parameter_groups = length(threshold_subset) / 2187,
            material_saving_share =
                count(row -> as_bool(row.material_saving), subset) / length(subset),
            material_saving_without_rebound_share =
                count(row -> as_bool(row.material_saving) && !as_bool(row.rebound), subset) /
                length(subset),
            rebound_share = count(row -> as_bool(row.rebound), subset) / length(subset),
            mean_pct_virgin_use = finite_mean(subset, :pct_virgin_use),
            mean_pct_toaster_service = finite_mean(subset, :pct_toaster_service),
            mean_government_net = finite_mean(subset, :government_net),
            mean_support_cost = finite_mean(subset, :support_cost),
            mean_virgin_saving_per_support_dollar =
                finite_mean(subset, :virgin_saving_per_support_dollar),
            max_virgin_saving_per_support_dollar =
                finite_max(subset, :virgin_saving_per_support_dollar),
            dominant_mechanism = dominant_mechanism,
            dominant_mechanism_count = dominant_mechanism_count,
            dominant_mechanism_share = dominant_mechanism_count / length(subset),
            dominant_transmission = transmission.dominant,
            dominant_transmission_count = transmission.count,
            dominant_transmission_share =
                model === :two_country ? transmission.count / length(subset) : NaN,
            mean_upstream_output_reduction_m =
                model === :two_country ? finite_mean(subset, :upstream_output_reduction_m) : NaN,
            mean_circular_activity_gain_c =
                model === :two_country ? finite_mean(subset, :circular_activity_gain_c) : NaN,
        ))
    end
    return out
end

function _lookup_by_strategy(rows)
    return Dict(row.strategy => row for row in rows)
end

function strategy_model_difference(single_summary, two_summary)
    single = _lookup_by_strategy(single_summary)
    two = _lookup_by_strategy(two_summary)
    out = NamedTuple[]
    for strategy in STRATEGIES
        haskey(single, strategy) && haskey(two, strategy) || continue
        s = single[strategy]
        t = two[strategy]
        push!(out, (
            strategy = strategy,
            delta_comparison_rows = t.comparison_rows - s.comparison_rows,
            delta_threshold_rows = t.threshold_rows - s.threshold_rows,
            delta_material_saving_share =
                t.material_saving_share - s.material_saving_share,
            delta_material_saving_without_rebound_share =
                t.material_saving_without_rebound_share -
                s.material_saving_without_rebound_share,
            delta_rebound_share = t.rebound_share - s.rebound_share,
            delta_mean_pct_virgin_use =
                t.mean_pct_virgin_use - s.mean_pct_virgin_use,
            delta_mean_pct_toaster_service =
                t.mean_pct_toaster_service - s.mean_pct_toaster_service,
            delta_mean_government_net =
                t.mean_government_net - s.mean_government_net,
            single_dominant_mechanism = s.dominant_mechanism,
            two_country_dominant_mechanism = t.dominant_mechanism,
            two_country_dominant_transmission = t.dominant_transmission,
            two_country_mean_upstream_output_reduction_m =
                t.mean_upstream_output_reduction_m,
            two_country_mean_circular_activity_gain_c =
                t.mean_circular_activity_gain_c,
        ))
    end
    return out
end

function coverage_comparison()
    out = NamedTuple[]
    for model in (:single_country, :two_country)
        for row in coverage_rows(model)
            push!(out, (
                model = model,
                strategy = Symbol(as_string(row.strategy)),
                records = Int(row.records),
                parameter_groups = Int(row.parameter_groups),
                valid_records = Int(row.valid_records),
                invalid_records = Int(row.invalid_records),
                valid_share = Int(row.valid_records) / Int(row.records),
                comparable_records = Int(row.comparable_records),
                comparable_groups = Int(row.comparable_groups),
                comparable_share = Int(row.comparable_records) / Int(row.records),
                max_abs_market_residual = as_float(row.max_abs_market_residual),
            ))
        end
    end
    return out
end

function status_comparison()
    out = NamedTuple[]
    for model in (:single_country, :two_country)
        for row in status_rows(model)
            push!(out, (
                model = model,
                strategy = Symbol(as_string(row.strategy)),
                status = as_string(row.status),
                count = Int(row.count),
                max_abs_market_residual = as_float(row.max_abs_market_residual),
            ))
        end
    end
    return out
end

function level_values(rows, field::Symbol)
    return sort(unique(as_float(getproperty(row, field)) for row in rows
        if !ismissing(getproperty(row, field))))
end

function invalid_parameter_patterns()
    out = NamedTuple[]
    for model in (:single_country, :two_country)
        for strategy in STRATEGIES
            rows = raw_strategy_rows(model, strategy)
            for parameter in PARAMETER_FIELDS
                for level in level_values(rows, parameter)
                    subset = [row for row in rows if as_float(getproperty(row, parameter)) == level]
                    invalid = [row for row in subset if !is_valid_raw_row(row, model)]
                    isempty(subset) && continue
                    statuses = count_by_string(invalid, :status)
                    dominant_status, dominant_status_count = dominant_count(statuses)
                    push!(out, (
                        model = model,
                        strategy = strategy,
                        parameter = parameter,
                        level = level,
                        records = length(subset),
                        invalid_records = length(invalid),
                        invalid_share = length(invalid) / length(subset),
                        dominant_invalid_status = dominant_status,
                        dominant_invalid_status_count = dominant_status_count,
                        max_invalid_market_residual =
                            isempty(invalid) ? 0.0 :
                            maximum(as_float(row.max_abs_market_residual) for row in invalid),
                    ))
                end
            end
        end
    end
    return out
end

function support_efficiency_comparison()
    rows = NamedTuple[]
    single_path = joinpath(SINGLE_GENERATED_DIR,
        "fiscal_parameter_region_support_efficiency_summary.csv")
    two_path = joinpath(TWO_GENERATED_DIR,
        "fiscal_parameter_region_support_efficiency_summary.csv")
    for (model, path) in ((:single_country, single_path), (:two_country, two_path))
        isfile(path) || continue
        for row in CSV.File(path; normalizenames = true)
            push!(rows, (
                model = model,
                strategy = Symbol(as_string(row.strategy)),
                count = Int(row.count),
                share = as_float(row.share),
                mean_policy_magnitude = as_float(row.mean_policy_magnitude),
                mean_support_cost = as_float(row.mean_support_cost),
                mean_virgin_saving = as_float(row.mean_virgin_saving),
                mean_virgin_saving_per_support_dollar =
                    as_float(row.mean_virgin_saving_per_support_dollar),
                mean_service_loss_per_support_dollar =
                    as_float(row.mean_service_loss_per_support_dollar),
                mean_upstream_output_reduction_m =
                    hasproperty(row, :mean_upstream_output_reduction_m) ?
                    as_float(row.mean_upstream_output_reduction_m) : NaN,
                mean_circular_activity_gain_c =
                    hasproperty(row, :mean_circular_activity_gain_c) ?
                    as_float(row.mean_circular_activity_gain_c) : NaN,
            ))
        end
    end
    return rows
end

function claim_candidates(single_summary, two_summary, differences, coverage)
    out = NamedTuple[]
    push!(out, (
        claim = "Both model branches have broad full-grid coverage after filtering.",
        evidence_metric = "minimum_comparable_share",
        value = minimum(row.comparable_share for row in coverage),
        note = "Non-comparable rows are retained in status/coverage diagnostics and excluded from comparison rows.",
    ))
    for row in differences
        push!(out, (
            claim = "Adding the upstream country changes $(row.strategy) material-saving frequency by $(round(100 * row.delta_material_saving_share; digits = 2)) percentage points.",
            evidence_metric = "delta_material_saving_share",
            value = row.delta_material_saving_share,
            note = "Difference is two-country minus single-country over comparable rows.",
        ))
    end
    for row in two_summary
        push!(out, (
            claim = "In the two-country model, $(row.strategy) is dominated by $(row.dominant_transmission) transmission.",
            evidence_metric = "dominant_transmission_share",
            value = row.dominant_transmission_share,
            note = "Transmission is through fixed virgin-material supply from M, not relocation.",
        ))
    end
    return out
end

single_comparison = comparison_rows(:single_country)
two_comparison = comparison_rows(:two_country)
single_thresholds = threshold_rows(:single_country)
two_thresholds = threshold_rows(:two_country)

single_summary = strategy_model_summary(:single_country, single_comparison, single_thresholds)
two_summary = strategy_model_summary(:two_country, two_comparison, two_thresholds)
model_summary = vcat(single_summary, two_summary)
differences = strategy_model_difference(single_summary, two_summary)
coverage = coverage_comparison()

outputs = Dict(
    "strategy_model_summary" => model_summary,
    "strategy_model_difference" => differences,
    "coverage_comparison" => coverage,
    "status_comparison" => status_comparison(),
    "invalid_parameter_patterns" => invalid_parameter_patterns(),
    "support_efficiency_comparison" => support_efficiency_comparison(),
    "claim_candidates" => claim_candidates(single_summary, two_summary, differences, coverage),
)

for name in sort(collect(keys(outputs)))
    rows = outputs[name]
    isempty(rows) && continue
    write_rows_csv(joinpath(OUTPUT_DIR, "$(name).csv"), rows)
end

println("Wrote cross-model analytics to $(OUTPUT_DIR)")
println("Single-country comparison rows: $(length(single_comparison))")
println("Two-country comparison rows: $(length(two_comparison))")
