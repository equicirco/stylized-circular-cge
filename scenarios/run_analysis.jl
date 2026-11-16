using CSV
using Dates
using FileWatching
using TOML
using SHA

include(joinpath(@__DIR__, "common", "checkpointed_execution.jl"))
using .ScenarioExecution

const ROOT = normpath(joinpath(@__DIR__, ".."))
const RESULTS = joinpath(ROOT, "results")
const RUN_DIR = joinpath(RESULTS, "run")
const ENVIRONMENT_PATH = joinpath(RUN_DIR, "environment.toml")
const STATUS_PATH = joinpath(RUN_DIR, "status.toml")
const OUTPUT_DIRECTORIES = (
    joinpath("single_country", "generated"), joinpath("single_country", "analytics"),
    joinpath("two_country", "generated"), joinpath("two_country", "analytics"),
    joinpath("cross_model", "analytics"),
)
const STAGES = [
    "single_country" => "scenarios/single_country/run_fiscal_parameter_regions.jl",
    "two_country" => "scenarios/two_country/run_fiscal_parameter_regions.jl",
    "nested_routes" => "scenarios/single_country/run_nested_eol_policy_regions.jl",
    "single_country_analytics" => "analytics/single_country/analyze_policy_regions.jl",
    "nested_routes_analytics" => "analytics/single_country/analyze_nested_eol_policy_regions.jl",
    "two_country_analytics" => "analytics/two_country/analyze_policy_regions.jl",
    "cross_model_analytics" => "analytics/cross_model/compare_single_two_country.jl",
]

function output_directories(model)
    model == "all" && return OUTPUT_DIRECTORIES
    model == "two_country" && return filter(path -> startswith(path, "two_country") ||
        startswith(path, "cross_model"), OUTPUT_DIRECTORIES)
    error("Unknown model selection $(model); use all or two_country")
end

function selected_stages(model)
    output_directories(model) # Validate the selection before doing any work.
    model == "all" && return STAGES
    return filter(stage -> first(stage) in
        ("two_country", "two_country_analytics", "cross_model_analytics"), STAGES)
end

function reused_result_hashes(model; results_dir = RESULTS)
    hashes = Dict{String,String}()
    model == "all" && return hashes
    for (directory, _, files) in walkdir(joinpath(results_dir, "single_country"))
        for name in files
            path = joinpath(directory, name)
            hashes[relpath(path, results_dir)] = bytes2hex(sha256(read(path)))
        end
    end
    isempty(hashes) && error("A two-country-only run requires existing single-country results")
    return hashes
end

function finish_preparation(environment; results_dir = RESULTS)
    # Clearing selected outputs prevents conditional exports from leaving stale CSVs.
    for relative in output_directories(get(environment, "model", "all"))
        directory = joinpath(results_dir, relative)
        ispath(directory) && rm(directory; recursive = true)
    end
    atomic_toml(joinpath(results_dir, "run", "status.toml"), Dict("state" => "prepared", "completed_stages" => String[],
        "updated_at" => string(now(UTC))))
end

function prepare_run(; model = "all", restart = false, root = ROOT)
    output_directories(model)
    results_dir = joinpath(root, "results")
    run_dir = joinpath(results_dir, "run")
    environment_path = joinpath(run_dir, "environment.toml")
    status_path = joinpath(run_dir, "status.toml")
    fingerprint = source_fingerprint(root)
    if isfile(environment_path) && !restart
        environment = TOML.parsefile(environment_path)
        if environment["source_fingerprint"] == fingerprint && get(environment, "model", "all") == model
            if !isfile(status_path) || TOML.parsefile(status_path)["state"] == "preparing"
                finish_preparation(environment; results_dir)
            end
            return environment
        end
        error("Sources or selection differ; use --restart to replace the current run")
    end

    reused = reused_result_hashes(model; results_dir)
    mkpath(run_dir)
    # Replace the current execution record and checkpoints; retain the PID lock.
    for source in readdir(run_dir; join = true)
        basename(source) == "analysis.pid" && continue
        rm(source; recursive = true)
    end
    cp(joinpath(root, "Project.toml"), joinpath(run_dir, "Project.toml"))
    cp(joinpath(root, "Manifest.toml"), joinpath(run_dir, "Manifest.toml"))
    environment = Dict(
        "source_fingerprint" => fingerprint,
        "source_commit" => readchomp(`git -C $root rev-parse HEAD`),
        "working_tree_at_start" => readchomp(`git -C $root status --porcelain`),
        "julia_version" => string(VERSION), "created_at" => string(now(UTC)),
        "main_grid" => "full", "nested_grid" => "route",
        "model" => model,
        "reused_result_sha256" => reused,
    )
    atomic_toml(environment_path, environment)
    atomic_toml(status_path, Dict("state" => "preparing", "completed_stages" => String[],
        "updated_at" => string(now(UTC))))
    finish_preparation(environment; results_dir)
    println("Recorded source and dependency environment in $(run_dir)")
    flush(stdout)
    return environment
end

function validate_results(; results_dir = RESULTS, run_dir = RUN_DIR,
    main_cases = 2187 * 4, nested_cases = 1024 * 4)
    main_fields = [:sigma_routes, :sigma_metal, :sigma_eol, :eta_service,
        :metal_quality, :metal_intensity_ref, :yield_ref]
    nested_fields = [:sigma_routes, :sigma_metal, :sigma_eol, :eta_service,
        :metal_quality, :metal_intensity_ref, :metal_intensity_rep,
        :yield_ref, :yield_rep, :yield_reu]
    tables = NamedTuple[]
    for model in ("single_country", "two_country")
        for (strategy, suffix, wedge) in (
            ("tax", "tax", :tau_material_vmtl),
            ("refurbishment", "refurbishment", :tau_route_ref),
            ("recycling", "recycling", :tau_eol_rec),
        )
            push!(tables, (; model, strategy, expected = main_cases, fields = main_fields, wedge,
                path = joinpath(results_dir, model, "generated", "fiscal_parameter_region_$(suffix)_results.csv")))
        end
    end
    for (strategy, suffix, wedge) in (
        ("tax", "linear", :tau_material_vmtl), ("recycling", "recycling", :tau_eol_rec),
        ("refurbishment", "ref", :tau_route_ref), ("repair", "rep", :tau_route_rep),
        ("reuse", "reu", :tau_route_reu),
    )
        push!(tables, (; model = "nested_routes", strategy, expected = nested_cases,
            fields = nested_fields, wedge,
            path = joinpath(results_dir, "single_country", "generated", "nested_eol_$(suffix)_results.csv")))
    end

    summary = NamedTuple[]
    for table in tables
        isfile(table.path) || error("Missing result table $(table.path)")
        required = unique(vcat([:label, :status, :max_abs_market_residual,
            :max_abs_financial_residual, :factor_income, :prefiscal_income,
            :eol_income, :operating_surplus, table.wedge], table.fields))
        financing_residuals = table.model == "two_country" ?
            [:saving_rule_m_residual, :saving_rule_c_residual,
             :consumption_income_m_residual, :consumption_income_c_residual,
             :financial_market_residual, :external_balance_residual] : Symbol[]
        append!(required, financing_residuals)
        rows = CSV.File(table.path; select = required)
        all(field -> field in propertynames(rows), required) ||
            error("Missing income or validation fields in $(table.path)")
        length(rows) == table.expected || error("Incomplete result table $(table.path)")
        length(Set(row.label for row in rows)) == length(rows) ||
            error("Duplicate experiment labels in $(table.path)")
        valid(row) = string(row.status) == "LOCALLY_SOLVED" &&
            isfinite(row.max_abs_market_residual) && row.max_abs_market_residual <= 1.0e-5 &&
            isfinite(row.max_abs_financial_residual) && row.max_abs_financial_residual <= 1.0e-5 &&
            all(field -> isfinite(getproperty(row, field)) &&
                abs(getproperty(row, field)) <= 1.0e-5, financing_residuals)
        key(row) = Tuple(getproperty(row, field) for field in table.fields)
        references = Set(key(row) for row in rows if valid(row) && getproperty(row, table.wedge) == 0.0)
        accepted = [row for row in rows if valid(row)]
        comparable = count(row -> key(row) in references, accepted)
        push!(summary, (
            model = table.model, strategy = table.strategy, attempted = length(rows),
            valid = length(accepted), rejected = length(rows) - length(accepted),
            valid_reference_groups = length(references), comparable = comparable,
            max_accepted_market_residual = isempty(accepted) ? NaN :
                maximum(row.max_abs_market_residual for row in accepted),
            max_accepted_financial_residual = isempty(accepted) ? NaN :
                maximum(row.max_abs_financial_residual for row in accepted),
        ))
    end
    total = sum(row.attempted for row in summary)
    total == 6 * main_cases + 5 * nested_cases || error("Unexpected total experiment count")
    ScenarioExecution.atomic_write(joinpath(run_dir, "validation.csv")) do io
        CSV.write(io, summary)
    end
    println("Verified $(total) recorded solves; validity and reference coverage are in $(joinpath(run_dir, "validation.csv"))")
    flush(stdout)
    return summary
end

function start_stage(command; output = stdout, errors = stderr)
    # run(...; wait=false) otherwise defaults child streams to devnull.
    return run(pipeline(command; stdin = devnull, stdout = output, stderr = errors); wait = false)
end

function run_stages(environment, workers)
    state = TOML.parsefile(STATUS_PATH)
    completed = String.(get(state, "completed_stages", String[]))
    state["pid"] = getpid()
    state["workers"] = workers
    state["execution_commit"] = readchomp(`git -C $ROOT rev-parse HEAD`)
    state["state"] = "running"
    atomic_toml(STATUS_PATH, state)
    try
        for (name, relative) in selected_stages(get(environment, "model", "all"))
            name in completed && continue
            source_fingerprint(ROOT) == environment["source_fingerprint"] ||
                error("Sources or dependencies changed during the run")
            state["current_stage"] = name
            state["updated_at"] = string(now(UTC))
            atomic_toml(STATUS_PATH, state)
            println("[$(now(UTC))] Starting $(name)")
            flush(stdout)
            script = joinpath(ROOT, relative)
            command = `$(Base.julia_cmd()) --project=$ROOT --threads=1 $script`
            process = start_stage(addenv(command,
                "OPENBLAS_NUM_THREADS" => "1", "OMP_NUM_THREADS" => "1",
                "JULIA_NUM_THREADS" => "1", "JCGE_EXPERIMENT_WORKERS" => string(workers),
                "JCGE_REGION_GRID" => "full", "JCGE_NESTED_EOL_GRID" => "route",
                "JCGE_CHECKPOINT_ROOT" => joinpath(RUN_DIR, "checkpoints"),
                "JCGE_CHECKPOINT_BATCH_SIZE" => "64",
                "JCGE_RUN_FINGERPRINT" => environment["source_fingerprint"]))
            state["child_pid"] = getpid(process)
            atomic_toml(STATUS_PATH, state)
            wait(process)
            success(process) || error("Stage $(name) exited with code $(process.exitcode)")
            push!(completed, name)
            state["completed_stages"] = completed
            state["updated_at"] = string(now(UTC))
            atomic_toml(STATUS_PATH, state)
        end
        source_fingerprint(ROOT) == environment["source_fingerprint"] ||
            error("Sources or dependencies changed before verification")
        for (relative, expected) in get(environment, "reused_result_sha256", Dict())
            bytes2hex(sha256(read(joinpath(RESULTS, relative)))) == expected ||
                error("An unchanged single-country result was modified: $(relative)")
        end
        validate_results()
        state["state"] = "completed"
        state["updated_at"] = string(now(UTC))
        atomic_toml(STATUS_PATH, state)
    catch err
        state["state"] = "failed"
        state["error"] = sprint(showerror, err)
        state["updated_at"] = string(now(UTC))
        atomic_toml(STATUS_PATH, state)
        rethrow()
    end
    return nothing
end

function main(args)
    if "--help" in args
        println("Usage: julia --project=. scenarios/run_analysis.jl [--workers N] [--model all|two_country] [--restart] [--prepare-only]")
        println("Runs the full paper designs and existing analytics; rerunning resumes saved batches.")
        println("--restart replaces current outputs and checkpoints. Logs/status/checkpoints: results/run/.")
        return
    end
    workers = 8
    prepare_only = false
    model = "all"
    restart = false
    index = 1
    while index <= length(args)
        if args[index] == "--workers"
            index += 1
            index <= length(args) || error("--workers requires an integer")
            workers = parse(Int, args[index])
        elseif args[index] == "--prepare-only"
            prepare_only = true
        elseif args[index] == "--model"
            index += 1
            index <= length(args) || error("--model requires all or two_country")
            model = args[index]
        elseif args[index] == "--restart"
            restart = true
        else
            error("Unknown argument $(args[index])")
        end
        index += 1
    end
    workers > 0 || error("Worker count must be positive")
    mkpath(RUN_DIR)
    FileWatching.Pidfile.mkpidlock(joinpath(RUN_DIR, "analysis.pid"); wait = false) do
        environment = prepare_run(; model, restart)
        prepare_only || run_stages(environment, workers)
    end
    return nothing
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    main(ARGS)
end
