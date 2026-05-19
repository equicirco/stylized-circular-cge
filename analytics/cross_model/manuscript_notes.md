# Cross-Model Manuscript Notes

These notes summarize the current full-grid outputs. They are claim candidates,
not final manuscript text.

## Scope

The two-country extension should be interpreted as upstream transmission through
the fixed virgin-material supply relation. It is not a relocation or production
offshoring model. Country `M` supplies virgin material; country `C` consumes the
durable service and hosts new production, refurbishment, repair, reuse,
recycling, and EOL allocation.

## Coverage

Both model branches have broad full-grid coverage after filtering to solved and
market-closing rows with valid references.

- Minimum comparable share across model and policy families: 98.4%.
- Single-country comparable rows: 25,901.
- Two-country comparable rows: 26,039.
- Non-comparable rows are documented in `status_comparison.csv`,
  `coverage_comparison.csv`, and `invalid_parameter_patterns.csv`.

The excluded cases are mostly solver status edge cases (`ITERATION_LIMIT`,
`LOCALLY_INFEASIBLE`, and a few `OTHER_ERROR`/`SLOW_PROGRESS` statuses). They
should not drive the headline claims, but they should be checked if a specific
claim depends on an extreme parameter region.

## Main Cross-Model Differences

Adding the upstream country materially changes how often policies produce
virgin-material savings in the full grid:

- Virgin-material tax: 24.5% in the single-country model, 56.8% in the
  two-country model.
- Refurbishment support: 26.3% in the single-country model, 33.5% in the
  two-country model.
- Recycling support: 3.1% in the single-country model, 46.9% in the two-country
  model.

Threshold availability also changes:

- Virgin-material tax thresholds: 879 single-country, 1,767 two-country.
- Refurbishment-support thresholds: 840 single-country, 1,027 two-country.
- Recycling-support thresholds: 146 single-country, 1,509 two-country.

This suggests that making the upstream material-supply country explicit changes
the numerical policy-region map, not only the interpretation of the same map.

## Upstream Transmission

In the current two-country structure, material-saving rows always imply upstream
contraction in `M`, because `M` is the only virgin-material supplier. This is a
clean theoretical implication of the model structure.

Dominant two-country transmission channels:

- Virgin-material tax: upstream contraction with service contraction.
- Refurbishment support: upstream expansion is the most frequent overall
  transmission, but material-saving refurbishment-support cases are upstream
  contractions.
- Recycling support: upstream contraction with service contraction.

This should be framed as cross-country incidence or upstream transmission, not
as leakage or relocation.

## Support Efficiency

Best support-efficiency rows differ between model branches:

- Single-country support-efficiency candidates are mostly refurbishment support:
  840 refurbishment rows versus 118 recycling rows.
- Two-country support-efficiency candidates are split differently: 776
  refurbishment rows versus 959 recycling rows.

Mean virgin saving per support dollar:

- Single-country refurbishment support: 0.103.
- Single-country recycling support: 0.083.
- Two-country refurbishment support: 0.067.
- Two-country recycling support: 0.117.

The two-country model therefore makes recycling support appear more competitive
in support-efficiency terms, while also showing stronger contraction of upstream
virgin-material activity.

## Distributional Interpretation

The activity and factor summaries should be read as reallocations, not welfare
or income-distribution results. Current closures keep household income
mechanically tied to benchmark endowment logic, so activity/factor movements are
the meaningful distributional diagnostics at this stage.

Important caution: circular policy support does not mechanically imply expansion
of all circular activities. Service-demand contraction can dominate, so
recycling/refurbishment support can still reduce aggregate activity in `C` in
some parameter regions.

## Candidate Claims To Test In Manuscript Drafting

1. Explicit upstream-country representation changes the material-saving policy
   region map, especially for virgin-material taxes and recycling support.
2. Material savings in the consuming/circular country map directly into upstream
   contraction in the resource country under the fixed-supplier structure.
3. Support efficiency is parameter-dependent and can favor recycling support in
   the two-country extension, unlike the single-country summaries where
   refurbishment support dominates the support-efficiency candidates.
4. Service-demand elasticity is central: many material-saving outcomes occur via
   service contraction, not only circular substitution.
5. The model is useful for theoretical region mapping, but results should be
   presented as equilibrium mechanism diagnostics, not empirical predictions.
