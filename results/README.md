# Results

This directory stores reproducible outputs from the scenario and analytics
scripts.

Only the current outputs are kept here; earlier tracked results remain available
through Git history. The analysis runner resumes matching checkpoints or replaces
the selected outputs when invoked with `--restart`.

The repository tracks compact analytics CSVs under:

- `results/single_country/analytics/`;
- `results/two_country/analytics/`;
- `results/cross_model/analytics/`.

Large raw grid outputs under `results/*/generated/` are intentionally ignored.
They can be regenerated from the scripts in `scenarios/` and `analytics/`.
