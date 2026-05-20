"""
Build methods and model assembly for the two-country circular CGE blocks.
"""

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

function _require_two_country_model(ctx::JCGERuntime.KernelContext, block)
    ctx.model isa JuMP.Model ||
        error("$(typeof(block)) requires a JuMP-backed JCGE runtime context")
    return nothing
end

function _ensure_two_country_outputs!(ctx::JCGERuntime.KernelContext, bench)
    for a in (TWO_COUNTRY_PRODUCTION_ACTIVITIES..., :TST_C)
        _ensure_var!(ctx, _global_var(:Z, a); start = bench.output[a])
    end
    return nothing
end

function _ensure_two_country_factors!(ctx::JCGERuntime.KernelContext, bench)
    for a in TWO_COUNTRY_PRODUCTION_ACTIVITIES
        for h in _two_country_activity_factors(a)
            _ensure_var!(ctx, _global_var(:F, h, a);
                start = bench.factor_input[(h, a)])
        end
    end
    return nothing
end

function _ensure_two_country_eol!(ctx::JCGERuntime.KernelContext, bench)
    for use in EOL_USES
        _ensure_var!(ctx, _global_var(:EOL_C, use);
            lower = 0.0, start = bench.eol_allocation[use])
    end
    return nothing
end

function _ensure_two_country_material_inputs!(ctx::JCGERuntime.KernelContext, params, bench)
    for route in MATERIAL_ROUTES
        activity = _two_country_route_activity(route)
        _ensure_var!(ctx, _global_var(:MEFF, route, :C);
            start = _metal_intensity(params, route) * bench.output[activity])
        _ensure_var!(ctx, _global_var(:VUSE, route, :M, :C);
            start = bench.material_input[(:VMTL, route)])
        _ensure_var!(ctx, _global_var(:RUSE, route, :C);
            start = bench.material_input[(:RMTL, route)])
    end
    return nothing
end

function _ensure_two_country_price_vars!(ctx::JCGERuntime.KernelContext, params, bench,
    policy::PolicyWedges)
    _ensure_var!(ctx, :P_BRD_M; start = 1.0)
    _ensure_var!(ctx, :P_BRD_C; start = 1.0)
    for use in EOL_USES
        _ensure_var!(ctx, _global_var(:P_EOL_C, use); start = _eol_unit_cost(policy, use))
    end
    for material in MATERIALS
        _ensure_var!(ctx, _global_var(:P_MAT_C, material);
            start = _two_country_material_unit_cost(params, bench, policy, material))
    end
    for route in MATERIAL_ROUTES
        _ensure_var!(ctx, _global_var(:P_MEFF_C, route); start = 1.0)
    end
    for route in ROUTES
        _ensure_var!(ctx, _global_var(:P_ROUTE_C, route);
            start = _two_country_route_unit_cost(params, bench, policy, route))
    end
    _ensure_var!(ctx, :P_TST_C; start = 1.0)
    return nothing
end

function _ensure_two_country_fiscal_vars!(ctx::JCGERuntime.KernelContext, bench)
    _ensure_var!(ctx, :Y_PREFISCAL_M; start = bench.prefiscal_income_m)
    _ensure_var!(ctx, :Y_HOH_M; start = bench.disposable_income_m)
    _ensure_var!(ctx, :Y_PREFISCAL_C; start = bench.prefiscal_income_c)
    _ensure_var!(ctx, :Y_HOH_C; start = bench.prefiscal_income_c)
    _ensure_var!(ctx, :GOV_NET_C; lower = nothing, start = 0.0)
    _ensure_var!(ctx, :GOV_REVENUE_C; lower = 0.0, start = 0.0)
    _ensure_var!(ctx, :GOV_SUBSIDY_C; lower = 0.0, start = 0.0)
    _ensure_var!(ctx, :GOV_TRANSFER_C; lower = nothing, start = 0.0)
    return nothing
end

function JCGECore.build!(block::TwoCountryBlock{:technology},
    ctx::JCGERuntime.KernelContext,
    spec::JCGECore.RunSpec)
    bench = block.benchmark
    _require_two_country_model(ctx, block)
    _ensure_two_country_outputs!(ctx, bench)
    _ensure_two_country_factors!(ctx, bench)

    for a in TWO_COUNTRY_PRODUCTION_ACTIVITIES
        lab, cap = _two_country_activity_factors(a)
        beta_lab = bench.factor_share[(lab, a)]
        beta_cap = bench.factor_share[(cap, a)]
        scale = bench.productivity[a]
        expr = _ele(_evar(:Z, a),
            _emul(
                _econst(scale),
                _epow(_evar(:F, lab, a), _econst(beta_lab)),
                _epow(_evar(:F, cap, a), _econst(beta_cap))))
        _register_ast_equation!(ctx, block, :technology, expr;
            info = "activity output is limited by calibrated local Cobb-Douglas factor technology",
            indices = (a,))
    end

    for h in TWO_COUNTRY_FACTORS
        activities = [a for a in TWO_COUNTRY_PRODUCTION_ACTIVITIES
                      if h in _two_country_activity_factors(a)]
        expr = _ele(
            _sum_expr([_evar(:F, h, a) for a in activities]),
            _econst(bench.factor_endowment[h]))
        _register_ast_equation!(ctx, block, :factor_endowment, expr;
            info = "aggregate factor use is limited by the country-specific factor endowment",
            indices = (h,))
    end

    return nothing
end

function JCGECore.build!(block::TwoCountryBlock{:eol},
    ctx::JCGERuntime.KernelContext,
    spec::JCGECore.RunSpec)
    params = block.params
    bench = block.benchmark
    policy = block.policy
    _require_two_country_model(ctx, block)
    _ensure_two_country_eol!(ctx, bench)

    ret = params.delta * bench.stock0
    eol_shares = _eol_allocation_shares(params, bench, policy)
    for use in EOL_USES
        expr = _eeq(_evar(:EOL_C, use), _econst(eol_shares[use] * ret))
        _register_ast_equation!(ctx, block, :eol_allocation, expr;
            info = "country C EOL allocation follows calibrated policy-adjusted use shares",
            indices = (use,))
    end

    for route in (:REF, :REP, :REU)
        expr = _ele(_evar(:Z, _two_country_route_activity(route)),
            _scaled(_route_yield(params, route), _evar(:EOL_C, route)))
        _register_ast_equation!(ctx, block, :route_yield, expr;
            info = "country C life-extension route output is limited by available EOL units and route yield",
            indices = (route,))
    end

    expr = _ele(_evar(:Z, :RMTL_C), _scaled(params.yield.rmtl, _evar(:EOL_C, :REC)))
    _register_ast_equation!(ctx, block, :recycling_yield, expr;
        info = "country C recycled material output is limited by recycling EOL units and recycling yield")

    return nothing
end

function JCGECore.build!(block::TwoCountryBlock{:material},
    ctx::JCGERuntime.KernelContext,
    spec::JCGECore.RunSpec)
    params = block.params
    bench = block.benchmark
    _require_two_country_model(ctx, block)
    _ensure_two_country_material_inputs!(ctx, params, bench)

    for route in MATERIAL_ROUTES
        activity = _two_country_route_activity(route)
        alpha = _metal_intensity(params, route)
        expr = _ele(_scaled(alpha, _evar(:Z, activity)), _evar(:MEFF, route, :C))
        _register_ast_equation!(ctx, block, :route_material_requirement, expr;
            info = "country C material-using route output requires effective metal input",
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
                _epow(_evar(:VUSE, route, :M, :C), _econst(theta_v)),
                _epow(_scaled(phi, _evar(:RUSE, route, :C)), _econst(theta_r)))
        else
            rhs = _emul(
                _econst(scale),
                _epow(
                    _eadd(
                        _scaled(theta_v,
                            _epow(_evar(:VUSE, route, :M, :C), _econst(rho_metal))),
                        _scaled(theta_r,
                            _epow(_scaled(phi, _evar(:RUSE, route, :C)), _econst(rho_metal)))),
                    _econst(1.0 / rho_metal)))
        end
        expr = _ele(_evar(:MEFF, route, :C), rhs)
        _register_ast_equation!(ctx, block, :metal_composite, expr;
            info = "country C effective metal input is limited by the calibrated imported-virgin and local-recycled material composite",
            indices = (route,))
    end

    expr = _eeq(_sum_expr([_evar(:VUSE, route, :M, :C) for route in MATERIAL_ROUTES]),
        _evar(:Z, :VMTL_M))
    _register_ast_equation!(ctx, block, :virgin_material_import_balance, expr;
        info = "country C imported virgin material use balances country M virgin material output")

    expr = _eeq(_sum_expr([_evar(:RUSE, route, :C) for route in MATERIAL_ROUTES]),
        _evar(:Z, :RMTL_C))
    _register_ast_equation!(ctx, block, :recycled_material_balance, expr;
        info = "country C recycled material use balances country C recycled material output")

    return nothing
end

function JCGECore.build!(block::TwoCountryBlock{:route_service},
    ctx::JCGERuntime.KernelContext,
    spec::JCGECore.RunSpec)
    params = block.params
    bench = block.benchmark
    _require_two_country_model(ctx, block)

    rho_routes = (params.sigma_routes - 1.0) / params.sigma_routes
    if abs(rho_routes) < 1.0e-8
        rhs = _emul(
            _econst(bench.route_scale),
            _prod_expr([
                _epow(_evar(:Z, _two_country_route_activity(route)),
                    _econst(bench.route_share[route]))
                for route in ROUTES
            ]))
    else
        rhs = _emul(
            _econst(bench.route_scale),
            _epow(
                _sum_expr([
                    _scaled(bench.route_share[route],
                        _epow(_evar(:Z, _two_country_route_activity(route)),
                            _econst(rho_routes)))
                    for route in ROUTES
                ]),
                _econst(1.0 / rho_routes)))
    end
    expr = _ele(_evar(:Z, :TST_C), rhs)
    _register_ast_equation!(ctx, block, :toaster_service_composite, expr;
        info = "country C toaster-service output is limited by the calibrated route composite")

    return nothing
end

function JCGECore.build!(block::TwoCountryBlock{:replication},
    ctx::JCGERuntime.KernelContext,
    spec::JCGECore.RunSpec)
    block.replicate_benchmark || return nothing

    params = block.params
    bench = block.benchmark
    _require_two_country_model(ctx, block)
    _ensure_two_country_outputs!(ctx, bench)
    _ensure_two_country_factors!(ctx, bench)
    _ensure_two_country_eol!(ctx, bench)
    _ensure_two_country_material_inputs!(ctx, params, bench)

    for a in (TWO_COUNTRY_PRODUCTION_ACTIVITIES..., :TST_C)
        expr = _eeq(_evar(:Z, a), _econst(bench.output[a]))
        _register_ast_equation!(ctx, block, :replicate_output, expr;
            info = "benchmark output replication", indices = (a,))
    end
    for a in TWO_COUNTRY_PRODUCTION_ACTIVITIES, h in _two_country_activity_factors(a)
        expr = _eeq(_evar(:F, h, a), _econst(bench.factor_input[(h, a)]))
        _register_ast_equation!(ctx, block, :replicate_factor_input, expr;
            info = "benchmark factor-input replication", indices = (h, a))
    end
    for use in EOL_USES
        expr = _eeq(_evar(:EOL_C, use), _econst(bench.eol_allocation[use]))
        _register_ast_equation!(ctx, block, :replicate_eol, expr;
            info = "benchmark EOL allocation replication", indices = (use,))
    end
    for route in MATERIAL_ROUTES
        expr = _eeq(_evar(:VUSE, route, :M, :C), _econst(bench.material_input[(:VMTL, route)]))
        _register_ast_equation!(ctx, block, :replicate_virgin_use, expr;
            info = "benchmark imported virgin-material-use replication", indices = (route,))
        expr = _eeq(_evar(:RUSE, route, :C), _econst(bench.material_input[(:RMTL, route)]))
        _register_ast_equation!(ctx, block, :replicate_recycled_use, expr;
            info = "benchmark recycled-material-use replication", indices = (route,))
    end

    return nothing
end

function JCGECore.build!(block::TwoCountryBlock{:price},
    ctx::JCGERuntime.KernelContext,
    spec::JCGECore.RunSpec)
    params = block.params
    bench = block.benchmark
    policy = block.policy
    _require_two_country_model(ctx, block)
    _ensure_two_country_price_vars!(ctx, params, bench, policy)

    expr = _eeq(_evar(:P_BRD_M), _econst(1.0))
    _register_ast_equation!(ctx, block, :numeraire_m, expr; info = "country M bread price numeraire")
    expr = _eeq(_evar(:P_BRD_C), _econst(1.0))
    _register_ast_equation!(ctx, block, :numeraire_c, expr; info = "country C bread price numeraire")

    for use in EOL_USES
        unit_cost = _eol_unit_cost(policy, use)
        expr = _eeq(_evar(:P_EOL_C, use), _econst(unit_cost))
        _register_ast_equation!(ctx, block, :eol_price, expr;
            info = "country C EOL use price is set from policy-adjusted unit cost",
            indices = (use,))
    end

    expr = _ege(_evar(:P_MAT_C, :VMTL),
        _econst(_two_country_factor_unit_cost(bench, :VMTL_M) + policy.material[:VMTL]))
    _register_ast_equation!(ctx, block, :material_price, expr;
        info = "country C virgin material price covers imported material cost and material policy wedge",
        indices = (:VMTL,))
    expr = _ege(_evar(:P_MAT_C, :RMTL),
        _eadd(
            _econst(_two_country_factor_unit_cost(bench, :RMTL_C) + policy.material[:RMTL]),
            _scaled(_two_country_recycling_eol_coefficient(bench), _evar(:P_EOL_C, :REC))))
    _register_ast_equation!(ctx, block, :material_price, expr;
        info = "country C recycled material price covers factor cost, EOL input cost, and material policy wedge",
        indices = (:RMTL,))

    for route in MATERIAL_ROUTES
        theta_v = bench.route_metal_share[(:VMTL, route)]
        theta_r = bench.route_metal_share[(:RMTL, route)]
        if abs(params.sigma_metal - 1.0) < 1.0e-8
            expr = _eeq(_evar(:P_MEFF_C, route),
                _emul(
                    _epow(_evar(:P_MAT_C, :VMTL), _econst(theta_v)),
                    _epow(_evar(:P_MAT_C, :RMTL), _econst(theta_r))))
        else
            expr = _eeq(_evar(:P_MEFF_C, route),
                _epow(
                    _eadd(
                        _scaled(theta_v,
                            _epow(_evar(:P_MAT_C, :VMTL), _econst(1.0 - params.sigma_metal))),
                        _scaled(theta_r,
                            _epow(_evar(:P_MAT_C, :RMTL), _econst(1.0 - params.sigma_metal)))),
                    _econst(1.0 / (1.0 - params.sigma_metal))))
        end
        _register_ast_equation!(ctx, block, :metal_price_index, expr;
            info = "country C effective metal price is the calibrated CES material price index",
            indices = (route,))
    end

    expr = _ege(_evar(:P_ROUTE_C, :NEW),
        _eadd(
            _econst(_two_country_factor_unit_cost(bench, :NEW_C) + policy.route[:NEW]),
            _scaled(_metal_intensity(params, :NEW), _evar(:P_MEFF_C, :NEW))))
    _register_ast_equation!(ctx, block, :route_price, expr;
        info = "country C new route price covers factor, material, and route-wedge costs",
        indices = (:NEW,))
    for route in (:REF, :REP)
        expr = _ege(_evar(:P_ROUTE_C, route),
            _eadd(
                _econst(_two_country_factor_unit_cost(bench, _two_country_route_activity(route)) +
                        policy.route[route]),
                _scaled(_metal_intensity(params, route), _evar(:P_MEFF_C, route)),
                _scaled(_two_country_route_eol_coefficient(bench, route), _evar(:P_EOL_C, route))))
        _register_ast_equation!(ctx, block, :route_price, expr;
            info = "country C circular material-using route price covers factor, material, EOL, and route-wedge costs",
            indices = (route,))
    end
    expr = _ege(_evar(:P_ROUTE_C, :REU),
        _eadd(
            _econst(_two_country_factor_unit_cost(bench, :REU_C) + policy.route[:REU]),
            _scaled(_two_country_route_eol_coefficient(bench, :REU), _evar(:P_EOL_C, :REU))))
    _register_ast_equation!(ctx, block, :route_price, expr;
        info = "country C reuse route price covers factor, EOL, and route-wedge costs",
        indices = (:REU,))

    if abs(params.sigma_routes - 1.0) < 1.0e-8
        expr = _eeq(_evar(:P_TST_C),
            _prod_expr([
                _epow(_evar(:P_ROUTE_C, route), _econst(bench.route_share[route]))
                for route in ROUTES
            ]))
    else
        expr = _eeq(_evar(:P_TST_C),
            _epow(
                _sum_expr([
                    _scaled(bench.route_share[route],
                        _epow(_evar(:P_ROUTE_C, route), _econst(1.0 - params.sigma_routes)))
                    for route in ROUTES
                ]),
                _econst(1.0 / (1.0 - params.sigma_routes))))
    end
    _register_ast_equation!(ctx, block, :toaster_service_price, expr;
        info = "country C toaster-service price is the calibrated CES route price index")

    return nothing
end

function JCGECore.build!(block::TwoCountryBlock{:fiscal_income},
    ctx::JCGERuntime.KernelContext,
    spec::JCGECore.RunSpec)
    bench = block.benchmark
    policy = block.policy
    _require_two_country_model(ctx, block)
    _ensure_two_country_fiscal_vars!(ctx, bench)

    route_var = route -> _evar(:Z, _two_country_route_activity(route))
    virgin_var = route -> _evar(:VUSE, route, :M, :C)
    recycled_var = route -> _evar(:RUSE, route, :C)
    eol_var = use -> _evar(:EOL_C, use)

    expr = _eeq(_evar(:Y_PREFISCAL_M), _econst(bench.prefiscal_income_m))
    _register_ast_equation!(ctx, block, :prefiscal_income_m, expr;
        info = "country M prefiscal income records mining-country factor endowment income")
    expr = _eeq(_evar(:Y_HOH_M),
        _eadd(_evar(:Y_PREFISCAL_M), _econst(-bench.nfa_transfer)))
    _register_ast_equation!(ctx, block, :household_income_m, expr;
        info = "country M household income records prefiscal income net of benchmark financial outflow")

    expr = _eeq(_evar(:Y_PREFISCAL_C), _econst(bench.prefiscal_income_c))
    _register_ast_equation!(ctx, block, :prefiscal_income_c, expr;
        info = "country C prefiscal income records factor, EOL, and benchmark financial inflow income")

    expr = _eeq(_evar(:GOV_NET_C),
        _policy_net_ast(policy;
            route_var = route_var,
            virgin_var = virgin_var,
            recycled_var = recycled_var,
            eol_var = eol_var))
    _register_ast_equation!(ctx, block, :government_net_revenue_c, expr;
        info = "country C net government revenue records policy revenue net of subsidy outlays")
    expr = _eeq(_evar(:GOV_REVENUE_C),
        _policy_revenue_ast(policy;
            route_var = route_var,
            virgin_var = virgin_var,
            recycled_var = recycled_var,
            eol_var = eol_var))
    _register_ast_equation!(ctx, block, :government_revenue_c, expr;
        info = "country C gross government revenue records positive policy wedge receipts")
    expr = _eeq(_evar(:GOV_SUBSIDY_C),
        _policy_subsidy_ast(policy;
            route_var = route_var,
            virgin_var = virgin_var,
            recycled_var = recycled_var,
            eol_var = eol_var))
    _register_ast_equation!(ctx, block, :government_subsidy_c, expr;
        info = "country C gross government subsidy records negative policy wedge outlays")
    expr = _eeq(_evar(:GOV_TRANSFER_C), _evar(:GOV_NET_C))
    _register_ast_equation!(ctx, block, :government_transfer_c, expr;
        info = "country C net government revenue is rebated to country C households")
    expr = _eeq(_evar(:Y_HOH_C), _eadd(_evar(:Y_PREFISCAL_C), _evar(:GOV_TRANSFER_C)))
    _register_ast_equation!(ctx, block, :household_income_c, expr;
        info = "country C household income includes prefiscal income and net government transfer")

    return nothing
end

function JCGECore.build!(block::TwoCountryBlock{:demand},
    ctx::JCGERuntime.KernelContext,
    spec::JCGECore.RunSpec)
    params = block.params
    bench = block.benchmark
    _require_two_country_model(ctx, block)

    y0_c = bench.prefiscal_income_c
    expr = _eeq(_evar(:Z, :TST_C),
        _emul(
            _econst(bench.output[:TST_C]),
            _ediv(_evar(:Y_HOH_C), _econst(y0_c)),
            _epow(_evar(:P_TST_C), _econst(-params.eta_service))))
    _register_ast_equation!(ctx, block, :household_toaster_demand_c, expr;
        info = "country C toaster-service demand follows an income-scaled isoelastic demand curve")

    expr = _eeq(_evar(:Z, :BRD_C),
        _ediv(
            _eadd(_evar(:Y_HOH_C), _eneg(_emul(_evar(:P_TST_C), _evar(:Z, :TST_C)))),
            _evar(:P_BRD_C)))
    _register_ast_equation!(ctx, block, :household_bread_demand_c, expr;
        info = "country C bread demand absorbs residual household income after toaster-service expenditure")
    expr = _eeq(_evar(:Z, :BRD_M), _ediv(_evar(:Y_HOH_M), _evar(:P_BRD_M)))
    _register_ast_equation!(ctx, block, :household_bread_demand_m, expr;
        info = "country M bread demand follows disposable income")

    for route in ROUTES
        activity = _two_country_route_activity(route)
        expr = _eeq(_evar(:Z, activity),
            _emul(
                _econst(bench.route_share[route]),
                _evar(:Z, :TST_C),
                _epow(_ediv(_evar(:P_TST_C), _evar(:P_ROUTE_C, route)),
                    _econst(params.sigma_routes))))
        _register_ast_equation!(ctx, block, :route_demand_c, expr;
            info = "country C route demand follows calibrated CES route substitution",
            indices = (route,))
    end

    for route in MATERIAL_ROUTES
        base_eff = _metal_intensity(params, route) * bench.output[_two_country_route_activity(route)]
        expr = _eeq(_evar(:VUSE, route, :M, :C),
            _emul(
                _econst(bench.material_input[(:VMTL, route)]),
                _ediv(_evar(:MEFF, route, :C), _econst(base_eff)),
                _epow(_ediv(_evar(:P_MEFF_C, route), _evar(:P_MAT_C, :VMTL)),
                    _econst(params.sigma_metal))))
        _register_ast_equation!(ctx, block, :virgin_material_demand_c, expr;
            info = "country C imported virgin material demand follows calibrated CES material substitution",
            indices = (route,))

        expr = _eeq(_evar(:RUSE, route, :C),
            _emul(
                _econst(bench.material_input[(:RMTL, route)]),
                _ediv(_evar(:MEFF, route, :C), _econst(base_eff)),
                _epow(_ediv(_evar(:P_MEFF_C, route), _evar(:P_MAT_C, :RMTL)),
                    _econst(params.sigma_metal))))
        _register_ast_equation!(ctx, block, :recycled_material_demand_c, expr;
            info = "country C recycled material demand follows calibrated CES material substitution",
            indices = (route,))
    end

    return nothing
end

function JCGECore.build!(block::TwoCountryBlock{:objective},
    ctx::JCGERuntime.KernelContext,
    spec::JCGECore.RunSpec)
    bench = block.benchmark
    _require_two_country_model(ctx, block)

    expr = _eadd(
        _scaled(bench.utility_share[:BRD_M], _elog(_evar(:Z, :BRD_M))),
        _scaled(bench.utility_share[:BRD_C], _elog(_evar(:Z, :BRD_C))),
        _scaled(bench.utility_share[:TST_C], _elog(_evar(:Z, :TST_C))))
    _register_ast_objective!(ctx, block, expr;
        info = "two-country benchmark-weighted household utility objective under country C fiscal closure")

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
    blocks = _two_country_blocks(;
        params = params,
        benchmark = benchmark,
        replicate_benchmark = replicate_benchmark,
        policy = policy,
        closure = :two_country_fiscal)

    allowed = JCGECore.allowed_sections()
    section_blocks = Dict(sym => Any[] for sym in allowed)
    append!(section_blocks[:production], blocks)
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
        if eq.tag == :metadata &&
           haskey(eq.payload, :closure) &&
           eq.payload.closure === :two_country_fiscal
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
