"""
    write_rows_csv(path, rows)

Write flattened result or comparison rows to CSV. Rows must be scalar
NamedTuples, such as the output of `result_rows` or `compare_to_reference`.
"""
function write_rows_csv(path::AbstractString, rows::AbstractVector{<:NamedTuple})
    return RuntimeExperiments.write_rows_csv(path, rows)
end

"""
    write_experiment_bundle(output_dir, records; reference=nothing, basename="experiment")

Write result rows and, when a reference is provided, comparison and summary CSVs.
"""
function write_experiment_bundle(output_dir::AbstractString,
    records::AbstractVector{<:NamedTuple};
    reference::Union{Nothing,NamedTuple} = nothing,
    basename::AbstractString = "experiment")
    mkpath(output_dir)
    results_path = write_rows_csv(joinpath(output_dir, "$(basename).csv"), result_rows(records))
    reference === nothing && return (results = results_path,)

    comparison = compare_to_reference(records, reference)
    comparison_path = write_rows_csv(joinpath(output_dir, "$(basename)_comparison.csv"), comparison)
    summary_path = write_rows_csv(joinpath(output_dir, "$(basename)_summary.csv"),
        [summary_row(summarize_comparison(comparison))])
    return (
        results = results_path,
        comparison = comparison_path,
        summary = summary_path,
    )
end
