"""
Model-local payment accounts for the fiscal closures. Factor quantities are
valued at their fixed calibration remuneration of one. Operating surpluses (or
losses) accrue to the household owning each domestic production activity.
"""
function _income_payment!(payments, payer, payee, kind, amount)
    push!(payments, (; payer, payee, kind, amount))
    return nothing
end

function _income_payments_sum(payments; payer = nothing, payee = nothing, kind = nothing)
    return _sum_expr([p.amount for p in payments
        if (payer === nothing || p.payer === payer) &&
           (payee === nothing || p.payee === payee) &&
           (kind === nothing || p.kind === kind)])
end

function _income_account_net(payments, account)
    return _eadd(_income_payments_sum(payments; payee = account),
        _eneg(_income_payments_sum(payments; payer = account)))
end

function _household_payment_accounts(bench, policy; two_country::Bool = false)
    payments = NamedTuple[]
    household = two_country ? :HOH_C : :HOH
    government = two_country ? :GOV_C : :GOV
    toaster = two_country ? :TST_C : :TST
    virgin = two_country ? :VMTL_M : :VMTL
    recycled = two_country ? :RMTL_C : :RMTL
    incineration = two_country ? :INC_C : :INC
    eol_base = two_country ? :EOL_C : :EOL
    material_base = two_country ? :P_MAT_C : :P_MAT
    eol_price_base = two_country ? :P_EOL_C : :P_EOL
    route_price_base = two_country ? :P_ROUTE_C : :P_ROUTE
    activities = two_country ? TWO_COUNTRY_PRODUCTION_ACTIVITIES : PRODUCTION_ACTIVITIES
    route_activity = r -> two_country ? _two_country_route_activity(r) : r
    owners = Dict(a => (two_country && a in (:BRD_M, :VMTL_M) ? :HOH_M : household)
        for a in (activities..., toaster, incineration))

    for activity in activities
        factors = two_country ? _two_country_activity_factors(activity) : FACTORS
        for factor in factors
            _income_payment!(payments, activity, owners[activity], :factor,
                _evar(:F, factor, activity))
        end
    end

    bread_activities = two_country ? (:BRD_M, :BRD_C) : (:BRD,)
    for bread in bread_activities
        price = two_country ? (bread === :BRD_M ? :P_BRD_M : :P_BRD_C) : :P_BRD
        _income_payment!(payments, owners[bread], bread, :consumption,
            _emul(_evar(price), _evar(:Z, bread)))
    end
    service_price = two_country ? :P_TST_C : :P_TST
    _income_payment!(payments, household, toaster, :consumption,
        _emul(_evar(service_price), _evar(:Z, toaster)))

    for route in ROUTES
        activity = route_activity(route)
        _income_payment!(payments, toaster, activity, :intermediate,
            _emul(_evar(route_price_base, route), _evar(:Z, activity)))
        _income_payment!(payments, activity, government, :policy,
            _scaled(policy.route[route], _evar(:Z, activity)))
    end

    for route in MATERIAL_ROUTES, material in MATERIALS
        supplier = material === :VMTL ? virgin : recycled
        quantity = if material === :VMTL
            two_country ? _evar(:VUSE, route, :M, :C) : _evar(:VUSE, route)
        else
            two_country ? _evar(:RUSE, route, :C) : _evar(:RUSE, route)
        end
        wedge = policy.material[material]
        # Purchasers pay the gross material price. The supplier receives the
        # amount net of the input wedge, including for imports taxed in C.
        _income_payment!(payments, route_activity(route), supplier, :intermediate,
            _emul(_eadd(_evar(material_base, material), _econst(-wedge)), quantity))
        _income_payment!(payments, route_activity(route), government, :policy,
            _scaled(wedge, quantity))
    end

    for use in EOL_USES
        payer = use === :REC ? recycled : use === :INC ? incineration : route_activity(use)
        quantity = _evar(eol_base, use)
        # End-of-life owners receive the price net of the EOL policy wedge;
        # the government receives that wedge on the full allocated flow.
        _income_payment!(payments, payer, household, :eol,
            _emul(_eadd(_evar(eol_price_base, use), _econst(-policy.eol[use])), quantity))
        _income_payment!(payments, payer, government, :policy,
            _scaled(policy.eol[use], quantity))
    end

    surplus = Dict(a => _income_account_net(payments, a) for a in keys(owners))
    for activity in sort!(collect(keys(owners)))
        _income_payment!(payments, activity, owners[activity], :surplus, surplus[activity])
    end

    if two_country
        _income_payment!(payments, :HOH_M, :NFA, :financial, _econst(bench.nfa_transfer))
        _income_payment!(payments, :NFA, :HOH_C, :financial, _econst(bench.nfa_transfer))
    end
    transfer = two_country ? :GOV_TRANSFER_C : :GOV_TRANSFER
    _income_payment!(payments, government, household, :fiscal_transfer, _evar(transfer))

    households = two_country ? (:HOH_M, :HOH_C) : (:HOH,)
    components = Dict(h => (
        factor = _income_payments_sum(payments; payee = h, kind = :factor),
        eol = _income_payments_sum(payments; payee = h, kind = :eol),
        surplus = _income_payments_sum(payments; payee = h, kind = :surplus),
        financial_inflow = _income_payments_sum(payments; payee = h, kind = :financial),
        financial_outflow = _income_payments_sum(payments; payer = h, kind = :financial),
    ) for h in households)
    prefiscal = Dict(h => _eadd(c.factor, c.eol, c.surplus, c.financial_inflow)
        for (h, c) in components)
    return (; payments, components, prefiscal, surplus)
end

_income_value(expr::JCGECore.EConst, result) = expr.value
_income_value(expr::JCGECore.EVar, result) =
    _solved_value(result, _global_var(expr.name, expr.idxs...))
_income_value(expr::JCGECore.EAdd, result) = sum(_income_value(t, result) for t in expr.terms)
_income_value(expr::JCGECore.EMul, result) = prod(_income_value(t, result) for t in expr.factors)
_income_value(expr::JCGECore.ENeg, result) = -_income_value(expr.expr, result)

function _household_income_accounting(result; two_country::Bool = false)
    metadata = two_country ? _two_country_run_metadata(result) : _run_metadata(result)
    accounts = _household_payment_accounts(metadata.benchmark, metadata.policy; two_country)
    components = Dict(h => (
        factor_income = _income_value(c.factor, result),
        eol_income = _income_value(c.eol, result),
        operating_surplus = _income_value(c.surplus, result),
        financial_inflow = _income_value(c.financial_inflow, result),
        financial_outflow = _income_value(c.financial_outflow, result),
    ) for (h, c) in accounts.components)
    payments = [(; p.payer, p.payee, p.kind, amount = _income_value(p.amount, result))
        for p in accounts.payments]
    balances = Dict{Symbol,Float64}()
    for p in payments
        balances[p.payer] = get(balances, p.payer, 0.0) - p.amount
        balances[p.payee] = get(balances, p.payee, 0.0) + p.amount
    end
    prefiscal_balance = Dict(h => begin
        variable = h === :HOH_M ? :Y_PREFISCAL_M : h === :HOH_C ? :Y_PREFISCAL_C : :Y_PREFISCAL
        _solved_value(result, variable) -
            (c.factor_income + c.eol_income + c.operating_surplus + c.financial_inflow)
    end for (h, c) in components)
    surplus = Dict(a => _income_value(expr, result) for (a, expr) in accounts.surplus)
    return (; components, payments, account_balance = balances, prefiscal_balance,
        operating_surplus = surplus,
        max_abs_account_residual = maximum(abs, values(balances)))
end
