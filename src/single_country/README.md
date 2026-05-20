# Single-Country Source

- `core.jl`: accounts, wedges, parameters, product profiles, and benchmark data.
- `blocks.jl`: single-country JCGE block definitions and block ordering.
- `model.jl`: block build methods, closures, solve path, residuals, and
  indicators.
- `scenarios.jl`: experiment execution helpers.
- `results.jl`: result flattening and closure validation.
- `analytics.jl`: comparison, frontier, classification, and summary utilities.
- `io.jl`: CSV and data-directory helpers.

The executable model is assembled from model-local JCGE blocks for metadata,
technology, EOL allocation, material balances, route service, benchmark
replication, prices, fiscal income, demand, and objective terms. The planner
branch omits fiscal-only blocks.
