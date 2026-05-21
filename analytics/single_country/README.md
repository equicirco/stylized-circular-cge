# Single-Country Analytics

Manuscript-oriented analysis scripts derived from generated single-country
results live here. Reusable analytics functions belong in
`src/single_country/analytics.jl`.

- `analyze_policy_regions.jl`: reads full-grid generated CSVs and writes compact
  policy-region, support-efficiency, mechanism, and distributional-incidence
  summaries to `results/single_country/analytics/`.
- `analyze_nested_eol_policy_regions.jl`: reads nested EOL generated CSVs and
  writes headline metrics and notes for the family-level and within-route
  comparison.
- `manuscript_notes.md`: non-executable notes for later manuscript limitations
  and table/figure preparation.
