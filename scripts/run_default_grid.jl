using StylizedCircularCGE

output_dir = joinpath(@__DIR__, "..", "outputs")
mkpath(output_dir)
execution_kwargs = experiment_execution_kwargs()

policy = single_wedge(:material, :VMTL, 0.25)

specs = parameter_grid(;
    sigma_routes = [1.25, 2.0, 3.0],
    sigma_metal = [1.25, 2.0],
    metal_quality = [0.75, 0.90],
    policy = policy,
    prefix = "virgin-metal-wedge",
)

reference = run_experiment(ExperimentSpec("reference"))
results = run_grid(specs; execution_kwargs...)
assert_closed_economy_results(vcat([reference], results))
comparison = compare_to_reference(results, reference)

write_experiment_bundle(output_dir, results; reference = reference, basename = "default_grid")

summary = summarize_comparison(comparison)
best = best_material_savers(comparison; n = 5)
sensitivity = sensitivity_screen(comparison, :pct_virgin_use,
    [:sigma_routes, :sigma_metal, :metal_quality])
write_rows_csv(joinpath(output_dir, "default_grid_sensitivity.csv"), sensitivity)

println("Ran $(length(results)) experiments")
println("Regimes: $(summary.regimes)")
println("Virgin-use change range: $(summary.pct_virgin_use)")
println("Toaster-service change range: $(summary.pct_toaster_service)")
println("Sensitivity screen for pct_virgin_use:")
for row in sensitivity
    println("  $(row.parameter): range=$(row.effect_range), levels=$(row.levels)")
end
if isempty(best)
    println("Material-saving labels: none in this grid")
else
    println("Top material-saving labels:")
    for row in best
        println("  $(row.label): delta_virgin_use=$(row.delta_virgin_use), pct_virgin_use=$(row.pct_virgin_use)")
    end
end
