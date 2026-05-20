"""
Single-country model-local JCGE blocks.

The parameterized subsystem block keeps the decomposition explicit in the
RunSpec while avoiding a separate data container per subsystem.
"""

struct SingleCountryBlock{Kind} <: JCGECore.AbstractBlock
    name::Symbol
    params::NamedTuple
    benchmark::NamedTuple
    replicate_benchmark::Bool
    policy::PolicyWedges
    closure::Symbol
end

function _single_country_block(kind::Symbol, name::Symbol;
    params::NamedTuple,
    benchmark::NamedTuple,
    replicate_benchmark::Bool,
    policy::PolicyWedges,
    closure::Symbol)
    return SingleCountryBlock{kind}(name, params, benchmark, replicate_benchmark, policy, closure)
end

_closure_kind(block::SingleCountryBlock) = block.closure

const SINGLE_PLANNER_BLOCK_KINDS = (
    :metadata,
    :technology,
    :eol,
    :material,
    :route_service,
    :replication,
    :objective,
)

const SINGLE_FISCAL_BLOCK_KINDS = (
    :metadata,
    :technology,
    :eol,
    :material,
    :route_service,
    :replication,
    :price,
    :fiscal_income,
    :demand,
    :objective,
)

function _single_country_blocks(; params, benchmark, replicate_benchmark, policy, closure::Symbol)
    kinds = closure === :planner ? SINGLE_PLANNER_BLOCK_KINDS :
            closure === :fiscal ? SINGLE_FISCAL_BLOCK_KINDS :
            error("Unsupported single-country closure $(closure)")
    return [
        _single_country_block(kind, Symbol(:single_, kind);
            params = params,
            benchmark = benchmark,
            replicate_benchmark = replicate_benchmark,
            policy = policy,
            closure = closure)
        for kind in kinds
    ]
end

function JCGECore.build!(block::SingleCountryBlock{:metadata},
    ctx::JCGERuntime.KernelContext,
    spec::JCGECore.RunSpec)
    _register_metadata!(ctx, block)
    return nothing
end
