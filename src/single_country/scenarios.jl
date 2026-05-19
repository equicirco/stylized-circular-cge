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
