# Two-Country Source

This branch contains the executable leakage/trade extension.

- `core.jl`: two-country benchmark SAM accounting. Country `M` produces local
  bread and all virgin metal. Country `C` produces local bread, recycled
  material, toaster routes, toaster services, and EOL allocation. `NFA` records
  household lending and borrowing, equal to the external surplus and deficit.
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

Both households allocate disposable income between consumption and net saving.
Their saving shares equal their calibrated shares plus the same endogenous
adjustment. Net saving sums to zero: lending in M finances borrowing in C.
The calibration shares are 40/65 in M and -40/335 in C, reproducing consumption
budgets of 25 and 375. Borrowing is recorded separately from earned income.
The financial flow and monetary trade balances can change in policy scenarios.
