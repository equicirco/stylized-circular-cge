"""
Model-specific block for the first one-period circular economy target.

The block is a compact planner-form equilibrium scaffold: it uses the JCGE
RunSpec/build/runtime interface while keeping the first circular constraints
inside this repository. Generic functionality can be moved to JCGEBlocks later if
it proves reusable.
"""
struct CircularOnePeriodBlock <: JCGECore.AbstractBlock
    name::Symbol
    params::NamedTuple
    benchmark::NamedTuple
    replicate_benchmark::Bool
    policy::PolicyWedges
end

struct CircularFiscalOnePeriodBlock <: JCGECore.AbstractBlock
    name::Symbol
    params::NamedTuple
    benchmark::NamedTuple
    replicate_benchmark::Bool
    policy::PolicyWedges
end

function _global_var(base::Symbol, idxs::Symbol...)
    isempty(idxs) && return base
    return Symbol(string(base), "_", join(string.(idxs), "_"))
end

function _ensure_var!(ctx::JCGERuntime.KernelContext, name::Symbol; lower=1.0e-6, start=nothing)
    haskey(ctx.variables, name) && return ctx.variables[name]
    model = ctx.model
    if model isa JuMP.Model
        if lower === nothing
            var = start === nothing ?
                  JuMP.@variable(model, base_name = string(name)) :
                  JuMP.@variable(model, start = start, base_name = string(name))
        else
            var = start === nothing ?
                  JuMP.@variable(model, lower_bound = lower, base_name = string(name)) :
                  JuMP.@variable(model, lower_bound = lower, start = start, base_name = string(name))
        end
    else
        var = (name = name,)
    end
    return JCGERuntime.register_variable!(ctx, name, var)
end

function _register_constraint!(ctx::JCGERuntime.KernelContext, block,
    tag::Symbol, constraint; info::String, indices=())
    JCGERuntime.register_equation!(ctx;
        tag = tag,
        block = block.name,
        payload = (
            indices = indices,
            params = block.params,
            info = info,
            expr = JCGECore.ERaw(info),
            constraint = constraint,
        ))
    return nothing
end

_closure_kind(::CircularOnePeriodBlock) = :planner
_closure_kind(::CircularFiscalOnePeriodBlock) = :fiscal

function _register_metadata!(ctx::JCGERuntime.KernelContext, block)
    JCGERuntime.register_equation!(ctx;
        tag = :metadata,
        block = block.name,
        payload = (
            indices = (),
            params = block.params,
            benchmark = block.benchmark,
            policy = block.policy,
            closure = _closure_kind(block),
            info = "circular one-period metadata",
            expr = JCGECore.ERaw("metadata"),
            constraint = nothing,
        ))
    return nothing
end

function _route_yield(params, route::Symbol)
    route === :REF && return params.yield.ref
    route === :REP && return params.yield.rep
    route === :REU && return params.yield.reu
    error("No life-extension yield for route $(route)")
end

function _metal_intensity(params, route::Symbol)
    route === :NEW && return params.metal_intensity.new
    route === :REF && return params.metal_intensity.ref
    route === :REP && return params.metal_intensity.rep
    route === :REU && return params.metal_intensity.reu
    error("No metal intensity for route $(route)")
end

function JCGECore.build!(block::CircularOnePeriodBlock,
    ctx::JCGERuntime.KernelContext,
    spec::JCGECore.RunSpec)
    params = block.params
    bench = block.benchmark
    policy = block.policy
    model = ctx.model
    model isa JuMP.Model || error("CircularOnePeriodBlock requires a JuMP-backed JCGE runtime context")
    _register_metadata!(ctx, block)

    z = Dict{Symbol,Any}()
    for a in (PRODUCTION_ACTIVITIES..., :TST)
        z[a] = _ensure_var!(ctx, _global_var(:Z, a); start = bench.output[a])
    end

    factors = Dict{Tuple{Symbol,Symbol},Any}()
    for h in FACTORS, a in PRODUCTION_ACTIVITIES
        factors[(h, a)] = _ensure_var!(ctx, _global_var(:F, h, a);
            start = bench.factor_input[(h, a)])
    end

    eol = Dict{Symbol,Any}()
    ret = params.delta * bench.stock0
    for use in EOL_USES
        eol[use] = _ensure_var!(ctx, _global_var(:EOL, use);
            lower = 0.0, start = bench.eol_allocation[use])
    end

    metal_eff = Dict{Symbol,Any}()
    virgin_use = Dict{Symbol,Any}()
    recycled_use = Dict{Symbol,Any}()
    for route in MATERIAL_ROUTES
        metal_eff[route] = _ensure_var!(ctx, _global_var(:MEFF, route);
            start = _metal_intensity(params, route) * bench.output[route])
        virgin_use[route] = _ensure_var!(ctx, _global_var(:VUSE, route);
            start = bench.material_input[(:VMTL, route)])
        recycled_use[route] = _ensure_var!(ctx, _global_var(:RUSE, route);
            start = bench.material_input[(:RMTL, route)])
    end

    for a in PRODUCTION_ACTIVITIES
        lab = factors[(:LAB, a)]
        cap = factors[(:CAP, a)]
        beta_lab = bench.factor_share[(:LAB, a)]
        beta_cap = bench.factor_share[(:CAP, a)]
        scale = bench.productivity[a]
        constraint = JuMP.@NLconstraint(model, z[a] <= scale * lab^beta_lab * cap^beta_cap)
        _register_constraint!(ctx, block, :technology, constraint;
            info = "Z[$(a)] <= A[$(a)] * F[LAB,$(a)]^beta * F[CAP,$(a)]^(1-beta)",
            indices = (a,))
    end

    for h in FACTORS
        constraint = JuMP.@constraint(model,
            sum(factors[(h, a)] for a in PRODUCTION_ACTIVITIES) <= bench.factor_endowment[h])
        _register_constraint!(ctx, block, :factor_endowment, constraint;
            info = "sum(F[$(h),a]) <= FF[$(h)]",
            indices = (h,))
    end

    constraint = JuMP.@constraint(model, sum(eol[use] for use in EOL_USES) == ret)
    _register_constraint!(ctx, block, :eol_allocation, constraint;
        info = "sum(EOL use) == delta * stock0")

    for route in (:REF, :REP, :REU)
        y = _route_yield(params, route)
        constraint = JuMP.@constraint(model, z[route] <= y * eol[route])
        _register_constraint!(ctx, block, :route_yield, constraint;
            info = "Z[$(route)] <= yield[$(route)] * EOL[$(route)]",
            indices = (route,))
    end

    constraint = JuMP.@constraint(model, z[:RMTL] <= params.yield.rmtl * eol[:REC])
    _register_constraint!(ctx, block, :recycling_yield, constraint;
        info = "Z[RMTL] <= yield[RMTL] * EOL[REC]")

    for route in MATERIAL_ROUTES
        alpha = _metal_intensity(params, route)
        constraint = JuMP.@constraint(model, alpha * z[route] <= metal_eff[route])
        _register_constraint!(ctx, block, :route_material_requirement, constraint;
            info = "metal_intensity[$(route)] * Z[$(route)] <= MEFF[$(route)]",
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
                metal_eff[route] <= scale * virgin_use[route]^theta_v * (phi * recycled_use[route])^theta_r)
        else
            constraint = JuMP.@NLconstraint(model,
                metal_eff[route] <=
                scale *
                (theta_v * virgin_use[route]^rho_metal +
                 theta_r * (phi * recycled_use[route])^rho_metal)^(1.0 / rho_metal))
        end
        _register_constraint!(ctx, block, :metal_composite, constraint;
            info = "MEFF[$(route)] <= calibrated CES(VUSE[$(route)], quality * RUSE[$(route)])",
            indices = (route,))
    end

    constraint = JuMP.@constraint(model,
        sum(virgin_use[route] for route in MATERIAL_ROUTES) <= z[:VMTL])
    _register_constraint!(ctx, block, :virgin_material_balance, constraint;
        info = "sum(VUSE[route]) <= Z[VMTL]")

    constraint = JuMP.@constraint(model,
        sum(recycled_use[route] for route in MATERIAL_ROUTES) <= z[:RMTL])
    _register_constraint!(ctx, block, :recycled_material_balance, constraint;
        info = "sum(RUSE[route]) <= Z[RMTL]")

    rho_routes = (params.sigma_routes - 1.0) / params.sigma_routes
    route_scale = bench.route_scale
    if abs(rho_routes) < 1.0e-8
        constraint = JuMP.@NLconstraint(model,
            z[:TST] <=
            route_scale *
            z[:NEW]^bench.route_share[:NEW] *
            z[:REF]^bench.route_share[:REF] *
            z[:REP]^bench.route_share[:REP] *
            z[:REU]^bench.route_share[:REU])
    else
        constraint = JuMP.@NLconstraint(model,
            z[:TST] <=
            route_scale *
            (sum(bench.route_share[route] * z[route]^rho_routes for route in ROUTES))^(1.0 / rho_routes))
    end
    _register_constraint!(ctx, block, :toaster_service_composite, constraint;
        info = "Z[TST] <= calibrated CES(Z[NEW], Z[REF], Z[REP], Z[REU])")

    if block.replicate_benchmark
        for a in (PRODUCTION_ACTIVITIES..., :TST)
            constraint = JuMP.@constraint(model, z[a] == bench.output[a])
            _register_constraint!(ctx, block, :replicate_output, constraint;
                info = "Z[$(a)] == benchmark output", indices = (a,))
        end
        for h in FACTORS, a in PRODUCTION_ACTIVITIES
            constraint = JuMP.@constraint(model, factors[(h, a)] == bench.factor_input[(h, a)])
            _register_constraint!(ctx, block, :replicate_factor_input, constraint;
                info = "F[$(h),$(a)] == benchmark factor input", indices = (h, a))
        end
        for use in EOL_USES
            constraint = JuMP.@constraint(model, eol[use] == bench.eol_allocation[use])
            _register_constraint!(ctx, block, :replicate_eol, constraint;
                info = "EOL[$(use)] == benchmark EOL allocation", indices = (use,))
        end
        for route in MATERIAL_ROUTES
            constraint = JuMP.@constraint(model, virgin_use[route] == bench.material_input[(:VMTL, route)])
            _register_constraint!(ctx, block, :replicate_virgin_use, constraint;
                info = "VUSE[$(route)] == benchmark virgin-metal use", indices = (route,))
            constraint = JuMP.@constraint(model, recycled_use[route] == bench.material_input[(:RMTL, route)])
            _register_constraint!(ctx, block, :replicate_recycled_use, constraint;
                info = "RUSE[$(route)] == benchmark recycled-metal use", indices = (route,))
        end
    end

    alpha_brd = bench.utility_share[:BRD]
    alpha_tst = bench.utility_share[:TST]
    total_final_demand = bench.output[:BRD] + bench.output[:TST]
    wedge_burden = (
        sum(policy.route[route] * z[route] for route in ROUTES) +
        policy.material[:VMTL] * sum(virgin_use[route] for route in MATERIAL_ROUTES) +
        policy.material[:RMTL] * sum(recycled_use[route] for route in MATERIAL_ROUTES) +
        sum(policy.eol[use] * eol[use] for use in EOL_USES)
    ) / total_final_demand
    JuMP.@NLobjective(model, Max,
        alpha_brd * log(z[:BRD]) + alpha_tst * log(z[:TST]) - wedge_burden)
    JCGERuntime.register_equation!(ctx;
        tag = :objective,
        block = block.name,
        payload = (
            indices = (),
            params = block.params,
            info = "maximize alpha_brd * log(Z[BRD]) + alpha_tst * log(Z[TST])",
            expr = JCGECore.ERaw("log utility objective"),
            constraint = nothing,
        ))

    return nothing
end

function _bounded_unit_cost(cost::Real)
    return max(1.0e-4, Float64(cost))
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

function _eol_unit_cost(policy::PolicyWedges, use::Symbol)
    return _bounded_unit_cost(1.0 + policy.eol[use])
end

function _eol_allocation_cost(policy::PolicyWedges, use::Symbol)
    downstream =
        if use in ROUTES
            policy.route[use]
        elseif use === :REC
            policy.material[:RMTL]
        else
            0.0
        end
    return _bounded_unit_cost(1.0 + policy.eol[use] + downstream)
end

function _eol_allocation_shares(params, bench, policy::PolicyWedges)
    base_total = sum(values(bench.eol_allocation))
    raw = Dict{Symbol,Float64}()
    for use in EOL_USES
        base_share = bench.eol_allocation[use] / base_total
        raw[use] = base_share * _eol_allocation_cost(policy, use)^(-params.sigma_eol)
    end
    total = sum(values(raw))
    total > 0.0 || error("EOL allocation shares are undefined because all raw shares are zero")
    return Dict(use => raw[use] / total for use in EOL_USES)
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

function _policy_net_expression(policy::PolicyWedges, z, eol, virgin_use, recycled_use)
    return (
        sum(policy.route[route] * z[route] for route in ROUTES) +
        policy.material[:VMTL] * sum(virgin_use[route] for route in MATERIAL_ROUTES) +
        policy.material[:RMTL] * sum(recycled_use[route] for route in MATERIAL_ROUTES) +
        sum(policy.eol[use] * eol[use] for use in EOL_USES)
    )
end

function _policy_revenue_expression(policy::PolicyWedges, z, eol, virgin_use, recycled_use)
    return (
        sum(max(policy.route[route], 0.0) * z[route] for route in ROUTES) +
        max(policy.material[:VMTL], 0.0) * sum(virgin_use[route] for route in MATERIAL_ROUTES) +
        max(policy.material[:RMTL], 0.0) * sum(recycled_use[route] for route in MATERIAL_ROUTES) +
        sum(max(policy.eol[use], 0.0) * eol[use] for use in EOL_USES)
    )
end

function _policy_subsidy_expression(policy::PolicyWedges, z, eol, virgin_use, recycled_use)
    return (
        sum(-min(policy.route[route], 0.0) * z[route] for route in ROUTES) +
        -min(policy.material[:VMTL], 0.0) * sum(virgin_use[route] for route in MATERIAL_ROUTES) +
        -min(policy.material[:RMTL], 0.0) * sum(recycled_use[route] for route in MATERIAL_ROUTES) +
        sum(-min(policy.eol[use], 0.0) * eol[use] for use in EOL_USES)
    )
end

function JCGECore.build!(block::CircularFiscalOnePeriodBlock,
    ctx::JCGERuntime.KernelContext,
    spec::JCGECore.RunSpec)
    params = block.params
    bench = block.benchmark
    policy = block.policy
    model = ctx.model
    model isa JuMP.Model || error("CircularFiscalOnePeriodBlock requires a JuMP-backed JCGE runtime context")
    _register_metadata!(ctx, block)

    z = Dict{Symbol,Any}()
    for a in (PRODUCTION_ACTIVITIES..., :TST)
        z[a] = _ensure_var!(ctx, _global_var(:Z, a); start = bench.output[a])
    end

    factors = Dict{Tuple{Symbol,Symbol},Any}()
    for h in FACTORS, a in PRODUCTION_ACTIVITIES
        factors[(h, a)] = _ensure_var!(ctx, _global_var(:F, h, a);
            start = bench.factor_input[(h, a)])
    end

    eol = Dict{Symbol,Any}()
    ret = params.delta * bench.stock0
    for use in EOL_USES
        eol[use] = _ensure_var!(ctx, _global_var(:EOL, use);
            lower = 0.0, start = bench.eol_allocation[use])
    end

    metal_eff = Dict{Symbol,Any}()
    virgin_use = Dict{Symbol,Any}()
    recycled_use = Dict{Symbol,Any}()
    for route in MATERIAL_ROUTES
        metal_eff[route] = _ensure_var!(ctx, _global_var(:MEFF, route);
            start = _metal_intensity(params, route) * bench.output[route])
        virgin_use[route] = _ensure_var!(ctx, _global_var(:VUSE, route);
            start = bench.material_input[(:VMTL, route)])
        recycled_use[route] = _ensure_var!(ctx, _global_var(:RUSE, route);
            start = bench.material_input[(:RMTL, route)])
    end

    for a in PRODUCTION_ACTIVITIES
        lab = factors[(:LAB, a)]
        cap = factors[(:CAP, a)]
        beta_lab = bench.factor_share[(:LAB, a)]
        beta_cap = bench.factor_share[(:CAP, a)]
        scale = bench.productivity[a]
        constraint = JuMP.@NLconstraint(model, z[a] <= scale * lab^beta_lab * cap^beta_cap)
        _register_constraint!(ctx, block, :technology, constraint;
            info = "Z[$(a)] <= A[$(a)] * F[LAB,$(a)]^beta * F[CAP,$(a)]^(1-beta)",
            indices = (a,))
    end

    for h in FACTORS
        constraint = JuMP.@constraint(model,
            sum(factors[(h, a)] for a in PRODUCTION_ACTIVITIES) <= bench.factor_endowment[h])
        _register_constraint!(ctx, block, :factor_endowment, constraint;
            info = "sum(F[$(h),a]) <= FF[$(h)]",
            indices = (h,))
    end

    eol_shares = _eol_allocation_shares(params, bench, policy)
    for use in EOL_USES
        constraint = JuMP.@constraint(model, eol[use] == eol_shares[use] * ret)
        _register_constraint!(ctx, block, :eol_allocation, constraint;
            info = "EOL[$(use)] follows calibrated allocation shares from policy-adjusted EOL costs",
            indices = (use,))
    end

    for route in (:REF, :REP, :REU)
        y = _route_yield(params, route)
        constraint = JuMP.@constraint(model, z[route] <= y * eol[route])
        _register_constraint!(ctx, block, :route_yield, constraint;
            info = "Z[$(route)] <= yield[$(route)] * EOL[$(route)]",
            indices = (route,))
    end

    constraint = JuMP.@constraint(model, z[:RMTL] <= params.yield.rmtl * eol[:REC])
    _register_constraint!(ctx, block, :recycling_yield, constraint;
        info = "Z[RMTL] <= yield[RMTL] * EOL[REC]")

    for route in MATERIAL_ROUTES
        alpha = _metal_intensity(params, route)
        constraint = JuMP.@constraint(model, alpha * z[route] <= metal_eff[route])
        _register_constraint!(ctx, block, :route_material_requirement, constraint;
            info = "metal_intensity[$(route)] * Z[$(route)] <= MEFF[$(route)]",
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
                metal_eff[route] <= scale * virgin_use[route]^theta_v * (phi * recycled_use[route])^theta_r)
        else
            constraint = JuMP.@NLconstraint(model,
                metal_eff[route] <=
                scale *
                (theta_v * virgin_use[route]^rho_metal +
                 theta_r * (phi * recycled_use[route])^rho_metal)^(1.0 / rho_metal))
        end
        _register_constraint!(ctx, block, :metal_composite, constraint;
            info = "MEFF[$(route)] <= calibrated CES(VUSE[$(route)], quality * RUSE[$(route)])",
            indices = (route,))
    end

    constraint = JuMP.@constraint(model,
        sum(virgin_use[route] for route in MATERIAL_ROUTES) == z[:VMTL])
    _register_constraint!(ctx, block, :virgin_material_balance, constraint;
        info = "sum(VUSE[route]) == Z[VMTL]")

    constraint = JuMP.@constraint(model,
        sum(recycled_use[route] for route in MATERIAL_ROUTES) == z[:RMTL])
    _register_constraint!(ctx, block, :recycled_material_balance, constraint;
        info = "sum(RUSE[route]) == Z[RMTL]")

    rho_routes = (params.sigma_routes - 1.0) / params.sigma_routes
    route_scale = bench.route_scale
    if abs(rho_routes) < 1.0e-8
        constraint = JuMP.@NLconstraint(model,
            z[:TST] <=
            route_scale *
            z[:NEW]^bench.route_share[:NEW] *
            z[:REF]^bench.route_share[:REF] *
            z[:REP]^bench.route_share[:REP] *
            z[:REU]^bench.route_share[:REU])
    else
        constraint = JuMP.@NLconstraint(model,
            z[:TST] <=
            route_scale *
            (sum(bench.route_share[route] * z[route]^rho_routes for route in ROUTES))^(1.0 / rho_routes))
    end
    _register_constraint!(ctx, block, :toaster_service_composite, constraint;
        info = "Z[TST] <= calibrated CES(Z[NEW], Z[REF], Z[REP], Z[REU])")

    if block.replicate_benchmark
        for a in (PRODUCTION_ACTIVITIES..., :TST)
            constraint = JuMP.@constraint(model, z[a] == bench.output[a])
            _register_constraint!(ctx, block, :replicate_output, constraint;
                info = "Z[$(a)] == benchmark output", indices = (a,))
        end
        for h in FACTORS, a in PRODUCTION_ACTIVITIES
            constraint = JuMP.@constraint(model, factors[(h, a)] == bench.factor_input[(h, a)])
            _register_constraint!(ctx, block, :replicate_factor_input, constraint;
                info = "F[$(h),$(a)] == benchmark factor input", indices = (h, a))
        end
        for use in EOL_USES
            constraint = JuMP.@constraint(model, eol[use] == bench.eol_allocation[use])
            _register_constraint!(ctx, block, :replicate_eol, constraint;
                info = "EOL[$(use)] == benchmark EOL allocation", indices = (use,))
        end
        for route in MATERIAL_ROUTES
            constraint = JuMP.@constraint(model, virgin_use[route] == bench.material_input[(:VMTL, route)])
            _register_constraint!(ctx, block, :replicate_virgin_use, constraint;
                info = "VUSE[$(route)] == benchmark virgin-metal use", indices = (route,))
            constraint = JuMP.@constraint(model, recycled_use[route] == bench.material_input[(:RMTL, route)])
            _register_constraint!(ctx, block, :replicate_recycled_use, constraint;
                info = "RUSE[$(route)] == benchmark recycled-metal use", indices = (route,))
        end
    end

    p_brd = _ensure_var!(ctx, :P_BRD; start = 1.0)
    constraint = JuMP.@constraint(model, p_brd == 1.0)
    _register_constraint!(ctx, block, :numeraire, constraint;
        info = "P[BRD] == 1")

    p_eol = Dict{Symbol,Any}()
    for use in EOL_USES
        unit_cost = _eol_unit_cost(policy, use)
        p_eol[use] = _ensure_var!(ctx, _global_var(:P_EOL, use); start = unit_cost)
        constraint = JuMP.@constraint(model, p_eol[use] == unit_cost)
        _register_constraint!(ctx, block, :eol_price, constraint;
            info = "P_EOL[$(use)] equals the tax-inclusive EOL use cost",
            indices = (use,))
    end

    p_material = Dict{Symbol,Any}()
    for material in MATERIALS
        unit_cost = _material_unit_cost(params, bench, policy, material)
        p_material[material] = _ensure_var!(ctx, _global_var(:P_MAT, material); start = unit_cost)
    end
    constraint = JuMP.@constraint(model,
        p_material[:VMTL] >= _factor_unit_cost(bench, :VMTL) + policy.material[:VMTL])
    _register_constraint!(ctx, block, :material_price, constraint;
        info = "P_MAT[VMTL] is bounded below by virgin-material factor cost plus material wedge",
        indices = (:VMTL,))
    constraint = JuMP.@constraint(model,
        p_material[:RMTL] >=
        _factor_unit_cost(bench, :RMTL) +
        _recycling_eol_coefficient(bench) * p_eol[:REC] +
        policy.material[:RMTL])
    _register_constraint!(ctx, block, :material_price, constraint;
        info = "P_MAT[RMTL] is bounded below by recycling factor cost plus EOL input cost plus material wedge",
        indices = (:RMTL,))

    p_eff = Dict{Symbol,Any}()
    for route in MATERIAL_ROUTES
        p_eff[route] = _ensure_var!(ctx, _global_var(:P_MEFF, route); start = 1.0)
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
            info = "P_MEFF[$(route)] is a CES material price index",
            indices = (route,))
    end

    p_route = Dict{Symbol,Any}()
    for route in ROUTES
        unit_cost = _route_unit_cost(params, bench, policy, route)
        p_route[route] = _ensure_var!(ctx, _global_var(:P_ROUTE, route); start = unit_cost)
    end
    constraint = JuMP.@constraint(model,
        p_route[:NEW] >=
        _factor_unit_cost(bench, :NEW) +
        _metal_intensity(params, :NEW) * p_eff[:NEW] +
        policy.route[:NEW])
    _register_constraint!(ctx, block, :route_price, constraint;
        info = "P_ROUTE[NEW] is bounded below by factor cost plus metal-composite cost plus route wedge",
        indices = (:NEW,))
    for route in (:REF, :REP)
        constraint = JuMP.@constraint(model,
            p_route[route] >=
            _factor_unit_cost(bench, route) +
            _metal_intensity(params, route) * p_eff[route] +
            _route_eol_coefficient(bench, route) * p_eol[route] +
            policy.route[route])
        _register_constraint!(ctx, block, :route_price, constraint;
            info = "P_ROUTE[$(route)] is bounded below by factor, metal, EOL input, and route-wedge costs",
            indices = (route,))
    end
    constraint = JuMP.@constraint(model,
        p_route[:REU] >=
        _factor_unit_cost(bench, :REU) +
        _route_eol_coefficient(bench, :REU) * p_eol[:REU] +
        policy.route[:REU])
    _register_constraint!(ctx, block, :route_price, constraint;
        info = "P_ROUTE[REU] is bounded below by factor, EOL input, and route-wedge costs",
        indices = (:REU,))

    p_tst = _ensure_var!(ctx, :P_TST; start = 1.0)
    if abs(params.sigma_routes - 1.0) < 1.0e-8
        constraint = JuMP.@NLconstraint(model,
            p_tst ==
            p_route[:NEW]^bench.route_share[:NEW] *
            p_route[:REF]^bench.route_share[:REF] *
            p_route[:REP]^bench.route_share[:REP] *
            p_route[:REU]^bench.route_share[:REU])
    else
        constraint = JuMP.@NLconstraint(model,
            p_tst ==
            (sum(bench.route_share[route] * p_route[route]^(1.0 - params.sigma_routes)
                 for route in ROUTES))^(1.0 / (1.0 - params.sigma_routes)))
    end
    _register_constraint!(ctx, block, :toaster_service_price, constraint;
        info = "P[TST] is a CES route price index")

    y_prefiscal = _ensure_var!(ctx, :Y_PREFISCAL; start = _pre_fiscal_income(params, bench))
    y_hoh = _ensure_var!(ctx, :Y_HOH; start = _pre_fiscal_income(params, bench))
    gov_net = _ensure_var!(ctx, :GOV_NET; lower = nothing, start = 0.0)
    gov_revenue = _ensure_var!(ctx, :GOV_REVENUE; lower = 0.0, start = 0.0)
    gov_subsidy = _ensure_var!(ctx, :GOV_SUBSIDY; lower = 0.0, start = 0.0)
    gov_transfer = _ensure_var!(ctx, :GOV_TRANSFER; lower = nothing, start = 0.0)

    net_expr = _policy_net_expression(policy, z, eol, virgin_use, recycled_use)
    revenue_expr = _policy_revenue_expression(policy, z, eol, virgin_use, recycled_use)
    subsidy_expr = _policy_subsidy_expression(policy, z, eol, virgin_use, recycled_use)

    constraint = JuMP.@constraint(model, y_prefiscal == _pre_fiscal_income(params, bench))
    _register_constraint!(ctx, block, :prefiscal_income, constraint;
        info = "Y_PREFISCAL equals factor plus EOL endowment income")

    constraint = JuMP.@constraint(model, gov_net == net_expr)
    _register_constraint!(ctx, block, :government_net_revenue, constraint;
        info = "GOV_NET equals tax revenue net of subsidy outlays")

    constraint = JuMP.@constraint(model, gov_revenue == revenue_expr)
    _register_constraint!(ctx, block, :government_revenue, constraint;
        info = "GOV_REVENUE equals positive policy wedge receipts")

    constraint = JuMP.@constraint(model, gov_subsidy == subsidy_expr)
    _register_constraint!(ctx, block, :government_subsidy, constraint;
        info = "GOV_SUBSIDY equals negative policy wedge outlays")

    constraint = JuMP.@constraint(model, gov_transfer == gov_net)
    _register_constraint!(ctx, block, :government_transfer, constraint;
        info = "GOV_TRANSFER rebates net revenue to households; negative values are lump-sum financing")

    constraint = JuMP.@constraint(model, y_hoh == y_prefiscal + gov_transfer)
    _register_constraint!(ctx, block, :household_income, constraint;
        info = "Y_HOH equals prefiscal income plus net government transfer")

    alpha_brd = bench.utility_share[:BRD]
    alpha_tst = bench.utility_share[:TST]
    y0 = _pre_fiscal_income(params, bench)
    constraint = JuMP.@NLconstraint(model,
        z[:TST] == bench.output[:TST] * (y_hoh / y0) * p_tst^(-params.eta_service))
    _register_constraint!(ctx, block, :household_toaster_demand, constraint;
        info = "Z[TST] follows an isoelastic service-demand curve with income scaling")

    constraint = JuMP.@NLconstraint(model, z[:BRD] == (y_hoh - p_tst * z[:TST]) / p_brd)
    _register_constraint!(ctx, block, :household_bread_demand, constraint;
        info = "Z[BRD] absorbs residual household income after toaster-service expenditure")

    for route in ROUTES
        constraint = JuMP.@NLconstraint(model,
            z[route] ==
            bench.route_share[route] * z[:TST] * (p_tst / p_route[route])^params.sigma_routes)
        _register_constraint!(ctx, block, :route_demand, constraint;
            info = "Z[$(route)] follows CES demand from the tax-inclusive route price",
            indices = (route,))
    end

    for route in MATERIAL_ROUTES
        base_eff = _metal_intensity(params, route) * bench.output[route]
        constraint = JuMP.@NLconstraint(model,
            virgin_use[route] ==
            bench.material_input[(:VMTL, route)] *
            (metal_eff[route] / base_eff) *
            (p_eff[route] / p_material[:VMTL])^params.sigma_metal)
        _register_constraint!(ctx, block, :virgin_material_demand, constraint;
            info = "VUSE[$(route)] follows CES demand from the tax-inclusive virgin material price",
            indices = (route,))

        constraint = JuMP.@NLconstraint(model,
            recycled_use[route] ==
            bench.material_input[(:RMTL, route)] *
            (metal_eff[route] / base_eff) *
            (p_eff[route] / p_material[:RMTL])^params.sigma_metal)
        _register_constraint!(ctx, block, :recycled_material_demand, constraint;
            info = "RUSE[$(route)] follows CES demand from the tax-inclusive recycled material price",
            indices = (route,))
    end

    JuMP.@NLobjective(model, Max,
        alpha_brd * log(z[:BRD]) + alpha_tst * log(z[:TST]))
    JCGERuntime.register_equation!(ctx;
        tag = :objective,
        block = block.name,
        payload = (
            indices = (),
            params = block.params,
            info = "maximize household log utility under fiscal closure",
            expr = JCGECore.ERaw("log utility objective with fiscal closure"),
            constraint = nothing,
        ))

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
    block = CircularOnePeriodBlock(:circular_one_period, params, benchmark, replicate_benchmark, policy)

    allowed = JCGECore.allowed_sections()
    section_blocks = Dict(sym => Any[] for sym in allowed)
    push!(section_blocks[:production], block)
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
    block = CircularFiscalOnePeriodBlock(:circular_fiscal_one_period,
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
        if eq.tag == :metadata && eq.block in (:circular_one_period, :circular_fiscal_one_period)
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
