# StylizedCircularCGE

This repository contains code for stylized circular-economy CGE experiments
built with the JCGE package stack.

This file documents the repository layout and execution entry points.

## Repository Layout

- `src/StylizedCircularCGE.jl`: package entry point and public exports.
- `src/common/`: shared model-local equation AST and circular-policy helpers.
- `src/single_country/`: executable single-country model branch.
- `src/two_country/`: executable two-country/leakage model branch.
- `scenarios/single_country/`: scripts that run single-country scenario grids.
- `scenarios/two_country/`: scripts that run two-country scenario grids.
- `analytics/single_country/`: analysis scripts for generated single-country
  results.
- `analytics/two_country/`: analysis scripts for generated two-country results.
- `analytics/cross_model/`: scripts comparing single-country and two-country
  outputs.
- `results/single_country/`: single-country analytics outputs; raw generated
  grids are reproducible and ignored.
- `results/two_country/`: two-country analytics outputs; raw generated grids
  are reproducible and ignored.
- `results/cross_model/`: cross-model comparison analytics outputs.
- `data/`: round-number synthetic calibration inputs.
- `test/`: package tests.
- `scripts/`: compatibility wrappers for scenario and analytics scripts.

## Common Source Files

- `src/common/ast.jl`: model-local helpers for creating variables and
  registering JCGE equation/objective AST objects.
- `src/common/circular_policy.jl`: shared circular-economy policy-wedge,
  material-intensity, route-yield, and EOL-allocation helpers.

## Single-Country Source Files

- `src/single_country/core.jl`: account sets, policy wedges, parameters, product
  profiles, and synthetic benchmark data.
- `src/single_country/blocks.jl`: single-country JCGE block definitions and
  block ordering.
- `src/single_country/model.jl`: single-country block build methods, closures,
  solver entry point, residuals, and indicators.
- `src/single_country/scenarios.jl`: experiment specs and grid execution.
- `src/single_country/results.jl`: result flattening and closure validation.
- `src/single_country/analytics.jl`: comparison, frontier, regime,
  distributional-incidence, and summary utilities.
- `src/single_country/io.jl`: CSV output and data-directory helpers.

## Two-Country Source Files

- `src/two_country/core.jl`: benchmark SAM split between the mining/resource
  country and the consuming/circular-economy country.
- `src/two_country/blocks.jl`: two-country JCGE block definitions and block
  ordering.
- `src/two_country/model.jl`: two-country block build methods, solver entry
  point, residuals, and indicators.
- `src/two_country/scenarios.jl`: two-country experiment specs and grid
  execution.
- `src/two_country/results.jl`: two-country result flattening and closure
  validation.
- `src/two_country/analytics.jl`: two-country comparison, classification,
  distributional-incidence, and summary utilities.
- `src/two_country/io.jl`: CSV output helpers.

Both executable branches are assembled from model-local JCGE blocks named
`metadata`, `technology`, `eol`, `material`, `route_service`, `replication`,
`price`, `fiscal_income`, `demand`, and `objective`, with the planner
single-country branch omitting fiscal-only blocks.

## Running Scenarios

Use the scenario paths directly:

```bash
julia --project=. scenarios/single_country/run_default_grid.jl
julia --project=. scenarios/single_country/run_fiscal_strategy_comparison.jl
julia --project=. scenarios/single_country/run_fiscal_parameter_regions.jl
julia --project=. scenarios/single_country/run_nested_eol_policy_regions.jl
julia --project=. scenarios/two_country/run_fiscal_parameter_regions.jl
```

The `scripts/run_*.jl` paths remain available as wrappers.

For parallel grid execution:

```bash
OPENBLAS_NUM_THREADS=1 JCGE_EXPERIMENT_WORKERS=6 julia --project=. scenarios/single_country/run_fiscal_parameter_regions.jl
```

Generated CSVs are written under the matching `results/*/generated/`
directory.

## Running Analytics

```bash
julia --project=. analytics/single_country/analyze_policy_regions.jl
julia --project=. analytics/single_country/analyze_nested_eol_policy_regions.jl
julia --project=. analytics/two_country/analyze_policy_regions.jl
julia --project=. analytics/cross_model/compare_single_two_country.jl
```

Derived analytics tables are written under the matching `results/*/analytics/`
directory.

## Testing

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```
