"""
Two-country model-local JCGE blocks.
"""

struct TwoCountryBlock{Kind} <: JCGECore.AbstractBlock
    name::Symbol
    params::NamedTuple
    benchmark::NamedTuple
    replicate_benchmark::Bool
    policy::PolicyWedges
    closure::Symbol
end

function _two_country_block(kind::Symbol, name::Symbol;
    params::NamedTuple,
    benchmark::NamedTuple,
    replicate_benchmark::Bool,
    policy::PolicyWedges,
    closure::Symbol)
    return TwoCountryBlock{kind}(name, params, benchmark, replicate_benchmark, policy, closure)
end

_closure_kind(block::TwoCountryBlock) = block.closure

const TWO_COUNTRY_FISCAL_BLOCK_KINDS = (
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

function _two_country_blocks(; params, benchmark, replicate_benchmark, policy,
    closure::Symbol = :two_country_fiscal)
    closure === :two_country_fiscal ||
        error("Unsupported two-country closure $(closure)")
    return [
        _two_country_block(kind, Symbol(:two_country_, kind);
            params = params,
            benchmark = benchmark,
            replicate_benchmark = replicate_benchmark,
            policy = policy,
            closure = closure)
        for kind in TWO_COUNTRY_FISCAL_BLOCK_KINDS
    ]
end

function JCGECore.build!(block::TwoCountryBlock{:metadata},
    ctx::JCGERuntime.KernelContext,
    spec::JCGECore.RunSpec)
    _register_metadata!(ctx, block)
    return nothing
end
