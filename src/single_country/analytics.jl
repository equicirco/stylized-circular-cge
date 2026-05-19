function _pct_change(value, reference)
    abs(reference) <= 1.0e-12 && return NaN
    return (value - reference) / abs(reference)
end

function _ratio_or_nan(numerator, denominator; tol::Real = 1.0e-12)
    abs(Float64(denominator)) <= tol && return NaN
    return Float64(numerator) / Float64(denominator)
end

function _comparison_fields(row::NamedTuple, ref::NamedTuple)
    delta_toaster_service = row.toaster_service - ref.toaster_service
    delta_virgin_use = row.virgin_use - ref.virgin_use
    delta_recycled_use = row.recycled_use - ref.recycled_use
    delta_government_net = row.government_net - ref.government_net
    delta_government_revenue = row.government_revenue - ref.government_revenue
    delta_government_subsidy = row.government_subsidy - ref.government_subsidy
    support_cost = max(delta_government_subsidy, 0.0)
    fiscal_cost = max(-delta_government_net, 0.0)
    revenue_gain = max(delta_government_revenue, 0.0)
    virgin_saving = -delta_virgin_use
    service_loss = max(-delta_toaster_service, 0.0)

    fields = (
        reference_label = ref.label,
        delta_toaster_service = delta_toaster_service,
        delta_virgin_use = delta_virgin_use,
        delta_recycled_use = delta_recycled_use,
        delta_route_new = row.route_new - ref.route_new,
        delta_route_ref = row.route_ref - ref.route_ref,
        delta_route_rep = row.route_rep - ref.route_rep,
        delta_route_reu = row.route_reu - ref.route_reu,
        delta_eol_ref = row.eol_ref - ref.eol_ref,
        delta_eol_rep = row.eol_rep - ref.eol_rep,
        delta_eol_reu = row.eol_reu - ref.eol_reu,
        delta_eol_rec = row.eol_rec - ref.eol_rec,
        delta_eol_inc = row.eol_inc - ref.eol_inc,
        delta_virgin_use_new = row.virgin_use_new - ref.virgin_use_new,
        delta_virgin_use_ref = row.virgin_use_ref - ref.virgin_use_ref,
        delta_virgin_use_rep = row.virgin_use_rep - ref.virgin_use_rep,
        delta_recycled_use_new = row.recycled_use_new - ref.recycled_use_new,
        delta_recycled_use_ref = row.recycled_use_ref - ref.recycled_use_ref,
        delta_recycled_use_rep = row.recycled_use_rep - ref.recycled_use_rep,
        delta_ref_share = row.route_ref_share - ref.route_ref_share,
        delta_rec_share = row.eol_rec_share - ref.eol_rec_share,
        pct_toaster_service = _pct_change(row.toaster_service, ref.toaster_service),
        pct_virgin_use = _pct_change(row.virgin_use, ref.virgin_use),
        pct_recycled_use = _pct_change(row.recycled_use, ref.recycled_use),
        delta_government_net = delta_government_net,
        delta_government_revenue = delta_government_revenue,
        delta_government_subsidy = delta_government_subsidy,
        support_cost = support_cost,
        fiscal_cost = fiscal_cost,
        revenue_gain = revenue_gain,
        virgin_saving = virgin_saving,
        service_loss = service_loss,
        virgin_saving_per_support_dollar = _ratio_or_nan(virgin_saving, support_cost),
        virgin_saving_per_fiscal_cost_dollar = _ratio_or_nan(virgin_saving, fiscal_cost),
        virgin_saving_per_revenue_dollar = _ratio_or_nan(virgin_saving, revenue_gain),
        service_change_per_support_dollar = _ratio_or_nan(delta_toaster_service, support_cost),
        service_loss_per_support_dollar = _ratio_or_nan(service_loss, support_cost),
        recycled_use_gain_per_support_dollar = _ratio_or_nan(delta_recycled_use, support_cost),
        material_saving = row.virgin_use < ref.virgin_use - 1.0e-8,
        rebound = row.toaster_service > ref.toaster_service + 1.0e-8,
    )
    return merge(fields, (mechanism = classify_mechanism(fields),))
end

"""
    compare_to_reference(records, reference)

Return flattened rows with absolute and relative changes against `reference`.
"""
function compare_to_reference(records::AbstractVector{<:NamedTuple}, reference::NamedTuple)
    ref = result_row(reference)
    rows = result_rows(records)
    return RuntimeExperiments.compare_to_reference(rows, ref; compare = _comparison_fields)
end

"""
    compare_to_group_reference(records, group_by; reference_filter)

Flatten experiment records and compare each row to the reference row in its own
group. The `reference_filter` function must identify exactly one reference row
inside each group, for example the zero-policy row of a policy sweep.
"""
function compare_to_group_reference(records::AbstractVector{<:NamedTuple},
    group_by::AbstractVector{Symbol};
    reference_filter::Function)
    rows = result_rows(records)
    return RuntimeExperiments.compare_to_group_reference(rows, group_by;
        reference_filter = reference_filter,
        compare = _comparison_fields)
end

"""
    classify_regime(row)

Classify one comparison row into a compact circular-strategy regime.
"""
function classify_regime(row::NamedTuple)
    hasproperty(row, :material_saving) || error("classify_regime expects rows from compare_to_reference")
    if row.material_saving && !row.rebound
        return :material_saving_without_rebound
    elseif row.material_saving && row.rebound
        return :material_saving_with_rebound
    elseif !row.material_saving && row.rebound
        return :rebound_without_material_saving
    end
    return :no_material_saving_no_rebound
end

"""
    regime_counts(rows)

Count comparison rows by circular-strategy regime.
"""
function regime_counts(rows::AbstractVector{<:NamedTuple})
    counts = Dict{Symbol,Int}()
    for row in rows
        regime = classify_regime(row)
        counts[regime] = get(counts, regime, 0) + 1
    end
    return counts
end

function _near_zero(value::Real, tol::Real)
    return abs(Float64(value)) <= tol
end

"""
    classify_mechanism(row; tol=1e-8)

Classify the dominant equilibrium channel in one comparison row. The labels are
diagnostic: they summarize route, EOL, material-use, and service-demand deltas
without replacing those underlying fields.
"""
function classify_mechanism(row::NamedTuple; tol::Real = 1.0e-8)
    hasproperty(row, :material_saving) || error("classify_mechanism expects comparison rows")
    hasproperty(row, :delta_route_new) || error("classify_mechanism expects decomposition deltas")

    d_service = row.delta_toaster_service
    d_virgin = row.delta_virgin_use
    d_new = row.delta_route_new
    d_ref = row.delta_route_ref
    d_rep = row.delta_route_rep
    d_reu = row.delta_route_reu
    d_eol_ref = row.delta_eol_ref

    if _near_zero(d_virgin, tol) && _near_zero(d_service, tol) &&
       _near_zero(d_new, tol) && _near_zero(d_ref, tol) &&
       _near_zero(d_rep, tol) && _near_zero(d_reu, tol)
        return :reference
    end

    service_contracts = d_service < -tol
    new_contracts = d_new < -tol
    ref_expands = d_ref > tol
    eol_ref_expands = d_eol_ref > tol
    circular_routes_contract = d_ref <= tol && d_rep <= tol && d_reu <= tol

    if row.material_saving
        if row.rebound
            if new_contracts && (ref_expands || eol_ref_expands)
                return :circular_substitution_with_rebound
            end
            return :rebound_material_saving
        elseif service_contracts && new_contracts && circular_routes_contract && !eol_ref_expands
            return :demand_contraction_material_saving
        elseif new_contracts && ref_expands
            return :refurbishment_substitution_material_saving
        elseif new_contracts && eol_ref_expands
            return :eol_reallocation_material_saving
        elseif service_contracts
            return :service_contraction_material_saving
        end
        return :mixed_material_saving
    end

    if row.rebound
        return :rebound_without_material_saving
    elseif d_virgin > tol && (ref_expands || eol_ref_expands)
        return :circular_expansion_material_increase
    elseif d_virgin > tol && service_contracts
        return :service_contraction_material_increase
    elseif service_contracts
        return :service_contraction_without_material_saving
    end
    return :no_material_saving
end

"""
    mechanism_counts(rows)

Count comparison rows by `classify_mechanism`.
"""
function mechanism_counts(rows::AbstractVector{<:NamedTuple})
    counts = Dict{Symbol,Int}()
    for row in rows
        mechanism = hasproperty(row, :mechanism) ? row.mechanism : classify_mechanism(row)
        counts[mechanism] = get(counts, mechanism, 0) + 1
    end
    return counts
end

"""
    frontier_rows(rows; group_by, select_by, predicate, sense=:min)

Return one selected row per group after filtering with `predicate`. This is a
generic helper for numerical threshold searches.
"""
function frontier_rows(rows::AbstractVector{<:NamedTuple};
    group_by::AbstractVector{Symbol} = Symbol[],
    select_by::Symbol,
    predicate::Function = row -> true,
    sense::Symbol = :min)
    return RuntimeExperiments.frontier_rows(rows;
        group_by = group_by,
        select_by = select_by,
        predicate = predicate,
        sense = sense)
end

"""
    material_saving_frontier(rows, policy_field; group_by, allow_rebound=false)

Return the smallest policy magnitude in each group that reduces virgin-material
use. By default, rows with rebound in toaster-service output are excluded.
"""
function material_saving_frontier(rows::AbstractVector{<:NamedTuple},
    policy_field::Symbol;
    group_by::AbstractVector{Symbol} = Symbol[],
    allow_rebound::Bool = false,
    sense::Symbol = :absolute_min)
    return frontier_rows(rows;
        group_by = group_by,
        select_by = policy_field,
        predicate = row -> row.material_saving && (allow_rebound || !row.rebound),
        sense = sense)
end

function _frontier_key(row::NamedTuple, group_by::AbstractVector{Symbol})
    return Tuple(getproperty(row, field) for field in group_by)
end

function _frontier_lookup(rows::AbstractVector{<:NamedTuple},
    group_by::AbstractVector{Symbol})
    lookup = Dict{Tuple,NamedTuple}()
    for row in rows
        key = _frontier_key(row, group_by)
        haskey(lookup, key) && error("Duplicate frontier row for group $(key)")
        lookup[key] = row
    end
    return lookup
end

_maybe_field(row::Nothing, field::Symbol) = NaN
_maybe_field(row::NamedTuple, field::Symbol) =
    hasproperty(row, field) ? Float64(getproperty(row, field)) : NaN

function _choose_strategy(left::Union{Nothing,NamedTuple},
    right::Union{Nothing,NamedTuple},
    field::Symbol,
    left_label::Symbol,
    right_label::Symbol;
    sense::Symbol)
    left === nothing && right === nothing && return :none
    left === nothing && return right_label
    right === nothing && return left_label
    left_value = getproperty(left, field)
    right_value = getproperty(right, field)
    isapprox(left_value, right_value; atol = 1.0e-12, rtol = 1.0e-12) && return :tie
    if sense === :min
        return left_value < right_value ? left_label : right_label
    elseif sense === :max
        return left_value > right_value ? left_label : right_label
    end
    error("Unknown comparison sense $(sense). Use :min or :max.")
end

function _choose_strategy_finite(left::Union{Nothing,NamedTuple},
    right::Union{Nothing,NamedTuple},
    field::Symbol,
    left_label::Symbol,
    right_label::Symbol;
    sense::Symbol)
    candidates = [
        (left_label, _maybe_field(left, field)),
        (right_label, _maybe_field(right, field)),
    ]
    finite = [(label, value) for (label, value) in candidates if isfinite(value)]
    isempty(finite) && return :none
    values = [value for (_, value) in finite]
    best = sense === :min ? minimum(values) :
           sense === :max ? maximum(values) :
           error("Unknown comparison sense $(sense). Use :min or :max.")
    winners = [label for (label, value) in finite if isapprox(value, best;
        atol = 1.0e-12, rtol = 1.0e-12)]
    return length(winners) == 1 ? only(winners) : :tie
end

"""
    compare_frontiers(left_rows, right_rows; group_by, left_label, right_label,
        left_policy, right_policy)

Pair two threshold frontiers by `group_by` fields and return compact comparison
rows. This is useful when two policy instruments are computed separately but
need to be compared on the same parameter grid.
"""
function compare_frontiers(left_rows::AbstractVector{<:NamedTuple},
    right_rows::AbstractVector{<:NamedTuple};
    group_by::AbstractVector{Symbol},
    left_label::Symbol = :left,
    right_label::Symbol = :right,
    left_policy::Symbol,
    right_policy::Symbol)
    left = _frontier_lookup(left_rows, group_by)
    right = _frontier_lookup(right_rows, group_by)
    keys_all = sort(collect(union(keys(left), keys(right))); by = string)
    return [
        merge(
            NamedTuple{Tuple(group_by)}(key),
            begin
                left_row = get(left, key, nothing)
                right_row = get(right, key, nothing)
                (
                    left_strategy = left_label,
                    right_strategy = right_label,
                    left_available = left_row !== nothing,
                    right_available = right_row !== nothing,
                    left_policy_value = _maybe_field(left_row, left_policy),
                    right_policy_value = _maybe_field(right_row, right_policy),
                    left_policy_magnitude = abs(_maybe_field(left_row, left_policy)),
                    right_policy_magnitude = abs(_maybe_field(right_row, right_policy)),
                    left_pct_virgin_use = _maybe_field(left_row, :pct_virgin_use),
                    right_pct_virgin_use = _maybe_field(right_row, :pct_virgin_use),
                    left_pct_toaster_service = _maybe_field(left_row, :pct_toaster_service),
                    right_pct_toaster_service = _maybe_field(right_row, :pct_toaster_service),
                    left_government_net = _maybe_field(left_row, :government_net),
                    right_government_net = _maybe_field(right_row, :government_net),
                    left_support_cost = _maybe_field(left_row, :support_cost),
                    right_support_cost = _maybe_field(right_row, :support_cost),
                    left_fiscal_cost = _maybe_field(left_row, :fiscal_cost),
                    right_fiscal_cost = _maybe_field(right_row, :fiscal_cost),
                    left_revenue_gain = _maybe_field(left_row, :revenue_gain),
                    right_revenue_gain = _maybe_field(right_row, :revenue_gain),
                    left_virgin_saving = _maybe_field(left_row, :virgin_saving),
                    right_virgin_saving = _maybe_field(right_row, :virgin_saving),
                    left_virgin_saving_per_support_dollar =
                        _maybe_field(left_row, :virgin_saving_per_support_dollar),
                    right_virgin_saving_per_support_dollar =
                        _maybe_field(right_row, :virgin_saving_per_support_dollar),
                    left_virgin_saving_per_fiscal_cost_dollar =
                        _maybe_field(left_row, :virgin_saving_per_fiscal_cost_dollar),
                    right_virgin_saving_per_fiscal_cost_dollar =
                        _maybe_field(right_row, :virgin_saving_per_fiscal_cost_dollar),
                    left_virgin_saving_per_revenue_dollar =
                        _maybe_field(left_row, :virgin_saving_per_revenue_dollar),
                    right_virgin_saving_per_revenue_dollar =
                        _maybe_field(right_row, :virgin_saving_per_revenue_dollar),
                    stronger_material_saving = _choose_strategy(left_row, right_row,
                        :pct_virgin_use, left_label, right_label; sense = :min),
                    lower_service_loss = _choose_strategy(left_row, right_row,
                        :pct_toaster_service, left_label, right_label; sense = :max),
                    higher_government_net = _choose_strategy(left_row, right_row,
                        :government_net, left_label, right_label; sense = :max),
                    higher_support_efficiency = _choose_strategy_finite(left_row, right_row,
                        :virgin_saving_per_support_dollar, left_label, right_label;
                        sense = :max),
                    higher_fiscal_cost_efficiency = _choose_strategy_finite(left_row, right_row,
                        :virgin_saving_per_fiscal_cost_dollar, left_label, right_label;
                        sense = :max),
                    higher_revenue_efficiency = _choose_strategy_finite(left_row, right_row,
                        :virgin_saving_per_revenue_dollar, left_label, right_label;
                        sense = :max),
                )
            end,
        )
        for key in keys_all
    ]
end

"""
    sensitivity_screen(rows, outcome, parameters)

Rank varied parameters by the range of mean `outcome` values across their
levels. This is a compact screening tool; it is not a substitute for a designed
global sensitivity analysis.
"""
function sensitivity_screen(rows::AbstractVector{<:NamedTuple},
    outcome::Symbol,
    parameters::AbstractVector{Symbol})
    return RuntimeExperiments.sensitivity_screen(rows, outcome, parameters)
end

function _minmax(values)
    isempty(values) && return (min = NaN, max = NaN)
    return (min = minimum(values), max = maximum(values))
end

function _finite_minmax(values)
    finite = [Float64(value) for value in values if isfinite(Float64(value))]
    isempty(finite) && return (min = NaN, max = NaN)
    return (min = minimum(finite), max = maximum(finite))
end

"""
    summarize_comparison(rows)

Return compact ranges and regime counts for comparison rows.
"""
function summarize_comparison(rows::AbstractVector{<:NamedTuple})
    return (
        count = length(rows),
        regimes = regime_counts(rows),
        mechanisms = mechanism_counts(rows),
        pct_virgin_use = _minmax([row.pct_virgin_use for row in rows]),
        pct_recycled_use = _minmax([row.pct_recycled_use for row in rows]),
        pct_toaster_service = _minmax([row.pct_toaster_service for row in rows]),
        delta_ref_share = _minmax([row.delta_ref_share for row in rows]),
        delta_rec_share = _minmax([row.delta_rec_share for row in rows]),
        wedge_net = _minmax([row.wedge_net for row in rows]),
        virgin_saving_per_support_dollar =
            _finite_minmax([row.virgin_saving_per_support_dollar for row in rows]),
        virgin_saving_per_fiscal_cost_dollar =
            _finite_minmax([row.virgin_saving_per_fiscal_cost_dollar for row in rows]),
        virgin_saving_per_revenue_dollar =
            _finite_minmax([row.virgin_saving_per_revenue_dollar for row in rows]),
    )
end

"""
    summary_row(summary)

Flatten `summarize_comparison` output into one CSV-friendly row.
"""
function summary_row(summary::NamedTuple)
    regimes = summary.regimes
    mechanisms = summary.mechanisms
    return (
        count = summary.count,
        material_saving_without_rebound = get(regimes, :material_saving_without_rebound, 0),
        material_saving_with_rebound = get(regimes, :material_saving_with_rebound, 0),
        rebound_without_material_saving = get(regimes, :rebound_without_material_saving, 0),
        no_material_saving_no_rebound = get(regimes, :no_material_saving_no_rebound, 0),
        mechanism_reference = get(mechanisms, :reference, 0),
        mechanism_demand_contraction_material_saving = get(mechanisms,
            :demand_contraction_material_saving, 0),
        mechanism_refurbishment_substitution_material_saving = get(mechanisms,
            :refurbishment_substitution_material_saving, 0),
        mechanism_eol_reallocation_material_saving = get(mechanisms,
            :eol_reallocation_material_saving, 0),
        mechanism_circular_substitution_with_rebound = get(mechanisms,
            :circular_substitution_with_rebound, 0),
        mechanism_rebound_material_saving = get(mechanisms, :rebound_material_saving, 0),
        mechanism_circular_expansion_material_increase = get(mechanisms,
            :circular_expansion_material_increase, 0),
        mechanism_service_contraction_material_increase = get(mechanisms,
            :service_contraction_material_increase, 0),
        mechanism_service_contraction_without_material_saving = get(mechanisms,
            :service_contraction_without_material_saving, 0),
        mechanism_rebound_without_material_saving = get(mechanisms,
            :rebound_without_material_saving, 0),
        mechanism_no_material_saving = get(mechanisms, :no_material_saving, 0),
        mechanism_mixed_material_saving = get(mechanisms, :mixed_material_saving, 0),
        pct_virgin_use_min = summary.pct_virgin_use.min,
        pct_virgin_use_max = summary.pct_virgin_use.max,
        pct_recycled_use_min = summary.pct_recycled_use.min,
        pct_recycled_use_max = summary.pct_recycled_use.max,
        pct_toaster_service_min = summary.pct_toaster_service.min,
        pct_toaster_service_max = summary.pct_toaster_service.max,
        delta_ref_share_min = summary.delta_ref_share.min,
        delta_ref_share_max = summary.delta_ref_share.max,
        delta_rec_share_min = summary.delta_rec_share.min,
        delta_rec_share_max = summary.delta_rec_share.max,
        wedge_net_min = summary.wedge_net.min,
        wedge_net_max = summary.wedge_net.max,
        virgin_saving_per_support_dollar_min = summary.virgin_saving_per_support_dollar.min,
        virgin_saving_per_support_dollar_max = summary.virgin_saving_per_support_dollar.max,
        virgin_saving_per_fiscal_cost_dollar_min =
            summary.virgin_saving_per_fiscal_cost_dollar.min,
        virgin_saving_per_fiscal_cost_dollar_max =
            summary.virgin_saving_per_fiscal_cost_dollar.max,
        virgin_saving_per_revenue_dollar_min = summary.virgin_saving_per_revenue_dollar.min,
        virgin_saving_per_revenue_dollar_max = summary.virgin_saving_per_revenue_dollar.max,
    )
end

"""
    best_material_savers(rows; n=5)

Return up to `n` comparison rows that reduce virgin material use, sorted from
largest to smallest reduction.
"""
function best_material_savers(rows::AbstractVector{<:NamedTuple}; n::Integer = 5)
    all(row -> hasproperty(row, :material_saving), rows) ||
        error("best_material_savers expects rows from compare_to_reference")
    savers = filter(row -> row.material_saving, rows)
    ordered = sort(collect(savers); by = row -> row.delta_virgin_use)
    return ordered[1:min(n, length(ordered))]
end
