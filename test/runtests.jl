using StylizedCircularCGE
using JuMP
using Test

const CLOSED_ECONOMY_ATOL = 1.0e-5

function test_closed_fiscal_markets(out; atol = CLOSED_ECONOMY_ATOL)
    @test out.closed_economy.max_abs_market_residual <= atol
    @test all(balance -> abs(balance) <= atol,
        values(out.closed_economy.material_balance))
    @test abs(out.closed_economy.eol_balance) <= atol
    @test abs(out.closed_economy.household_budget) <= atol
    @test abs(out.closed_economy.income_balance) <= atol
    @test abs(out.closed_economy.government_budget) <= atol
    @test abs(out.closed_economy.government_transfer) <= atol
    return nothing
end

@testset "account structure" begin
    a = accounts()
    @test a.factors == (:LAB, :CAP)
    @test :TST in a.goods
    @test :EOL in a.goods
    @test (:NEW, :REF, :REP, :REU) == a.routes
    @test Set(a.eol_uses) == Set((:REF, :REP, :REU, :REC, :INC))
end

@testset "parameter scaffold" begin
    p = default_parameters()
    @test 0.0 < p.delta < 1.0
    @test 0.0 < p.metal_quality <= 1.0
    @test p.sigma_metal > 0.0
    @test p.sigma_routes > 0.0
    @test p.sigma_eol > 0.0
    @test p.eta_service > 0.0
    @test p.metal_intensity.new > p.metal_intensity.ref > p.metal_intensity.rep >= p.metal_intensity.reu
end

@testset "product profiles" begin
    profile = default_product_profile()
    params = profile_parameters(profile)
    benchmark = profile_benchmark(profile)

    @test profile.label == "round-number-toaster"
    @test params == default_parameters()
    @test benchmark.stock0 == 200.0
    @test sum(values(benchmark.eol_allocation)) == params.delta * benchmark.stock0

    durable = ProductProfile("durable";
        stock0 = 300.0,
        delta = 1.0 / 6.0,
        metal_quality = 0.90,
        yield = (ref = 5.0, rep = 4.0, reu = 2.0, rmtl = 1.7),
        metal_intensity = (new = 0.35, ref = 0.20, rep = 0.12, reu = 0.0))
    durable_params = profile_parameters(durable)
    durable_benchmark = profile_benchmark(durable)
    @test durable_params.yield.ref == 5.0
    @test durable_params.metal_intensity.new == 0.35
    @test durable_benchmark.stock0 == 300.0
    @test isapprox(sum(values(durable_benchmark.eol_allocation)), 50.0)

    specs = product_profile_grid([profile, durable]; policy = single_wedge(:route, :REF, -0.1))
    @test length(specs) == 2
    @test specs[2].benchmark.stock0 == 300.0
    @test specs[1].policy.route[:REF] == -0.1

    grid = product_parameter_grid(durable; sigma_routes = [1.5, 2.0])
    @test length(grid) == 2
    @test all(spec -> spec.benchmark.stock0 == 300.0, grid)
end

@testset "round-number SAM" begin
    sam = synthetic_sam()
    balance = sam_balance(sam)
    @test balance.max_abs_imbalance == 0.0
    @test sam.values[(:BRD, :HOH)] == 200.0
    @test sam.values[(:TST, :HOH)] == 200.0
    @test sam.values[(:NEW, :TST)] == 100.0
    @test sam.values[(:EOL, :RMTL)] == 10.0
    @test balance.row_sums[:LAB] == 200.0
    @test balance.row_sums[:CAP] == 150.0
end

@testset "policy wedges" begin
    policy = with_wedge(zero_policy(), :material, :VMTL, 0.25)
    @test policy.material[:VMTL] == 0.25
    @test policy.material[:RMTL] == 0.0
    @test_throws ErrorException with_wedge(policy, :route, :BAD, 0.1)
end

@testset "experiment execution settings" begin
    @test experiment_execution_kwargs(; env = Dict{String,String}()) == (;)
    @test experiment_execution_kwargs(;
        env = Dict("JCGE_EXPERIMENT_WORKERS" => "1")) == (;)

    parallel = experiment_execution_kwargs(;
        env = Dict("JCGE_EXPERIMENT_WORKERS" => "2"))
    @test parallel.execution == :distributed
    @test parallel.workers == 2
    @test parallel.worker_modules == [:StylizedCircularCGE]

    @test_throws ErrorException experiment_execution_kwargs(;
        env = Dict("JCGE_EXPERIMENT_WORKERS" => "many"))
end

@testset "benchmark replication" begin
    result = solve(baseline(replicate_benchmark = true))
    residuals = benchmark_residuals(result)
    @test residuals.max_abs <= 1.0e-5

    fiscal_result = solve(fiscal_baseline(replicate_benchmark = true))
    fiscal_residuals = benchmark_residuals(fiscal_result)
    @test fiscal_residuals.max_abs <= 1.0e-5
end

@testset "one-period model" begin
    spec = baseline()
    @test spec.name == "StylizedCircularCGE"
    result = solve(spec)
    out = indicators(result)
    @test isfinite(out.utility_log)
    @test out.bread > 0.0
    @test out.toaster_service > 0.0
    @test out.virgin_use <= out.virgin_metal + 1.0e-5
    @test out.recycled_use <= out.recycled_metal + 1.0e-5
    @test isapprox(out.virgin_use, sum(values(out.virgin_use_by_route)); atol = 1.0e-6)
    @test isapprox(out.recycled_use, sum(values(out.recycled_use_by_route)); atol = 1.0e-6)
    @test isapprox(sum(values(out.route_share)), 1.0; atol = 1.0e-6)
    @test isapprox(sum(values(out.eol_share)), 1.0; atol = 1.0e-6)
end

@testset "fiscal closure" begin
    result = solve(fiscal_baseline())
    out = indicators(result)
    @test termination_status(result.context.model) == JuMP.MOI.LOCALLY_SOLVED
    @test out.closure == :fiscal
    @test isapprox(out.bread, 200.0; atol = 1.0e-4)
    @test isapprox(out.toaster_service, 200.0; atol = 1.0e-4)
    @test isapprox(out.prices.bread, 1.0; atol = 1.0e-6)
    @test isapprox(out.prices.toaster_service, 1.0; atol = 1.0e-6)
    @test isapprox(out.fiscal.prefiscal_income, 400.0; atol = 1.0e-4)
    @test isapprox(out.fiscal.household_income, 400.0; atol = 1.0e-4)
    @test abs(out.fiscal.government_net) <= 1.0e-6
    test_closed_fiscal_markets(out)
    @test isapprox(sum(values(out.route_share)), 1.0; atol = 1.0e-6)

    base = out
    taxed = indicators(solve(fiscal_baseline(policy = single_wedge(:material, :VMTL, 0.25))))
    supported = indicators(solve(fiscal_baseline(policy = single_wedge(:route, :REF, -0.25))))

    @test taxed.prices.material[:VMTL] > base.prices.material[:VMTL]
    @test taxed.prices.toaster_service >= base.prices.toaster_service
    @test taxed.fiscal.government_revenue > 0.0
    @test taxed.fiscal.government_net > 0.0
    test_closed_fiscal_markets(taxed)

    @test supported.route_share[:REF] > base.route_share[:REF]
    @test supported.eol_share[:REF] > base.eol_share[:REF]
    @test supported.prices.route[:REF] < base.prices.route[:REF]
    @test supported.fiscal.government_subsidy > 0.0
    @test supported.fiscal.government_net < 0.0
    test_closed_fiscal_markets(supported)

    eol_supported = indicators(solve(fiscal_baseline(policy = single_wedge(:eol, :REC, -0.25))))
    @test eol_supported.eol_share[:REC] > base.eol_share[:REC]
    @test eol_supported.prices.eol[:REC] < base.prices.eol[:REC]
    test_closed_fiscal_markets(eol_supported)

    record = run_experiment(ExperimentSpec("fiscal-tax";
        policy = single_wedge(:material, :VMTL, 0.25)); closure = :fiscal)
    row = result_row(record)
    @test row.closure == :fiscal
    @test row.price_toaster_service > 1.0
    @test row.government_revenue > 0.0
    @test row.max_abs_market_residual <= 1.0e-5
    @test isempty(closed_economy_failures([record]))
    @test assert_closed_economy_results([record]) == [record]

    low_eta = with_parameter(default_parameters(), :eta_service, 0.25)
    high_eta = with_parameter(default_parameters(), :eta_service, 2.0)
    low_response = indicators(solve(fiscal_baseline(params = low_eta,
        policy = single_wedge(:route, :REF, -0.25))))
    high_response = indicators(solve(fiscal_baseline(params = high_eta,
        policy = single_wedge(:route, :REF, -0.25))))
    @test !isapprox(high_response.toaster_service, low_response.toaster_service;
        atol = 1.0e-4)
    test_closed_fiscal_markets(low_response)
    test_closed_fiscal_markets(high_response)

    low_eol = with_parameter(default_parameters(), :sigma_eol, 0.5)
    high_eol = with_parameter(default_parameters(), :sigma_eol, 4.0)
    low_allocation = indicators(solve(fiscal_baseline(params = low_eol,
        policy = single_wedge(:route, :REF, -0.25))))
    high_allocation = indicators(solve(fiscal_baseline(params = high_eol,
        policy = single_wedge(:route, :REF, -0.25))))
    @test high_allocation.eol_share[:REF] > low_allocation.eol_share[:REF]
    test_closed_fiscal_markets(low_allocation)
    test_closed_fiscal_markets(high_allocation)
end

@testset "policy response" begin
    base = indicators(solve())
    taxed = indicators(solve(fiscal_baseline(policy = single_wedge(:material, :VMTL, 0.5))))
    subsidized = indicators(solve(fiscal_baseline(policy = single_wedge(:route, :REF, -0.5))))

    @test base.closure == :fiscal
    @test taxed.prices.material[:VMTL] > base.prices.material[:VMTL]
    @test taxed.wedge_accounting.material[:VMTL] > 0.0
    @test subsidized.route_share[:REF] >= base.route_share[:REF] - 1.0e-5
    @test subsidized.wedge_accounting.route[:REF] < 0.0
    test_closed_fiscal_markets(base)
    test_closed_fiscal_markets(taxed)
    test_closed_fiscal_markets(subsidized)

    planner_base = indicators(solve(baseline()))
    planner_taxed = indicators(solve(baseline(policy = single_wedge(:material, :VMTL, 0.5))))
    planner_supported = indicators(solve(baseline(policy = single_wedge(:route, :REF, -0.5))))
    @test planner_taxed.virgin_use <= planner_base.virgin_use + 1.0e-5
    @test planner_supported.route_share[:REF] >= planner_base.route_share[:REF] - 1.0e-5
end

@testset "experiments" begin
    params = with_parameter(default_parameters(), :sigma_routes, 3.0)
    params = with_parameter(params, :yield_ref, 5.0)
    params = with_parameter(params, :sigma_eol, 3.5)
    params = with_parameter(params, :eta_service, 1.5)
    @test params.sigma_routes == 3.0
    @test params.yield.ref == 5.0
    @test params.sigma_eol == 3.5
    @test params.eta_service == 1.5

    specs = parameter_grid(;
        sigma_routes = [1.5, 2.0],
        metal_quality = [0.75, 0.90],
        policy = single_wedge(:material, :VMTL, 0.25),
    )
    @test length(specs) == 4
    results = run_grid(specs)
    @test length(results) == 4
    @test all(result -> result.closure == :fiscal, results)
    @test all(result -> result.status !== nothing, results)
    @test all(result -> haskey(result.policy.material, :VMTL), results)
    @test all(result -> isfinite(result.indicators.utility_log), results)
    @test isempty(closed_economy_failures(results))

    rows = result_rows(results)
    @test length(rows) == 4
    @test all(row -> row.tau_material_vmtl == 0.25, rows)
    @test all(row -> row.sigma_routes in (1.5, 2.0), rows)
    @test all(row -> row.sigma_eol == default_parameters().sigma_eol, rows)
    @test all(row -> row.eta_service == default_parameters().eta_service, rows)
    @test all(row -> row.stock0 == 200.0, rows)
    @test all(row -> row.delta == default_parameters().delta, rows)
    @test all(row -> isapprox(row.virgin_use,
            row.virgin_use_new + row.virgin_use_ref + row.virgin_use_rep; atol = 1.0e-6), rows)
    @test all(row -> isapprox(row.recycled_use,
            row.recycled_use_new + row.recycled_use_ref + row.recycled_use_rep; atol = 1.0e-6), rows)
    @test all(row -> isapprox(row.eol_ref + row.eol_rep + row.eol_reu + row.eol_rec + row.eol_inc,
            row.delta * row.stock0; atol = 1.0e-6), rows)

    reference = run_experiment(ExperimentSpec("reference"))
    @test reference.closure == :fiscal
    compared = compare_to_reference(results, reference)
    @test length(compared) == 4
    @test all(row -> isfinite(row.delta_virgin_use), compared)
    @test all(row -> isfinite(row.delta_route_ref), compared)
    @test all(row -> isfinite(row.delta_eol_ref), compared)
    @test all(row -> isfinite(row.delta_virgin_use_ref), compared)
    @test all(row -> isfinite(row.delta_government_net), compared)
    @test all(row -> row.support_cost >= 0.0, compared)
    @test all(row -> row.revenue_gain >= 0.0, compared)
    @test all(row -> isfinite(row.virgin_saving_per_revenue_dollar),
        filter(row -> row.revenue_gain > 1.0e-10, compared))
    @test all(row -> row.material_saving isa Bool, compared)
    @test all(row -> classify_regime(row) isa Symbol, compared)
    @test all(row -> classify_mechanism(row) isa Symbol, compared)
    @test all(row -> row.mechanism == classify_mechanism(row), compared)
    @test sum(values(mechanism_counts(compared))) == 4

    summary = summarize_comparison(compared)
    @test summary.count == 4
    @test sum(values(summary.regimes)) == 4
    @test sum(values(summary.mechanisms)) == 4
    flat_summary = summary_row(summary)
    @test flat_summary.count == 4
    @test flat_summary.material_saving_without_rebound + flat_summary.material_saving_with_rebound +
          flat_summary.rebound_without_material_saving + flat_summary.no_material_saving_no_rebound == 4
    @test flat_summary.mechanism_demand_contraction_material_saving >= 0

    best = best_material_savers(compared; n = 2)
    @test length(best) <= 2
    @test all(row -> row.material_saving, best)
    @test issorted([row.delta_virgin_use for row in best])

    screen = sensitivity_screen(compared, :pct_virgin_use, [:sigma_routes, :metal_quality])
    @test length(screen) == 2
    @test screen[1].abs_effect_range >= screen[2].abs_effect_range
    @test all(row -> row.outcome == :pct_virgin_use, screen)

    csv_path = joinpath(mktempdir(), "comparison.csv")
    @test write_rows_csv(csv_path, compared) == csv_path
    @test isfile(csv_path)
    @test occursin("delta_virgin_use", read(csv_path, String))

    output_dir = mktempdir()
    paths = write_experiment_bundle(output_dir, results; reference = reference, basename = "grid")
    @test isfile(paths.results)
    @test isfile(paths.comparison)
    @test isfile(paths.summary)
    @test occursin("pct_virgin_use_min", read(paths.summary, String))

    policy_specs = policy_grid(:material, :VMTL, [0.0, 0.25])
    @test length(policy_specs) == 2
    @test policy_specs[2].policy.material[:VMTL] == 0.25

    combined_specs = parameter_policy_grid(;
        policy_kind = :route,
        policy_target = :REF,
        tau = [-0.50, -0.25, 0.0],
        sigma_routes = [1.5, 2.0],
    )
    @test length(combined_specs) == 6
    @test combined_specs[1].policy.route[:REF] in (-0.50, -0.25, 0.0)

    combined_results = run_grid(combined_specs)
    @test all(result -> result.closure == :fiscal, combined_results)
    grouped = compare_to_group_reference(combined_results, [:sigma_routes];
        reference_filter = row -> row.tau_route_ref == 0.0)
    @test length(grouped) == 6
    @test all(row -> row.reference_label !== "", grouped)
    @test count(row -> row.tau_route_ref == 0.0 && row.delta_virgin_use == 0.0, grouped) == 2
    @test any(row -> row.support_cost > 0.0, grouped)
    @test all(row -> isfinite(row.virgin_saving_per_support_dollar),
        filter(row -> row.support_cost > 1.0e-10, grouped))

    frontier = material_saving_frontier(grouped, :tau_route_ref; group_by = [:sigma_routes])
    @test length(frontier) <= 2
    @test all(row -> row.material_saving && !row.rebound, frontier)

    paired = compare_frontiers(
        [(sigma_routes = 1.5, tau_material_vmtl = 0.1, pct_virgin_use = -0.03,
            pct_toaster_service = -0.04, government_net = 3.0)],
        [(sigma_routes = 1.5, tau_route_ref = -0.1, pct_virgin_use = -0.02,
            pct_toaster_service = -0.01, government_net = -2.0)];
        group_by = [:sigma_routes],
        left_label = :virgin_material_tax,
        right_label = :refurbishment_support,
        left_policy = :tau_material_vmtl,
        right_policy = :tau_route_ref)
    @test length(paired) == 1
    @test paired[1].stronger_material_saving == :virgin_material_tax
    @test paired[1].lower_service_loss == :refurbishment_support
    @test paired[1].higher_government_net == :virgin_material_tax
    @test paired[1].higher_support_efficiency == :none

    @test classify_mechanism((material_saving = true, rebound = false,
        delta_toaster_service = -5.0, delta_virgin_use = -1.0,
        delta_route_new = -4.0, delta_route_ref = -1.0,
        delta_route_rep = -1.0, delta_route_reu = 0.0,
        delta_eol_ref = 0.0)) == :demand_contraction_material_saving
    @test classify_mechanism((material_saving = true, rebound = false,
        delta_toaster_service = -1.0, delta_virgin_use = -1.0,
        delta_route_new = -4.0, delta_route_ref = 2.0,
        delta_route_rep = -1.0, delta_route_reu = 0.0,
        delta_eol_ref = 1.0)) == :refurbishment_substitution_material_saving
    @test classify_mechanism((material_saving = false, rebound = false,
        delta_toaster_service = -1.0, delta_virgin_use = 1.0,
        delta_route_new = 0.0, delta_route_ref = 2.0,
        delta_route_rep = 0.0, delta_route_reu = 0.0,
        delta_eol_ref = 1.0)) == :circular_expansion_material_increase

    planner_record = run_experiment(ExperimentSpec("planner-check"); closure = :planner)
    @test planner_record.closure == :planner
end
