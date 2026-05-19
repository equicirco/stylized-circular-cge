# StylizedCircularCGE

This repository contains code for stylized circular-economy CGE experiments
built with the JCGE package stack.

Modeling choices, interpretation, and manuscript text should live outside this
README. This file only documents the repository layout and execution entry
points.

## Repository Layout

- `src/StylizedCircularCGE.jl`: package entry point and public exports.
- `src/single_country/`: executable single-country model branch.
- `src/two_country/`: two-country/leakage branch.
- `scenarios/single_country/`: scripts that run single-country scenario grids.
- `scenarios/two_country/`: reserved for future two-country scenario scripts.
- `analytics/single_country/`: manuscript-oriented analysis scripts for
  generated single-country results.
- `analytics/two_country/`: reserved for future two-country analysis scripts.
- `results/single_country/`: generated single-country CSV outputs.
- `results/two_country/`: generated future two-country outputs.
- `data/`: round-number synthetic calibration inputs.
- `test/`: package tests.
- `scripts/`: compatibility wrappers for the single-country scenario scripts.

## Single-Country Source Files

- `src/single_country/core.jl`: account sets, policy wedges, parameters, product
  profiles, and synthetic benchmark data.
- `src/single_country/model.jl`: model blocks, closures, solver entry point,
  residuals, and indicators.
- `src/single_country/scenarios.jl`: experiment specs and grid execution.
- `src/single_country/results.jl`: result flattening and closure validation.
- `src/single_country/analytics.jl`: comparison, frontier, regime,
  distributional-incidence, and summary utilities.
- `src/single_country/io.jl`: CSV output and data-directory helpers.

## Two-Country Source Files

- `src/two_country/core.jl`: benchmark SAM split between the mining/resource
  country and the consuming/circular-economy country.
- `src/two_country/model.jl`: reserved for executable two-country equations.

## Running Scenarios

Use the new scenario paths:

```bash
julia --project=. scenarios/single_country/run_default_grid.jl
julia --project=. scenarios/single_country/run_fiscal_strategy_comparison.jl
julia --project=. scenarios/single_country/run_fiscal_parameter_regions.jl
```

The old `scripts/run_*.jl` paths remain available as wrappers.

For parallel grid execution:

```bash
OPENBLAS_NUM_THREADS=1 JCGE_EXPERIMENT_WORKERS=6 julia --project=. scenarios/single_country/run_fiscal_parameter_regions.jl
```

Generated CSVs are written under `results/single_country/generated/`.

## Running Analytics

```bash
julia --project=. analytics/single_country/analyze_policy_regions.jl
```

Derived analytics tables are written under `results/single_country/analytics/`.

## Testing

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```
