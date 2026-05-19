"""
    write_two_country_experiment_bundle(output_dir, records; reference=nothing, basename="two_country")

Write two-country result rows and, when a reference is supplied, comparison and
summary CSVs.
"""
function write_two_country_experiment_bundle(output_dir::AbstractString,
    records::AbstractVector{<:NamedTuple};
    reference::Union{Nothing,NamedTuple} = nothing,
    basename::AbstractString = "two_country")
    mkpath(output_dir)
    results_path = write_rows_csv(joinpath(output_dir, "$(basename).csv"),
        two_country_result_rows(records))
    reference === nothing && return (results = results_path,)

    comparison = compare_two_country_to_reference(records, reference)
    comparison_path = write_rows_csv(joinpath(output_dir, "$(basename)_comparison.csv"),
        comparison)
    summary_path = write_rows_csv(joinpath(output_dir, "$(basename)_summary.csv"),
        [two_country_summary_row(summarize_two_country_comparison(comparison))])
    return (
        results = results_path,
        comparison = comparison_path,
        summary = summary_path,
    )
end
