# Single-Country Scenarios

These scripts execute scenario grids for the single-country model branch and
write generated CSVs under `results/single_country/generated/`.

- `run_fiscal_parameter_regions.jl`: compares virgin-metal taxation,
  refurbishment support, and recycling support across the main policy grid.
- `run_nested_eol_policy_regions.jl`: runs the nested EOL policy comparison:
  linear/virgin-metal taxation versus recycling versus the life-extension family,
  then refurbishment versus repair versus reuse within that family.
