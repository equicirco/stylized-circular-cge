function _two_country_comparison_fields(row::NamedTuple, ref::NamedTuple)
    base = _comparison_fields(row, ref)
    delta(field::Symbol) = getproperty(row, field) - getproperty(ref, field)
    pct(field::Symbol) = _pct_change(getproperty(row, field), getproperty(ref, field))

    upstream_output_reduction_m = -delta(:virgin_metal_m)
    upstream_factor_reduction_m = -delta(:activity_factor_vmtl_m)
    circular_activity_gain_c =
        delta(:activity_rmtl_c) + delta(:activity_ref_c) +
        delta(:activity_rep_c) + delta(:activity_reu_c)
    life_extension_activity_gain_c =
        delta(:activity_ref_c) + delta(:activity_rep_c) + delta(:activity_reu_c)

    country_fields = (
        delta_bread_m = delta(:bread_m),
        delta_bread_c = delta(:bread_c),
        pct_bread_m = pct(:bread_m),
        pct_bread_c = pct(:bread_c),
        delta_virgin_metal_m = delta(:virgin_metal_m),
        delta_virgin_imports_c = delta(:virgin_imports_c),
        delta_recycled_metal_c = delta(:recycled_metal_c),
        delta_recycled_use_c = delta(:recycled_use_c),
        pct_virgin_metal_m = pct(:virgin_metal_m),
        pct_virgin_imports_c = pct(:virgin_imports_c),
        pct_recycled_metal_c = pct(:recycled_metal_c),
        pct_recycled_use_c = pct(:recycled_use_c),
        delta_activity_m_total = delta(:activity_m_total),
        delta_activity_c_total = delta(:activity_c_total),
        pct_activity_m_total = pct(:activity_m_total),
        pct_activity_c_total = pct(:activity_c_total),
        delta_activity_share_m = delta(:activity_share_m),
        delta_activity_share_c = delta(:activity_share_c),
        delta_activity_brd_m = delta(:activity_brd_m),
        delta_activity_vmtl_m = delta(:activity_vmtl_m),
        delta_activity_brd_c = delta(:activity_brd_c),
        delta_activity_rmtl_c = delta(:activity_rmtl_c),
        delta_activity_new_c = delta(:activity_new_c),
        delta_activity_ref_c = delta(:activity_ref_c),
        delta_activity_rep_c = delta(:activity_rep_c),
        delta_activity_reu_c = delta(:activity_reu_c),
        pct_activity_brd_m = pct(:activity_brd_m),
        pct_activity_vmtl_m = pct(:activity_vmtl_m),
        pct_activity_brd_c = pct(:activity_brd_c),
        pct_activity_rmtl_c = pct(:activity_rmtl_c),
        pct_activity_new_c = pct(:activity_new_c),
        pct_activity_ref_c = pct(:activity_ref_c),
        pct_activity_rep_c = pct(:activity_rep_c),
        pct_activity_reu_c = pct(:activity_reu_c),
        delta_factor_m_total = delta(:factor_m_total),
        delta_factor_c_total = delta(:factor_c_total),
        pct_factor_m_total = pct(:factor_m_total),
        pct_factor_c_total = pct(:factor_c_total),
        delta_factor_lab_m = delta(:factor_lab_m),
        delta_factor_cap_m = delta(:factor_cap_m),
        delta_factor_lab_c = delta(:factor_lab_c),
        delta_factor_cap_c = delta(:factor_cap_c),
        pct_factor_lab_m = pct(:factor_lab_m),
        pct_factor_cap_m = pct(:factor_cap_m),
        pct_factor_lab_c = pct(:factor_lab_c),
        pct_factor_cap_c = pct(:factor_cap_c),
        delta_activity_factor_brd_m = delta(:activity_factor_brd_m),
        delta_activity_factor_vmtl_m = delta(:activity_factor_vmtl_m),
        delta_activity_factor_brd_c = delta(:activity_factor_brd_c),
        delta_activity_factor_rmtl_c = delta(:activity_factor_rmtl_c),
        delta_activity_factor_new_c = delta(:activity_factor_new_c),
        delta_activity_factor_ref_c = delta(:activity_factor_ref_c),
        delta_activity_factor_rep_c = delta(:activity_factor_rep_c),
        delta_activity_factor_reu_c = delta(:activity_factor_reu_c),
        pct_activity_factor_brd_m = pct(:activity_factor_brd_m),
        pct_activity_factor_vmtl_m = pct(:activity_factor_vmtl_m),
        pct_activity_factor_brd_c = pct(:activity_factor_brd_c),
        pct_activity_factor_rmtl_c = pct(:activity_factor_rmtl_c),
        pct_activity_factor_new_c = pct(:activity_factor_new_c),
        pct_activity_factor_ref_c = pct(:activity_factor_ref_c),
        pct_activity_factor_rep_c = pct(:activity_factor_rep_c),
        pct_activity_factor_reu_c = pct(:activity_factor_reu_c),
        delta_household_income_m = delta(:household_income_m),
        delta_household_income_c = delta(:household_income_c),
        pct_household_income_m = pct(:household_income_m),
        pct_household_income_c = pct(:household_income_c),
        delta_prefiscal_income_m = delta(:prefiscal_income_m),
        delta_prefiscal_income_c = delta(:prefiscal_income_c),
        pct_prefiscal_income_m = pct(:prefiscal_income_m),
        pct_prefiscal_income_c = pct(:prefiscal_income_c),
        upstream_output_reduction_m = upstream_output_reduction_m,
        upstream_factor_reduction_m = upstream_factor_reduction_m,
        circular_activity_gain_c = circular_activity_gain_c,
        life_extension_activity_gain_c = life_extension_activity_gain_c,
        upstream_output_reduction_per_support_dollar =
            _ratio_or_nan(upstream_output_reduction_m, base.support_cost),
        upstream_factor_reduction_per_support_dollar =
            _ratio_or_nan(upstream_factor_reduction_m, base.support_cost),
        circular_activity_gain_per_support_dollar =
            _ratio_or_nan(circular_activity_gain_c, base.support_cost),
        upstream_output_reduction_per_virgin_saving =
            _ratio_or_nan(upstream_output_reduction_m, base.virgin_saving),
        upstream_factor_reduction_per_virgin_saving =
            _ratio_or_nan(upstream_factor_reduction_m, base.virgin_saving),
    )
    fields = merge(base, country_fields)
    return merge(fields, (transmission = classify_two_country_transmission(fields),))
end

"""
    compare_two_country_to_reference(records, reference)

Return two-country result rows with comparable single-country deltas plus
country-transmission deltas against `reference`.
"""
function compare_two_country_to_reference(records::AbstractVector{<:NamedTuple},
    reference::NamedTuple)
    ref = two_country_result_row(reference)
    rows = two_country_result_rows(records)
    return RuntimeExperiments.compare_to_reference(rows, ref; compare = _two_country_comparison_fields)
end

"""
    compare_two_country_to_group_reference(records, group_by; reference_filter)

Compare two-country rows to one reference row inside each parameter group.
"""
function compare_two_country_to_group_reference(records::AbstractVector{<:NamedTuple},
    group_by::AbstractVector{Symbol};
    reference_filter::Function)
    rows = two_country_result_rows(records)
    return RuntimeExperiments.compare_to_group_reference(rows, group_by;
        reference_filter = reference_filter,
        compare = _two_country_comparison_fields)
end

"""
    classify_two_country_transmission(row; tol=1e-8)

Classify the upstream resource-country channel in one two-country comparison
row. This is not relocation leakage; it summarizes transmission through the
fixed virgin-material supply relation.
"""
function classify_two_country_transmission(row::NamedTuple; tol::Real = 1.0e-8)
    if _near_zero(row.delta_virgin_metal_m, tol) &&
       _near_zero(row.delta_toaster_service, tol) &&
       _near_zero(row.circular_activity_gain_c, tol)
        return :reference
    end
    upstream_contracts = row.delta_virgin_metal_m < -tol
    upstream_expands = row.delta_virgin_metal_m > tol
    circular_expands = row.circular_activity_gain_c > tol
    service_contracts = row.delta_toaster_service < -tol

    if row.material_saving
        if upstream_contracts && circular_expands
            return :upstream_contraction_with_circular_expansion
        elseif upstream_contracts && service_contracts
            return :upstream_contraction_with_service_contraction
        elseif upstream_contracts
            return :upstream_contraction_material_saving
        end
        return :material_saving_without_upstream_contraction
    elseif upstream_expands && row.rebound
        return :upstream_expansion_with_rebound
    elseif upstream_expands
        return :upstream_expansion
    end
    return :no_upstream_change
end

function two_country_transmission_counts(rows::AbstractVector{<:NamedTuple})
    counts = Dict{Symbol,Int}()
    for row in rows
        transmission = hasproperty(row, :transmission) ?
                       row.transmission : classify_two_country_transmission(row)
        counts[transmission] = get(counts, transmission, 0) + 1
    end
    return counts
end

"""
    summarize_two_country_comparison(rows)

Return compact ranges, mechanism counts, and country-transmission counts for
two-country comparison rows.
"""
function summarize_two_country_comparison(rows::AbstractVector{<:NamedTuple})
    base = summarize_comparison(rows)
    return merge(base, (
        transmissions = two_country_transmission_counts(rows),
        pct_virgin_metal_m = _minmax([row.pct_virgin_metal_m for row in rows]),
        pct_activity_m_total = _minmax([row.pct_activity_m_total for row in rows]),
        pct_activity_c_total = _minmax([row.pct_activity_c_total for row in rows]),
        pct_factor_m_total = _minmax([row.pct_factor_m_total for row in rows]),
        pct_factor_c_total = _minmax([row.pct_factor_c_total for row in rows]),
        upstream_output_reduction_m =
            _minmax([row.upstream_output_reduction_m for row in rows]),
        upstream_factor_reduction_m =
            _minmax([row.upstream_factor_reduction_m for row in rows]),
        circular_activity_gain_c = _minmax([row.circular_activity_gain_c for row in rows]),
        upstream_output_reduction_per_support_dollar =
            _finite_minmax([row.upstream_output_reduction_per_support_dollar for row in rows]),
        upstream_factor_reduction_per_support_dollar =
            _finite_minmax([row.upstream_factor_reduction_per_support_dollar for row in rows]),
    ))
end

function two_country_summary_row(summary::NamedTuple)
    base = summary_row(summary)
    transmissions = summary.transmissions
    return merge(base, (
        transmission_reference = get(transmissions, :reference, 0),
        transmission_upstream_contraction_with_circular_expansion =
            get(transmissions, :upstream_contraction_with_circular_expansion, 0),
        transmission_upstream_contraction_with_service_contraction =
            get(transmissions, :upstream_contraction_with_service_contraction, 0),
        transmission_upstream_contraction_material_saving =
            get(transmissions, :upstream_contraction_material_saving, 0),
        transmission_material_saving_without_upstream_contraction =
            get(transmissions, :material_saving_without_upstream_contraction, 0),
        transmission_upstream_expansion_with_rebound =
            get(transmissions, :upstream_expansion_with_rebound, 0),
        transmission_upstream_expansion = get(transmissions, :upstream_expansion, 0),
        transmission_no_upstream_change = get(transmissions, :no_upstream_change, 0),
        pct_virgin_metal_m_min = summary.pct_virgin_metal_m.min,
        pct_virgin_metal_m_max = summary.pct_virgin_metal_m.max,
        pct_activity_m_total_min = summary.pct_activity_m_total.min,
        pct_activity_m_total_max = summary.pct_activity_m_total.max,
        pct_activity_c_total_min = summary.pct_activity_c_total.min,
        pct_activity_c_total_max = summary.pct_activity_c_total.max,
        pct_factor_m_total_min = summary.pct_factor_m_total.min,
        pct_factor_m_total_max = summary.pct_factor_m_total.max,
        pct_factor_c_total_min = summary.pct_factor_c_total.min,
        pct_factor_c_total_max = summary.pct_factor_c_total.max,
        upstream_output_reduction_m_min = summary.upstream_output_reduction_m.min,
        upstream_output_reduction_m_max = summary.upstream_output_reduction_m.max,
        upstream_factor_reduction_m_min = summary.upstream_factor_reduction_m.min,
        upstream_factor_reduction_m_max = summary.upstream_factor_reduction_m.max,
        circular_activity_gain_c_min = summary.circular_activity_gain_c.min,
        circular_activity_gain_c_max = summary.circular_activity_gain_c.max,
        upstream_output_reduction_per_support_dollar_min =
            summary.upstream_output_reduction_per_support_dollar.min,
        upstream_output_reduction_per_support_dollar_max =
            summary.upstream_output_reduction_per_support_dollar.max,
        upstream_factor_reduction_per_support_dollar_min =
            summary.upstream_factor_reduction_per_support_dollar.min,
        upstream_factor_reduction_per_support_dollar_max =
            summary.upstream_factor_reduction_per_support_dollar.max,
    ))
end

const TWO_COUNTRY_DISTRIBUTIONAL_ACTIVITY_SPECS = (
    (country = :M, activity = :BRD, component = :bread_m,
        delta = :delta_activity_brd_m, pct = :pct_activity_brd_m),
    (country = :M, activity = :VMTL, component = :virgin_material_m,
        delta = :delta_activity_vmtl_m, pct = :pct_activity_vmtl_m),
    (country = :C, activity = :BRD, component = :bread_c,
        delta = :delta_activity_brd_c, pct = :pct_activity_brd_c),
    (country = :C, activity = :RMTL, component = :recycled_material_c,
        delta = :delta_activity_rmtl_c, pct = :pct_activity_rmtl_c),
    (country = :C, activity = :NEW, component = :new_production_c,
        delta = :delta_activity_new_c, pct = :pct_activity_new_c),
    (country = :C, activity = :REF, component = :refurbishment_c,
        delta = :delta_activity_ref_c, pct = :pct_activity_ref_c),
    (country = :C, activity = :REP, component = :repair_c,
        delta = :delta_activity_rep_c, pct = :pct_activity_rep_c),
    (country = :C, activity = :REU, component = :reuse_c,
        delta = :delta_activity_reu_c, pct = :pct_activity_reu_c),
)

const TWO_COUNTRY_DISTRIBUTIONAL_FACTOR_SPECS = (
    (country = :M, factor = :TOTAL, activity = :TOTAL, component = :resource_country_total,
        delta = :delta_factor_m_total, pct = :pct_factor_m_total),
    (country = :M, factor = :LAB, activity = :TOTAL, component = :resource_country_labor,
        delta = :delta_factor_lab_m, pct = :pct_factor_lab_m),
    (country = :M, factor = :CAP, activity = :TOTAL, component = :resource_country_capital,
        delta = :delta_factor_cap_m, pct = :pct_factor_cap_m),
    (country = :C, factor = :TOTAL, activity = :TOTAL, component = :consuming_country_total,
        delta = :delta_factor_c_total, pct = :pct_factor_c_total),
    (country = :C, factor = :LAB, activity = :TOTAL, component = :consuming_country_labor,
        delta = :delta_factor_lab_c, pct = :pct_factor_lab_c),
    (country = :C, factor = :CAP, activity = :TOTAL, component = :consuming_country_capital,
        delta = :delta_factor_cap_c, pct = :pct_factor_cap_c),
    (country = :M, factor = :TOTAL, activity = :VMTL, component = :virgin_material_factor_m,
        delta = :delta_activity_factor_vmtl_m, pct = :pct_activity_factor_vmtl_m),
    (country = :C, factor = :TOTAL, activity = :RMTL, component = :recycling_factor_c,
        delta = :delta_activity_factor_rmtl_c, pct = :pct_activity_factor_rmtl_c),
    (country = :C, factor = :TOTAL, activity = :NEW, component = :new_production_factor_c,
        delta = :delta_activity_factor_new_c, pct = :pct_activity_factor_new_c),
    (country = :C, factor = :TOTAL, activity = :REF, component = :refurbishment_factor_c,
        delta = :delta_activity_factor_ref_c, pct = :pct_activity_factor_ref_c),
    (country = :C, factor = :TOTAL, activity = :REP, component = :repair_factor_c,
        delta = :delta_activity_factor_rep_c, pct = :pct_activity_factor_rep_c),
    (country = :C, factor = :TOTAL, activity = :REU, component = :reuse_factor_c,
        delta = :delta_activity_factor_reu_c, pct = :pct_activity_factor_reu_c),
)

function two_country_distributional_activity_summary(rows::AbstractVector;
    group_by::AbstractVector{Symbol} = [:transmission])
    out = NamedTuple[]
    for key in _distributional_group_keys(rows, group_by)
        subset = _distributional_subset(rows, key, group_by)
        prefix = _distributional_prefix(key, group_by)
        for spec in TWO_COUNTRY_DISTRIBUTIONAL_ACTIVITY_SPECS
            push!(out, merge(prefix, (
                dimension = :country_activity_output,
                country = spec.country,
                activity = spec.activity,
                component = spec.component,
                count = length(subset),
                mean_delta_output = _finite_mean(_field_values(subset, spec.delta)),
                mean_pct_output = _finite_mean(_field_values(subset, spec.pct)),
                expansion_share = _signed_share(subset, spec.delta, :positive),
                contraction_share = _signed_share(subset, spec.delta, :negative),
            )))
        end
    end
    return out
end

function two_country_distributional_factor_summary(rows::AbstractVector;
    group_by::AbstractVector{Symbol} = [:transmission])
    out = NamedTuple[]
    for key in _distributional_group_keys(rows, group_by)
        subset = _distributional_subset(rows, key, group_by)
        prefix = _distributional_prefix(key, group_by)
        for spec in TWO_COUNTRY_DISTRIBUTIONAL_FACTOR_SPECS
            push!(out, merge(prefix, (
                dimension = :country_factor_use,
                country = spec.country,
                factor = spec.factor,
                activity = spec.activity,
                component = spec.component,
                count = length(subset),
                mean_delta_factor_use = _finite_mean(_field_values(subset, spec.delta)),
                mean_pct_factor_use = _finite_mean(_field_values(subset, spec.pct)),
                expansion_share = _signed_share(subset, spec.delta, :positive),
                contraction_share = _signed_share(subset, spec.delta, :negative),
            )))
        end
    end
    return out
end
