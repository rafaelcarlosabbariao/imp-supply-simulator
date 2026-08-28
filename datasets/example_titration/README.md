# Example: a titrating arm

A copy of the sample dosing schedule in which **TRIAL-118 / Combo7 titrates**
over a six-rung ladder, and every other arm stays fixed dose. It is kept
separate so the shipped sample run, the committed `output/` and the README
figures stay reproducible; nothing here is loaded unless you point at it.

The point of the example is the **DU switch**. Low rungs dispense
`Compound-C 25 mg`, high rungs dispense `Compound-C 100 mg`, and
`Compound-B 15 mg` is background at every rung:

| Rung | Compound-B 15 mg | Compound-C 25 mg | Compound-C 100 mg |
|---|---|---|---|
| 1 | 2 | 2 | — |
| 2 | 2 | 4 | — |
| 3 | 2 | 1 | 1 |
| 4 | 2 | — | 2 |
| 5 | 2 | — | 3 |
| 6 | 2 | — | 4 |

So a patient who misses a visit and restarts pulls the **25 mg** DU again,
months after the depot stopped forecasting for it. That is the demand echo the
`(s,S)` reorder point in `R/inventory.R` lags, because its rate is a trailing
average.

`Tolerance_Level = 5` is the second-to-last rung, the usual CSP convention. It
is the rung a patient must *tolerate once* before their floor ratchets up to
it; until then a missed visit sends them back to rung 1.

## Run it

```r
source("R/titration.R"); source("R/simulation.R")
dosing    <- read.csv("datasets/example_titration/dosing_input.csv")
titration <- read_titration("datasets/example_titration/titration_input.csv")

visits <- simulate_visits(enroll, dosing, titration = titration,
                          simulation_end_date = as.Date("2026-12-31"))

# and the exact expectation, with no Monte Carlo at all:
expected_demand(build_ladders(dosing, titration))
```

Note `simulate_visits()` is handed the **wide** sheet. `expand_dosing()`
collapses the Option columns to one quantity, which throws the ladder away.
