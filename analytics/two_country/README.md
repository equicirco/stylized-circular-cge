# Two-Country Analytics

Manuscript-oriented analysis scripts for the two-country branch live here.

- `analyze_policy_regions.jl`: reads the full-grid generated CSVs from
  `results/two_country/generated` and writes interpretation-oriented summaries
  under `results/two_country/analytics`.

Transmission outputs currently persisted for manuscript review:

- `material_saving_transmission_set.csv`: all solved non-reference
  two-country comparisons with primary-material saving, keeping the C-side
  material, route, service, and EOL changes together with the M-side output and
  factor changes.
- `material_saving_transmission_summary.csv`: strategy-by-variable medians,
  interquartile ranges, and sign shares for the neutral transmission result set.
- `material_saving_transmission_sign_patterns.csv`: sign diagnostics by policy
  strategy for the same material-saving rows.
