using CSV
using Statistics

const ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const GENERATED_DIR = joinpath(ROOT, "results", "single_country", "generated")
const ANALYTICS_DIR = joinpath(ROOT, "results", "single_country", "analytics")

mkpath(ANALYTICS_DIR)

function read_rows(filename::AbstractString)
    path = joinpath(GENERATED_DIR, filename)
    isfile(path) || error("Missing generated input: $(path)")
    return collect(CSV.File(path; normalizenames = true))
end

as_string(value) = ismissing(value) ? "" : string(value)
as_float(value) = ismissing(value) ? NaN : Float64(value)
as_int(value) = ismissing(value) ? 0 : Int(value)

function share_pct(value)
    isfinite(Float64(value)) || return "not available"
    return "$(round(100 * Float64(value); digits = 1))%"
end

function rows_for(rows, field::Symbol, value::AbstractString)
    return [row for row in rows if as_string(getproperty(row, field)) == value]
end

function row_count(summary_rows, dimension::AbstractString, value::AbstractString)
    matches = [
        row for row in summary_rows
        if as_string(row.dimension) == dimension && as_string(row.value) == value
    ]
    isempty(matches) && return 0
    return as_int(first(matches).count)
end

function row_share(summary_rows, dimension::AbstractString, value::AbstractString)
    matches = [
        row for row in summary_rows
        if as_string(row.dimension) == dimension && as_string(row.value) == value
    ]
    isempty(matches) && return NaN
    return as_float(first(matches).share)
end

function finite_mean(rows, field::Symbol)
    values = [as_float(getproperty(row, field)) for row in rows]
    finite = filter(isfinite, values)
    isempty(finite) && return NaN
    return mean(finite)
end

function count_by(rows, field::Symbol)
    counts = Dict{String,Int}()
    for row in rows
        key = as_string(getproperty(row, field))
        counts[key] = get(counts, key, 0) + 1
    end
    return counts
end

function top_count(counts::Dict{String,Int})
    isempty(counts) && return ("none", 0)
    ordered = sort(collect(counts); by = pair -> (-pair.second, pair.first))
    first(ordered)
end

function write_notes(path, run_summary, family_summary, within_summary,
    family_map, within_map, support_efficiency)
    run = first(run_summary)
    total_groups = as_int(run.parameter_groups)
    life_only = row_count(family_summary, "region", "life_extension_only")
    all_available = row_count(family_summary, "region", "all_available")
    linear_life = row_count(family_summary, "region", "linear_and_life_extension")
    none_available = row_count(family_summary, "region", "none_available")
    best_route_counts = count_by(
        [row for row in within_map if as_string(row.best_support_efficiency_route) != "none"],
        :best_support_efficiency_route)
    top_eff_route, top_eff_count = top_count(best_route_counts)

    open(path, "w") do io
        println(io, "# Nested EOL Policy Analysis")
        println(io)
        println(io, "Grid mode: $(as_string(run.grid_mode))")
        println(io, "Parameter groups: $(total_groups)")
        println(io)
        println(io, "## Family-Level Comparison")
        println(io)
        println(io, "- Life extension only: $(life_only) groups ($(share_pct(life_only / total_groups))).")
        println(io, "- Linear and life extension: $(linear_life) groups ($(share_pct(linear_life / total_groups))).")
        println(io, "- All three families available: $(all_available) groups ($(share_pct(all_available / total_groups))).")
        println(io, "- No tested family available: $(none_available) groups ($(share_pct(none_available / total_groups))).")
        println(io, "- Life-extension family thresholds: $(as_int(run.life_extension_family_thresholds)).")
        println(io, "- Recycling thresholds: $(as_int(run.recycling_thresholds)).")
        println(io, "- Linear thresholds: $(as_int(run.linear_thresholds)).")
        println(io)
        println(io, "## Within Life Extension")
        println(io)
        for route in ("REF", "REP", "REU", "tie", "none")
            count = row_count(within_summary, "weakest_support_route", route)
            count == 0 && continue
            println(io, "- Weakest support route $(route): $(count) groups ($(share_pct(count / total_groups))).")
        end
        println(io, "- Best support-efficiency route among non-empty groups: $(top_eff_route) ($(top_eff_count) groups).")
        println(io)
        println(io, "## Interpretation")
        println(io)
        println(io, "The nested analysis separates two questions. The first is whether the life-extension family is a viable material-saving strategy relative to linear virgin-metal taxation and recycling support. The second is which life-extension route drives that result. In this grid, life-extension availability is not equivalent to refurbishment availability: reuse and ties across routes explain a large share of the family-level result. Recycling remains conceptually distinct because it acts through virgin--recycled metal substitution rather than product-service route substitution.")
        println(io)
        println(io, "These statements are conditional on the selected grid mode. The route grid is the appropriate mode when the question is how route-specific yields and metal intensities change the within-family ranking.")
    end
end

run_summary = read_rows("nested_eol_run_summary.csv")
family_summary = read_rows("nested_eol_family_region_summary.csv")
within_summary = read_rows("nested_eol_within_route_summary.csv")
family_map = read_rows("nested_eol_family_region_map.csv")
within_map = read_rows("nested_eol_within_route_map.csv")
support_efficiency = read_rows("nested_eol_support_efficiency.csv")

headline_rows = [
    (metric = "parameter_groups", value = as_float(first(run_summary).parameter_groups)),
    (metric = "life_extension_only_groups",
        value = row_count(family_summary, "region", "life_extension_only")),
    (metric = "all_available_groups",
        value = row_count(family_summary, "region", "all_available")),
    (metric = "no_family_available_groups",
        value = row_count(family_summary, "region", "none_available")),
    (metric = "mean_family_life_extension_threshold",
        value = finite_mean(rows_for(family_map, :life_extension_available, "true"),
            :life_extension_threshold_magnitude)),
    (metric = "mean_recycling_threshold",
        value = finite_mean(rows_for(family_map, :recycling_available, "true"),
            :recycling_threshold_magnitude)),
]

CSV.write(joinpath(ANALYTICS_DIR, "nested_eol_policy_headlines.csv"), headline_rows)
write_notes(joinpath(ANALYTICS_DIR, "nested_eol_policy_notes.md"), run_summary,
    family_summary, within_summary, family_map, within_map, support_efficiency)

println("Wrote nested EOL analytics to $(ANALYTICS_DIR)")
