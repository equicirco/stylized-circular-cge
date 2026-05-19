# Single-Country Analytics

Manuscript-oriented analysis scripts derived from generated single-country
results live here. Reusable analytics functions belong in
`src/single_country/analytics.jl`.

- `analyze_policy_regions.jl`: reads full-grid generated CSVs and writes compact
  policy-region, support-efficiency, mechanism, and distributional-incidence
  summaries to `results/single_country/analytics/`.
- `manuscript_notes.md`: non-executable notes for later manuscript limitations
  and table/figure preparation.
