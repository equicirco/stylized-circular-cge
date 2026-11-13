using CSV
using Dates
using FileWatching
using TOML

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

function finish_preparation()
    # The complete snapshot exists before clearing the old working outputs.
    # Clearing them prevents conditional exports from leaving stale CSVs.
    for relative in OUTPUT_DIRECTORIES
        directory = joinpath(RESULTS, relative)
        ispath(directory) && rm(directory; recursive = true)
    end
    atomic_toml(STATUS_PATH, Dict("state" => "prepared", "completed_stages" => String[],
        "updated_at" => string(now(UTC))))
end

function prepare_run()
    fingerprint = source_fingerprint(ROOT)
    if isfile(ENVIRONMENT_PATH)
        environment = TOML.parsefile(ENVIRONMENT_PATH)
        environment["source_fingerprint"] == fingerprint ||
            error("Sources or dependencies differ from this run; archive results/run before starting a new run")
        if !isfile(STATUS_PATH) || TOML.parsefile(STATUS_PATH)["state"] == "preparing"
            finish_preparation()
        end
        return environment
    end

    archive = joinpath(RESULTS, "archive")
    ispath(archive) && error("results/archive already exists; refusing to overwrite the previous results")
    temporary = joinpath(RESULTS, "archive.tmp")
    ispath(temporary) && error("An incomplete results/archive.tmp exists; inspect it before restarting")
    mkpath(temporary)
    for relative in OUTPUT_DIRECTORIES
        source = joinpath(RESULTS, relative)
        if isdir(source)
            destination = joinpath(temporary, relative)
            mkpath(dirname(destination))
            cp(source, destination)
        end
    end
    mv(temporary, archive)
    mkpath(RUN_DIR)
    cp(joinpath(ROOT, "Project.toml"), joinpath(RUN_DIR, "Project.toml"))
    cp(joinpath(ROOT, "Manifest.toml"), joinpath(RUN_DIR, "Manifest.toml"))
    environment = Dict(
        "source_fingerprint" => fingerprint,
        "source_commit" => readchomp(`git -C $ROOT rev-parse HEAD`),
        "working_tree_at_start" => readchomp(`git -C $ROOT status --porcelain`),
        "julia_version" => string(VERSION), "created_at" => string(now(UTC)),
        "main_grid" => "full", "nested_grid" => "route",
        "archive" => archive,
    )
    atomic_toml(ENVIRONMENT_PATH, environment)
    atomic_toml(STATUS_PATH, Dict("state" => "preparing", "completed_stages" => String[],
        "updated_at" => string(now(UTC))))
    finish_preparation()
    println("Preserved previous results in $(archive)")
    println("Recorded source and dependency environment in $(RUN_DIR)")
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
        rows = CSV.File(table.path; select = required)
        all(field -> field in propertynames(rows), required) ||
            error("Missing income or validation fields in $(table.path)")
        length(rows) == table.expected || error("Incomplete result table $(table.path)")
        length(Set(row.label for row in rows)) == length(rows) ||
            error("Duplicate experiment labels in $(table.path)")
        valid(row) = string(row.status) == "LOCALLY_SOLVED" &&
            isfinite(row.max_abs_market_residual) && row.max_abs_market_residual <= 1.0e-5 &&
            isfinite(row.max_abs_financial_residual) && row.max_abs_financial_residual <= 1.0e-5
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

function run_stages(environment, workers)
    state = TOML.parsefile(STATUS_PATH)
    completed = String.(get(state, "completed_stages", String[]))
    state["pid"] = getpid()
    state["workers"] = workers
    state["execution_commit"] = readchomp(`git -C $ROOT rev-parse HEAD`)
    state["state"] = "running"
    atomic_toml(STATUS_PATH, state)
    try
        for (name, relative) in STAGES
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
            process = run(addenv(command,
                "OPENBLAS_NUM_THREADS" => "1", "OMP_NUM_THREADS" => "1",
                "JULIA_NUM_THREADS" => "1", "JCGE_EXPERIMENT_WORKERS" => string(workers),
                "JCGE_REGION_GRID" => "full", "JCGE_NESTED_EOL_GRID" => "route",
                "JCGE_CHECKPOINT_ROOT" => joinpath(RUN_DIR, "checkpoints"),
                "JCGE_CHECKPOINT_BATCH_SIZE" => "64",
                "JCGE_RUN_FINGERPRINT" => environment["source_fingerprint"]); wait = false)
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
        println("Usage: julia --project=. scenarios/run_analysis.jl [--workers N] [--prepare-only]")
        println("Runs the full paper designs and existing analytics; rerunning resumes saved batches.")
        println("Previous results: results/archive/. Logs/status/checkpoints: results/run/.")
        return
    end
    workers = 8
    prepare_only = false
    index = 1
    while index <= length(args)
        if args[index] == "--workers"
            index += 1
            index <= length(args) || error("--workers requires an integer")
            workers = parse(Int, args[index])
        elseif args[index] == "--prepare-only"
            prepare_only = true
        else
            error("Unknown argument $(args[index])")
        end
        index += 1
    end
    workers > 0 || error("Worker count must be positive")
    mkpath(RUN_DIR)
    FileWatching.Pidfile.mkpidlock(joinpath(RUN_DIR, "analysis.pid"); wait = false) do
        environment = prepare_run()
        prepare_only || run_stages(environment, workers)
    end
    return nothing
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    main(ARGS)
end
