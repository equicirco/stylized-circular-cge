using StylizedCircularCGE

output_dir = joinpath(@__DIR__, "..", "..", "results", "single_country", "generated")
mkpath(output_dir)
execution_kwargs = experiment_execution_kwargs()

group_fields = [:sigma_routes, :sigma_metal, :metal_quality, :eta_service]

specs = parameter_policy_grid(;
    policy_kind = :material,
    policy_target = :VMTL,
    tau = [0.0, 0.10, 0.25, 0.50],
    sigma_routes = [1.25, 2.0, 3.0],
    sigma_metal = [1.25, 2.0],
    metal_quality = [0.75, 0.90],
    eta_service = [0.5, 1.0, 1.5],
    prefix = "fiscal-virgin-metal-frontier",
)

results = run_grid(specs; closure = :fiscal, execution_kwargs...)
assert_closed_economy_results(results)
comparison = compare_to_group_reference(results, group_fields;
    reference_filter = row -> row.tau_material_vmtl == 0.0)
summary = summarize_comparison(comparison)
frontier = material_saving_frontier(comparison, :tau_material_vmtl;
    group_by = group_fields,
    allow_rebound = false,
    sense = :min)
sensitivity = sensitivity_screen(comparison, :pct_virgin_use,
    [:tau_material_vmtl, :sigma_routes, :sigma_metal, :metal_quality, :eta_service])

write_rows_csv(joinpath(output_dir, "fiscal_virgin_metal_frontier.csv"), result_rows(results))
write_rows_csv(joinpath(output_dir, "fiscal_virgin_metal_frontier_comparison.csv"), comparison)
write_rows_csv(joinpath(output_dir, "fiscal_virgin_metal_frontier_summary.csv"), [summary_row(summary)])
write_rows_csv(joinpath(output_dir, "fiscal_virgin_metal_frontier_sensitivity.csv"), sensitivity)
if !isempty(frontier)
    write_rows_csv(joinpath(output_dir, "fiscal_virgin_metal_frontier_thresholds.csv"), frontier)
end

println("Ran $(length(results)) fiscal policy-frontier experiments")
println("Compared each policy row against the zero-policy row with matching parameters")
println("Regimes: $(summary.regimes)")
println("Sensitivity screen for pct_virgin_use:")
for row in sensitivity
    println("  $(row.parameter): range=$(row.effect_range), levels=$(row.levels)")
end
println("Material-saving thresholds without rebound: $(length(frontier))")
for row in frontier
    println(
        "  sigma_routes=$(row.sigma_routes), sigma_metal=$(row.sigma_metal), " *
        "metal_quality=$(row.metal_quality), eta_service=$(row.eta_service): " *
        "tau_material_vmtl=$(row.tau_material_vmtl), " *
        "pct_virgin_use=$(row.pct_virgin_use), pct_toaster_service=$(row.pct_toaster_service), " *
        "government_net=$(row.government_net)",
    )
end
