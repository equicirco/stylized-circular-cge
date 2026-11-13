using Test
using StylizedCircularCGE
using JuMP
using TOML

include(joinpath(@__DIR__, "..", "scenarios", "common", "checkpointed_execution.jl"))
using .ScenarioExecution

@testset "checkpoint execution and interrupted-run recovery" begin
    mktempdir() do directory
        specs = [(label = "case-$(i)",) for i in 1:5]
        calls = Vector{String}[]
        fail = Ref(true)
        executor = function (batch; kwargs...)
            labels = [s.label for s in batch]
            push!(calls, labels)
            fail[] && first(labels) == "case-3" && error("simulated interrupted batch")
            return [(label = s.label, value = length(s.label)) for s in batch]
        end
        @test_throws ErrorException checkpointed_grid(specs; executor,
            key = "recovery", checkpoint_root = directory, batch_size = 2, fingerprint = "test")
        @test isfile(joinpath(directory, "recovery", "batch_000001.jls"))
        @test !isfile(joinpath(directory, "recovery", "batch_000002.jls"))
        @test TOML.parsefile(joinpath(directory, "recovery", "progress.toml"))["state"] == "failed"
        fail[] = false
        empty!(calls)
        results = checkpointed_grid(specs; executor,
            key = "recovery", checkpoint_root = directory, batch_size = 2, fingerprint = "test")
        @test [r.label for r in results] == [s.label for s in specs]
        @test calls == [["case-3", "case-4"], ["case-5"]]
        empty!(calls)
        @test checkpointed_grid(specs; executor, key = "recovery",
            checkpoint_root = directory, batch_size = 2, fingerprint = "test") == results
        @test isempty(calls)
        @test_throws ErrorException checkpointed_grid(specs; executor, key = "recovery",
            checkpoint_root = directory, batch_size = 2, fingerprint = "different-model")
        @test_throws ErrorException checkpointed_grid(reverse(specs); executor, key = "recovery",
            checkpoint_root = directory, batch_size = 2, fingerprint = "test")
        @test_throws ErrorException checkpointed_grid([specs[1], specs[1]]; executor,
            key = "duplicate", checkpoint_root = directory, fingerprint = "test")
    end
end

@testset "real distributed model checkpoints" begin
    mktempdir() do directory
        for two_country in (false, true)
            factory = two_country ? two_country_policy_grid : policy_grid
            executor = two_country ? run_two_country_grid : run_grid
            specs = factory(:material, :VMTL, [0.0, 0.25])
            kwargs = two_country ? (;) : (; closure = :fiscal)
            key = two_country ? "two_country" : "single_country"
            results = checkpointed_grid(specs; executor, key,
                checkpoint_root = directory, batch_size = 1,
                execution = :distributed, workers = 2,
                worker_modules = [:StylizedCircularCGE], kwargs...)
            @test length(results) == 2
            @test all(r -> r.status == JuMP.MOI.LOCALLY_SOLVED, results)
            @test all(r -> r.indicators.closed_economy.max_abs_market_residual <= 1.0e-5, results)
            @test all(r -> r.indicators.closed_economy.max_abs_financial_residual <= 1.0e-5, results)
            # A complete resume must not invoke an executor or a solver again.
            resumed = checkpointed_grid(specs; executor = _ -> error("unexpected solve"), key,
                checkpoint_root = directory, batch_size = 1, kwargs...)
            @test isequal(resumed, results)
            @test TOML.parsefile(joinpath(directory, key, "progress.toml"))["completed"] == 2
        end
    end
end
