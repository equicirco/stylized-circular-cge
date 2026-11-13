using Test
using CSV

module AnalysisRunnerForTests
include(joinpath(@__DIR__, "..", "scenarios", "run_analysis.jl"))
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
