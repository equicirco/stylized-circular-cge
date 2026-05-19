# StylizedCircularCGE

`StylizedCircularCGE` is a stylized JCGE model project for studying circular
economy strategies in a deliberately simplified economy.

The purpose is not to reproduce a particular country or sector. The purpose is to
build a controlled numerical environment where assumptions about substitution,
quality, end-of-life allocation, and policy wedges can be varied systematically.
The resulting simulations should support theoretical statements about when a
circular strategy is effective, where it is limited, and which parameter
combinations make a policy relevant.

## Modeling Direction

The model should be developed as a JCGE model rather than as a standalone
equation script:

- economic structure is expressed as a `RunSpec`;
- reusable production, demand, market, closure, and initialization blocks are used
  where they fit;
- circular-economy mechanisms are added as model-specific blocks when they are
  not generic enough for `JCGEBlocks`;
- calibration data, parameter grids, scenarios, and outputs remain separate from
  the structural model definition;
- generic experiment mechanics use `JCGERuntime.Experiments`, while
  circular-economy indicators and regime labels remain model-specific.

The starting point is a minimal economy with bread, metal, new toasters,
refurbishment, repair, reuse, recycling, incineration, and a composite toaster
service/need good. The important policy object is not the level of any single
flow, but the equilibrium response of the system as elasticities, yields, metal
quality, and fiscal incentives change.

## Current Executable Target

The current code provides a first one-period, closed-economy, materials-only
model scaffold. The default solve path uses the fiscal closure:

```julia
using StylizedCircularCGE

result = solve()
indicators(result)
```

This first target is intentionally small. Two closure variants are available,
but the fiscal closure is the default for `solve()`, `run_experiment`, and
`run_grid`:

- `fiscal_baseline()` is the decentralized fiscal closure with purchaser
  prices, household income, government revenue/subsidy accounting, and
  tax-inclusive route and material demand;
- `baseline()` is a planner-form numerical equilibrium used to test the physical
  circular structure;
- planner experiments remain available explicitly with `closure = :planner`.

The fiscal closure separates four key elasticities:

- `sigma_routes`: substitution among `NEW`, `REF`, `REP`, and `REU` routes;
- `sigma_metal`: substitution between virgin metal and quality-adjusted recycled
  metal inside each material-using route;
- `sigma_eol`: allocation response among end-of-life uses;
- `eta_service`: total toaster-service demand response to the service price.

The round-number benchmark can also be replicated directly:

```julia
result = solve(baseline(replicate_benchmark = true))
benchmark_residuals(result)
```

Policies use one comparable ad-valorem wedge convention throughout:

```julia
policy = single_wedge(:material, :VMTL, 0.25)  # positive = penalty
result = solve(baseline(policy = policy))
indicators(result).wedge_accounting
```

Use `:route`, `:material`, or `:eol` as the wedge kind. Negative values represent
support; positive values represent penalties.

The main single-instrument strategies currently compared are:

- linear pressure on primary material: `single_wedge(:material, :VMTL, tau)`,
  with positive `tau`;
- life-extension support: `single_wedge(:route, :REF, tau)`, with negative
  `tau`;
- loop-closing support: `single_wedge(:eol, :REC, tau)`, with negative `tau`.

The recycling strategy works through the same price system as the others. It
changes the cost of the recycling EOL route, which changes recycled-material
supply and the recycled-material price. Recycled material then substitutes for
virgin material through the `sigma_metal` CES nest, with `metal_quality`
controlling the effective quality of recycled metal.

The fiscal closure can be solved directly:

```julia
result = solve(fiscal_baseline(policy = single_wedge(:material, :VMTL, 0.25)))
out = indicators(result)

out.prices.toaster_service
out.fiscal.government_revenue
out.fiscal.government_subsidy
```

Net fiscal revenue is recycled as a lump-sum household transfer in this closure.
The model does not represent government consumption, public investment, or public
service provision. Fiscal results should therefore be read as net revenue or
financing requirements under revenue recycling, not as a full welfare comparison
between private household demand and alternative uses of public funds.

Closed-economy diagnostics are reported with each result:

```julia
out.closed_economy.max_abs_market_residual
out.closed_economy.material_balance
out.closed_economy.government_budget
```

For the fiscal closure, market residuals are expected to stay close to zero:
material supply is used domestically, end-of-life units are allocated domestically,
and the household and government accounts balance. Capacity slack is reported
separately, so unused domestic technology, route, recycling, or factor capacity is
not confused with an import/export leakage term.

Flattened experiment rows also report route quantities, end-of-life quantities,
and virgin/recycled material use by route. These fields make it possible to
separate material savings coming from lower service demand, substitution away
from new production, EOL reallocation, or route-level material intensity.
Comparison rows add a `mechanism` label derived from those deltas so large
parameter grids can be screened before inspecting individual channels.

Small parameter grids can be run locally:

```julia
specs = parameter_grid(
    sigma_routes = [1.5, 2.0, 3.0],
    eta_service = [0.5, 1.0, 1.5],
    metal_quality = [0.75, 0.90],
    policy = single_wedge(:material, :VMTL, 0.25),
)

results = run_grid(specs)
assert_closed_economy_results(results)
rows = result_rows(results)

reference = run_experiment(ExperimentSpec("reference"))
comparison = compare_to_reference(results, reference)
summary = summarize_comparison(comparison)
best_material_savers(comparison; n = 5)
sensitivity_screen(comparison, :pct_virgin_use,
    [:sigma_routes, :sigma_metal, :sigma_eol, :eta_service, :metal_quality])
write_rows_csv("outputs/comparison.csv", comparison)
```

Use the planner diagnostic closure explicitly when the physical structure needs
to be isolated from the fiscal accounting layer:

```julia
planner_results = run_grid(specs; closure = :planner)
```

For policy sweeps, compare each row to a zero-policy row with the same
parameters before looking for thresholds:

```julia
specs = parameter_policy_grid(
    policy_kind = :route,
    policy_target = :REF,
    tau = [-0.50, -0.25, -0.10, 0.0, 0.10],
    sigma_routes = [1.5, 2.0, 3.0],
)

results = run_grid(specs)
comparison = compare_to_group_reference(results, [:sigma_routes],
    reference_filter = row -> row.tau_route_ref == 0.0,
)

frontier = material_saving_frontier(comparison, :tau_route_ref,
    group_by = [:sigma_routes],
)
```

Product interpretations can be documented as profiles and then mapped to the
same parameter interface:

```julia
profile = ProductProfile("durable-toaster",
    stock0 = 300,
    delta = 1 / 6,
    metal_quality = 0.90,
    yield = (ref = 5, rep = 4, reu = 2, rmtl = 1.7),
    metal_intensity = (new = 0.35, ref = 0.20, rep = 0.12, reu = 0.0),
)

specs = product_parameter_grid(profile,
    sigma_routes = [1.5, 2.0, 3.0],
    policy = single_wedge(:route, :REF, -0.25),
)
```

This is meant as a traceable bridge from product assumptions to parameter
experiments, not as a fixed product taxonomy.

The same workflow is available as a script:

```bash
julia --project=. scripts/run_default_grid.jl
julia --project=. scripts/run_policy_frontier.jl              # planner diagnostic
julia --project=. scripts/run_fiscal_policy_frontier.jl
julia --project=. scripts/run_fiscal_refurbishment_frontier.jl
julia --project=. scripts/run_fiscal_strategy_comparison.jl
julia --project=. scripts/run_fiscal_parameter_regions.jl
```

Grid scripts run serially by default. For larger parameter-space screens, set
`JCGE_EXPERIMENT_WORKERS` to use `JCGERuntime.Experiments` distributed execution
with the same model runner and result format:

```bash
OPENBLAS_NUM_THREADS=1 JCGE_EXPERIMENT_WORKERS=6 julia --project=. scripts/run_fiscal_parameter_regions.jl
```

The worker count should be chosen for the machine. On the current development
machine, six workers match the physical CPU cores; keeping BLAS single-threaded
avoids oversubscribing the same cores from each worker process.

The script writes a bundle under `outputs/`: experiment rows, comparison rows,
and a one-row summary with regime counts and indicator ranges. The default
scripts also write a sensitivity screen ranking the varied parameters by their
mean effect on virgin-material use.

`run_fiscal_strategy_comparison.jl` runs the virgin-material tax,
refurbishment-support, and recycling-support instruments on the same
closed-economy parameter grid. It writes pairwise threshold rows so the
benchmark tax and the CE-targeted strategies can be compared by material saving,
service contraction, and government net position. It also writes a threshold
channel summary that decomposes the average route, EOL, and route-level
material-use changes, plus mechanism-count tables for the full grid and for
threshold rows.

`run_fiscal_parameter_regions.jl` expands the abstract parameter-space screen
over route substitution, virgin/recycled material substitution, EOL response,
service demand, recycled-material quality, refurbishment material intensity, and
refurbishment yield. The default `screen` grid keeps the run compact; set
`JCGE_REGION_GRID=full` to include the central levels as well. The script writes
raw result/status/coverage tables and uses only closed, locally solved rows for
policy comparisons. It also writes complete policy-region maps and pairwise
threshold summaries, including parameter-level counts, to identify where the
virgin-material tax, refurbishment support, recycling support, combinations of
these instruments, or none of them reach no-rebound material-saving thresholds.
Region-map rows include validity and comparability flags so incomplete numerical
cases can be separated from complete `none_available` cases, with a separate
quality summary for that distinction. The workflow also writes a `sigma_eol` by
`eta_service` summary for the main elasticity-region view.
