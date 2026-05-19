"""
StylizedCircularCGE defines the account sets and development scaffold for a
stylized circular-economy CGE model built with the JCGE framework.
"""
module StylizedCircularCGE

using Ipopt
using JCGECore
using JCGERuntime
using JuMP

const RuntimeExperiments = JCGERuntime.Experiments

export FACTORS, MATERIALS, ROUTES, EOL_USES, GOODS, INSTITUTIONS
export PolicyWedges, zero_policy, single_wedge, with_wedge
export ProductProfile, default_product_profile, profile_parameters, profile_benchmark
export profile_experiment, product_profile_grid, product_parameter_grid
export ExperimentSpec, with_parameter, parameter_grid, run_experiment, run_grid
export policy_grid, parameter_policy_grid
export experiment_execution_kwargs
export accounts, default_parameters, synthetic_sam, sam_balance, synthetic_benchmark
export model, baseline, fiscal_model, fiscal_baseline, decentralized_model, decentralized_baseline
export scenario, solve
export indicators, benchmark_residuals, result_row, result_rows
export closed_economy_residuals
export closed_economy_failures, assert_closed_economy_results
export compare_to_reference, compare_to_group_reference
export classify_regime, regime_counts, classify_mechanism, mechanism_counts
export summarize_comparison, best_material_savers
export frontier_rows, material_saving_frontier
export compare_frontiers, sensitivity_screen
export summary_row, write_rows_csv, write_experiment_bundle
export datadir

const FACTORS = (:LAB, :CAP)
const MATERIALS = (:VMTL, :RMTL)
const ROUTES = (:NEW, :REF, :REP, :REU)
const EOL_USES = (:REF, :REP, :REU, :REC, :INC)
const GOODS = (:BRD, :VMTL, :RMTL, :NEW, :REF, :REP, :REU, :TST, :EOL, :INC)
const INSTITUTIONS = (:HOH, :GOV, :IDT)
const SAM_ACCOUNTS = (GOODS..., FACTORS..., INSTITUTIONS...)
const PRODUCTION_ACTIVITIES = (:BRD, :VMTL, :RMTL, :NEW, :REF, :REP, :REU)
const MATERIAL_ROUTES = (:NEW, :REF, :REP)

"""
Comparable ad-valorem policy wedges.

The sign convention is uniform:
- `tau > 0` is a penalty/tax-like wedge.
- `tau < 0` is support/subsidy-like wedge.
- `tau = 0` is the benchmark.
"""
struct PolicyWedges
    route::Dict{Symbol,Float64}
    material::Dict{Symbol,Float64}
    eol::Dict{Symbol,Float64}
end

"""
    zero_policy()

Return a policy object with all wedges set to zero.
"""
function zero_policy()
    return PolicyWedges(
        Dict(route => 0.0 for route in ROUTES),
        Dict(material => 0.0 for material in MATERIALS),
        Dict(use => 0.0 for use in EOL_USES),
    )
end

function _copy_policy(policy::PolicyWedges)
    return PolicyWedges(copy(policy.route), copy(policy.material), copy(policy.eol))
end

function _policy_bucket(policy::PolicyWedges, kind::Symbol)
    kind === :route && return policy.route
    kind === :material && return policy.material
    kind === :eol && return policy.eol
    error("Unknown policy wedge kind $(kind). Use :route, :material, or :eol.")
end

"""
    with_wedge(policy, kind, target, tau)

Return a copy of `policy` with one ad-valorem wedge changed. `kind` must be
`:route`, `:material`, or `:eol`.
"""
function with_wedge(policy::PolicyWedges, kind::Symbol, target::Symbol, tau::Real)
    next = _copy_policy(policy)
    bucket = _policy_bucket(next, kind)
    haskey(bucket, target) || error("Unknown $(kind) policy target $(target)")
    bucket[target] = Float64(tau)
    return next
end

"""
    single_wedge(kind, target, tau)

Return a zero policy with one ad-valorem wedge set.
"""
single_wedge(kind::Symbol, target::Symbol, tau::Real) =
    with_wedge(zero_policy(), kind, target, tau)

"""
One local parameter-space experiment.
"""
struct ExperimentSpec
    label::String
    params::NamedTuple
    policy::PolicyWedges
    benchmark::NamedTuple
end

ExperimentSpec(label::AbstractString;
    params = default_parameters(),
    policy::PolicyWedges = zero_policy(),
    benchmark = synthetic_benchmark(params)) =
    ExperimentSpec(String(label), params, policy, benchmark)

function _replace_namedtuple(nt::NamedTuple, key::Symbol, value)
    haskey(nt, key) || error("Unknown parameter $(key)")
    return merge(nt, NamedTuple{(key,)}((value,)))
end

"""
    with_parameter(params, key, value)

Return a copy of the model parameter tuple with one parameter changed. Nested
keys are written as `:yield_ref`, `:yield_rep`, `:yield_reu`, `:yield_rmtl`,
`:metal_intensity_new`, `:metal_intensity_ref`, `:metal_intensity_rep`, or
`:metal_intensity_reu`.
"""
function with_parameter(params::NamedTuple, key::Symbol, value::Real)
    if key in (:delta, :metal_quality, :sigma_metal, :sigma_routes, :sigma_eol, :eta_service)
        return _replace_namedtuple(params, key, Float64(value))
    elseif startswith(String(key), "yield_")
        inner_key = Symbol(replace(String(key), "yield_" => ""))
        haskey(params.yield, inner_key) || error("Unknown yield parameter $(key)")
        return merge(params, (yield = _replace_namedtuple(params.yield, inner_key, Float64(value)),))
    elseif startswith(String(key), "metal_intensity_")
        inner_key = Symbol(replace(String(key), "metal_intensity_" => ""))
        haskey(params.metal_intensity, inner_key) || error("Unknown metal intensity parameter $(key)")
        return merge(params, (metal_intensity = _replace_namedtuple(params.metal_intensity, inner_key, Float64(value)),))
    end
    error("Unknown parameter $(key)")
end

function _set_parameters(params::NamedTuple, assignments)
    out = params
    for (key, value) in assignments
        out = with_parameter(out, key, value)
    end
    return out
end

"""
    parameter_grid(; base_params=default_parameters(), policy=zero_policy(), kwargs...)

Create local experiment specs from keyword vectors, e.g.
`parameter_grid(sigma_routes=[1.2, 2.0], metal_quality=[0.75, 0.9])`.
"""
function parameter_grid(; base_params = default_parameters(),
    base_benchmark = synthetic_benchmark(base_params),
    policy::PolicyWedges = zero_policy(),
    prefix::AbstractString = "grid",
    kwargs...)
    stock0 = base_benchmark.stock0
    return RuntimeExperiments.parameter_grid(; prefix = prefix, kwargs...) do label, a
        params = _set_parameters(base_params, a)
        ExperimentSpec(label;
            params = params,
            policy = policy,
            benchmark = synthetic_benchmark(params; stock0 = stock0))
    end
end

"""
    policy_grid(kind, target, taus; params=default_parameters(), base_policy=zero_policy())

Create experiment specs that vary one comparable ad-valorem policy wedge.
"""
function policy_grid(kind::Symbol, target::Symbol, taus;
    params = default_parameters(),
    benchmark = synthetic_benchmark(params),
    base_policy::PolicyWedges = zero_policy(),
    prefix::AbstractString = "policy")
    return RuntimeExperiments.policy_grid(kind, target, taus; prefix = prefix) do label, k, t, tau
        ExperimentSpec(label;
            params = params,
            policy = with_wedge(base_policy, k, t, tau),
            benchmark = benchmark)
    end
end

"""
    parameter_policy_grid(; policy_kind, policy_target, tau, kwargs...)

Create experiment specs for all combinations of parameter assignments and one
policy wedge sequence.
"""
function parameter_policy_grid(; policy_kind::Symbol,
    policy_target::Symbol,
    tau,
    base_params = default_parameters(),
    base_benchmark = synthetic_benchmark(base_params),
    base_policy::PolicyWedges = zero_policy(),
    prefix::AbstractString = "grid",
    kwargs...)
    stock0 = base_benchmark.stock0
    return RuntimeExperiments.parameter_policy_grid(;
        policy_kind = policy_kind,
        policy_target = policy_target,
        tau = tau,
        prefix = prefix,
        kwargs...) do label, a, kind, target, tau_value
        params = _set_parameters(base_params, a)
        policy = with_wedge(base_policy, kind, target, tau_value)
        ExperimentSpec(label;
            params = params,
            policy = policy,
            benchmark = synthetic_benchmark(params; stock0 = stock0))
    end
end

"""
    accounts()

Return the canonical account groups used by the stylized circular model.
"""
function accounts()
    return (
        goods = GOODS,
        factors = FACTORS,
        materials = MATERIALS,
        routes = ROUTES,
        eol_uses = EOL_USES,
        institutions = INSTITUTIONS,
    )
end

"""
    default_parameters()

Return neutral starting values for the core theoretical parameters. These are
placeholders for model development and parameter-space exploration, not
empirical estimates.
"""
function default_parameters()
    return (
        delta = 0.25,
        metal_quality = 0.85,
        sigma_metal = 2.0,
        sigma_routes = 2.0,
        sigma_eol = 2.0,
        eta_service = 1.0,
        yield = (
            ref = 4.0,
            rep = 3.0,
            reu = 1.5,
            rmtl = 1.5,
        ),
        metal_intensity = (
            new = 0.40,
            ref = 0.25,
            rep = 1.0 / 6.0,
            reu = 0.00,
        ),
    )
end

"""
Structured mapping from a stylized product interpretation to model parameters.

The profile is not an empirical product database. It is a compact, comparable
way to document which product-side assumptions generated a parameter set.
"""
struct ProductProfile
    label::String
    stock0::Float64
    delta::Float64
    metal_quality::Float64
    yield::NamedTuple{(:ref,:rep,:reu,:rmtl),NTuple{4,Float64}}
    metal_intensity::NamedTuple{(:new,:ref,:rep,:reu),NTuple{4,Float64}}
end

const PROFILE_YIELD_KEYS = (:ref, :rep, :reu, :rmtl)
const PROFILE_METAL_INTENSITY_KEYS = (:new, :ref, :rep, :reu)

function _profile_tuple(values::NamedTuple, keys, what::AbstractString)
    missing = [key for key in keys if !haskey(values, key)]
    isempty(missing) || error("Missing $(what) profile keys: $(join(string.(missing), ", "))")
    return NamedTuple{keys}(Tuple(Float64(getproperty(values, key)) for key in keys))
end

function ProductProfile(label::AbstractString;
    stock0::Real = 200.0,
    delta::Real = default_parameters().delta,
    metal_quality::Real = default_parameters().metal_quality,
    yield::NamedTuple = default_parameters().yield,
    metal_intensity::NamedTuple = default_parameters().metal_intensity)
    return ProductProfile(
        String(label),
        Float64(stock0),
        Float64(delta),
        Float64(metal_quality),
        _profile_tuple(yield, PROFILE_YIELD_KEYS, "yield"),
        _profile_tuple(metal_intensity, PROFILE_METAL_INTENSITY_KEYS, "metal intensity"),
    )
end

"""
    default_product_profile()

Return the round-number toaster-service profile used by the synthetic benchmark.
"""
default_product_profile() = ProductProfile("round-number-toaster")

"""
    profile_parameters(profile; base_params=default_parameters())

Convert a product profile into the model parameter tuple.
"""
function profile_parameters(profile::ProductProfile; base_params = default_parameters())
    return merge(base_params, (
        delta = profile.delta,
        metal_quality = profile.metal_quality,
        yield = profile.yield,
        metal_intensity = profile.metal_intensity,
    ))
end

"""
    synthetic_sam()

Return a round-number SAM for calibration experiments. A cell `(row, column)` is
a payment from the column account to the row account.
"""
function synthetic_sam()
    values = Dict{Tuple{Symbol,Symbol},Float64}(
        (row, col) => 0.0 for row in SAM_ACCOUNTS for col in SAM_ACCOUNTS
    )

    values[(:BRD, :HOH)] = 200.0
    values[(:TST, :HOH)] = 200.0

    values[(:NEW, :TST)] = 100.0
    values[(:REF, :TST)] = 40.0
    values[(:REP, :TST)] = 30.0
    values[(:REU, :TST)] = 30.0

    values[(:VMTL, :NEW)] = 30.0
    values[(:VMTL, :REF)] = 6.0
    values[(:VMTL, :REP)] = 4.0

    values[(:RMTL, :NEW)] = 10.0
    values[(:RMTL, :REF)] = 4.0
    values[(:RMTL, :REP)] = 1.0

    values[(:EOL, :RMTL)] = 10.0
    values[(:EOL, :REF)] = 10.0
    values[(:EOL, :REP)] = 10.0
    values[(:EOL, :REU)] = 20.0

    values[(:LAB, :BRD)] = 123.0
    values[(:CAP, :BRD)] = 77.0
    values[(:LAB, :VMTL)] = 10.0
    values[(:CAP, :VMTL)] = 30.0
    values[(:LAB, :RMTL)] = 3.0
    values[(:CAP, :RMTL)] = 2.0
    values[(:LAB, :NEW)] = 30.0
    values[(:CAP, :NEW)] = 30.0
    values[(:LAB, :REF)] = 15.0
    values[(:CAP, :REF)] = 5.0
    values[(:LAB, :REP)] = 12.0
    values[(:CAP, :REP)] = 3.0
    values[(:LAB, :REU)] = 7.0
    values[(:CAP, :REU)] = 3.0

    values[(:HOH, :LAB)] = 200.0
    values[(:HOH, :CAP)] = 150.0
    values[(:HOH, :EOL)] = 50.0

    return (accounts = SAM_ACCOUNTS, values = values)
end

"""
    sam_balance(sam=synthetic_sam())

Return row sums, column sums, balances, and maximum absolute imbalance for a SAM.
"""
function sam_balance(sam = synthetic_sam())
    row_sums = Dict(account => sum(sam.values[(account, col)] for col in sam.accounts)
        for account in sam.accounts)
    column_sums = Dict(account => sum(sam.values[(row, account)] for row in sam.accounts)
        for account in sam.accounts)
    balances = Dict(account => row_sums[account] - column_sums[account]
        for account in sam.accounts)
    max_abs_imbalance = maximum(abs, values(balances))
    return (
        row_sums = row_sums,
        column_sums = column_sums,
        balances = balances,
        max_abs_imbalance = max_abs_imbalance,
    )
end

"""
    synthetic_benchmark()

Return a small synthetic benchmark used by the first executable model. The
values are intentionally stylized and should be read as calibration scaffolding,
not empirical data.
"""
function _ces_quantity(inputs::Dict{Symbol,Float64}, shares::Dict{Symbol,Float64},
    sigma::Real; quality::Dict{Symbol,Float64}=Dict(k => 1.0 for k in keys(inputs)))
    rho = (sigma - 1.0) / sigma
    if abs(rho) < 1.0e-8
        return prod((quality[k] * inputs[k]) ^ shares[k] for k in keys(inputs))
    end
    return sum(shares[k] * (quality[k] * inputs[k]) ^ rho for k in keys(inputs)) ^ (1.0 / rho)
end

function synthetic_benchmark(params = default_parameters(); stock0::Real = 200.0)
    sam = synthetic_sam()
    sam_values = sam.values
    output = Dict(a => sum(sam_values[(a, col)] for col in sam.accounts)
        for a in (PRODUCTION_ACTIVITIES..., :TST))
    factor_endowment = Dict(h => sum(sam_values[(h, col)] for col in sam.accounts)
        for h in FACTORS)
    factor_input = Dict((h, a) => sam_values[(h, a)]
        for h in FACTORS for a in PRODUCTION_ACTIVITIES)
    material_input = Dict((m, route) => sam_values[(m, route)]
        for m in MATERIALS for route in MATERIAL_ROUTES)

    factor_share = Dict{Tuple{Symbol,Symbol},Float64}()
    for a in PRODUCTION_ACTIVITIES
        total_factor = sum(factor_input[(h, a)] for h in FACTORS)
        for h in FACTORS
            factor_share[(h, a)] = factor_input[(h, a)] / total_factor
        end
    end
    productivity = Dict(a =>
            output[a] / prod(factor_input[(h, a)] ^ factor_share[(h, a)] for h in FACTORS)
        for a in PRODUCTION_ACTIVITIES)

    final_demand = Dict(g => sam_values[(g, :HOH)] for g in (:BRD, :TST))
    total_final_demand = sum(values(final_demand))
    route_demand = Dict(route => sam_values[(route, :TST)] for route in ROUTES)
    total_route_demand = sum(values(route_demand))
    material_demand = Dict(m => sum(sam_values[(m, route)] for route in MATERIAL_ROUTES)
        for m in MATERIALS)
    total_material_demand = sum(values(material_demand))

    route_metal_share = Dict{Tuple{Symbol,Symbol},Float64}()
    metal_scale = Dict{Symbol,Float64}()
    for route in MATERIAL_ROUTES
        total = sum(material_input[(m, route)] for m in MATERIALS)
        route_inputs = Dict(m => material_input[(m, route)] for m in MATERIALS)
        route_shares = Dict(m => route_inputs[m] / total for m in MATERIALS)
        for m in MATERIALS
            route_metal_share[(m, route)] = route_shares[m]
        end
        quality = Dict(:VMTL => 1.0, :RMTL => params.metal_quality)
        unscaled = _ces_quantity(route_inputs, route_shares, params.sigma_metal; quality = quality)
        metal_scale[route] = (_metal_intensity(params, route) * output[route]) / unscaled
    end

    route_inputs = Dict(route => route_demand[route] for route in ROUTES)
    route_shares = Dict(route => route_demand[route] / total_route_demand for route in ROUTES)
    route_scale = output[:TST] / _ces_quantity(route_inputs, route_shares, params.sigma_routes)

    raw_eol_allocation = Dict(
        :REF => sam_values[(:EOL, :REF)],
        :REP => sam_values[(:EOL, :REP)],
        :REU => sam_values[(:EOL, :REU)],
        :REC => sam_values[(:EOL, :RMTL)],
        :INC => sam_values[(:EOL, :INC)],
    )
    target_retirement = params.delta * Float64(stock0)
    eol_scale = target_retirement / sum(values(raw_eol_allocation))
    eol_allocation = Dict(use => raw_eol_allocation[use] * eol_scale for use in EOL_USES)

    return (
        stock0 = Float64(stock0),
        output = output,
        factor_endowment = factor_endowment,
        factor_input = factor_input,
        material_input = material_input,
        productivity = productivity,
        factor_share = factor_share,
        utility_share = Dict(g => final_demand[g] / total_final_demand for g in keys(final_demand)),
        route_share = route_shares,
        metal_share = Dict(m => material_demand[m] / total_material_demand for m in MATERIALS),
        route_metal_share = route_metal_share,
        metal_scale = metal_scale,
        route_scale = route_scale,
        eol_allocation = eol_allocation,
    )
end

"""
    profile_benchmark(profile)

Return a benchmark calibrated from the synthetic SAM while preserving the
profile's opening stock and retirement-rate assumptions.
"""
function profile_benchmark(profile::ProductProfile)
    params = profile_parameters(profile)
    return synthetic_benchmark(params; stock0 = profile.stock0)
end

"""
    profile_experiment(label, profile; policy=zero_policy())

Create an experiment spec from a product profile.
"""
function profile_experiment(label::AbstractString,
    profile::ProductProfile;
    policy::PolicyWedges = zero_policy())
    params = profile_parameters(profile)
    return ExperimentSpec(label;
        params = params,
        policy = policy,
        benchmark = profile_benchmark(profile))
end

"""
    product_profile_grid(profiles; policy=zero_policy(), prefix="profile")

Create one experiment spec per product profile.
"""
function product_profile_grid(profiles::AbstractVector{<:ProductProfile};
    policy::PolicyWedges = zero_policy(),
    prefix::AbstractString = "profile")
    return [
        profile_experiment("$(prefix):$(profile.label)", profile; policy = policy)
        for profile in profiles
    ]
end

"""
    product_parameter_grid(profile; kwargs...)

Create parameter-grid experiments anchored on one product profile.
"""
function product_parameter_grid(profile::ProductProfile;
    policy::PolicyWedges = zero_policy(),
    prefix::AbstractString = "profile-grid",
    kwargs...)
    return parameter_grid(;
        base_params = profile_parameters(profile),
        base_benchmark = profile_benchmark(profile),
        policy = policy,
        prefix = "$(prefix):$(profile.label)",
        kwargs...)
end

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

function _policy_summary(policy::PolicyWedges)
    return (
        route = copy(policy.route),
        material = copy(policy.material),
        eol = copy(policy.eol),
    )
end

function _parameter_summary(params::NamedTuple)
    return (
        delta = params.delta,
        metal_quality = params.metal_quality,
        sigma_metal = params.sigma_metal,
        sigma_routes = params.sigma_routes,
        sigma_eol = params.sigma_eol,
        eta_service = params.eta_service,
        yield = params.yield,
        metal_intensity = params.metal_intensity,
    )
end

function _benchmark_summary(benchmark::NamedTuple)
    return (
        stock0 = benchmark.stock0,
    )
end

"""
    run_experiment(spec; closure=:fiscal)

Solve one local experiment and return metadata plus compact indicators. The
default is the fiscal closed-economy closure; use `closure = :planner` for the
planner-form diagnostic variant.
"""
function run_experiment(spec::ExperimentSpec; closure::Symbol = :fiscal, kwargs...)
    run_spec =
        if closure === :planner
            baseline(params = spec.params, benchmark = spec.benchmark, policy = spec.policy)
        elseif closure in (:fiscal, :decentralized)
            fiscal_baseline(params = spec.params, benchmark = spec.benchmark, policy = spec.policy)
        else
            error("Unknown experiment closure $(closure). Use :planner or :fiscal.")
        end
    result = solve(run_spec; kwargs...)
    out = indicators(result)
    return (
        label = spec.label,
        closure = closure === :decentralized ? :fiscal : closure,
        params = _parameter_summary(spec.params),
        benchmark = _benchmark_summary(spec.benchmark),
        policy = _policy_summary(spec.policy),
        status = JuMP.termination_status(result.context.model),
        indicators = out,
    )
end

"""
    run_grid(specs)

Run a vector of `ExperimentSpec`s and return one result record per experiment.
By default this uses the fiscal closed-economy closure through `run_experiment`.
"""
run_grid(specs::AbstractVector{ExperimentSpec}; kwargs...) =
    RuntimeExperiments.run_grid(specs; runner = run_experiment, kwargs...)

"""
    experiment_execution_kwargs(; env=ENV)

Return keyword arguments for experiment execution based on environment settings.
By default this returns an empty tuple and grids run serially. Set
`JCGE_EXPERIMENT_WORKERS` to an integer greater than one to opt into
process-based distributed execution.
"""
function experiment_execution_kwargs(; env = ENV)
    text = get(env, "JCGE_EXPERIMENT_WORKERS", "")
    isempty(strip(text)) && return (;)
    workers = tryparse(Int, strip(text))
    workers === nothing && error("JCGE_EXPERIMENT_WORKERS must be an integer")
    workers <= 1 && return (;)
    return (
        execution = :distributed,
        workers = workers,
        worker_modules = [:StylizedCircularCGE],
    )
end

"""
    result_row(record)

Flatten one experiment result into a scalar NamedTuple suitable for printing,
filtering, or later export.
"""
function result_row(record::NamedTuple)
    ind = record.indicators
    return (
        label = record.label,
        closure = record.closure,
        status = record.status,
        stock0 = record.benchmark.stock0,
        delta = record.params.delta,
        sigma_routes = record.params.sigma_routes,
        sigma_metal = record.params.sigma_metal,
        sigma_eol = record.params.sigma_eol,
        eta_service = record.params.eta_service,
        metal_quality = record.params.metal_quality,
        yield_ref = record.params.yield.ref,
        yield_rep = record.params.yield.rep,
        yield_reu = record.params.yield.reu,
        yield_rmtl = record.params.yield.rmtl,
        metal_intensity_new = record.params.metal_intensity.new,
        metal_intensity_ref = record.params.metal_intensity.ref,
        metal_intensity_rep = record.params.metal_intensity.rep,
        metal_intensity_reu = record.params.metal_intensity.reu,
        tau_route_new = record.policy.route[:NEW],
        tau_route_ref = record.policy.route[:REF],
        tau_route_rep = record.policy.route[:REP],
        tau_route_reu = record.policy.route[:REU],
        tau_material_vmtl = record.policy.material[:VMTL],
        tau_material_rmtl = record.policy.material[:RMTL],
        tau_eol_ref = record.policy.eol[:REF],
        tau_eol_rep = record.policy.eol[:REP],
        tau_eol_reu = record.policy.eol[:REU],
        tau_eol_rec = record.policy.eol[:REC],
        tau_eol_inc = record.policy.eol[:INC],
        bread = ind.bread,
        toaster_service = ind.toaster_service,
        virgin_use = ind.virgin_use,
        recycled_use = ind.recycled_use,
        route_new = ind.route_quantity[:NEW],
        route_ref = ind.route_quantity[:REF],
        route_rep = ind.route_quantity[:REP],
        route_reu = ind.route_quantity[:REU],
        eol_ref = ind.eol_quantity[:REF],
        eol_rep = ind.eol_quantity[:REP],
        eol_reu = ind.eol_quantity[:REU],
        eol_rec = ind.eol_quantity[:REC],
        eol_inc = ind.eol_quantity[:INC],
        virgin_use_new = ind.virgin_use_by_route[:NEW],
        virgin_use_ref = ind.virgin_use_by_route[:REF],
        virgin_use_rep = ind.virgin_use_by_route[:REP],
        recycled_use_new = ind.recycled_use_by_route[:NEW],
        recycled_use_ref = ind.recycled_use_by_route[:REF],
        recycled_use_rep = ind.recycled_use_by_route[:REP],
        route_new_share = ind.route_share[:NEW],
        route_ref_share = ind.route_share[:REF],
        route_rep_share = ind.route_share[:REP],
        route_reu_share = ind.route_share[:REU],
        eol_ref_share = ind.eol_share[:REF],
        eol_rep_share = ind.eol_share[:REP],
        eol_reu_share = ind.eol_share[:REU],
        eol_rec_share = ind.eol_share[:REC],
        eol_inc_share = ind.eol_share[:INC],
        wedge_net = ind.wedge_accounting.net,
        wedge_penalties = ind.wedge_accounting.penalties,
        wedge_support = ind.wedge_accounting.support,
        price_bread = ind.prices.bread,
        price_toaster_service = ind.prices.toaster_service,
        price_route_new = ind.prices.route[:NEW],
        price_route_ref = ind.prices.route[:REF],
        price_route_rep = ind.prices.route[:REP],
        price_route_reu = ind.prices.route[:REU],
        price_material_vmtl = ind.prices.material[:VMTL],
        price_material_rmtl = ind.prices.material[:RMTL],
        price_eol_ref = ind.prices.eol[:REF],
        price_eol_rep = ind.prices.eol[:REP],
        price_eol_reu = ind.prices.eol[:REU],
        price_eol_rec = ind.prices.eol[:REC],
        price_eol_inc = ind.prices.eol[:INC],
        household_income = ind.fiscal.household_income,
        prefiscal_income = ind.fiscal.prefiscal_income,
        government_net = ind.fiscal.government_net,
        government_revenue = ind.fiscal.government_revenue,
        government_subsidy = ind.fiscal.government_subsidy,
        government_transfer = ind.fiscal.government_transfer,
        max_abs_market_residual = ind.closed_economy.max_abs_market_residual,
        max_positive_capacity_slack = ind.closed_economy.max_positive_capacity_slack,
        max_factor_slack = ind.closed_economy.max_factor_slack,
        material_balance_vmtl = ind.closed_economy.material_balance[:VMTL],
        material_balance_rmtl = ind.closed_economy.material_balance[:RMTL],
        eol_balance = ind.closed_economy.eol_balance,
        household_budget_residual = ind.closed_economy.household_budget,
        government_budget_residual = ind.closed_economy.government_budget,
        route_capacity_ref = ind.closed_economy.route_capacity_slack[:REF],
        route_capacity_rep = ind.closed_economy.route_capacity_slack[:REP],
        route_capacity_reu = ind.closed_economy.route_capacity_slack[:REU],
        recycling_capacity_slack = ind.closed_economy.recycling_capacity_slack,
        utility_log = ind.utility_log,
    )
end

"""
    result_rows(records)

Flatten many experiment records into scalar rows.
"""
result_rows(records::AbstractVector{<:NamedTuple}) = [result_row(record) for record in records]

"""
    closed_economy_failures(records; market_tol=1e-5)

Return fiscal experiment rows that should not be used as closed-economy results.
A row fails if it is not locally solved or if any market-accounting residual is
larger than `market_tol`.
"""
function closed_economy_failures(records::AbstractVector{<:NamedTuple};
    market_tol::Real = 1.0e-5)
    return RuntimeExperiments.closure_failures(result_rows(records);
        closure = :fiscal,
        status = JuMP.MOI.LOCALLY_SOLVED,
        residual_field = :max_abs_market_residual,
        residual_tol = market_tol)
end

"""
    assert_closed_economy_results(records; market_tol=1e-5)

Validate a fiscal experiment batch and return `records` unchanged. Throws an
error listing the first failing rows when the batch contains non-solved or
non-closing results.
"""
function assert_closed_economy_results(records::AbstractVector{<:NamedTuple};
    market_tol::Real = 1.0e-5)
    RuntimeExperiments.assert_closure(result_rows(records);
        closure = :fiscal,
        status = JuMP.MOI.LOCALLY_SOLVED,
        residual_field = :max_abs_market_residual,
        residual_tol = market_tol,
        describe = row ->
            "$(row.label): status=$(row.status), max_abs_market_residual=$(row.max_abs_market_residual)")
    return records
end

function _pct_change(value, reference)
    abs(reference) <= 1.0e-12 && return NaN
    return (value - reference) / abs(reference)
end

function _comparison_fields(row::NamedTuple, ref::NamedTuple)
    fields = (
        reference_label = ref.label,
        delta_toaster_service = row.toaster_service - ref.toaster_service,
        delta_virgin_use = row.virgin_use - ref.virgin_use,
        delta_recycled_use = row.recycled_use - ref.recycled_use,
        delta_route_new = row.route_new - ref.route_new,
        delta_route_ref = row.route_ref - ref.route_ref,
        delta_route_rep = row.route_rep - ref.route_rep,
        delta_route_reu = row.route_reu - ref.route_reu,
        delta_eol_ref = row.eol_ref - ref.eol_ref,
        delta_eol_rep = row.eol_rep - ref.eol_rep,
        delta_eol_reu = row.eol_reu - ref.eol_reu,
        delta_eol_rec = row.eol_rec - ref.eol_rec,
        delta_eol_inc = row.eol_inc - ref.eol_inc,
        delta_virgin_use_new = row.virgin_use_new - ref.virgin_use_new,
        delta_virgin_use_ref = row.virgin_use_ref - ref.virgin_use_ref,
        delta_virgin_use_rep = row.virgin_use_rep - ref.virgin_use_rep,
        delta_recycled_use_new = row.recycled_use_new - ref.recycled_use_new,
        delta_recycled_use_ref = row.recycled_use_ref - ref.recycled_use_ref,
        delta_recycled_use_rep = row.recycled_use_rep - ref.recycled_use_rep,
        delta_ref_share = row.route_ref_share - ref.route_ref_share,
        delta_rec_share = row.eol_rec_share - ref.eol_rec_share,
        pct_toaster_service = _pct_change(row.toaster_service, ref.toaster_service),
        pct_virgin_use = _pct_change(row.virgin_use, ref.virgin_use),
        pct_recycled_use = _pct_change(row.recycled_use, ref.recycled_use),
        material_saving = row.virgin_use < ref.virgin_use - 1.0e-8,
        rebound = row.toaster_service > ref.toaster_service + 1.0e-8,
    )
    return merge(fields, (mechanism = classify_mechanism(fields),))
end

"""
    compare_to_reference(records, reference)

Return flattened rows with absolute and relative changes against `reference`.
"""
function compare_to_reference(records::AbstractVector{<:NamedTuple}, reference::NamedTuple)
    ref = result_row(reference)
    rows = result_rows(records)
    return RuntimeExperiments.compare_to_reference(rows, ref; compare = _comparison_fields)
end

"""
    compare_to_group_reference(records, group_by; reference_filter)

Flatten experiment records and compare each row to the reference row in its own
group. The `reference_filter` function must identify exactly one reference row
inside each group, for example the zero-policy row of a policy sweep.
"""
function compare_to_group_reference(records::AbstractVector{<:NamedTuple},
    group_by::AbstractVector{Symbol};
    reference_filter::Function)
    rows = result_rows(records)
    return RuntimeExperiments.compare_to_group_reference(rows, group_by;
        reference_filter = reference_filter,
        compare = _comparison_fields)
end

"""
    classify_regime(row)

Classify one comparison row into a compact circular-strategy regime.
"""
function classify_regime(row::NamedTuple)
    hasproperty(row, :material_saving) || error("classify_regime expects rows from compare_to_reference")
    if row.material_saving && !row.rebound
        return :material_saving_without_rebound
    elseif row.material_saving && row.rebound
        return :material_saving_with_rebound
    elseif !row.material_saving && row.rebound
        return :rebound_without_material_saving
    end
    return :no_material_saving_no_rebound
end

"""
    regime_counts(rows)

Count comparison rows by circular-strategy regime.
"""
function regime_counts(rows::AbstractVector{<:NamedTuple})
    counts = Dict{Symbol,Int}()
    for row in rows
        regime = classify_regime(row)
        counts[regime] = get(counts, regime, 0) + 1
    end
    return counts
end

function _near_zero(value::Real, tol::Real)
    return abs(Float64(value)) <= tol
end

"""
    classify_mechanism(row; tol=1e-8)

Classify the dominant equilibrium channel in one comparison row. The labels are
diagnostic: they summarize route, EOL, material-use, and service-demand deltas
without replacing those underlying fields.
"""
function classify_mechanism(row::NamedTuple; tol::Real = 1.0e-8)
    hasproperty(row, :material_saving) || error("classify_mechanism expects comparison rows")
    hasproperty(row, :delta_route_new) || error("classify_mechanism expects decomposition deltas")

    d_service = row.delta_toaster_service
    d_virgin = row.delta_virgin_use
    d_new = row.delta_route_new
    d_ref = row.delta_route_ref
    d_rep = row.delta_route_rep
    d_reu = row.delta_route_reu
    d_eol_ref = row.delta_eol_ref

    if _near_zero(d_virgin, tol) && _near_zero(d_service, tol) &&
       _near_zero(d_new, tol) && _near_zero(d_ref, tol) &&
       _near_zero(d_rep, tol) && _near_zero(d_reu, tol)
        return :reference
    end

    service_contracts = d_service < -tol
    new_contracts = d_new < -tol
    ref_expands = d_ref > tol
    eol_ref_expands = d_eol_ref > tol
    circular_routes_contract = d_ref <= tol && d_rep <= tol && d_reu <= tol

    if row.material_saving
        if row.rebound
            if new_contracts && (ref_expands || eol_ref_expands)
                return :circular_substitution_with_rebound
            end
            return :rebound_material_saving
        elseif service_contracts && new_contracts && circular_routes_contract && !eol_ref_expands
            return :demand_contraction_material_saving
        elseif new_contracts && ref_expands
            return :refurbishment_substitution_material_saving
        elseif new_contracts && eol_ref_expands
            return :eol_reallocation_material_saving
        elseif service_contracts
            return :service_contraction_material_saving
        end
        return :mixed_material_saving
    end

    if row.rebound
        return :rebound_without_material_saving
    elseif d_virgin > tol && (ref_expands || eol_ref_expands)
        return :circular_expansion_material_increase
    elseif d_virgin > tol && service_contracts
        return :service_contraction_material_increase
    elseif service_contracts
        return :service_contraction_without_material_saving
    end
    return :no_material_saving
end

"""
    mechanism_counts(rows)

Count comparison rows by `classify_mechanism`.
"""
function mechanism_counts(rows::AbstractVector{<:NamedTuple})
    counts = Dict{Symbol,Int}()
    for row in rows
        mechanism = hasproperty(row, :mechanism) ? row.mechanism : classify_mechanism(row)
        counts[mechanism] = get(counts, mechanism, 0) + 1
    end
    return counts
end

"""
    frontier_rows(rows; group_by, select_by, predicate, sense=:min)

Return one selected row per group after filtering with `predicate`. This is a
generic helper for numerical threshold searches.
"""
function frontier_rows(rows::AbstractVector{<:NamedTuple};
    group_by::AbstractVector{Symbol} = Symbol[],
    select_by::Symbol,
    predicate::Function = row -> true,
    sense::Symbol = :min)
    return RuntimeExperiments.frontier_rows(rows;
        group_by = group_by,
        select_by = select_by,
        predicate = predicate,
        sense = sense)
end

"""
    material_saving_frontier(rows, policy_field; group_by, allow_rebound=false)

Return the smallest policy magnitude in each group that reduces virgin-material
use. By default, rows with rebound in toaster-service output are excluded.
"""
function material_saving_frontier(rows::AbstractVector{<:NamedTuple},
    policy_field::Symbol;
    group_by::AbstractVector{Symbol} = Symbol[],
    allow_rebound::Bool = false,
    sense::Symbol = :absolute_min)
    return frontier_rows(rows;
        group_by = group_by,
        select_by = policy_field,
        predicate = row -> row.material_saving && (allow_rebound || !row.rebound),
        sense = sense)
end

function _frontier_key(row::NamedTuple, group_by::AbstractVector{Symbol})
    return Tuple(getproperty(row, field) for field in group_by)
end

function _frontier_lookup(rows::AbstractVector{<:NamedTuple},
    group_by::AbstractVector{Symbol})
    lookup = Dict{Tuple,NamedTuple}()
    for row in rows
        key = _frontier_key(row, group_by)
        haskey(lookup, key) && error("Duplicate frontier row for group $(key)")
        lookup[key] = row
    end
    return lookup
end

_maybe_field(row::Nothing, field::Symbol) = NaN
_maybe_field(row::NamedTuple, field::Symbol) = Float64(getproperty(row, field))

function _choose_strategy(left::Union{Nothing,NamedTuple},
    right::Union{Nothing,NamedTuple},
    field::Symbol,
    left_label::Symbol,
    right_label::Symbol;
    sense::Symbol)
    left === nothing && right === nothing && return :none
    left === nothing && return right_label
    right === nothing && return left_label
    left_value = getproperty(left, field)
    right_value = getproperty(right, field)
    isapprox(left_value, right_value; atol = 1.0e-12, rtol = 1.0e-12) && return :tie
    if sense === :min
        return left_value < right_value ? left_label : right_label
    elseif sense === :max
        return left_value > right_value ? left_label : right_label
    end
    error("Unknown comparison sense $(sense). Use :min or :max.")
end

"""
    compare_frontiers(left_rows, right_rows; group_by, left_label, right_label,
        left_policy, right_policy)

Pair two threshold frontiers by `group_by` fields and return compact comparison
rows. This is useful when two policy instruments are computed separately but
need to be compared on the same parameter grid.
"""
function compare_frontiers(left_rows::AbstractVector{<:NamedTuple},
    right_rows::AbstractVector{<:NamedTuple};
    group_by::AbstractVector{Symbol},
    left_label::Symbol = :left,
    right_label::Symbol = :right,
    left_policy::Symbol,
    right_policy::Symbol)
    left = _frontier_lookup(left_rows, group_by)
    right = _frontier_lookup(right_rows, group_by)
    keys_all = sort(collect(union(keys(left), keys(right))); by = string)
    return [
        merge(
            NamedTuple{Tuple(group_by)}(key),
            begin
                left_row = get(left, key, nothing)
                right_row = get(right, key, nothing)
                (
                    left_strategy = left_label,
                    right_strategy = right_label,
                    left_available = left_row !== nothing,
                    right_available = right_row !== nothing,
                    left_policy_value = _maybe_field(left_row, left_policy),
                    right_policy_value = _maybe_field(right_row, right_policy),
                    left_policy_magnitude = abs(_maybe_field(left_row, left_policy)),
                    right_policy_magnitude = abs(_maybe_field(right_row, right_policy)),
                    left_pct_virgin_use = _maybe_field(left_row, :pct_virgin_use),
                    right_pct_virgin_use = _maybe_field(right_row, :pct_virgin_use),
                    left_pct_toaster_service = _maybe_field(left_row, :pct_toaster_service),
                    right_pct_toaster_service = _maybe_field(right_row, :pct_toaster_service),
                    left_government_net = _maybe_field(left_row, :government_net),
                    right_government_net = _maybe_field(right_row, :government_net),
                    stronger_material_saving = _choose_strategy(left_row, right_row,
                        :pct_virgin_use, left_label, right_label; sense = :min),
                    lower_service_loss = _choose_strategy(left_row, right_row,
                        :pct_toaster_service, left_label, right_label; sense = :max),
                    higher_government_net = _choose_strategy(left_row, right_row,
                        :government_net, left_label, right_label; sense = :max),
                )
            end,
        )
        for key in keys_all
    ]
end

"""
    sensitivity_screen(rows, outcome, parameters)

Rank varied parameters by the range of mean `outcome` values across their
levels. This is a compact screening tool; it is not a substitute for a designed
global sensitivity analysis.
"""
function sensitivity_screen(rows::AbstractVector{<:NamedTuple},
    outcome::Symbol,
    parameters::AbstractVector{Symbol})
    return RuntimeExperiments.sensitivity_screen(rows, outcome, parameters)
end

function _minmax(values)
    isempty(values) && return (min = NaN, max = NaN)
    return (min = minimum(values), max = maximum(values))
end

"""
    summarize_comparison(rows)

Return compact ranges and regime counts for comparison rows.
"""
function summarize_comparison(rows::AbstractVector{<:NamedTuple})
    return (
        count = length(rows),
        regimes = regime_counts(rows),
        mechanisms = mechanism_counts(rows),
        pct_virgin_use = _minmax([row.pct_virgin_use for row in rows]),
        pct_recycled_use = _minmax([row.pct_recycled_use for row in rows]),
        pct_toaster_service = _minmax([row.pct_toaster_service for row in rows]),
        delta_ref_share = _minmax([row.delta_ref_share for row in rows]),
        delta_rec_share = _minmax([row.delta_rec_share for row in rows]),
        wedge_net = _minmax([row.wedge_net for row in rows]),
    )
end

"""
    summary_row(summary)

Flatten `summarize_comparison` output into one CSV-friendly row.
"""
function summary_row(summary::NamedTuple)
    regimes = summary.regimes
    mechanisms = summary.mechanisms
    return (
        count = summary.count,
        material_saving_without_rebound = get(regimes, :material_saving_without_rebound, 0),
        material_saving_with_rebound = get(regimes, :material_saving_with_rebound, 0),
        rebound_without_material_saving = get(regimes, :rebound_without_material_saving, 0),
        no_material_saving_no_rebound = get(regimes, :no_material_saving_no_rebound, 0),
        mechanism_reference = get(mechanisms, :reference, 0),
        mechanism_demand_contraction_material_saving = get(mechanisms,
            :demand_contraction_material_saving, 0),
        mechanism_refurbishment_substitution_material_saving = get(mechanisms,
            :refurbishment_substitution_material_saving, 0),
        mechanism_eol_reallocation_material_saving = get(mechanisms,
            :eol_reallocation_material_saving, 0),
        mechanism_circular_substitution_with_rebound = get(mechanisms,
            :circular_substitution_with_rebound, 0),
        mechanism_rebound_material_saving = get(mechanisms, :rebound_material_saving, 0),
        mechanism_circular_expansion_material_increase = get(mechanisms,
            :circular_expansion_material_increase, 0),
        mechanism_service_contraction_material_increase = get(mechanisms,
            :service_contraction_material_increase, 0),
        mechanism_service_contraction_without_material_saving = get(mechanisms,
            :service_contraction_without_material_saving, 0),
        mechanism_rebound_without_material_saving = get(mechanisms,
            :rebound_without_material_saving, 0),
        mechanism_no_material_saving = get(mechanisms, :no_material_saving, 0),
        mechanism_mixed_material_saving = get(mechanisms, :mixed_material_saving, 0),
        pct_virgin_use_min = summary.pct_virgin_use.min,
        pct_virgin_use_max = summary.pct_virgin_use.max,
        pct_recycled_use_min = summary.pct_recycled_use.min,
        pct_recycled_use_max = summary.pct_recycled_use.max,
        pct_toaster_service_min = summary.pct_toaster_service.min,
        pct_toaster_service_max = summary.pct_toaster_service.max,
        delta_ref_share_min = summary.delta_ref_share.min,
        delta_ref_share_max = summary.delta_ref_share.max,
        delta_rec_share_min = summary.delta_rec_share.min,
        delta_rec_share_max = summary.delta_rec_share.max,
        wedge_net_min = summary.wedge_net.min,
        wedge_net_max = summary.wedge_net.max,
    )
end

"""
    best_material_savers(rows; n=5)

Return up to `n` comparison rows that reduce virgin material use, sorted from
largest to smallest reduction.
"""
function best_material_savers(rows::AbstractVector{<:NamedTuple}; n::Integer = 5)
    all(row -> hasproperty(row, :material_saving), rows) ||
        error("best_material_savers expects rows from compare_to_reference")
    savers = filter(row -> row.material_saving, rows)
    ordered = sort(collect(savers); by = row -> row.delta_virgin_use)
    return ordered[1:min(n, length(ordered))]
end

"""
    write_rows_csv(path, rows)

Write flattened result or comparison rows to CSV. Rows must be scalar
NamedTuples, such as the output of `result_rows` or `compare_to_reference`.
"""
function write_rows_csv(path::AbstractString, rows::AbstractVector{<:NamedTuple})
    return RuntimeExperiments.write_rows_csv(path, rows)
end

"""
    write_experiment_bundle(output_dir, records; reference=nothing, basename="experiment")

Write result rows and, when a reference is provided, comparison and summary CSVs.
"""
function write_experiment_bundle(output_dir::AbstractString,
    records::AbstractVector{<:NamedTuple};
    reference::Union{Nothing,NamedTuple} = nothing,
    basename::AbstractString = "experiment")
    mkpath(output_dir)
    results_path = write_rows_csv(joinpath(output_dir, "$(basename).csv"), result_rows(records))
    reference === nothing && return (results = results_path,)

    comparison = compare_to_reference(records, reference)
    comparison_path = write_rows_csv(joinpath(output_dir, "$(basename)_comparison.csv"), comparison)
    summary_path = write_rows_csv(joinpath(output_dir, "$(basename)_summary.csv"),
        [summary_row(summarize_comparison(comparison))])
    return (
        results = results_path,
        comparison = comparison_path,
        summary = summary_path,
    )
end

"""
    datadir()

Return the package data directory.
"""
datadir() = joinpath(@__DIR__, "..", "data")

end # module
