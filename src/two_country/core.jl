const TWO_COUNTRIES = (:M, :C)
const TWO_COUNTRY_PRODUCTION_ACTIVITIES =
    (:BRD_M, :VMTL_M, :BRD_C, :RMTL_C, :NEW_C, :REF_C, :REP_C, :REU_C)
const TWO_COUNTRY_FACTORS = (:LAB_M, :CAP_M, :LAB_C, :CAP_C)
const TWO_COUNTRY_ACCOUNTS = (
    :BRD_M, :VMTL_M, :LAB_M, :CAP_M, :HOH_M,
    :BRD_C, :RMTL_C, :NEW_C, :REF_C, :REP_C, :REU_C, :TST_C, :EOL_C,
    :LAB_C, :CAP_C, :HOH_C,
    :NFA,
)

const TWO_COUNTRY_AGGREGATION = Dict{Symbol,Union{Nothing,Symbol}}(
    :BRD_M => :BRD,
    :VMTL_M => :VMTL,
    :LAB_M => :LAB,
    :CAP_M => :CAP,
    :HOH_M => :HOH,
    :BRD_C => :BRD,
    :RMTL_C => :RMTL,
    :NEW_C => :NEW,
    :REF_C => :REF,
    :REP_C => :REP,
    :REU_C => :REU,
    :TST_C => :TST,
    :EOL_C => :EOL,
    :LAB_C => :LAB,
    :CAP_C => :CAP,
    :HOH_C => :HOH,
    :NFA => nothing,
)

"""
    two_country_sam()

Return the initial two-country accounting scaffold. A cell `(row, column)` is a
payment from the column account to the row account.

The split encodes the first leakage structure:
- country `M` produces local bread and all virgin metal;
- country `C` produces local bread, recycled material, toaster routes, toaster
  services, and EOL allocation;
- country `C` imports virgin metal from `M`;
- `NFA` balances the benchmark current-account counterpart of the virgin-metal
  export income.
"""
function two_country_sam()
    values = Dict{Tuple{Symbol,Symbol},Float64}(
        (row, col) => 0.0 for row in TWO_COUNTRY_ACCOUNTS for col in TWO_COUNTRY_ACCOUNTS
    )

    values[(:BRD_M, :HOH_M)] = 25.0
    values[(:BRD_C, :HOH_C)] = 175.0
    values[(:TST_C, :HOH_C)] = 200.0

    values[(:NEW_C, :TST_C)] = 100.0
    values[(:REF_C, :TST_C)] = 40.0
    values[(:REP_C, :TST_C)] = 30.0
    values[(:REU_C, :TST_C)] = 30.0

    values[(:VMTL_M, :NEW_C)] = 30.0
    values[(:VMTL_M, :REF_C)] = 6.0
    values[(:VMTL_M, :REP_C)] = 4.0

    values[(:RMTL_C, :NEW_C)] = 10.0
    values[(:RMTL_C, :REF_C)] = 4.0
    values[(:RMTL_C, :REP_C)] = 1.0

    values[(:EOL_C, :RMTL_C)] = 10.0
    values[(:EOL_C, :REF_C)] = 10.0
    values[(:EOL_C, :REP_C)] = 10.0
    values[(:EOL_C, :REU_C)] = 20.0

    values[(:LAB_M, :BRD_M)] = 15.0
    values[(:CAP_M, :BRD_M)] = 10.0
    values[(:LAB_M, :VMTL_M)] = 10.0
    values[(:CAP_M, :VMTL_M)] = 30.0

    values[(:LAB_C, :BRD_C)] = 108.0
    values[(:CAP_C, :BRD_C)] = 67.0
    values[(:LAB_C, :RMTL_C)] = 3.0
    values[(:CAP_C, :RMTL_C)] = 2.0
    values[(:LAB_C, :NEW_C)] = 30.0
    values[(:CAP_C, :NEW_C)] = 30.0
    values[(:LAB_C, :REF_C)] = 15.0
    values[(:CAP_C, :REF_C)] = 5.0
    values[(:LAB_C, :REP_C)] = 12.0
    values[(:CAP_C, :REP_C)] = 3.0
    values[(:LAB_C, :REU_C)] = 7.0
    values[(:CAP_C, :REU_C)] = 3.0

    values[(:HOH_M, :LAB_M)] = 25.0
    values[(:HOH_M, :CAP_M)] = 40.0
    values[(:NFA, :HOH_M)] = 40.0

    values[(:HOH_C, :LAB_C)] = 175.0
    values[(:HOH_C, :CAP_C)] = 110.0
    values[(:HOH_C, :EOL_C)] = 50.0
    values[(:HOH_C, :NFA)] = 40.0

    return (accounts = TWO_COUNTRY_ACCOUNTS, values = values)
end

"""
    two_country_sam_balance(sam=two_country_sam())

Return row sums, column sums, balances, and maximum absolute imbalance for a
two-country SAM.
"""
function two_country_sam_balance(sam = two_country_sam())
    row_sums = Dict(account => sum(sam.values[(account, col)] for col in sam.accounts)
        for account in sam.accounts)
    column_sums = Dict(account => sum(sam.values[(row, account)] for row in sam.accounts)
        for account in sam.accounts)
    balances = Dict(account => row_sums[account] - column_sums[account]
        for account in sam.accounts)
    max_abs_imbalance = maximum(abs, values(balances))
    return (
        row_sums = row_sums,
        column_sums = column_sums,
        balances = balances,
        max_abs_imbalance = max_abs_imbalance,
    )
end

"""
    aggregate_two_country_sam(sam=two_country_sam())

Aggregate the two-country SAM back to the single-country account set. The
financial-balancing account `NFA` is omitted from the real aggregate accounts.
"""
function aggregate_two_country_sam(sam = two_country_sam())
    values = Dict{Tuple{Symbol,Symbol},Float64}(
        (row, col) => 0.0 for row in SAM_ACCOUNTS for col in SAM_ACCOUNTS
    )
    for row in sam.accounts, col in sam.accounts
        mapped_row = TWO_COUNTRY_AGGREGATION[row]
        mapped_col = TWO_COUNTRY_AGGREGATION[col]
        (mapped_row === nothing || mapped_col === nothing) && continue
        values[(mapped_row, mapped_col)] += sam.values[(row, col)]
    end
    return (accounts = SAM_ACCOUNTS, values = values)
end

function _two_country_route_activity(route::Symbol)
    route === :NEW && return :NEW_C
    route === :REF && return :REF_C
    route === :REP && return :REP_C
    route === :REU && return :REU_C
    error("Unknown route $(route)")
end

function _two_country_activity_factors(activity::Symbol)
    activity in (:BRD_M, :VMTL_M) && return (:LAB_M, :CAP_M)
    activity in (:BRD_C, :RMTL_C, :NEW_C, :REF_C, :REP_C, :REU_C) &&
        return (:LAB_C, :CAP_C)
    error("Unknown two-country activity $(activity)")
end

function _two_country_country(activity::Symbol)
    activity in (:BRD_M, :VMTL_M) && return :M
    activity in (:BRD_C, :RMTL_C, :NEW_C, :REF_C, :REP_C, :REU_C, :TST_C, :EOL_C) &&
        return :C
    error("Unknown two-country activity $(activity)")
end

"""
    two_country_benchmark(params=default_parameters(); stock0=200)

Return the calibrated benchmark used by the executable two-country extension.
It preserves the same round-number technology and circular-economy quantities as
the single-country benchmark while assigning activities to countries.
"""
function two_country_benchmark(params = default_parameters(); stock0::Real = 200.0)
    sam = two_country_sam()
    sam_values = sam.values
    output = Dict(a => sum(sam_values[(a, col)] for col in sam.accounts)
        for a in (TWO_COUNTRY_PRODUCTION_ACTIVITIES..., :TST_C))
    factor_endowment = Dict(h => sum(sam_values[(h, col)] for col in sam.accounts)
        for h in TWO_COUNTRY_FACTORS)
    factor_input = Dict((h, a) => sam_values[(h, a)]
        for h in TWO_COUNTRY_FACTORS for a in TWO_COUNTRY_PRODUCTION_ACTIVITIES)
    material_input = Dict((m, route) =>
            sam_values[(m === :VMTL ? :VMTL_M : :RMTL_C, _two_country_route_activity(route))]
        for m in MATERIALS for route in MATERIAL_ROUTES)

    factor_share = Dict{Tuple{Symbol,Symbol},Float64}()
    for a in TWO_COUNTRY_PRODUCTION_ACTIVITIES
        local_factors = _two_country_activity_factors(a)
        total_factor = sum(factor_input[(h, a)] for h in local_factors)
        for h in local_factors
            factor_share[(h, a)] = factor_input[(h, a)] / total_factor
        end
    end
    productivity = Dict(a =>
            begin
                local_factors = _two_country_activity_factors(a)
                output[a] / prod(factor_input[(h, a)] ^ factor_share[(h, a)]
                    for h in local_factors)
            end
        for a in TWO_COUNTRY_PRODUCTION_ACTIVITIES)

    final_demand = Dict(
        :BRD_M => sam_values[(:BRD_M, :HOH_M)],
        :BRD_C => sam_values[(:BRD_C, :HOH_C)],
        :TST_C => sam_values[(:TST_C, :HOH_C)],
    )
    total_final_demand = sum(values(final_demand))
    route_demand = Dict(route => sam_values[(_two_country_route_activity(route), :TST_C)]
        for route in ROUTES)
    total_route_demand = sum(values(route_demand))
    material_demand = Dict(m => sum(material_input[(m, route)] for route in MATERIAL_ROUTES)
        for m in MATERIALS)
    total_material_demand = sum(values(material_demand))

    route_metal_share = Dict{Tuple{Symbol,Symbol},Float64}()
    metal_scale = Dict{Symbol,Float64}()
    for route in MATERIAL_ROUTES
        total = sum(material_input[(m, route)] for m in MATERIALS)
        route_inputs = Dict(m => material_input[(m, route)] for m in MATERIALS)
        route_shares = Dict(m => route_inputs[m] / total for m in MATERIALS)
        for m in MATERIALS
            route_metal_share[(m, route)] = route_shares[m]
        end
        quality = Dict(:VMTL => 1.0, :RMTL => params.metal_quality)
        unscaled = _ces_quantity(route_inputs, route_shares, params.sigma_metal; quality = quality)
        metal_scale[route] =
            (_metal_intensity(params, route) * output[_two_country_route_activity(route)]) / unscaled
    end

    route_inputs = Dict(route => route_demand[route] for route in ROUTES)
    route_shares = Dict(route => route_demand[route] / total_route_demand for route in ROUTES)
    route_scale = output[:TST_C] / _ces_quantity(route_inputs, route_shares, params.sigma_routes)

    raw_eol_allocation = Dict(
        :REF => sam_values[(:EOL_C, :REF_C)],
        :REP => sam_values[(:EOL_C, :REP_C)],
        :REU => sam_values[(:EOL_C, :REU_C)],
        :REC => sam_values[(:EOL_C, :RMTL_C)],
        :INC => 0.0,
    )
    target_retirement = params.delta * Float64(stock0)
    eol_scale = target_retirement / sum(values(raw_eol_allocation))
    eol_allocation = Dict(use => raw_eol_allocation[use] * eol_scale for use in EOL_USES)
    nfa_transfer = sam_values[(:HOH_C, :NFA)]

    return (
        stock0 = Float64(stock0),
        output = output,
        factor_endowment = factor_endowment,
        factor_input = factor_input,
        material_input = material_input,
        productivity = productivity,
        factor_share = factor_share,
        utility_share = Dict(g => final_demand[g] / total_final_demand for g in keys(final_demand)),
        route_share = route_shares,
        metal_share = Dict(m => material_demand[m] / total_material_demand for m in MATERIALS),
        route_metal_share = route_metal_share,
        metal_scale = metal_scale,
        route_scale = route_scale,
        eol_allocation = eol_allocation,
        nfa_transfer = nfa_transfer,
        prefiscal_income_m = factor_endowment[:LAB_M] + factor_endowment[:CAP_M],
        disposable_income_m =
            factor_endowment[:LAB_M] + factor_endowment[:CAP_M] - nfa_transfer,
        prefiscal_income_c =
            factor_endowment[:LAB_C] + factor_endowment[:CAP_C] +
            target_retirement + nfa_transfer,
    )
end
