# Material-Saving Transmission Diagnostics

This note records the neutral result set used to inspect two-country
transmission. It is not manuscript text.

## Result Set

The transmission set includes two-country comparisons that satisfy all of the
following conditions:

- solver status is `LOCALLY_SOLVED`;
- the policy value is non-zero;
- `material_saving == true`, meaning virgin-metal imports/use in country C are
  lower than in the zero-policy reference for the same parameter group.

The persisted result files are:

- `results/two_country/analytics/material_saving_transmission_set.csv`;
- `results/two_country/analytics/material_saving_transmission_summary.csv`;
- `results/two_country/analytics/material_saving_transmission_sign_patterns.csv`.

## First Diagnostics

These points are descriptive diagnostics of the solved parameter design, not
empirical frequencies.

- Material-saving rows always reduce country M virgin-metal output. This is the
  direct transmission relation in the two-country structure: country M is the
  only virgin-metal supplier and country C imports that metal.
- Refurbishment-support material-saving rows usually expand refurbishment output
  in country C. In the current summary, the median change in refurbishment
  output is positive, and the sign-pattern table reports expansion in 2227 of
  2907 material-saving rows.
- Recycling-support material-saving rows always increase the end-of-life share
  allocated to recycling, but they do not usually increase recycled-metal
  output. The median recycled-metal-output change is negative, and expansion
  occurs in 479 of 4069 material-saving rows.
- Virgin-metal taxation material-saving rows mainly operate through lower
  virgin-metal use and lower new-production activity. The end-of-life recycling
  share is unchanged in these rows.

The recycling-support result is therefore not a simple "more recycling output"
channel. It can be a material-saving policy because end-of-life allocation,
route composition, virgin/recycled substitution, and the scale of metal-using
activities move together in equilibrium.
