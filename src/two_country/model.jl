struct CircularTwoCountryFiscalOnePeriodBlock <: JCGECore.AbstractBlock
    name::Symbol
    params::NamedTuple
    benchmark::NamedTuple
    replicate_benchmark::Bool
    policy::PolicyWedges
end

_closure_kind(::CircularTwoCountryFiscalOnePeriodBlock) = :two_country_fiscal

function _two_country_factor_unit_cost(bench, activity::Symbol)
    local_factors = _two_country_activity_factors(activity)
    return sum(bench.factor_input[(h, activity)] for h in local_factors) / bench.output[activity]
end

function _two_country_route_eol_coefficient(bench, route::Symbol)
    route in (:REF, :REP, :REU) || return 0.0
    return bench.eol_allocation[route] / bench.output[_two_country_route_activity(route)]
end

function _two_country_recycling_eol_coefficient(bench)
    return bench.eol_allocation[:REC] / bench.output[:RMTL_C]
end

function _two_country_material_unit_cost(params, bench, policy::PolicyWedges, material::Symbol)
    if material === :VMTL
        cost = _two_country_factor_unit_cost(bench, :VMTL_M) + policy.material[:VMTL]
    elseif material === :RMTL
        cost = _two_country_factor_unit_cost(bench, :RMTL_C) +
               _two_country_recycling_eol_coefficient(bench) * _eol_unit_cost(policy, :REC) +
               policy.material[:RMTL]
    else
        error("Unknown material $(material)")
    end
    return _bounded_unit_cost(cost)
end

function _two_country_route_unit_cost(params, bench, policy::PolicyWedges, route::Symbol)
    activity = _two_country_route_activity(route)
    cost = _two_country_factor_unit_cost(bench, activity) + policy.route[route]
    if route in MATERIAL_ROUTES
        cost += _metal_intensity(params, route)
    end
    route in (:REF, :REP, :REU) &&
        (cost += _two_country_route_eol_coefficient(bench, route) * _eol_unit_cost(policy, route))
    return _bounded_unit_cost(cost)
end

function _two_country_policy_net_expression(policy::PolicyWedges, z, eol, virgin_use, recycled_use)
    return (
        sum(policy.route[route] * z[_two_country_route_activity(route)] for route in ROUTES) +
        policy.material[:VMTL] * sum(virgin_use[route] for route in MATERIAL_ROUTES) +
        policy.material[:RMTL] * sum(recycled_use[route] for route in MATERIAL_ROUTES) +
        sum(policy.eol[use] * eol[use] for use in EOL_USES)
    )
end

function _two_country_policy_revenue_expression(policy::PolicyWedges, z, eol, virgin_use, recycled_use)
    return (
        sum(max(policy.route[route], 0.0) * z[_two_country_route_activity(route)] for route in ROUTES) +
        max(policy.material[:VMTL], 0.0) * sum(virgin_use[route] for route in MATERIAL_ROUTES) +
        max(policy.material[:RMTL], 0.0) * sum(recycled_use[route] for route in MATERIAL_ROUTES) +
        sum(max(policy.eol[use], 0.0) * eol[use] for use in EOL_USES)
    )
end

function _two_country_policy_subsidy_expression(policy::PolicyWedges, z, eol, virgin_use, recycled_use)
    return (
        sum(-min(policy.route[route], 0.0) * z[_two_country_route_activity(route)]
            for route in ROUTES) +
        -min(policy.material[:VMTL], 0.0) * sum(virgin_use[route] for route in MATERIAL_ROUTES) +
        -min(policy.material[:RMTL], 0.0) * sum(recycled_use[route] for route in MATERIAL_ROUTES) +
        sum(-min(policy.eol[use], 0.0) * eol[use] for use in EOL_USES)
    )
end

function JCGECore.build!(block::CircularTwoCountryFiscalOnePeriodBlock,
    ctx::JCGERuntime.KernelContext,
    spec::JCGECore.RunSpec)
    params = block.params
    bench = block.benchmark
    policy = block.policy
    model = ctx.model
    model isa JuMP.Model || error("CircularTwoCountryFiscalOnePeriodBlock requires a JuMP-backed JCGE runtime context")
    _register_metadata!(ctx, block)

    z = Dict{Symbol,Any}()
    for a in (TWO_COUNTRY_PRODUCTION_ACTIVITIES..., :TST_C)
        z[a] = _ensure_var!(ctx, _global_var(:Z, a); start = bench.output[a])
    end

    factors = Dict{Tuple{Symbol,Symbol},Any}()
    for a in TWO_COUNTRY_PRODUCTION_ACTIVITIES
        for h in _two_country_activity_factors(a)
            factors[(h, a)] = _ensure_var!(ctx, _global_var(:F, h, a);
                start = bench.factor_input[(h, a)])
        end
    end

    eol = Dict{Symbol,Any}()
    ret = params.delta * bench.stock0
    for use in EOL_USES
        eol[use] = _ensure_var!(ctx, _global_var(:EOL_C, use);
            lower = 0.0, start = bench.eol_allocation[use])
    end

    metal_eff = Dict{Symbol,Any}()
    virgin_use = Dict{Symbol,Any}()
    recycled_use = Dict{Symbol,Any}()
    for route in MATERIAL_ROUTES
        activity = _two_country_route_activity(route)
        metal_eff[route] = _ensure_var!(ctx, _global_var(:MEFF, route, :C);
            start = _metal_intensity(params, route) * bench.output[activity])
        virgin_use[route] = _ensure_var!(ctx, _global_var(:VUSE, route, :M, :C);
            start = bench.material_input[(:VMTL, route)])
        recycled_use[route] = _ensure_var!(ctx, _global_var(:RUSE, route, :C);
            start = bench.material_input[(:RMTL, route)])
    end

    for a in TWO_COUNTRY_PRODUCTION_ACTIVITIES
        lab, cap = _two_country_activity_factors(a)
        beta_lab = bench.factor_share[(lab, a)]
        beta_cap = bench.factor_share[(cap, a)]
        scale = bench.productivity[a]
        constraint = JuMP.@NLconstraint(model,
            z[a] <= scale * factors[(lab, a)]^beta_lab * factors[(cap, a)]^beta_cap)
        _register_constraint!(ctx, block, :technology, constraint;
            info = "Z[$(a)] <= A[$(a)] * local Cobb-Douglas factor composite",
            indices = (a,))
    end

    for h in TWO_COUNTRY_FACTORS
        activities = [a for a in TWO_COUNTRY_PRODUCTION_ACTIVITIES
                      if h in _two_country_activity_factors(a)]
        constraint = JuMP.@constraint(model,
            sum(factors[(h, a)] for a in activities) <= bench.factor_endowment[h])
        _register_constraint!(ctx, block, :factor_endowment, constraint;
            info = "sum(F[$(h),a]) <= FF[$(h)]",
            indices = (h,))
    end

    eol_shares = _eol_allocation_shares(params, bench, policy)
    for use in EOL_USES
        constraint = JuMP.@constraint(model, eol[use] == eol_shares[use] * ret)
        _register_constraint!(ctx, block, :eol_allocation, constraint;
            info = "EOL_C[$(use)] follows calibrated allocation shares from policy-adjusted EOL costs",
            indices = (use,))
    end

    for route in (:REF, :REP, :REU)
        constraint = JuMP.@constraint(model,
            z[_two_country_route_activity(route)] <= _route_yield(params, route) * eol[route])
        _register_constraint!(ctx, block, :route_yield, constraint;
            info = "Z[$(route)_C] <= yield[$(route)] * EOL_C[$(route)]",
            indices = (route,))
    end

    constraint = JuMP.@constraint(model, z[:RMTL_C] <= params.yield.rmtl * eol[:REC])
    _register_constraint!(ctx, block, :recycling_yield, constraint;
        info = "Z[RMTL_C] <= yield[RMTL] * EOL_C[REC]")

    for route in MATERIAL_ROUTES
        activity = _two_country_route_activity(route)
        alpha = _metal_intensity(params, route)
        constraint = JuMP.@constraint(model, alpha * z[activity] <= metal_eff[route])
        _register_constraint!(ctx, block, :route_material_requirement, constraint;
            info = "metal_intensity[$(route)] * Z[$(activity)] <= MEFF[$(route),C]",
            indices = (route,))
    end

    rho_metal = (params.sigma_metal - 1.0) / params.sigma_metal
    phi = params.metal_quality
    for route in MATERIAL_ROUTES
        theta_v = bench.route_metal_share[(:VMTL, route)]
        theta_r = bench.route_metal_share[(:RMTL, route)]
        scale = bench.metal_scale[route]
        if abs(rho_metal) < 1.0e-8
            constraint = JuMP.@NLconstraint(model,
                metal_eff[route] <= scale * virgin_use[route]^theta_v *
                                    (phi * recycled_use[route])^theta_r)
        else
            constraint = JuMP.@NLconstraint(model,
                metal_eff[route] <=
                scale *
                (theta_v * virgin_use[route]^rho_metal +
                 theta_r * (phi * recycled_use[route])^rho_metal)^(1.0 / rho_metal))
        end
        _register_constraint!(ctx, block, :metal_composite, constraint;
            info = "MEFF[$(route),C] <= calibrated CES(imported VMTL_M, quality * RMTL_C)",
            indices = (route,))
    end

    constraint = JuMP.@constraint(model,
        sum(virgin_use[route] for route in MATERIAL_ROUTES) == z[:VMTL_M])
    _register_constraint!(ctx, block, :virgin_material_import_balance, constraint;
        info = "sum(VUSE[route,M->C]) == Z[VMTL_M]")

    constraint = JuMP.@constraint(model,
        sum(recycled_use[route] for route in MATERIAL_ROUTES) == z[:RMTL_C])
    _register_constraint!(ctx, block, :recycled_material_balance, constraint;
        info = "sum(RUSE[route,C]) == Z[RMTL_C]")

    rho_routes = (params.sigma_routes - 1.0) / params.sigma_routes
    if abs(rho_routes) < 1.0e-8
        constraint = JuMP.@NLconstraint(model,
            z[:TST_C] <=
            bench.route_scale *
            prod(z[_two_country_route_activity(route)]^bench.route_share[route]
                 for route in ROUTES))
    else
        constraint = JuMP.@NLconstraint(model,
            z[:TST_C] <=
            bench.route_scale *
            (sum(bench.route_share[route] *
                 z[_two_country_route_activity(route)]^rho_routes
                 for route in ROUTES))^(1.0 / rho_routes))
    end
    _register_constraint!(ctx, block, :toaster_service_composite, constraint;
        info = "Z[TST_C] <= calibrated CES(Z[NEW_C], Z[REF_C], Z[REP_C], Z[REU_C])")

    if block.replicate_benchmark
        for a in (TWO_COUNTRY_PRODUCTION_ACTIVITIES..., :TST_C)
            constraint = JuMP.@constraint(model, z[a] == bench.output[a])
            _register_constraint!(ctx, block, :replicate_output, constraint;
                info = "Z[$(a)] == benchmark output", indices = (a,))
        end
        for a in TWO_COUNTRY_PRODUCTION_ACTIVITIES, h in _two_country_activity_factors(a)
            constraint = JuMP.@constraint(model, factors[(h, a)] == bench.factor_input[(h, a)])
            _register_constraint!(ctx, block, :replicate_factor_input, constraint;
                info = "F[$(h),$(a)] == benchmark factor input", indices = (h, a))
        end
        for use in EOL_USES
            constraint = JuMP.@constraint(model, eol[use] == bench.eol_allocation[use])
            _register_constraint!(ctx, block, :replicate_eol, constraint;
                info = "EOL_C[$(use)] == benchmark EOL allocation", indices = (use,))
        end
        for route in MATERIAL_ROUTES
            constraint = JuMP.@constraint(model, virgin_use[route] == bench.material_input[(:VMTL, route)])
            _register_constraint!(ctx, block, :replicate_virgin_use, constraint;
                info = "VUSE[$(route),M->C] == benchmark virgin-metal use", indices = (route,))
            constraint = JuMP.@constraint(model, recycled_use[route] == bench.material_input[(:RMTL, route)])
            _register_constraint!(ctx, block, :replicate_recycled_use, constraint;
                info = "RUSE[$(route),C] == benchmark recycled-metal use", indices = (route,))
        end
    end

    p_brd_m = _ensure_var!(ctx, :P_BRD_M; start = 1.0)
    p_brd_c = _ensure_var!(ctx, :P_BRD_C; start = 1.0)
    constraint = JuMP.@constraint(model, p_brd_m == 1.0)
    _register_constraint!(ctx, block, :numeraire_m, constraint; info = "P[BRD_M] == 1")
    constraint = JuMP.@constraint(model, p_brd_c == 1.0)
    _register_constraint!(ctx, block, :numeraire_c, constraint; info = "P[BRD_C] == 1")

    p_eol = Dict{Symbol,Any}()
    for use in EOL_USES
        unit_cost = _eol_unit_cost(policy, use)
        p_eol[use] = _ensure_var!(ctx, _global_var(:P_EOL_C, use); start = unit_cost)
        constraint = JuMP.@constraint(model, p_eol[use] == unit_cost)
        _register_constraint!(ctx, block, :eol_price, constraint;
            info = "P_EOL_C[$(use)] equals the tax-inclusive EOL use cost",
            indices = (use,))
    end

    p_material = Dict{Symbol,Any}()
    for material in MATERIALS
        p_material[material] = _ensure_var!(ctx, _global_var(:P_MAT_C, material);
            start = _two_country_material_unit_cost(params, bench, policy, material))
    end
    constraint = JuMP.@constraint(model,
        p_material[:VMTL] >= _two_country_factor_unit_cost(bench, :VMTL_M) +
                             policy.material[:VMTL])
    _register_constraint!(ctx, block, :material_price, constraint;
        info = "P_MAT_C[VMTL] is imported VMTL_M cost plus material wedge",
        indices = (:VMTL,))
    constraint = JuMP.@constraint(model,
        p_material[:RMTL] >=
        _two_country_factor_unit_cost(bench, :RMTL_C) +
        _two_country_recycling_eol_coefficient(bench) * p_eol[:REC] +
        policy.material[:RMTL])
    _register_constraint!(ctx, block, :material_price, constraint;
        info = "P_MAT_C[RMTL] is recycling factor cost plus EOL input cost plus material wedge",
        indices = (:RMTL,))

    p_eff = Dict{Symbol,Any}()
    for route in MATERIAL_ROUTES
        p_eff[route] = _ensure_var!(ctx, _global_var(:P_MEFF_C, route); start = 1.0)
        theta_v = bench.route_metal_share[(:VMTL, route)]
        theta_r = bench.route_metal_share[(:RMTL, route)]
        if abs(params.sigma_metal - 1.0) < 1.0e-8
            constraint = JuMP.@NLconstraint(model,
                p_eff[route] == p_material[:VMTL]^theta_v * p_material[:RMTL]^theta_r)
        else
            constraint = JuMP.@NLconstraint(model,
                p_eff[route] ==
                (theta_v * p_material[:VMTL]^(1.0 - params.sigma_metal) +
                 theta_r * p_material[:RMTL]^(1.0 - params.sigma_metal))^
                (1.0 / (1.0 - params.sigma_metal)))
        end
        _register_constraint!(ctx, block, :metal_price_index, constraint;
            info = "P_MEFF_C[$(route)] is a CES material price index",
            indices = (route,))
    end

    p_route = Dict{Symbol,Any}()
    for route in ROUTES
        p_route[route] = _ensure_var!(ctx, _global_var(:P_ROUTE_C, route);
            start = _two_country_route_unit_cost(params, bench, policy, route))
    end
    constraint = JuMP.@constraint(model,
        p_route[:NEW] >=
        _two_country_factor_unit_cost(bench, :NEW_C) +
        _metal_intensity(params, :NEW) * p_eff[:NEW] +
        policy.route[:NEW])
    _register_constraint!(ctx, block, :route_price, constraint;
        info = "P_ROUTE_C[NEW] is bounded below by factor, material, and route-wedge costs",
        indices = (:NEW,))
    for route in (:REF, :REP)
        constraint = JuMP.@constraint(model,
            p_route[route] >=
            _two_country_factor_unit_cost(bench, _two_country_route_activity(route)) +
            _metal_intensity(params, route) * p_eff[route] +
            _two_country_route_eol_coefficient(bench, route) * p_eol[route] +
            policy.route[route])
        _register_constraint!(ctx, block, :route_price, constraint;
            info = "P_ROUTE_C[$(route)] is bounded below by factor, material, EOL, and route-wedge costs",
            indices = (route,))
    end
    constraint = JuMP.@constraint(model,
        p_route[:REU] >=
        _two_country_factor_unit_cost(bench, :REU_C) +
        _two_country_route_eol_coefficient(bench, :REU) * p_eol[:REU] +
        policy.route[:REU])
    _register_constraint!(ctx, block, :route_price, constraint;
        info = "P_ROUTE_C[REU] is bounded below by factor, EOL, and route-wedge costs",
        indices = (:REU,))

    p_tst = _ensure_var!(ctx, :P_TST_C; start = 1.0)
    if abs(params.sigma_routes - 1.0) < 1.0e-8
        constraint = JuMP.@NLconstraint(model,
            p_tst ==
            prod(p_route[route]^bench.route_share[route] for route in ROUTES))
    else
        constraint = JuMP.@NLconstraint(model,
            p_tst ==
            (sum(bench.route_share[route] * p_route[route]^(1.0 - params.sigma_routes)
                 for route in ROUTES))^(1.0 / (1.0 - params.sigma_routes)))
    end
    _register_constraint!(ctx, block, :toaster_service_price, constraint;
        info = "P[TST_C] is a CES route price index")

    y_prefiscal_m = _ensure_var!(ctx, :Y_PREFISCAL_M; start = bench.prefiscal_income_m)
    y_hoh_m = _ensure_var!(ctx, :Y_HOH_M; start = bench.disposable_income_m)
    y_prefiscal_c = _ensure_var!(ctx, :Y_PREFISCAL_C; start = bench.prefiscal_income_c)
    y_hoh_c = _ensure_var!(ctx, :Y_HOH_C; start = bench.prefiscal_income_c)
    gov_net = _ensure_var!(ctx, :GOV_NET_C; lower = nothing, start = 0.0)
    gov_revenue = _ensure_var!(ctx, :GOV_REVENUE_C; lower = 0.0, start = 0.0)
    gov_subsidy = _ensure_var!(ctx, :GOV_SUBSIDY_C; lower = 0.0, start = 0.0)
    gov_transfer = _ensure_var!(ctx, :GOV_TRANSFER_C; lower = nothing, start = 0.0)

    net_expr = _two_country_policy_net_expression(policy, z, eol, virgin_use, recycled_use)
    revenue_expr = _two_country_policy_revenue_expression(policy, z, eol, virgin_use, recycled_use)
    subsidy_expr = _two_country_policy_subsidy_expression(policy, z, eol, virgin_use, recycled_use)

    constraint = JuMP.@constraint(model, y_prefiscal_m == bench.prefiscal_income_m)
    _register_constraint!(ctx, block, :prefiscal_income_m, constraint;
        info = "Y_PREFISCAL_M equals mining-country factor endowment income")
    constraint = JuMP.@constraint(model, y_hoh_m == y_prefiscal_m - bench.nfa_transfer)
    _register_constraint!(ctx, block, :household_income_m, constraint;
        info = "Y_HOH_M equals M prefiscal income net of benchmark NFA outflow")

    constraint = JuMP.@constraint(model, y_prefiscal_c == bench.prefiscal_income_c)
    _register_constraint!(ctx, block, :prefiscal_income_c, constraint;
        info = "Y_PREFISCAL_C equals C factor, EOL, and benchmark NFA income")

    constraint = JuMP.@constraint(model, gov_net == net_expr)
    _register_constraint!(ctx, block, :government_net_revenue_c, constraint;
        info = "GOV_NET_C equals C policy revenue net of subsidy outlays")
    constraint = JuMP.@constraint(model, gov_revenue == revenue_expr)
    _register_constraint!(ctx, block, :government_revenue_c, constraint;
        info = "GOV_REVENUE_C equals positive C policy wedge receipts")
    constraint = JuMP.@constraint(model, gov_subsidy == subsidy_expr)
    _register_constraint!(ctx, block, :government_subsidy_c, constraint;
        info = "GOV_SUBSIDY_C equals negative C policy wedge outlays")
    constraint = JuMP.@constraint(model, gov_transfer == gov_net)
    _register_constraint!(ctx, block, :government_transfer_c, constraint;
        info = "GOV_TRANSFER_C rebates net revenue to C households")
    constraint = JuMP.@constraint(model, y_hoh_c == y_prefiscal_c + gov_transfer)
    _register_constraint!(ctx, block, :household_income_c, constraint;
        info = "Y_HOH_C equals C prefiscal income plus C net government transfer")

    y0_c = bench.prefiscal_income_c
    constraint = JuMP.@NLconstraint(model,
        z[:TST_C] == bench.output[:TST_C] * (y_hoh_c / y0_c) * p_tst^(-params.eta_service))
    _register_constraint!(ctx, block, :household_toaster_demand_c, constraint;
        info = "Z[TST_C] follows an isoelastic service-demand curve with C income scaling")

    constraint = JuMP.@NLconstraint(model, z[:BRD_C] == (y_hoh_c - p_tst * z[:TST_C]) / p_brd_c)
    _register_constraint!(ctx, block, :household_bread_demand_c, constraint;
        info = "Z[BRD_C] absorbs residual C household income after toaster-service expenditure")
    constraint = JuMP.@NLconstraint(model, z[:BRD_M] == y_hoh_m / p_brd_m)
    _register_constraint!(ctx, block, :household_bread_demand_m, constraint;
        info = "Z[BRD_M] follows M disposable income")

    for route in ROUTES
        activity = _two_country_route_activity(route)
        constraint = JuMP.@NLconstraint(model,
            z[activity] ==
            bench.route_share[route] * z[:TST_C] * (p_tst / p_route[route])^params.sigma_routes)
        _register_constraint!(ctx, block, :route_demand_c, constraint;
            info = "Z[$(activity)] follows CES demand from the tax-inclusive route price",
            indices = (route,))
    end

    for route in MATERIAL_ROUTES
        base_eff = _metal_intensity(params, route) * bench.output[_two_country_route_activity(route)]
        constraint = JuMP.@NLconstraint(model,
            virgin_use[route] ==
            bench.material_input[(:VMTL, route)] *
            (metal_eff[route] / base_eff) *
            (p_eff[route] / p_material[:VMTL])^params.sigma_metal)
        _register_constraint!(ctx, block, :virgin_material_demand_c, constraint;
            info = "VUSE[$(route),M->C] follows CES demand from the tax-inclusive imported virgin-material price",
            indices = (route,))

        constraint = JuMP.@NLconstraint(model,
            recycled_use[route] ==
            bench.material_input[(:RMTL, route)] *
            (metal_eff[route] / base_eff) *
            (p_eff[route] / p_material[:RMTL])^params.sigma_metal)
        _register_constraint!(ctx, block, :recycled_material_demand_c, constraint;
            info = "RUSE[$(route),C] follows CES demand from the tax-inclusive recycled-material price",
            indices = (route,))
    end

    JuMP.@NLobjective(model, Max,
        bench.utility_share[:BRD_M] * log(z[:BRD_M]) +
        bench.utility_share[:BRD_C] * log(z[:BRD_C]) +
        bench.utility_share[:TST_C] * log(z[:TST_C]))
    JCGERuntime.register_equation!(ctx;
        tag = :objective,
        block = block.name,
        payload = (
            indices = (),
            params = block.params,
            info = "maximize two-country benchmark-weighted log utility under C fiscal closure",
            expr = JCGECore.ERaw("two-country log utility objective with fiscal closure"),
            constraint = nothing,
        ))

    return nothing
end

function two_country_fiscal_model(; params = default_parameters(),
    benchmark = two_country_benchmark(params),
    name::String = "StylizedCircularCGETwoCountryFiscal",
    scenario_spec::JCGECore.ScenarioSpec = scenario(:baseline),
    replicate_benchmark::Bool = false,
    policy::PolicyWedges = zero_policy())
    commodities = collect(Symbol,
        (:BRD_M, :VMTL_M, :BRD_C, :RMTL_C, :NEW_C, :REF_C, :REP_C, :REU_C, :TST_C, :EOL_C))
    activities = collect(Symbol, TWO_COUNTRY_PRODUCTION_ACTIVITIES)
    factors = collect(Symbol, TWO_COUNTRY_FACTORS)
    institutions = collect(Symbol, (:HOH_M, :HOH_C, :GOV_C, :NFA))
    sets = JCGECore.Sets(commodities, activities, factors, institutions)
    mappings = JCGECore.Mappings(Dict(a => a for a in activities))
    block = CircularTwoCountryFiscalOnePeriodBlock(:circular_two_country_fiscal_one_period,
        params, benchmark, replicate_benchmark, policy)

    allowed = JCGECore.allowed_sections()
    section_blocks = Dict(sym => Any[] for sym in allowed)
    push!(section_blocks[:production], block)
    sections = [JCGECore.section(sym, section_blocks[sym]) for sym in allowed]

    return JCGECore.build_spec(
        name,
        sets,
        mappings,
        sections;
        closure = JCGECore.ClosureSpec(:LAB_C),
        scenario = scenario_spec,
        required_sections = allowed,
        allowed_sections = allowed,
        required_nonempty = [:production],
    )
end

two_country_fiscal_baseline(; kwargs...) = two_country_fiscal_model(; kwargs...)

function _two_country_run_metadata(result)
    for eq in result.context.equations
        if eq.tag == :metadata && eq.block === :circular_two_country_fiscal_one_period
            return eq.payload
        end
    end
    return (
        policy = zero_policy(),
        benchmark = two_country_benchmark(),
        params = default_parameters(),
        closure = :two_country_fiscal,
    )
end

function _two_country_wedge_accounting(result, policy::PolicyWedges)
    route = Dict(route =>
            policy.route[route] *
            _solved_value(result, _global_var(:Z, _two_country_route_activity(route)))
        for route in ROUTES)
    material = Dict(
        :VMTL => policy.material[:VMTL] *
                 sum(_solved_value(result, _global_var(:VUSE, route, :M, :C))
                     for route in MATERIAL_ROUTES),
        :RMTL => policy.material[:RMTL] *
                 sum(_solved_value(result, _global_var(:RUSE, route, :C))
                     for route in MATERIAL_ROUTES),
    )
    eol = Dict(use =>
            policy.eol[use] * _solved_value(result, _global_var(:EOL_C, use))
        for use in EOL_USES)
    all_values = vcat(collect(values(route)), collect(values(material)), collect(values(eol)))
    return (
        route = route,
        material = material,
        eol = eol,
        net = sum(all_values),
        penalties = sum(max(value, 0.0) for value in all_values),
        support = -sum(min(value, 0.0) for value in all_values),
    )
end

function _two_country_prices(result)
    return (
        bread_m = _maybe_solved_value(result, :P_BRD_M),
        bread_c = _maybe_solved_value(result, :P_BRD_C),
        toaster_service = _maybe_solved_value(result, :P_TST_C),
        route = Dict(route => _maybe_solved_value(result, _global_var(:P_ROUTE_C, route))
            for route in ROUTES),
        material = Dict(material => _maybe_solved_value(result, _global_var(:P_MAT_C, material))
            for material in MATERIALS),
        eol = Dict(use => _maybe_solved_value(result, _global_var(:P_EOL_C, use))
            for use in EOL_USES),
    )
end

function _two_country_activity_accounting(result)
    quantity = Dict(a => _solved_value(result, _global_var(:Z, a))
        for a in TWO_COUNTRY_PRODUCTION_ACTIVITIES)
    total = sum(values(quantity))
    share = Dict(a => total <= 1.0e-12 ? NaN : quantity[a] / total
        for a in TWO_COUNTRY_PRODUCTION_ACTIVITIES)
    by_country = Dict(
        country => sum(quantity[a] for a in TWO_COUNTRY_PRODUCTION_ACTIVITIES
            if _two_country_country(a) === country)
        for country in TWO_COUNTRIES)
    country_share = Dict(country => total <= 1.0e-12 ? NaN : by_country[country] / total
        for country in TWO_COUNTRIES)
    aggregate = Dict(
        :BRD => quantity[:BRD_M] + quantity[:BRD_C],
        :VMTL => quantity[:VMTL_M],
        :RMTL => quantity[:RMTL_C],
        :NEW => quantity[:NEW_C],
        :REF => quantity[:REF_C],
        :REP => quantity[:REP_C],
        :REU => quantity[:REU_C],
    )
    aggregate_total = sum(values(aggregate))
    aggregate_share = Dict(a => aggregate_total <= 1.0e-12 ? NaN : aggregate[a] / aggregate_total
        for a in PRODUCTION_ACTIVITIES)
    return (
        quantity = quantity,
        total = total,
        share = share,
        by_country = by_country,
        country_share = country_share,
        aggregate = aggregate,
        aggregate_total = aggregate_total,
        aggregate_share = aggregate_share,
    )
end

function _two_country_factor_accounting(result)
    use = Dict((h, a) => _solved_value(result, _global_var(:F, h, a))
        for a in TWO_COUNTRY_PRODUCTION_ACTIVITIES for h in _two_country_activity_factors(a))
    by_factor = Dict(h =>
            sum(get(use, (h, a), 0.0) for a in TWO_COUNTRY_PRODUCTION_ACTIVITIES)
        for h in TWO_COUNTRY_FACTORS)
    by_activity = Dict(a => sum(use[(h, a)] for h in _two_country_activity_factors(a))
        for a in TWO_COUNTRY_PRODUCTION_ACTIVITIES)
    by_country = Dict(country =>
            sum(by_activity[a] for a in TWO_COUNTRY_PRODUCTION_ACTIVITIES
                if _two_country_country(a) === country)
        for country in TWO_COUNTRIES)
    aggregate_by_factor = Dict(
        :LAB => by_factor[:LAB_M] + by_factor[:LAB_C],
        :CAP => by_factor[:CAP_M] + by_factor[:CAP_C],
    )
    aggregate_by_activity = Dict(
        :BRD => by_activity[:BRD_M] + by_activity[:BRD_C],
        :VMTL => by_activity[:VMTL_M],
        :RMTL => by_activity[:RMTL_C],
        :NEW => by_activity[:NEW_C],
        :REF => by_activity[:REF_C],
        :REP => by_activity[:REP_C],
        :REU => by_activity[:REU_C],
    )
    aggregate_use = Dict(
        (:LAB, :BRD) => get(use, (:LAB_M, :BRD_M), 0.0) + get(use, (:LAB_C, :BRD_C), 0.0),
        (:CAP, :BRD) => get(use, (:CAP_M, :BRD_M), 0.0) + get(use, (:CAP_C, :BRD_C), 0.0),
        (:LAB, :VMTL) => get(use, (:LAB_M, :VMTL_M), 0.0),
        (:CAP, :VMTL) => get(use, (:CAP_M, :VMTL_M), 0.0),
        (:LAB, :RMTL) => get(use, (:LAB_C, :RMTL_C), 0.0),
        (:CAP, :RMTL) => get(use, (:CAP_C, :RMTL_C), 0.0),
        (:LAB, :NEW) => get(use, (:LAB_C, :NEW_C), 0.0),
        (:CAP, :NEW) => get(use, (:CAP_C, :NEW_C), 0.0),
        (:LAB, :REF) => get(use, (:LAB_C, :REF_C), 0.0),
        (:CAP, :REF) => get(use, (:CAP_C, :REF_C), 0.0),
        (:LAB, :REP) => get(use, (:LAB_C, :REP_C), 0.0),
        (:CAP, :REP) => get(use, (:CAP_C, :REP_C), 0.0),
        (:LAB, :REU) => get(use, (:LAB_C, :REU_C), 0.0),
        (:CAP, :REU) => get(use, (:CAP_C, :REU_C), 0.0),
    )
    total = sum(values(by_activity))
    factor_activity_share = Dict((h, a) =>
            by_factor[h] <= 1.0e-12 ? NaN : use[(h, a)] / by_factor[h]
        for a in TWO_COUNTRY_PRODUCTION_ACTIVITIES for h in _two_country_activity_factors(a))
    activity_share = Dict(a => total <= 1.0e-12 ? NaN : by_activity[a] / total
        for a in TWO_COUNTRY_PRODUCTION_ACTIVITIES)
    aggregate_activity_share = Dict(a => total <= 1.0e-12 ? NaN : aggregate_by_activity[a] / total
        for a in PRODUCTION_ACTIVITIES)
    aggregate_factor_activity_share = Dict((h, a) =>
            aggregate_by_factor[h] <= 1.0e-12 ? NaN : aggregate_use[(h, a)] / aggregate_by_factor[h]
        for h in FACTORS for a in PRODUCTION_ACTIVITIES)
    country_factor = Dict((country, factor) =>
            begin
                local_factor = Symbol(string(factor), "_", string(country))
                by_factor[local_factor]
            end
        for country in TWO_COUNTRIES for factor in FACTORS)
    return (
        use = use,
        by_factor = by_factor,
        by_activity = by_activity,
        by_country = by_country,
        by_country_factor = country_factor,
        total = total,
        factor_activity_share = factor_activity_share,
        activity_share = activity_share,
        aggregate_use = aggregate_use,
        aggregate_by_factor = aggregate_by_factor,
        aggregate_by_activity = aggregate_by_activity,
        aggregate_activity_share = aggregate_activity_share,
        aggregate_factor_activity_share = aggregate_factor_activity_share,
    )
end

function _two_country_technology_output(params, bench, result, activity::Symbol)
    lab, cap = _two_country_activity_factors(activity)
    lab_use = _solved_value(result, _global_var(:F, lab, activity))
    cap_use = _solved_value(result, _global_var(:F, cap, activity))
    beta_lab = bench.factor_share[(lab, activity)]
    beta_cap = bench.factor_share[(cap, activity)]
    return bench.productivity[activity] * lab_use^beta_lab * cap_use^beta_cap
end

function _two_country_metal_composite_output(params, bench, result, route::Symbol)
    vuse = _solved_value(result, _global_var(:VUSE, route, :M, :C))
    ruse = _solved_value(result, _global_var(:RUSE, route, :C))
    inputs = Dict(:VMTL => vuse, :RMTL => ruse)
    shares = Dict(m => bench.route_metal_share[(m, route)] for m in MATERIALS)
    quality = Dict(:VMTL => 1.0, :RMTL => params.metal_quality)
    return bench.metal_scale[route] *
           _ces_quantity(inputs, shares, params.sigma_metal; quality = quality)
end

function _two_country_toaster_service_composite(params, bench, result)
    inputs = Dict(route => _solved_value(result,
            _global_var(:Z, _two_country_route_activity(route))) for route in ROUTES)
    shares = Dict(route => bench.route_share[route] for route in ROUTES)
    return bench.route_scale * _ces_quantity(inputs, shares, params.sigma_routes)
end

function two_country_closed_economy_residuals(result)
    metadata = _two_country_run_metadata(result)
    params = metadata.params
    bench = metadata.benchmark

    factor_slack = Dict(h =>
            bench.factor_endowment[h] -
            sum(_solved_value(result, _global_var(:F, h, a))
                for a in TWO_COUNTRY_PRODUCTION_ACTIVITIES
                if h in _two_country_activity_factors(a))
        for h in TWO_COUNTRY_FACTORS)

    technology_slack = Dict(a =>
            _two_country_technology_output(params, bench, result, a) -
            _solved_value(result, _global_var(:Z, a))
        for a in TWO_COUNTRY_PRODUCTION_ACTIVITIES)

    material_requirement = Dict(route =>
            _solved_value(result, _global_var(:MEFF, route, :C)) -
            _metal_intensity(params, route) *
            _solved_value(result, _global_var(:Z, _two_country_route_activity(route)))
        for route in MATERIAL_ROUTES)

    metal_composite_slack = Dict(route =>
            _two_country_metal_composite_output(params, bench, result, route) -
            _solved_value(result, _global_var(:MEFF, route, :C))
        for route in MATERIAL_ROUTES)

    material_balance = Dict(
        :VMTL => _solved_value(result, :Z_VMTL_M) -
                 sum(_solved_value(result, _global_var(:VUSE, route, :M, :C))
                     for route in MATERIAL_ROUTES),
        :RMTL => _solved_value(result, :Z_RMTL_C) -
                 sum(_solved_value(result, _global_var(:RUSE, route, :C))
                     for route in MATERIAL_ROUTES),
    )

    eol_total = sum(_solved_value(result, _global_var(:EOL_C, use)) for use in EOL_USES)
    eol_balance = eol_total - params.delta * bench.stock0
    route_capacity_slack = Dict(route =>
            _route_yield(params, route) * _solved_value(result, _global_var(:EOL_C, route)) -
            _solved_value(result, _global_var(:Z, _two_country_route_activity(route)))
        for route in (:REF, :REP, :REU))
    recycling_capacity_slack =
        params.yield.rmtl * _solved_value(result, :EOL_C_REC) - _solved_value(result, :Z_RMTL_C)

    toaster_composite =
        _two_country_toaster_service_composite(params, bench, result) -
        _solved_value(result, :Z_TST_C)

    household_budget_m =
        _solved_value(result, :Y_HOH_M) -
        _solved_value(result, :P_BRD_M) * _solved_value(result, :Z_BRD_M)
    household_budget_c =
        _solved_value(result, :Y_HOH_C) -
        (_solved_value(result, :P_BRD_C) * _solved_value(result, :Z_BRD_C) +
         _solved_value(result, :P_TST_C) * _solved_value(result, :Z_TST_C))
    income_balance_m =
        _solved_value(result, :Y_HOH_M) -
        (_solved_value(result, :Y_PREFISCAL_M) - bench.nfa_transfer)
    income_balance_c =
        _solved_value(result, :Y_HOH_C) -
        (_solved_value(result, :Y_PREFISCAL_C) + _solved_value(result, :GOV_TRANSFER_C))
    government_budget =
        _solved_value(result, :GOV_NET_C) - _two_country_wedge_accounting(result, metadata.policy).net
    government_transfer =
        _solved_value(result, :GOV_TRANSFER_C) - _solved_value(result, :GOV_NET_C)

    market_values = vcat(
        collect(values(material_balance)),
        [eol_balance, household_budget_m, household_budget_c,
            income_balance_m, income_balance_c, government_budget, government_transfer],
    )
    capacity_values = vcat(
        collect(values(factor_slack)),
        collect(values(technology_slack)),
        collect(values(material_requirement)),
        collect(values(metal_composite_slack)),
        collect(values(route_capacity_slack)),
        [recycling_capacity_slack, toaster_composite],
    )

    return (
        factor_slack = factor_slack,
        technology_slack = technology_slack,
        material_requirement = material_requirement,
        metal_composite_slack = metal_composite_slack,
        material_balance = material_balance,
        eol_balance = eol_balance,
        route_capacity_slack = route_capacity_slack,
        recycling_capacity_slack = recycling_capacity_slack,
        toaster_composite = toaster_composite,
        household_budget_m = household_budget_m,
        household_budget_c = household_budget_c,
        income_balance_m = income_balance_m,
        income_balance_c = income_balance_c,
        government_budget = government_budget,
        government_transfer = government_transfer,
        max_abs_market_residual = _max_abs(market_values),
        max_positive_capacity_slack = _max_positive(capacity_values),
        max_factor_slack = _max_positive(values(factor_slack)),
    )
end

function two_country_indicators(result)
    metadata = _two_country_run_metadata(result)
    policy = metadata.policy
    routes = Dict(route =>
            _solved_value(result, _global_var(:Z, _two_country_route_activity(route)))
        for route in ROUTES)
    total_routes = sum(values(routes))
    eol = Dict(use => _solved_value(result, _global_var(:EOL_C, use)) for use in EOL_USES)
    virgin_use_by_route = Dict(route =>
            _solved_value(result, _global_var(:VUSE, route, :M, :C))
        for route in MATERIAL_ROUTES)
    recycled_use_by_route = Dict(route =>
            _solved_value(result, _global_var(:RUSE, route, :C))
        for route in MATERIAL_ROUTES)
    virgin_imports = sum(values(virgin_use_by_route))
    recycled_use = sum(values(recycled_use_by_route))
    return (
        closure = metadata.closure,
        bread_m = _solved_value(result, :Z_BRD_M),
        bread_c = _solved_value(result, :Z_BRD_C),
        toaster_service_c = _solved_value(result, :Z_TST_C),
        virgin_metal_m = _solved_value(result, :Z_VMTL_M),
        recycled_metal_c = _solved_value(result, :Z_RMTL_C),
        virgin_imports_c = virgin_imports,
        recycled_use_c = recycled_use,
        route_quantity = routes,
        eol_quantity = eol,
        virgin_use_by_route = virgin_use_by_route,
        recycled_use_by_route = recycled_use_by_route,
        route_share = Dict(route => routes[route] / total_routes for route in ROUTES),
        eol_share = Dict(use => eol[use] / sum(values(eol)) for use in EOL_USES),
        wedge_accounting = _two_country_wedge_accounting(result, policy),
        activity = _two_country_activity_accounting(result),
        factor = _two_country_factor_accounting(result),
        prices = _two_country_prices(result),
        fiscal = (
            household_income_m = _solved_value(result, :Y_HOH_M),
            household_income_c = _solved_value(result, :Y_HOH_C),
            prefiscal_income_m = _solved_value(result, :Y_PREFISCAL_M),
            prefiscal_income_c = _solved_value(result, :Y_PREFISCAL_C),
            government_net_c = _solved_value(result, :GOV_NET_C),
            government_revenue_c = _solved_value(result, :GOV_REVENUE_C),
            government_subsidy_c = _solved_value(result, :GOV_SUBSIDY_C),
            government_transfer_c = _solved_value(result, :GOV_TRANSFER_C),
        ),
        closed_economy = two_country_closed_economy_residuals(result),
        utility_log = JuMP.objective_value(result.context.model),
    )
end

function two_country_benchmark_residuals(result; benchmark = two_country_benchmark())
    residuals = Dict{Symbol,Float64}()
    for a in (TWO_COUNTRY_PRODUCTION_ACTIVITIES..., :TST_C)
        residuals[_global_var(:Z, a)] = _solved_value(result, _global_var(:Z, a)) - benchmark.output[a]
    end
    for use in EOL_USES
        residuals[_global_var(:EOL_C, use)] =
            _solved_value(result, _global_var(:EOL_C, use)) - benchmark.eol_allocation[use]
    end
    for route in MATERIAL_ROUTES
        residuals[_global_var(:VUSE, route, :M, :C)] =
            _solved_value(result, _global_var(:VUSE, route, :M, :C)) -
            benchmark.material_input[(:VMTL, route)]
        residuals[_global_var(:RUSE, route, :C)] =
            _solved_value(result, _global_var(:RUSE, route, :C)) -
            benchmark.material_input[(:RMTL, route)]
    end
    return (
        residuals = residuals,
        max_abs = maximum(abs, values(residuals)),
    )
end
