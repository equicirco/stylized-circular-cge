using StylizedCircularCGE

output_dir = joinpath(@__DIR__, "..", "outputs")
mkpath(output_dir)
execution_kwargs = experiment_execution_kwargs()

group_fields = [:sigma_routes, :sigma_metal, :metal_quality]

specs = parameter_policy_grid(;
    policy_kind = :route,
    policy_target = :REF,
    tau = [-0.50, -0.25, -0.10, 0.0, 0.10, 0.25],
    sigma_routes = [1.25, 2.0, 3.0],
    sigma_metal = [1.25, 2.0],
    metal_quality = [0.75, 0.90],
    prefix = "refurbishment-frontier",
)

results = run_grid(specs; closure = :planner, execution_kwargs...)
comparison = compare_to_group_reference(results, group_fields;
    reference_filter = row -> row.tau_route_ref == 0.0)
summary = summarize_comparison(comparison)
frontier = material_saving_frontier(comparison, :tau_route_ref;
    group_by = group_fields,
    allow_rebound = false)
sensitivity = sensitivity_screen(comparison, :pct_virgin_use,
    [:tau_route_ref, :sigma_routes, :sigma_metal, :metal_quality])

write_rows_csv(joinpath(output_dir, "refurbishment_frontier.csv"), result_rows(results))
write_rows_csv(joinpath(output_dir, "refurbishment_frontier_comparison.csv"), comparison)
write_rows_csv(joinpath(output_dir, "refurbishment_frontier_summary.csv"), [summary_row(summary)])
write_rows_csv(joinpath(output_dir, "refurbishment_frontier_sensitivity.csv"), sensitivity)
if !isempty(frontier)
    write_rows_csv(joinpath(output_dir, "refurbishment_frontier_thresholds.csv"), frontier)
end

println("Ran $(length(results)) planner policy-frontier experiments")
println("Compared each policy row against the zero-policy row with matching parameters")
println("Regimes: $(summary.regimes)")
println("Sensitivity screen for pct_virgin_use:")
for row in sensitivity
    println("  $(row.parameter): range=$(row.effect_range), levels=$(row.levels)")
end
println("Frontier rows without rebound: $(length(frontier))")
for row in frontier
    println(
        "  sigma_routes=$(row.sigma_routes), sigma_metal=$(row.sigma_metal), " *
        "metal_quality=$(row.metal_quality): tau_route_ref=$(row.tau_route_ref), " *
        "pct_virgin_use=$(row.pct_virgin_use), pct_toaster_service=$(row.pct_toaster_service)",
    )
end
