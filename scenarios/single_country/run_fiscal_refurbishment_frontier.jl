using StylizedCircularCGE

output_dir = joinpath(@__DIR__, "..", "..", "results", "single_country", "generated")
mkpath(output_dir)
execution_kwargs = experiment_execution_kwargs()

group_fields = [:sigma_routes, :sigma_eol, :eta_service]

specs = parameter_policy_grid(;
    policy_kind = :route,
    policy_target = :REF,
    tau = [-0.50, -0.25, -0.10, 0.0],
    sigma_routes = [1.25, 2.0, 3.0],
    sigma_eol = [0.5, 2.0, 4.0],
    eta_service = [0.5, 1.0, 1.5],
    prefix = "fiscal-refurbishment-frontier",
)

results = run_grid(specs; closure = :fiscal, execution_kwargs...)
assert_closed_economy_results(results)
comparison = compare_to_group_reference(results, group_fields;
    reference_filter = row -> row.tau_route_ref == 0.0)
summary = summarize_comparison(comparison)
sensitivity = sensitivity_screen(comparison, :pct_virgin_use,
    [:tau_route_ref, :sigma_routes, :sigma_eol, :eta_service])

support_frontier = frontier_rows(comparison;
    group_by = group_fields,
    select_by = :tau_route_ref,
    predicate = row -> row.tau_route_ref < 0.0 && row.material_saving && !row.rebound,
    sense = :absolute_min)
support_frontier_with_rebound = frontier_rows(comparison;
    group_by = group_fields,
    select_by = :tau_route_ref,
    predicate = row -> row.tau_route_ref < 0.0 && row.material_saving,
    sense = :absolute_min)

write_rows_csv(joinpath(output_dir, "fiscal_refurbishment_frontier.csv"), result_rows(results))
write_rows_csv(joinpath(output_dir, "fiscal_refurbishment_frontier_comparison.csv"), comparison)
write_rows_csv(joinpath(output_dir, "fiscal_refurbishment_frontier_summary.csv"), [summary_row(summary)])
write_rows_csv(joinpath(output_dir, "fiscal_refurbishment_frontier_sensitivity.csv"), sensitivity)
if !isempty(support_frontier)
    write_rows_csv(joinpath(output_dir, "fiscal_refurbishment_frontier_thresholds.csv"),
        support_frontier)
end
if !isempty(support_frontier_with_rebound)
    write_rows_csv(joinpath(output_dir, "fiscal_refurbishment_frontier_thresholds_with_rebound.csv"),
        support_frontier_with_rebound)
end

println("Ran $(length(results)) fiscal refurbishment-frontier experiments")
println("Compared each policy row against the zero-policy row with matching parameters")
println("Regimes: $(summary.regimes)")
println("Sensitivity screen for pct_virgin_use:")
for row in sensitivity
    println("  $(row.parameter): range=$(row.effect_range), levels=$(row.levels)")
end
println("Support thresholds without rebound: $(length(support_frontier))")
println("Support thresholds allowing rebound: $(length(support_frontier_with_rebound))")
for row in support_frontier_with_rebound
    println(
        "  sigma_routes=$(row.sigma_routes), sigma_eol=$(row.sigma_eol), " *
        "eta_service=$(row.eta_service): tau_route_ref=$(row.tau_route_ref), " *
        "pct_virgin_use=$(row.pct_virgin_use), pct_toaster_service=$(row.pct_toaster_service), " *
        "eol_ref_share=$(row.eol_ref_share), government_net=$(row.government_net)",
    )
end
