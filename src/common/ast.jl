"""
Model-local helpers for registering and composing JCGE equation AST objects.
"""

function _global_var(base::Symbol, idxs::Symbol...)
    isempty(idxs) && return base
    return Symbol(string(base), "_", join(string.(idxs), "_"))
end

function _ensure_var!(ctx::JCGERuntime.KernelContext, name::Symbol; lower=1.0e-6, start=nothing)
    haskey(ctx.variables, name) && return ctx.variables[name]
    model = ctx.model
    if model isa JuMP.Model
        if lower === nothing
            var = start === nothing ?
                  JuMP.@variable(model, base_name = string(name)) :
                  JuMP.@variable(model, start = start, base_name = string(name))
        else
            var = start === nothing ?
                  JuMP.@variable(model, lower_bound = lower, base_name = string(name)) :
                  JuMP.@variable(model, lower_bound = lower, start = start, base_name = string(name))
        end
    else
        var = (name = name,)
    end
    return JCGERuntime.register_variable!(ctx, name, var)
end

function _register_ast_equation!(ctx::JCGERuntime.KernelContext, block,
    tag::Symbol, expr::JCGECore.EquationExpr; info::String, indices=(), index_names=nothing)
    JCGERuntime.register_equation!(ctx;
        tag = tag,
        block = block.name,
        payload = (
            indices = indices,
            index_names = index_names,
            params = block.params,
            info = info,
            expr = expr,
            constraint = nothing,
        ))
    return nothing
end

function _register_ast_objective!(ctx::JCGERuntime.KernelContext, block,
    expr::JCGECore.EquationExpr; info::String, indices=(), index_names=nothing, sense::Symbol=:Max)
    JCGERuntime.register_equation!(ctx;
        tag = :objective,
        block = block.name,
        payload = (
            indices = indices,
            index_names = index_names,
            params = block.params,
            info = info,
            objective_expr = expr,
            objective_sense = sense,
            constraint = nothing,
        ))
    return nothing
end

function _register_metadata!(ctx::JCGERuntime.KernelContext, block)
    JCGERuntime.register_equation!(ctx;
        tag = :metadata,
        block = block.name,
        payload = (
            indices = (),
            params = block.params,
            benchmark = block.benchmark,
            policy = block.policy,
            closure = _closure_kind(block),
            info = "circular one-period metadata",
            constraint = nothing,
        ))
    return nothing
end

_evar(base::Symbol, idxs...) = JCGECore.EVar(base, Any[idxs...])
_eidx(name::Symbol) = JCGECore.EIndex(name)
_econst(x::Real) = JCGECore.EConst(Float64(x))
_eadd(terms...) = JCGECore.EAdd(JCGECore.EquationExpr[terms...])
_emul(terms...) = JCGECore.EMul(JCGECore.EquationExpr[terms...])
_epow(base, exponent) = JCGECore.EPow(base, exponent)
_ediv(numerator, denominator) = JCGECore.EDiv(numerator, denominator)
_eneg(expr) = JCGECore.ENeg(expr)
_elog(expr) = JCGECore.ELog(expr)
_eeq(lhs, rhs) = JCGECore.EEq(lhs, rhs)
_ele(lhs, rhs) = JCGECore.ELe(lhs, rhs)
_ege(lhs, rhs) = JCGECore.EGe(lhs, rhs)

function _sum_expr(terms)
    isempty(terms) && return _econst(0.0)
    length(terms) == 1 && return only(terms)
    return JCGECore.EAdd(JCGECore.EquationExpr[terms...])
end

function _prod_expr(terms)
    isempty(terms) && return _econst(1.0)
    length(terms) == 1 && return only(terms)
    return JCGECore.EMul(JCGECore.EquationExpr[terms...])
end

_esum(index::Symbol, domain, expr) = JCGECore.ESum(index, collect(Symbol, domain), expr)
_eprod(index::Symbol, domain, expr) = JCGECore.EProd(index, collect(Symbol, domain), expr)
_scaled(coeff::Real, expr) = _emul(_econst(coeff), expr)
