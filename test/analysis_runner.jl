using Test
using CSV

module AnalysisRunnerForTests
include(joinpath(@__DIR__, "..", "scenarios", "run_analysis.jl"))
end

@testset "two-country-only stage selection" begin
    @test first.(AnalysisRunnerForTests.selected_stages("two_country")) ==
        ["two_country", "two_country_analytics", "cross_model_analytics"]
    @test AnalysisRunnerForTests.selected_stages("all") == AnalysisRunnerForTests.STAGES
    @test all(path -> !startswith(path, "single_country"),
        AnalysisRunnerForTests.output_directories("two_country"))
    @test_throws ErrorException AnalysisRunnerForTests.selected_stages("unknown")
end

@testset "current outputs and checkpoint restart" begin
    mktempdir() do directory
        run(`git -C $directory init --quiet`)
        run(`git -C $directory -c user.name=Fixture -c user.email=fixture@example.invalid commit --quiet --allow-empty -m fixture`)
        write(joinpath(directory, "Project.toml"), "name = \"Fixture\"\n")
        write(joinpath(directory, "Manifest.toml"), "manifest_format = \"2.0\"\n")
        mkpath(joinpath(directory, "src"))
        mkpath(joinpath(directory, "data"))
        results = joinpath(directory, "results")
        run_dir = joinpath(results, "run")
        mkpath(run_dir)
        lock = joinpath(run_dir, "analysis.pid")
        write(lock, "active lock")
        for relative in AnalysisRunnerForTests.OUTPUT_DIRECTORIES
            mkpath(joinpath(results, relative))
            write(joinpath(results, relative, "old.csv"), "old output")
        end
        environment = AnalysisRunnerForTests.prepare_run(; root = directory)
        @test all(relative -> !ispath(joinpath(results, relative)),
            AnalysisRunnerForTests.OUTPUT_DIRECTORIES)
        @test !ispath(joinpath(results, "archive"))
        @test !haskey(environment, "archive")
        @test read(lock, String) == "active lock"
        checkpoints = joinpath(run_dir, "checkpoints")
        mkpath(checkpoints)
        checkpoint = joinpath(checkpoints, "batch.jls")
        write(checkpoint, "completed batch")
        output = joinpath(results, "two_country", "generated", "current.csv")
        mkpath(dirname(output))
        write(output, "current output")
        @test AnalysisRunnerForTests.prepare_run(; root = directory) == environment
        @test read(checkpoint, String) == "completed batch"
        @test read(output, String) == "current output"
        write(joinpath(directory, "src", "model.jl"), "# changed source\n")
        @test_throws ErrorException AnalysisRunnerForTests.prepare_run(; root = directory)
        @test isfile(checkpoint) && isfile(output)
        for relative in (joinpath("single_country", "generated"),
                         joinpath("single_country", "analytics"))
            mkpath(joinpath(results, relative))
            write(joinpath(results, relative, "current.csv"), "retained single-country output")
        end
        single_hashes = AnalysisRunnerForTests.reused_result_hashes("two_country";
            results_dir = results)
        replacement = AnalysisRunnerForTests.prepare_run(; root = directory,
            model = "two_country", restart = true)
        @test !ispath(checkpoints) && !ispath(output)
        @test read(lock, String) == "active lock"
        @test replacement["reused_result_sha256"] == single_hashes
        @test AnalysisRunnerForTests.reused_result_hashes("two_country";
            results_dir = results) == single_hashes
        @test_throws ErrorException AnalysisRunnerForTests.prepare_run(; root = directory)
        # Finish a preparation interrupted after its environment was recorded.
        AnalysisRunnerForTests.atomic_toml(joinpath(run_dir, "status.toml"),
            Dict("state" => "preparing"))
        mkpath(dirname(output))
        write(output, "incomplete replacement")
        @test AnalysisRunnerForTests.prepare_run(; root = directory,
            model = "two_country") == replacement
        @test !ispath(output)
        @test AnalysisRunnerForTests.reused_result_hashes("two_country";
            results_dir = results) == single_hashes
        @test !ispath(joinpath(results, "archive"))
    end
end

@testset "detached child stream forwarding" begin
    mktempdir() do directory
        path = joinpath(directory, "child.log")
        open(path, "w") do io
            command = `$(Base.julia_cmd()) --startup-file=no -e 'println("child stdout"); println(stderr, "child stderr")'`
            process = AnalysisRunnerForTests.start_stage(command; output = io, errors = io)
            wait(process)
            @test success(process)
        end
        content = read(path, String)
        @test occursin("child stdout", content)
        @test occursin("child stderr", content)
    end
end

@testset "complete-run result validation" begin
    mktempdir() do directory
        tables = Tuple{String,Symbol}[]
        for model in ("single_country", "two_country"), (suffix, wedge) in (
            ("tax", :tau_material_vmtl), ("refurbishment", :tau_route_ref),
            ("recycling", :tau_eol_rec),
        )
            push!(tables, (joinpath(directory, model, "generated",
                "fiscal_parameter_region_$(suffix)_results.csv"), wedge))
        end
        for (suffix, wedge) in (("linear", :tau_material_vmtl), ("recycling", :tau_eol_rec),
            ("ref", :tau_route_ref), ("rep", :tau_route_rep), ("reu", :tau_route_reu))
            push!(tables, (joinpath(directory, "single_country", "generated",
                "nested_eol_$(suffix)_results.csv"), wedge))
        end
        for (path, wedge) in tables
            mkpath(dirname(path))
            rows = [merge((
                label = "fixture-$(i)", status = i == 3 ? "LOCALLY_INFEASIBLE" : "LOCALLY_SOLVED",
                max_abs_market_residual = i == 3 ? 1.0 : 1.0e-9,
                max_abs_financial_residual = 1.0e-9,
                factor_income = 350.0, prefiscal_income = 400.0,
                eol_income = 50.0, operating_surplus = 0.0,
                sigma_routes = 2.0, sigma_metal = 2.0, sigma_eol = 2.0,
                eta_service = 1.0, metal_quality = 0.85,
                metal_intensity_ref = 0.25, metal_intensity_rep = 1 / 6,
                yield_ref = 4.0, yield_rep = 3.0, yield_reu = 1.5,
                saving_rule_m_residual = 0.0, saving_rule_c_residual = 0.0,
                consumption_income_m_residual = 0.0, consumption_income_c_residual = 0.0,
                financial_market_residual = 0.0, external_balance_residual = 0.0,
            ), NamedTuple{(wedge,)}((i == 1 ? 0.0 : 0.25,))) for i in 1:3]
            CSV.write(path, rows)
        end
        run_dir = joinpath(directory, "run")
        summary = AnalysisRunnerForTests.validate_results(;
            results_dir = directory, run_dir, main_cases = 3, nested_cases = 3)
        @test length(summary) == 11
        @test all(row -> row.attempted == 3 && row.valid == 2 && row.rejected == 1, summary)
        @test all(row -> row.valid_reference_groups == 1 && row.comparable == 2, summary)
        @test isfile(joinpath(run_dir, "validation.csv"))
        # A partial export must fail, even when its individual rows are valid.
        CSV.write(first(tables)[1], first(CSV.File(first(tables)[1]), 2))
        @test_throws ErrorException AnalysisRunnerForTests.validate_results(;
            results_dir = directory, run_dir, main_cases = 3, nested_cases = 3)
    end
end
