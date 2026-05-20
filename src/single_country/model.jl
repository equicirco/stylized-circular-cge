"""
Build methods and model assembly for the single-country circular CGE blocks.
"""

function _require_single_model(ctx::JCGERuntime.KernelContext, block)
    ctx.model isa JuMP.Model ||
        error("$(typeof(block)) requires a JuMP-backed JCGE runtime context")
    return nothing
end

function _ensure_single_outputs!(ctx::JCGERuntime.KernelContext, bench)
    for a in (PRODUCTION_ACTIVITIES..., :TST)
        _ensure_var!(ctx, _global_var(:Z, a); start = bench.output[a])
    end
    return nothing
end

function _ensure_single_factors!(ctx::JCGERuntime.KernelContext, bench)
    for h in FACTORS, a in PRODUCTION_ACTIVITIES
        _ensure_var!(ctx, _global_var(:F, h, a);
            start = bench.factor_input[(h, a)])
    end
    return nothing
end

function _ensure_single_eol!(ctx::JCGERuntime.KernelContext, bench)
    for use in EOL_USES
        _ensure_var!(ctx, _global_var(:EOL, use);
            lower = 0.0, start = bench.eol_allocation[use])
    end
    return nothing
end

function _ensure_single_material_inputs!(ctx::JCGERuntime.KernelContext, params, bench)
    for route in MATERIAL_ROUTES
        _ensure_var!(ctx, _global_var(:MEFF, route);
            start = _metal_intensity(params, route) * bench.output[route])
        _ensure_var!(ctx, _global_var(:VUSE, route);
            start = bench.material_input[(:VMTL, route)])
        _ensure_var!(ctx, _global_var(:RUSE, route);
            start = bench.material_input[(:RMTL, route)])
    end
    return nothing
end

function _ensure_single_price_vars!(ctx::JCGERuntime.KernelContext, params, bench,
    policy::PolicyWedges)
    _ensure_var!(ctx, :P_BRD; start = 1.0)
    for use in EOL_USES
        _ensure_var!(ctx, _global_var(:P_EOL, use); start = _eol_unit_cost(policy, use))
    end
    for material in MATERIALS
        _ensure_var!(ctx, _global_var(:P_MAT, material);
            start = _material_unit_cost(params, bench, policy, material))
    end
    for route in MATERIAL_ROUTES
        _ensure_var!(ctx, _global_var(:P_MEFF, route); start = 1.0)
    end
    for route in ROUTES
        _ensure_var!(ctx, _global_var(:P_ROUTE, route);
            start = _route_unit_cost(params, bench, policy, route))
    end
    _ensure_var!(ctx, :P_TST; start = 1.0)
    return nothing
end

function _ensure_single_fiscal_vars!(ctx::JCGERuntime.KernelContext, params, bench)
    _ensure_var!(ctx, :Y_PREFISCAL; start = _pre_fiscal_income(params, bench))
    _ensure_var!(ctx, :Y_HOH; start = _pre_fiscal_income(params, bench))
    _ensure_var!(ctx, :GOV_NET; lower = nothing, start = 0.0)
    _ensure_var!(ctx, :GOV_REVENUE; lower = 0.0, start = 0.0)
    _ensure_var!(ctx, :GOV_SUBSIDY; lower = 0.0, start = 0.0)
    _ensure_var!(ctx, :GOV_TRANSFER; lower = nothing, start = 0.0)
    return nothing
end

function JCGECore.build!(block::SingleCountryBlock{:technology},
    ctx::JCGERuntime.KernelContext,
    spec::JCGECore.RunSpec)
    bench = block.benchmark
    _require_single_model(ctx, block)
    _ensure_single_outputs!(ctx, bench)
    _ensure_single_factors!(ctx, bench)

    for a in PRODUCTION_ACTIVITIES
        beta_lab = bench.factor_share[(:LAB, a)]
        beta_cap = bench.factor_share[(:CAP, a)]
        scale = bench.productivity[a]
        expr = _ele(_evar(:Z, a),
            _emul(
                _econst(scale),
                _epow(_evar(:F, :LAB, a), _econst(beta_lab)),
                _epow(_evar(:F, :CAP, a), _econst(beta_cap))))
        _register_ast_equation!(ctx, block, :technology, expr;
            info = "activity output is limited by calibrated Cobb-Douglas factor technology",
            indices = (a,))
    end

    for h in FACTORS
        expr = _ele(
            _sum_expr([_evar(:F, h, a) for a in PRODUCTION_ACTIVITIES]),
            _econst(bench.factor_endowment[h]))
        _register_ast_equation!(ctx, block, :factor_endowment, expr;
            info = "aggregate factor use is limited by the available factor endowment",
            indices = (h,))
    end

    return nothing
end

function JCGECore.build!(block::SingleCountryBlock{:eol},
    ctx::JCGERuntime.KernelContext,
    spec::JCGECore.RunSpec)
    params = block.params
    bench = block.benchmark
    policy = block.policy
    _require_single_model(ctx, block)
    _ensure_single_eol!(ctx, bench)

    ret = params.delta * bench.stock0
    if block.closure === :planner
        expr = _eeq(_esum(:use, EOL_USES, _evar(:EOL, _eidx(:use))), _econst(ret))
        _register_ast_equation!(ctx, block, :eol_allocation, expr;
            info = "end-of-life uses exhaust the returned stock")
    elseif block.closure === :fiscal
        eol_shares = _eol_allocation_shares(params, bench, policy)
        for use in EOL_USES
            expr = _eeq(_evar(:EOL, use), _econst(eol_shares[use] * ret))
            _register_ast_equation!(ctx, block, :eol_allocation, expr;
                info = "EOL allocation follows calibrated policy-adjusted use shares",
                indices = (use,))
        end
    else
        error("Unsupported single-country closure $(block.closure)")
    end

    for route in (:REF, :REP, :REU)
        y = _route_yield(params, route)
        expr = _ele(_evar(:Z, route), _scaled(y, _evar(:EOL, route)))
        _register_ast_equation!(ctx, block, :route_yield, expr;
            info = "life-extension route output is limited by available EOL units and route yield",
            indices = (route,))
    end

    expr = _ele(_evar(:Z, :RMTL), _scaled(params.yield.rmtl, _evar(:EOL, :REC)))
    _register_ast_equation!(ctx, block, :recycling_yield, expr;
        info = "recycled material output is limited by recycling EOL units and recycling yield")

    return nothing
end

function JCGECore.build!(block::SingleCountryBlock{:material},
    ctx::JCGERuntime.KernelContext,
    spec::JCGECore.RunSpec)
    params = block.params
    bench = block.benchmark
    _require_single_model(ctx, block)
    _ensure_single_material_inputs!(ctx, params, bench)

    for route in MATERIAL_ROUTES
        alpha = _metal_intensity(params, route)
        expr = _ele(_scaled(alpha, _evar(:Z, route)), _evar(:MEFF, route))
        _register_ast_equation!(ctx, block, :route_material_requirement, expr;
            info = "material-using route output requires effective metal input",
            indices = (route,))
    end

    rho_metal = (params.sigma_metal - 1.0) / params.sigma_metal
    phi = params.metal_quality
    for route in MATERIAL_ROUTES
        theta_v = bench.route_metal_share[(:VMTL, route)]
        theta_r = bench.route_metal_share[(:RMTL, route)]
        scale = bench.metal_scale[route]
        if abs(rho_metal) < 1.0e-8
            rhs = _emul(
                _econst(scale),
                _epow(_evar(:VUSE, route), _econst(theta_v)),
                _epow(_scaled(phi, _evar(:RUSE, route)), _econst(theta_r)))
        else
            rhs = _emul(
                _econst(scale),
                _epow(
                    _eadd(
                        _scaled(theta_v, _epow(_evar(:VUSE, route), _econst(rho_metal))),
                        _scaled(theta_r, _epow(_scaled(phi, _evar(:RUSE, route)), _econst(rho_metal)))),
                    _econst(1.0 / rho_metal)))
        end
        expr = _ele(_evar(:MEFF, route), rhs)
        _register_ast_equation!(ctx, block, :metal_composite, expr;
            info = "effective metal input is limited by the calibrated virgin-recycled material composite",
            indices = (route,))
    end

    if block.closure === :planner
        expr = _ele(_sum_expr([_evar(:VUSE, route) for route in MATERIAL_ROUTES]), _evar(:Z, :VMTL))
        _register_ast_equation!(ctx, block, :virgin_material_balance, expr;
            info = "virgin material use is limited by virgin material output")

        expr = _ele(_sum_expr([_evar(:RUSE, route) for route in MATERIAL_ROUTES]), _evar(:Z, :RMTL))
        _register_ast_equation!(ctx, block, :recycled_material_balance, expr;
            info = "recycled material use is limited by recycled material output")
    elseif block.closure === :fiscal
        expr = _eeq(_sum_expr([_evar(:VUSE, route) for route in MATERIAL_ROUTES]), _evar(:Z, :VMTL))
        _register_ast_equation!(ctx, block, :virgin_material_balance, expr;
            info = "virgin material use balances virgin material output")

        expr = _eeq(_sum_expr([_evar(:RUSE, route) for route in MATERIAL_ROUTES]), _evar(:Z, :RMTL))
        _register_ast_equation!(ctx, block, :recycled_material_balance, expr;
            info = "recycled material use balances recycled material output")
    else
        error("Unsupported single-country closure $(block.closure)")
    end

    return nothing
end

function JCGECore.build!(block::SingleCountryBlock{:route_service},
    ctx::JCGERuntime.KernelContext,
    spec::JCGECore.RunSpec)
    params = block.params
    bench = block.benchmark
    _require_single_model(ctx, block)

    rho_routes = (params.sigma_routes - 1.0) / params.sigma_routes
    route_scale = bench.route_scale
    if abs(rho_routes) < 1.0e-8
        rhs = _emul(
            _econst(route_scale),
            _prod_expr([
                _epow(_evar(:Z, route), _econst(bench.route_share[route]))
                for route in ROUTES
            ]))
    else
        rhs = _emul(
            _econst(route_scale),
            _epow(
                _sum_expr([
                    _scaled(bench.route_share[route],
                        _epow(_evar(:Z, route), _econst(rho_routes)))
                    for route in ROUTES
                ]),
                _econst(1.0 / rho_routes)))
    end
    expr = _ele(_evar(:Z, :TST), rhs)
    _register_ast_equation!(ctx, block, :toaster_service_composite, expr;
        info = "toaster-service output is limited by the calibrated route composite")

    return nothing
end

function JCGECore.build!(block::SingleCountryBlock{:replication},
    ctx::JCGERuntime.KernelContext,
    spec::JCGECore.RunSpec)
    block.replicate_benchmark || return nothing

    params = block.params
    bench = block.benchmark
    _require_single_model(ctx, block)
    _ensure_single_outputs!(ctx, bench)
    _ensure_single_factors!(ctx, bench)
    _ensure_single_eol!(ctx, bench)
    _ensure_single_material_inputs!(ctx, params, bench)

    for a in (PRODUCTION_ACTIVITIES..., :TST)
        expr = _eeq(_evar(:Z, a), _econst(bench.output[a]))
        _register_ast_equation!(ctx, block, :replicate_output, expr;
            info = "benchmark output replication", indices = (a,))
    end
    for h in FACTORS, a in PRODUCTION_ACTIVITIES
        expr = _eeq(_evar(:F, h, a), _econst(bench.factor_input[(h, a)]))
        _register_ast_equation!(ctx, block, :replicate_factor_input, expr;
            info = "benchmark factor-input replication", indices = (h, a))
    end
    for use in EOL_USES
        expr = _eeq(_evar(:EOL, use), _econst(bench.eol_allocation[use]))
        _register_ast_equation!(ctx, block, :replicate_eol, expr;
            info = "benchmark EOL allocation replication", indices = (use,))
    end
    for route in MATERIAL_ROUTES
        expr = _eeq(_evar(:VUSE, route), _econst(bench.material_input[(:VMTL, route)]))
        _register_ast_equation!(ctx, block, :replicate_virgin_use, expr;
            info = "benchmark virgin-material-use replication", indices = (route,))
        expr = _eeq(_evar(:RUSE, route), _econst(bench.material_input[(:RMTL, route)]))
        _register_ast_equation!(ctx, block, :replicate_recycled_use, expr;
            info = "benchmark recycled-material-use replication", indices = (route,))
    end

    return nothing
end

function _factor_unit_cost(bench, activity::Symbol)
    return sum(bench.factor_input[(h, activity)] for h in FACTORS) / bench.output[activity]
end

function _route_eol_coefficient(bench, route::Symbol)
    route in (:REF, :REP, :REU) || return 0.0
    return bench.eol_allocation[route] / bench.output[route]
end

function _recycling_eol_coefficient(bench)
    return bench.eol_allocation[:REC] / bench.output[:RMTL]
end

function _material_unit_cost(params, bench, policy::PolicyWedges, material::Symbol)
    if material === :VMTL
        cost = _factor_unit_cost(bench, :VMTL) + policy.material[:VMTL]
    elseif material === :RMTL
        cost = _factor_unit_cost(bench, :RMTL) +
               _recycling_eol_coefficient(bench) * _eol_unit_cost(policy, :REC) +
               policy.material[:RMTL]
    else
        error("Unknown material $(material)")
    end
    return _bounded_unit_cost(cost)
end

function _route_unit_cost(params, bench, policy::PolicyWedges, route::Symbol)
    cost = _factor_unit_cost(bench, route) + policy.route[route]
    if route in MATERIAL_ROUTES
        cost += _metal_intensity(params, route)
    end
    route in (:REF, :REP, :REU) && (cost += _route_eol_coefficient(bench, route) * _eol_unit_cost(policy, route))
    return _bounded_unit_cost(cost)
end

function _pre_fiscal_income(params, bench)
    return sum(values(bench.factor_endowment)) + params.delta * bench.stock0
end

function JCGECore.build!(block::SingleCountryBlock{:price},
    ctx::JCGERuntime.KernelContext,
    spec::JCGECore.RunSpec)
    block.closure === :fiscal ||
        error("Price block is only defined for the fiscal single-country closure")

    params = block.params
    bench = block.benchmark
    policy = block.policy
    _require_single_model(ctx, block)
    _ensure_single_price_vars!(ctx, params, bench, policy)

    expr = _eeq(_evar(:P_BRD), _econst(1.0))
    _register_ast_equation!(ctx, block, :numeraire, expr;
        info = "bread price numeraire")

    for use in EOL_USES
        unit_cost = _eol_unit_cost(policy, use)
        expr = _eeq(_evar(:P_EOL, use), _econst(unit_cost))
        _register_ast_equation!(ctx, block, :eol_price, expr;
            info = "EOL use price is set from policy-adjusted unit cost",
            indices = (use,))
    end

    expr = _ege(_evar(:P_MAT, :VMTL),
        _econst(_factor_unit_cost(bench, :VMTL) + policy.material[:VMTL]))
    _register_ast_equation!(ctx, block, :material_price, expr;
        info = "virgin material price covers factor cost and material policy wedge",
        indices = (:VMTL,))
    expr = _ege(_evar(:P_MAT, :RMTL),
        _eadd(
            _econst(_factor_unit_cost(bench, :RMTL) + policy.material[:RMTL]),
            _scaled(_recycling_eol_coefficient(bench), _evar(:P_EOL, :REC))))
    _register_ast_equation!(ctx, block, :material_price, expr;
        info = "recycled material price covers factor cost, EOL input cost, and material policy wedge",
        indices = (:RMTL,))

    for route in MATERIAL_ROUTES
        theta_v = bench.route_metal_share[(:VMTL, route)]
        theta_r = bench.route_metal_share[(:RMTL, route)]
        if abs(params.sigma_metal - 1.0) < 1.0e-8
            expr = _eeq(_evar(:P_MEFF, route),
                _emul(
                    _epow(_evar(:P_MAT, :VMTL), _econst(theta_v)),
                    _epow(_evar(:P_MAT, :RMTL), _econst(theta_r))))
        else
            expr = _eeq(_evar(:P_MEFF, route),
                _epow(
                    _eadd(
                        _scaled(theta_v,
                            _epow(_evar(:P_MAT, :VMTL), _econst(1.0 - params.sigma_metal))),
                        _scaled(theta_r,
                            _epow(_evar(:P_MAT, :RMTL), _econst(1.0 - params.sigma_metal)))),
                    _econst(1.0 / (1.0 - params.sigma_metal))))
        end
        _register_ast_equation!(ctx, block, :metal_price_index, expr;
            info = "effective metal price is the calibrated CES material price index",
            indices = (route,))
    end

    expr = _ege(_evar(:P_ROUTE, :NEW),
        _eadd(
            _econst(_factor_unit_cost(bench, :NEW) + policy.route[:NEW]),
            _scaled(_metal_intensity(params, :NEW), _evar(:P_MEFF, :NEW))))
    _register_ast_equation!(ctx, block, :route_price, expr;
        info = "new route price covers factor cost, metal-composite cost, and route wedge",
        indices = (:NEW,))
    for route in (:REF, :REP)
        expr = _ege(_evar(:P_ROUTE, route),
            _eadd(
                _econst(_factor_unit_cost(bench, route) + policy.route[route]),
                _scaled(_metal_intensity(params, route), _evar(:P_MEFF, route)),
                _scaled(_route_eol_coefficient(bench, route), _evar(:P_EOL, route))))
        _register_ast_equation!(ctx, block, :route_price, expr;
            info = "circular material-using route price covers factor, metal, EOL input, and route-wedge costs",
            indices = (route,))
    end
    expr = _ege(_evar(:P_ROUTE, :REU),
        _eadd(
            _econst(_factor_unit_cost(bench, :REU) + policy.route[:REU]),
            _scaled(_route_eol_coefficient(bench, :REU), _evar(:P_EOL, :REU))))
    _register_ast_equation!(ctx, block, :route_price, expr;
        info = "reuse route price covers factor, EOL input, and route-wedge costs",
        indices = (:REU,))

    if abs(params.sigma_routes - 1.0) < 1.0e-8
        expr = _eeq(_evar(:P_TST),
            _prod_expr([
                _epow(_evar(:P_ROUTE, route), _econst(bench.route_share[route]))
                for route in ROUTES
            ]))
    else
        expr = _eeq(_evar(:P_TST),
            _epow(
                _sum_expr([
                    _scaled(bench.route_share[route],
                        _epow(_evar(:P_ROUTE, route), _econst(1.0 - params.sigma_routes)))
                    for route in ROUTES
                ]),
                _econst(1.0 / (1.0 - params.sigma_routes))))
    end
    _register_ast_equation!(ctx, block, :toaster_service_price, expr;
        info = "toaster-service price is the calibrated CES route price index")

    return nothing
end

function JCGECore.build!(block::SingleCountryBlock{:fiscal_income},
    ctx::JCGERuntime.KernelContext,
    spec::JCGECore.RunSpec)
    block.closure === :fiscal ||
        error("Fiscal-income block is only defined for the fiscal single-country closure")

    params = block.params
    bench = block.benchmark
    policy = block.policy
    _require_single_model(ctx, block)
    _ensure_single_fiscal_vars!(ctx, params, bench)

    route_var = route -> _evar(:Z, route)
    virgin_var = route -> _evar(:VUSE, route)
    recycled_var = route -> _evar(:RUSE, route)
    eol_var = use -> _evar(:EOL, use)

    expr = _eeq(_evar(:Y_PREFISCAL), _econst(_pre_fiscal_income(params, bench)))
    _register_ast_equation!(ctx, block, :prefiscal_income, expr;
        info = "prefiscal income records factor and EOL endowment income")

    expr = _eeq(_evar(:GOV_NET),
        _policy_net_ast(policy;
            route_var = route_var,
            virgin_var = virgin_var,
            recycled_var = recycled_var,
            eol_var = eol_var))
    _register_ast_equation!(ctx, block, :government_net_revenue, expr;
        info = "net government revenue records tax revenue net of subsidy outlays")

    expr = _eeq(_evar(:GOV_REVENUE),
        _policy_revenue_ast(policy;
            route_var = route_var,
            virgin_var = virgin_var,
            recycled_var = recycled_var,
            eol_var = eol_var))
    _register_ast_equation!(ctx, block, :government_revenue, expr;
        info = "gross government revenue records positive policy wedge receipts")

    expr = _eeq(_evar(:GOV_SUBSIDY),
        _policy_subsidy_ast(policy;
            route_var = route_var,
            virgin_var = virgin_var,
            recycled_var = recycled_var,
            eol_var = eol_var))
    _register_ast_equation!(ctx, block, :government_subsidy, expr;
        info = "gross government subsidy records negative policy wedge outlays")

    expr = _eeq(_evar(:GOV_TRANSFER), _evar(:GOV_NET))
    _register_ast_equation!(ctx, block, :government_transfer, expr;
        info = "net government revenue is rebated to households; negative values are lump-sum financing")

    expr = _eeq(_evar(:Y_HOH), _eadd(_evar(:Y_PREFISCAL), _evar(:GOV_TRANSFER)))
    _register_ast_equation!(ctx, block, :household_income, expr;
        info = "household income includes prefiscal income and net government transfer")

    return nothing
end

function JCGECore.build!(block::SingleCountryBlock{:demand},
    ctx::JCGERuntime.KernelContext,
    spec::JCGECore.RunSpec)
    block.closure === :fiscal ||
        error("Demand block is only defined for the fiscal single-country closure")

    params = block.params
    bench = block.benchmark
    _require_single_model(ctx, block)

    y0 = _pre_fiscal_income(params, bench)
    expr = _eeq(_evar(:Z, :TST),
        _emul(
            _econst(bench.output[:TST]),
            _ediv(_evar(:Y_HOH), _econst(y0)),
            _epow(_evar(:P_TST), _econst(-params.eta_service))))
    _register_ast_equation!(ctx, block, :household_toaster_demand, expr;
        info = "toaster-service demand follows an income-scaled isoelastic demand curve")

    expr = _eeq(_evar(:Z, :BRD),
        _ediv(
            _eadd(_evar(:Y_HOH), _eneg(_emul(_evar(:P_TST), _evar(:Z, :TST)))),
            _evar(:P_BRD)))
    _register_ast_equation!(ctx, block, :household_bread_demand, expr;
        info = "bread demand absorbs residual household income after toaster-service expenditure")

    for route in ROUTES
        expr = _eeq(_evar(:Z, route),
            _emul(
                _econst(bench.route_share[route]),
                _evar(:Z, :TST),
                _epow(_ediv(_evar(:P_TST), _evar(:P_ROUTE, route)),
                    _econst(params.sigma_routes))))
        _register_ast_equation!(ctx, block, :route_demand, expr;
            info = "route demand follows calibrated CES route substitution",
            indices = (route,))
    end

    for route in MATERIAL_ROUTES
        base_eff = _metal_intensity(params, route) * bench.output[route]
        expr = _eeq(_evar(:VUSE, route),
            _emul(
                _econst(bench.material_input[(:VMTL, route)]),
                _ediv(_evar(:MEFF, route), _econst(base_eff)),
                _epow(_ediv(_evar(:P_MEFF, route), _evar(:P_MAT, :VMTL)),
                    _econst(params.sigma_metal))))
        _register_ast_equation!(ctx, block, :virgin_material_demand, expr;
            info = "virgin material demand follows calibrated CES material substitution",
            indices = (route,))

        expr = _eeq(_evar(:RUSE, route),
            _emul(
                _econst(bench.material_input[(:RMTL, route)]),
                _ediv(_evar(:MEFF, route), _econst(base_eff)),
                _epow(_ediv(_evar(:P_MEFF, route), _evar(:P_MAT, :RMTL)),
                    _econst(params.sigma_metal))))
        _register_ast_equation!(ctx, block, :recycled_material_demand, expr;
            info = "recycled material demand follows calibrated CES material substitution",
            indices = (route,))
    end

    return nothing
end

function JCGECore.build!(block::SingleCountryBlock{:objective},
    ctx::JCGERuntime.KernelContext,
    spec::JCGECore.RunSpec)
    bench = block.benchmark
    _require_single_model(ctx, block)

    alpha_brd = bench.utility_share[:BRD]
    alpha_tst = bench.utility_share[:TST]

    if block.closure === :planner
        policy = block.policy
        total_final_demand = bench.output[:BRD] + bench.output[:TST]
        route_var = route -> _evar(:Z, route)
        virgin_var = route -> _evar(:VUSE, route)
        recycled_var = route -> _evar(:RUSE, route)
        eol_var = use -> _evar(:EOL, use)
        expr = _eadd(
            _scaled(alpha_brd, _elog(_evar(:Z, :BRD))),
            _scaled(alpha_tst, _elog(_evar(:Z, :TST))),
            _eneg(_ediv(
                _policy_net_ast(policy;
                    route_var = route_var,
                    virgin_var = virgin_var,
                    recycled_var = recycled_var,
                    eol_var = eol_var),
                _econst(total_final_demand))))
        _register_ast_objective!(ctx, block, expr;
            info = "planner utility objective")
    elseif block.closure === :fiscal
        expr = _eadd(
            _scaled(alpha_brd, _elog(_evar(:Z, :BRD))),
            _scaled(alpha_tst, _elog(_evar(:Z, :TST))))
        _register_ast_objective!(ctx, block, expr;
            info = "household utility objective under fiscal closure")
    else
        error("Unsupported single-country closure $(block.closure)")
    end

    return nothing
end

"""
    model(; params=default_parameters(), benchmark=synthetic_benchmark(params), name="StylizedCircularCGE")

Return the first one-period JCGE RunSpec for the stylized circular economy.
"""
function model(; params = default_parameters(),
    benchmark = synthetic_benchmark(params),
    name::String = "StylizedCircularCGE",
    scenario_spec::JCGECore.ScenarioSpec = scenario(:baseline),
    replicate_benchmark::Bool = false,
    policy::PolicyWedges = zero_policy())
    commodities = collect(Symbol, GOODS)
    activities = collect(Symbol, PRODUCTION_ACTIVITIES)
    factors = collect(Symbol, FACTORS)
    institutions = collect(Symbol, INSTITUTIONS)
    sets = JCGECore.Sets(commodities, activities, factors, institutions)
    mappings = JCGECore.Mappings(Dict(a => a for a in activities))
    blocks = _single_country_blocks(;
        params = params,
        benchmark = benchmark,
        replicate_benchmark = replicate_benchmark,
        policy = policy,
        closure = :planner)

    allowed = JCGECore.allowed_sections()
    section_blocks = Dict(sym => Any[] for sym in allowed)
    append!(section_blocks[:production], blocks)
    sections = [JCGECore.section(sym, section_blocks[sym]) for sym in allowed]

    return JCGECore.build_spec(
        name,
        sets,
        mappings,
        sections;
        closure = JCGECore.ClosureSpec(:LAB),
        scenario = scenario_spec,
        required_sections = allowed,
        allowed_sections = allowed,
        required_nonempty = [:production],
    )
end

"""
Return the planner-form baseline RunSpec.
"""
baseline(; kwargs...) = model(; kwargs...)

"""
    fiscal_model(; params=default_parameters(), benchmark=synthetic_benchmark(params), policy=zero_policy())

Return the one-period fiscal-closure RunSpec. This variant keeps the physical
circular constraints but interprets policy wedges as tax/subsidy instruments with
household income, purchaser prices, and government net revenue.
"""
function fiscal_model(; params = default_parameters(),
    benchmark = synthetic_benchmark(params),
    name::String = "StylizedCircularCGEFiscal",
    scenario_spec::JCGECore.ScenarioSpec = scenario(:baseline),
    replicate_benchmark::Bool = false,
    policy::PolicyWedges = zero_policy())
    commodities = collect(Symbol, GOODS)
    activities = collect(Symbol, PRODUCTION_ACTIVITIES)
    factors = collect(Symbol, FACTORS)
    institutions = collect(Symbol, INSTITUTIONS)
    sets = JCGECore.Sets(commodities, activities, factors, institutions)
    mappings = JCGECore.Mappings(Dict(a => a for a in activities))
    blocks = _single_country_blocks(;
        params = params,
        benchmark = benchmark,
        replicate_benchmark = replicate_benchmark,
        policy = policy,
        closure = :fiscal)

    allowed = JCGECore.allowed_sections()
    section_blocks = Dict(sym => Any[] for sym in allowed)
    append!(section_blocks[:production], blocks)
    sections = [JCGECore.section(sym, section_blocks[sym]) for sym in allowed]

    return JCGECore.build_spec(
        name,
        sets,
        mappings,
        sections;
        closure = JCGECore.ClosureSpec(:LAB),
        scenario = scenario_spec,
        required_sections = allowed,
        allowed_sections = allowed,
        required_nonempty = [:production],
    )
end

"""
Return the fiscal-closure baseline RunSpec.
"""
fiscal_baseline(; kwargs...) = fiscal_model(; kwargs...)

decentralized_model(; kwargs...) = fiscal_model(; kwargs...)
decentralized_baseline(; kwargs...) = fiscal_baseline(; kwargs...)

"""
Create a scenario descriptor. Scenario shocks are recorded for reproducibility;
the first executable block does not yet apply policy shocks automatically.
"""
function scenario(name::Symbol; shocks...)
    return JCGECore.ScenarioSpec(name, Dict{Symbol,Any}(shocks))
end

"""
Solve the fiscal closed-economy baseline or supplied model specification.
"""
function solve(spec::JCGECore.RunSpec = fiscal_baseline();
    optimizer = JuMP.optimizer_with_attributes(Ipopt.Optimizer, "print_level" => 0, "sb" => "yes"),
    kwargs...)
    return JCGERuntime.run!(spec; optimizer = optimizer, kwargs...)
end

function _solved_value(result, name::Symbol)
    return JuMP.value(result.context.variables[name])
end

function _run_metadata(result)
    for eq in result.context.equations
        if eq.tag == :metadata &&
           haskey(eq.payload, :closure) &&
           eq.payload.closure in (:planner, :fiscal)
            return eq.payload
        end
    end
    return (
        policy = zero_policy(),
        benchmark = synthetic_benchmark(),
        params = default_parameters(),
        closure = :planner,
    )
end

function _wedge_accounting(result, policy::PolicyWedges)
    route = Dict(route =>
            policy.route[route] * _solved_value(result, _global_var(:Z, route))
        for route in ROUTES)
    material = Dict(
        :VMTL => policy.material[:VMTL] *
                 sum(_solved_value(result, _global_var(:VUSE, route)) for route in MATERIAL_ROUTES),
        :RMTL => policy.material[:RMTL] *
                 sum(_solved_value(result, _global_var(:RUSE, route)) for route in MATERIAL_ROUTES),
    )
    eol = Dict(use =>
            policy.eol[use] * _solved_value(result, _global_var(:EOL, use))
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

function _maybe_solved_value(result, name::Symbol)
    haskey(result.context.variables, name) || return NaN
    return _solved_value(result, name)
end

function _fiscal_accounting(result)
    haskey(result.context.variables, :Y_HOH) || return (
        household_income = NaN,
        prefiscal_income = NaN,
        government_net = NaN,
        government_revenue = NaN,
        government_subsidy = NaN,
        government_transfer = NaN,
    )
    return (
        household_income = _solved_value(result, :Y_HOH),
        prefiscal_income = _solved_value(result, :Y_PREFISCAL),
        government_net = _solved_value(result, :GOV_NET),
        government_revenue = _solved_value(result, :GOV_REVENUE),
        government_subsidy = _solved_value(result, :GOV_SUBSIDY),
        government_transfer = _solved_value(result, :GOV_TRANSFER),
    )
end

function _price_accounting(result)
    return (
        bread = _maybe_solved_value(result, :P_BRD),
        toaster_service = _maybe_solved_value(result, :P_TST),
        route = Dict(route => _maybe_solved_value(result, _global_var(:P_ROUTE, route))
            for route in ROUTES),
        material = Dict(material => _maybe_solved_value(result, _global_var(:P_MAT, material))
            for material in MATERIALS),
        eol = Dict(use => _maybe_solved_value(result, _global_var(:P_EOL, use))
            for use in EOL_USES),
    )
end

function _activity_accounting(result)
    quantity = Dict(a => _solved_value(result, _global_var(:Z, a))
        for a in PRODUCTION_ACTIVITIES)
    total = sum(values(quantity))
    share = Dict(a => total <= 1.0e-12 ? NaN : quantity[a] / total
        for a in PRODUCTION_ACTIVITIES)
    return (
        quantity = quantity,
        total = total,
        share = share,
    )
end

function _factor_accounting(result)
    use = Dict((h, a) => _solved_value(result, _global_var(:F, h, a))
        for h in FACTORS for a in PRODUCTION_ACTIVITIES)
    by_factor = Dict(h => sum(use[(h, a)] for a in PRODUCTION_ACTIVITIES)
        for h in FACTORS)
    by_activity = Dict(a => sum(use[(h, a)] for h in FACTORS)
        for a in PRODUCTION_ACTIVITIES)
    total = sum(values(by_activity))
    factor_activity_share = Dict((h, a) =>
            by_factor[h] <= 1.0e-12 ? NaN : use[(h, a)] / by_factor[h]
        for h in FACTORS for a in PRODUCTION_ACTIVITIES)
    activity_share = Dict(a => total <= 1.0e-12 ? NaN : by_activity[a] / total
        for a in PRODUCTION_ACTIVITIES)
    return (
        use = use,
        by_factor = by_factor,
        by_activity = by_activity,
        total = total,
        factor_activity_share = factor_activity_share,
        activity_share = activity_share,
    )
end

function _max_abs(values)
    finite_values = [abs(Float64(value)) for value in values if isfinite(Float64(value))]
    isempty(finite_values) && return NaN
    return maximum(finite_values)
end

function _max_positive(values)
    finite_values = [max(Float64(value), 0.0) for value in values if isfinite(Float64(value))]
    isempty(finite_values) && return NaN
    return maximum(finite_values)
end

function _technology_output(params, bench, result, activity::Symbol)
    lab = _solved_value(result, _global_var(:F, :LAB, activity))
    cap = _solved_value(result, _global_var(:F, :CAP, activity))
    beta_lab = bench.factor_share[(:LAB, activity)]
    beta_cap = bench.factor_share[(:CAP, activity)]
    return bench.productivity[activity] * lab^beta_lab * cap^beta_cap
end

function _metal_composite_output(params, bench, result, route::Symbol)
    vuse = _solved_value(result, _global_var(:VUSE, route))
    ruse = _solved_value(result, _global_var(:RUSE, route))
    inputs = Dict(:VMTL => vuse, :RMTL => ruse)
    shares = Dict(m => bench.route_metal_share[(m, route)] for m in MATERIALS)
    quality = Dict(:VMTL => 1.0, :RMTL => params.metal_quality)
    return bench.metal_scale[route] *
           _ces_quantity(inputs, shares, params.sigma_metal; quality = quality)
end

function _toaster_service_composite(params, bench, result)
    inputs = Dict(route => _solved_value(result, _global_var(:Z, route)) for route in ROUTES)
    shares = Dict(route => bench.route_share[route] for route in ROUTES)
    return bench.route_scale * _ces_quantity(inputs, shares, params.sigma_routes)
end

"""
    closed_economy_residuals(result)

Return accounting residuals and capacity slacks for the one-period model. Market
residuals should be close to zero in the fiscal closed-economy closure; positive
capacity slacks are reported separately so unused domestic technology, route,
recycling, or factor capacity is not treated as market leakage.
"""
function closed_economy_residuals(result)
    metadata = _run_metadata(result)
    params = metadata.params
    bench = metadata.benchmark

    factor_slack = Dict(h =>
            bench.factor_endowment[h] -
            sum(_solved_value(result, _global_var(:F, h, a)) for a in PRODUCTION_ACTIVITIES)
        for h in FACTORS)

    technology_slack = Dict(a =>
            _technology_output(params, bench, result, a) -
            _solved_value(result, _global_var(:Z, a))
        for a in PRODUCTION_ACTIVITIES)

    material_requirement = Dict(route =>
            _solved_value(result, _global_var(:MEFF, route)) -
            _metal_intensity(params, route) * _solved_value(result, _global_var(:Z, route))
        for route in MATERIAL_ROUTES)

    metal_composite_slack = Dict(route =>
            _metal_composite_output(params, bench, result, route) -
            _solved_value(result, _global_var(:MEFF, route))
        for route in MATERIAL_ROUTES)

    material_balance = Dict(
        :VMTL => _solved_value(result, :Z_VMTL) -
                 sum(_solved_value(result, _global_var(:VUSE, route)) for route in MATERIAL_ROUTES),
        :RMTL => _solved_value(result, :Z_RMTL) -
                 sum(_solved_value(result, _global_var(:RUSE, route)) for route in MATERIAL_ROUTES),
    )

    eol_total = sum(_solved_value(result, _global_var(:EOL, use)) for use in EOL_USES)
    eol_balance = eol_total - params.delta * bench.stock0
    route_capacity_slack = Dict(route =>
            _route_yield(params, route) * _solved_value(result, _global_var(:EOL, route)) -
            _solved_value(result, _global_var(:Z, route))
        for route in (:REF, :REP, :REU))
    recycling_capacity_slack =
        params.yield.rmtl * _solved_value(result, :EOL_REC) - _solved_value(result, :Z_RMTL)

    toaster_composite = _toaster_service_composite(params, bench, result) - _solved_value(result, :Z_TST)

    household_budget =
        if haskey(result.context.variables, :Y_HOH)
            _solved_value(result, :Y_HOH) -
            (_solved_value(result, :P_BRD) * _solved_value(result, :Z_BRD) +
             _solved_value(result, :P_TST) * _solved_value(result, :Z_TST))
        else
            NaN
        end
    income_balance =
        if haskey(result.context.variables, :Y_HOH)
            _solved_value(result, :Y_HOH) -
            (_solved_value(result, :Y_PREFISCAL) + _solved_value(result, :GOV_TRANSFER))
        else
            NaN
        end
    government_budget =
        if haskey(result.context.variables, :GOV_NET)
            _solved_value(result, :GOV_NET) - _wedge_accounting(result, metadata.policy).net
        else
            NaN
        end
    government_transfer =
        if haskey(result.context.variables, :GOV_TRANSFER)
            _solved_value(result, :GOV_TRANSFER) - _solved_value(result, :GOV_NET)
        else
            NaN
        end

    market_values = vcat(
        collect(values(material_balance)),
        [eol_balance, household_budget, income_balance,
            government_budget, government_transfer],
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
        household_budget = household_budget,
        income_balance = income_balance,
        government_budget = government_budget,
        government_transfer = government_transfer,
        max_abs_market_residual = _max_abs(market_values),
        max_positive_capacity_slack = _max_positive(capacity_values),
        max_factor_slack = _max_positive(values(factor_slack)),
    )
end

"""
    indicators(result)

Return a compact indicator table as a NamedTuple for a solved V0 model.
"""
function indicators(result)
    metadata = _run_metadata(result)
    policy = metadata.policy
    routes = Dict(route => _solved_value(result, _global_var(:Z, route)) for route in ROUTES)
    total_routes = sum(values(routes))
    eol = Dict(use => _solved_value(result, _global_var(:EOL, use)) for use in EOL_USES)
    virgin_use_by_route = Dict(route => _solved_value(result, _global_var(:VUSE, route))
        for route in MATERIAL_ROUTES)
    recycled_use_by_route = Dict(route => _solved_value(result, _global_var(:RUSE, route))
        for route in MATERIAL_ROUTES)
    virgin_use = sum(values(virgin_use_by_route))
    recycled_use = sum(values(recycled_use_by_route))
    residuals = closed_economy_residuals(result)
    return (
        closure = metadata.closure,
        bread = _solved_value(result, :Z_BRD),
        toaster_service = _solved_value(result, :Z_TST),
        virgin_metal = _solved_value(result, :Z_VMTL),
        recycled_metal = _solved_value(result, :Z_RMTL),
        virgin_use = virgin_use,
        recycled_use = recycled_use,
        route_quantity = routes,
        eol_quantity = eol,
        virgin_use_by_route = virgin_use_by_route,
        recycled_use_by_route = recycled_use_by_route,
        route_share = Dict(route => routes[route] / total_routes for route in ROUTES),
        eol_share = Dict(use => eol[use] / sum(values(eol)) for use in EOL_USES),
        wedge_accounting = _wedge_accounting(result, policy),
        activity = _activity_accounting(result),
        factor = _factor_accounting(result),
        prices = _price_accounting(result),
        fiscal = _fiscal_accounting(result),
        closed_economy = residuals,
        utility_log = JuMP.objective_value(result.context.model),
    )
end

"""
    benchmark_residuals(result; benchmark=synthetic_benchmark())

Compare a solved result to the round-number benchmark quantities.
"""
function benchmark_residuals(result; benchmark = synthetic_benchmark())
    residuals = Dict{Symbol,Float64}()
    for a in (PRODUCTION_ACTIVITIES..., :TST)
        residuals[_global_var(:Z, a)] = _solved_value(result, _global_var(:Z, a)) - benchmark.output[a]
    end
    for use in EOL_USES
        residuals[_global_var(:EOL, use)] =
            _solved_value(result, _global_var(:EOL, use)) - benchmark.eol_allocation[use]
    end
    for route in MATERIAL_ROUTES
        residuals[_global_var(:VUSE, route)] =
            _solved_value(result, _global_var(:VUSE, route)) - benchmark.material_input[(:VMTL, route)]
        residuals[_global_var(:RUSE, route)] =
            _solved_value(result, _global_var(:RUSE, route)) - benchmark.material_input[(:RMTL, route)]
    end
    return (
        residuals = residuals,
        max_abs = maximum(abs, values(residuals)),
    )
end
