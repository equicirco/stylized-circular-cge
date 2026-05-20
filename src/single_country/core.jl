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
    calibration = default_calibration_set(),
    params = default_parameters(; calibration = calibration),
    policy::PolicyWedges = zero_policy(),
    benchmark = synthetic_benchmark(params; calibration = calibration)) =
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
    parameter_grid(; calibration=default_calibration_set(), policy=zero_policy(), kwargs...)

Create local experiment specs from keyword vectors, e.g.
`parameter_grid(sigma_routes=[1.2, 2.0], metal_quality=[0.75, 0.9])`.
"""
function parameter_grid(; calibration = default_calibration_set(),
    base_params = default_parameters(; calibration = calibration),
    base_benchmark = synthetic_benchmark(base_params; calibration = calibration),
    policy::PolicyWedges = zero_policy(),
    prefix::AbstractString = "grid",
    kwargs...)
    stock0 = base_benchmark.stock0
    return RuntimeExperiments.parameter_grid(; prefix = prefix, kwargs...) do label, a
        params = _set_parameters(base_params, a)
        ExperimentSpec(label;
            calibration = calibration,
            params = params,
            policy = policy,
            benchmark = synthetic_benchmark(params; stock0 = stock0, calibration = calibration))
    end
end

"""
    policy_grid(kind, target, taus; calibration=default_calibration_set(), base_policy=zero_policy())

Create experiment specs that vary one comparable ad-valorem policy wedge.
"""
function policy_grid(kind::Symbol, target::Symbol, taus;
    calibration = default_calibration_set(),
    params = default_parameters(; calibration = calibration),
    benchmark = synthetic_benchmark(params; calibration = calibration),
    base_policy::PolicyWedges = zero_policy(),
    prefix::AbstractString = "policy")
    return RuntimeExperiments.policy_grid(kind, target, taus; prefix = prefix) do label, k, t, tau
        ExperimentSpec(label;
            calibration = calibration,
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
    calibration = default_calibration_set(),
    base_params = default_parameters(; calibration = calibration),
    base_benchmark = synthetic_benchmark(base_params; calibration = calibration),
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
            calibration = calibration,
            params = params,
            policy = policy,
            benchmark = synthetic_benchmark(params; stock0 = stock0, calibration = calibration))
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

Return the core theoretical parameters from a calibration set. The default
calibration is intentionally stylized and is not an empirical estimate.
"""
default_parameters(; calibration = default_calibration_set()) =
    calibration_parameters(calibration)

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
    calibration = default_calibration_set(),
    stock0 = nothing,
    delta = nothing,
    metal_quality = nothing,
    yield::Union{Nothing,NamedTuple} = nothing,
    metal_intensity::Union{Nothing,NamedTuple} = nothing)
    params = default_parameters(; calibration = calibration)
    return ProductProfile(
        String(label),
        Float64(stock0 === nothing ? calibration_stock0(calibration) : stock0),
        Float64(delta === nothing ? params.delta : delta),
        Float64(metal_quality === nothing ? params.metal_quality : metal_quality),
        _profile_tuple(yield === nothing ? params.yield : yield, PROFILE_YIELD_KEYS, "yield"),
        _profile_tuple(metal_intensity === nothing ? params.metal_intensity : metal_intensity,
            PROFILE_METAL_INTENSITY_KEYS, "metal intensity"),
    )
end

"""
    default_product_profile()

Return the round-number toaster-service profile used by the synthetic benchmark.
"""
default_product_profile(; calibration = default_calibration_set()) =
    ProductProfile("round-number-toaster"; calibration = calibration)

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

Return the single-country SAM loaded from a calibration set. A cell
`(row, column)` is a payment from the column account to the row account.
"""
function synthetic_sam(calibration = default_calibration_set())
    return (accounts = SAM_ACCOUNTS, values = _sam_values(calibration.single_sam, SAM_ACCOUNTS))
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

Return the single-country benchmark calibrated from the selected calibration
set. The default values are intentionally stylized and should not be read as
empirical data.
"""
function _ces_quantity(inputs::Dict{Symbol,Float64}, shares::Dict{Symbol,Float64},
    sigma::Real; quality::Dict{Symbol,Float64}=Dict(k => 1.0 for k in keys(inputs)))
    rho = (sigma - 1.0) / sigma
    if abs(rho) < 1.0e-8
        return prod((quality[k] * inputs[k]) ^ shares[k] for k in keys(inputs))
    end
    return sum(shares[k] * (quality[k] * inputs[k]) ^ rho for k in keys(inputs)) ^ (1.0 / rho)
end

function synthetic_benchmark(params = default_parameters();
    stock0 = nothing,
    calibration = default_calibration_set())
    sam = synthetic_sam(calibration)
    stock = Float64(stock0 === nothing ? calibration_stock0(calibration) : stock0)
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
    target_retirement = params.delta * stock
    eol_scale = target_retirement / sum(values(raw_eol_allocation))
    eol_allocation = Dict(use => raw_eol_allocation[use] * eol_scale for use in EOL_USES)

    return (
        stock0 = stock,
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
function profile_benchmark(profile::ProductProfile; calibration = default_calibration_set())
    params = profile_parameters(profile; base_params = default_parameters(; calibration = calibration))
    return synthetic_benchmark(params; stock0 = profile.stock0, calibration = calibration)
end

"""
    profile_experiment(label, profile; policy=zero_policy())

Create an experiment spec from a product profile.
"""
function profile_experiment(label::AbstractString,
    profile::ProductProfile;
    calibration = default_calibration_set(),
    policy::PolicyWedges = zero_policy())
    params = profile_parameters(profile; base_params = default_parameters(; calibration = calibration))
    return ExperimentSpec(label;
        calibration = calibration,
        params = params,
        policy = policy,
        benchmark = profile_benchmark(profile; calibration = calibration))
end

"""
    product_profile_grid(profiles; policy=zero_policy(), prefix="profile")

Create one experiment spec per product profile.
"""
function product_profile_grid(profiles::AbstractVector{<:ProductProfile};
    calibration = default_calibration_set(),
    policy::PolicyWedges = zero_policy(),
    prefix::AbstractString = "profile")
    return [
        profile_experiment("$(prefix):$(profile.label)", profile;
            calibration = calibration,
            policy = policy)
        for profile in profiles
    ]
end

"""
    product_parameter_grid(profile; kwargs...)

Create parameter-grid experiments anchored on one product profile.
"""
function product_parameter_grid(profile::ProductProfile;
    calibration = default_calibration_set(),
    policy::PolicyWedges = zero_policy(),
    prefix::AbstractString = "profile-grid",
    kwargs...)
    return parameter_grid(;
        calibration = calibration,
        base_params = profile_parameters(profile; base_params = default_parameters(; calibration = calibration)),
        base_benchmark = profile_benchmark(profile; calibration = calibration),
        policy = policy,
        prefix = "$(prefix):$(profile.label)",
        kwargs...)
end
