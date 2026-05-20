"""
Shared circular-economy helpers used by the single- and two-country model blocks.
"""

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

function _bounded_unit_cost(cost::Real)
    return max(1.0e-4, Float64(cost))
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

function _policy_flow_ast(route_coeffs, material_coeffs, eol_coeffs;
    route_var, virgin_var, recycled_var, eol_var)
    terms = JCGECore.EquationExpr[]
    append!(terms, [_scaled(route_coeffs[route], route_var(route)) for route in ROUTES])
    push!(terms, _scaled(material_coeffs[:VMTL],
        _sum_expr([virgin_var(route) for route in MATERIAL_ROUTES])))
    push!(terms, _scaled(material_coeffs[:RMTL],
        _sum_expr([recycled_var(route) for route in MATERIAL_ROUTES])))
    append!(terms, [_scaled(eol_coeffs[use], eol_var(use)) for use in EOL_USES])
    return _sum_expr(terms)
end

function _policy_net_ast(policy::PolicyWedges; route_var, virgin_var, recycled_var, eol_var)
    return _policy_flow_ast(policy.route, policy.material, policy.eol;
        route_var = route_var,
        virgin_var = virgin_var,
        recycled_var = recycled_var,
        eol_var = eol_var)
end

function _policy_revenue_ast(policy::PolicyWedges; route_var, virgin_var, recycled_var, eol_var)
    route_coeffs = Dict(route => max(policy.route[route], 0.0) for route in ROUTES)
    material_coeffs = Dict(material => max(policy.material[material], 0.0) for material in MATERIALS)
    eol_coeffs = Dict(use => max(policy.eol[use], 0.0) for use in EOL_USES)
    return _policy_flow_ast(route_coeffs, material_coeffs, eol_coeffs;
        route_var = route_var,
        virgin_var = virgin_var,
        recycled_var = recycled_var,
        eol_var = eol_var)
end

function _policy_subsidy_ast(policy::PolicyWedges; route_var, virgin_var, recycled_var, eol_var)
    route_coeffs = Dict(route => -min(policy.route[route], 0.0) for route in ROUTES)
    material_coeffs = Dict(material => -min(policy.material[material], 0.0) for material in MATERIALS)
    eol_coeffs = Dict(use => -min(policy.eol[use], 0.0) for use in EOL_USES)
    return _policy_flow_ast(route_coeffs, material_coeffs, eol_coeffs;
        route_var = route_var,
        virgin_var = virgin_var,
        recycled_var = recycled_var,
        eol_var = eol_var)
end
