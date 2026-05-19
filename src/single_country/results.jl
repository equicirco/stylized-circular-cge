"""
    result_row(record)

Flatten one experiment result into a scalar NamedTuple suitable for printing,
filtering, or later export.
"""
function result_row(record::NamedTuple)
    ind = record.indicators
    return (
        label = record.label,
        closure = record.closure,
        status = record.status,
        stock0 = record.benchmark.stock0,
        delta = record.params.delta,
        sigma_routes = record.params.sigma_routes,
        sigma_metal = record.params.sigma_metal,
        sigma_eol = record.params.sigma_eol,
        eta_service = record.params.eta_service,
        metal_quality = record.params.metal_quality,
        yield_ref = record.params.yield.ref,
        yield_rep = record.params.yield.rep,
        yield_reu = record.params.yield.reu,
        yield_rmtl = record.params.yield.rmtl,
        metal_intensity_new = record.params.metal_intensity.new,
        metal_intensity_ref = record.params.metal_intensity.ref,
        metal_intensity_rep = record.params.metal_intensity.rep,
        metal_intensity_reu = record.params.metal_intensity.reu,
        tau_route_new = record.policy.route[:NEW],
        tau_route_ref = record.policy.route[:REF],
        tau_route_rep = record.policy.route[:REP],
        tau_route_reu = record.policy.route[:REU],
        tau_material_vmtl = record.policy.material[:VMTL],
        tau_material_rmtl = record.policy.material[:RMTL],
        tau_eol_ref = record.policy.eol[:REF],
        tau_eol_rep = record.policy.eol[:REP],
        tau_eol_reu = record.policy.eol[:REU],
        tau_eol_rec = record.policy.eol[:REC],
        tau_eol_inc = record.policy.eol[:INC],
        bread = ind.bread,
        toaster_service = ind.toaster_service,
        virgin_use = ind.virgin_use,
        recycled_use = ind.recycled_use,
        route_new = ind.route_quantity[:NEW],
        route_ref = ind.route_quantity[:REF],
        route_rep = ind.route_quantity[:REP],
        route_reu = ind.route_quantity[:REU],
        eol_ref = ind.eol_quantity[:REF],
        eol_rep = ind.eol_quantity[:REP],
        eol_reu = ind.eol_quantity[:REU],
        eol_rec = ind.eol_quantity[:REC],
        eol_inc = ind.eol_quantity[:INC],
        virgin_use_new = ind.virgin_use_by_route[:NEW],
        virgin_use_ref = ind.virgin_use_by_route[:REF],
        virgin_use_rep = ind.virgin_use_by_route[:REP],
        recycled_use_new = ind.recycled_use_by_route[:NEW],
        recycled_use_ref = ind.recycled_use_by_route[:REF],
        recycled_use_rep = ind.recycled_use_by_route[:REP],
        route_new_share = ind.route_share[:NEW],
        route_ref_share = ind.route_share[:REF],
        route_rep_share = ind.route_share[:REP],
        route_reu_share = ind.route_share[:REU],
        eol_ref_share = ind.eol_share[:REF],
        eol_rep_share = ind.eol_share[:REP],
        eol_reu_share = ind.eol_share[:REU],
        eol_rec_share = ind.eol_share[:REC],
        eol_inc_share = ind.eol_share[:INC],
        wedge_net = ind.wedge_accounting.net,
        wedge_penalties = ind.wedge_accounting.penalties,
        wedge_support = ind.wedge_accounting.support,
        price_bread = ind.prices.bread,
        price_toaster_service = ind.prices.toaster_service,
        price_route_new = ind.prices.route[:NEW],
        price_route_ref = ind.prices.route[:REF],
        price_route_rep = ind.prices.route[:REP],
        price_route_reu = ind.prices.route[:REU],
        price_material_vmtl = ind.prices.material[:VMTL],
        price_material_rmtl = ind.prices.material[:RMTL],
        price_eol_ref = ind.prices.eol[:REF],
        price_eol_rep = ind.prices.eol[:REP],
        price_eol_reu = ind.prices.eol[:REU],
        price_eol_rec = ind.prices.eol[:REC],
        price_eol_inc = ind.prices.eol[:INC],
        household_income = ind.fiscal.household_income,
        prefiscal_income = ind.fiscal.prefiscal_income,
        government_net = ind.fiscal.government_net,
        government_revenue = ind.fiscal.government_revenue,
        government_subsidy = ind.fiscal.government_subsidy,
        government_transfer = ind.fiscal.government_transfer,
        max_abs_market_residual = ind.closed_economy.max_abs_market_residual,
        max_positive_capacity_slack = ind.closed_economy.max_positive_capacity_slack,
        max_factor_slack = ind.closed_economy.max_factor_slack,
        material_balance_vmtl = ind.closed_economy.material_balance[:VMTL],
        material_balance_rmtl = ind.closed_economy.material_balance[:RMTL],
        eol_balance = ind.closed_economy.eol_balance,
        household_budget_residual = ind.closed_economy.household_budget,
        government_budget_residual = ind.closed_economy.government_budget,
        route_capacity_ref = ind.closed_economy.route_capacity_slack[:REF],
        route_capacity_rep = ind.closed_economy.route_capacity_slack[:REP],
        route_capacity_reu = ind.closed_economy.route_capacity_slack[:REU],
        recycling_capacity_slack = ind.closed_economy.recycling_capacity_slack,
        utility_log = ind.utility_log,
    )
end

"""
    result_rows(records)

Flatten many experiment records into scalar rows.
"""
result_rows(records::AbstractVector{<:NamedTuple}) = [result_row(record) for record in records]

"""
    closed_economy_failures(records; market_tol=1e-5)

Return fiscal experiment rows that should not be used as closed-economy results.
A row fails if it is not locally solved or if any market-accounting residual is
larger than `market_tol`.
"""
function closed_economy_failures(records::AbstractVector{<:NamedTuple};
    market_tol::Real = 1.0e-5)
    return RuntimeExperiments.closure_failures(result_rows(records);
        closure = :fiscal,
        status = JuMP.MOI.LOCALLY_SOLVED,
        residual_field = :max_abs_market_residual,
        residual_tol = market_tol)
end

"""
    assert_closed_economy_results(records; market_tol=1e-5)

Validate a fiscal experiment batch and return `records` unchanged. Throws an
error listing the first failing rows when the batch contains non-solved or
non-closing results.
"""
function assert_closed_economy_results(records::AbstractVector{<:NamedTuple};
    market_tol::Real = 1.0e-5)
    RuntimeExperiments.assert_closure(result_rows(records);
        closure = :fiscal,
        status = JuMP.MOI.LOCALLY_SOLVED,
        residual_field = :max_abs_market_residual,
        residual_tol = market_tol,
        describe = row ->
            "$(row.label): status=$(row.status), max_abs_market_residual=$(row.max_abs_market_residual)")
    return records
end
