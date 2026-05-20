# Two-Country Source

This branch contains the executable leakage/trade extension.

- `core.jl`: two-country benchmark SAM accounting. Country `M` produces local
  bread and all virgin metal. Country `C` produces local bread, recycled
  material, toaster routes, toaster services, and EOL allocation. `NFA` records
  the benchmark current-account counterpart of virgin-metal export income.
- `blocks.jl`: two-country JCGE block definitions and block ordering.
- `model.jl`: block build methods, solve path, residuals, and indicators.
- `scenarios.jl`: experiment execution helpers.
- `results.jl`: result flattening and closure validation.
- `analytics.jl`: comparison, transmission classification, distributional
  incidence, and summary utilities.
- `io.jl`: CSV and data-directory helpers.

The executable model is assembled from model-local JCGE blocks for metadata,
technology, EOL allocation, material balances, route service, benchmark
replication, prices, fiscal income, demand, and objective terms.
