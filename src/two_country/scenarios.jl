"""
    two_country_experiment(label; params, policy, benchmark)

Create one experiment specification for the two-country extension. It uses the
same `ExperimentSpec` container as the single-country model, but calibrates the
benchmark with `two_country_benchmark`.
"""
function two_country_experiment(label::AbstractString;
    params = default_parameters(),
    policy::PolicyWedges = zero_policy(),
    benchmark = two_country_benchmark(params))
    return ExperimentSpec(label; params = params, policy = policy, benchmark = benchmark)
end

"""
    two_country_parameter_grid(; kwargs...)

Create two-country experiment specs from the same parameter-grid syntax used by
`parameter_grid`.
"""
function two_country_parameter_grid(; base_params = default_parameters(),
    base_benchmark = two_country_benchmark(base_params),
    policy::PolicyWedges = zero_policy(),
    prefix::AbstractString = "two_country_grid",
    kwargs...)
    stock0 = base_benchmark.stock0
    return RuntimeExperiments.parameter_grid(; prefix = prefix, kwargs...) do label, a
        params = _set_parameters(base_params, a)
        ExperimentSpec(label;
            params = params,
            policy = policy,
            benchmark = two_country_benchmark(params; stock0 = stock0))
    end
end

"""
    two_country_policy_grid(kind, target, taus; params, base_policy)

Create two-country experiments that vary one comparable policy wedge.
"""
function two_country_policy_grid(kind::Symbol, target::Symbol, taus;
    params = default_parameters(),
    benchmark = two_country_benchmark(params),
    base_policy::PolicyWedges = zero_policy(),
    prefix::AbstractString = "two_country_policy")
    return RuntimeExperiments.policy_grid(kind, target, taus; prefix = prefix) do label, k, t, tau
        ExperimentSpec(label;
            params = params,
            policy = with_wedge(base_policy, k, t, tau),
            benchmark = benchmark)
    end
end

"""
    two_country_parameter_policy_grid(; policy_kind, policy_target, tau, kwargs...)

Create two-country experiments for all parameter and one-policy combinations.
"""
function two_country_parameter_policy_grid(; policy_kind::Symbol,
    policy_target::Symbol,
    tau,
    base_params = default_parameters(),
    base_benchmark = two_country_benchmark(base_params),
    base_policy::PolicyWedges = zero_policy(),
    prefix::AbstractString = "two_country_grid",
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
            benchmark = two_country_benchmark(params; stock0 = stock0))
    end
end

"""
    run_two_country_experiment(spec)

Solve one two-country fiscal experiment and return metadata plus indicators.
"""
function run_two_country_experiment(spec::ExperimentSpec; closure::Symbol = :two_country_fiscal, kwargs...)
    closure in (:two_country_fiscal, :fiscal, :decentralized) ||
        error("Unknown two-country experiment closure $(closure). Use :two_country_fiscal.")
    run_spec = two_country_fiscal_baseline(params = spec.params,
        benchmark = spec.benchmark,
        policy = spec.policy)
    result = solve(run_spec; kwargs...)
    out = two_country_indicators(result)
    return (
        label = spec.label,
        closure = :two_country_fiscal,
        params = _parameter_summary(spec.params),
        benchmark = _benchmark_summary(spec.benchmark),
        policy = _policy_summary(spec.policy),
        status = JuMP.termination_status(result.context.model),
        indicators = out,
    )
end

"""
    run_two_country_grid(specs)

Run a vector of two-country experiment specs.
"""
run_two_country_grid(specs::AbstractVector{ExperimentSpec}; kwargs...) =
    RuntimeExperiments.run_grid(specs; runner = run_two_country_experiment, kwargs...)
