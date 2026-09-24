# Pre-registration — does a forecast that counts patients by dose beat a trailing average?

**Written:** 2026-09-24 (third version; see *History* at the end)
**Status:** PRE-REGISTERED. Nothing below has been run as a confirmatory
experiment. Results, when they exist, go in a *Results* section appended to
this file; the text above it is not edited afterwards.
**Implementation frozen at:** `ce00c7903f44aea9ac1cfdaf154d514f317b7bfc`
(2026-09-24)

> **The rule.** A seed means something only for one implementation, because
> any change to the engine can change the order in which random numbers are
> drawn. If the engine or `scripts/experiment_setup.R` changes before the
> confirmatory run, this document is void and is rewritten, not amended.

---

## 1. What this does and does not claim

**Claims:** an experiment-design result. Randomisation, blocking, a
pre-specified estimator, a power calculation, and an account of the threats, on
a question whose answer was measured once (n = 1 replication) and not tested.

**Does not claim:** causal identification under confounding. The
data-generating process is one we wrote, so there is no unobserved confounding
to defeat and nothing about propensity matching or synthetic controls is
demonstrated. A randomised experiment inside our own simulator is not an
identification strategy.

Because the true effect is known by construction, the estimator's **coverage
can be checked against ground truth** (§9), which a real-data study cannot do.

The companion item, the Supp acquisition-spend cutoff as an interrupted time
series, is the one that addresses identification on real data.

---

## 2. Motivation

The `(s, S)` reorder rule (`R/inventory.R`, METHODOLOGY §2.4) orders when the
stock a site holds and has on order falls below

```
reorder_point = lead_demand + safety_stock_days × rate
```

where `lead_demand` and `rate` come from a forecast. The default forecast is a
**trailing average** of the site's own dispensing over 60 days. Under a
titration ladder a missed visit restarts a patient at their floor, a stable
patient can be demoted back to titrating, and a cohort steps up the ladder
together. Each of these is a step change in the DU mix, and a trailing average
lags a step change by up to its window, with the lead time on top.

The **rung forecast** (METHODOLOGY §2.4a) counts the patients enrolled at the
site instead: each at their dose, their status (titrating or stable), the
ratchet and their visit number, projected forward through the CSP's titration
probabilities to their last cycle. That is information an IRT system holds.

On one replication of the frame (2026-09-24, `scripts/compare_forecasts.R`),
titrating protocols stocked out on 49% of their site × DUs under the trailing
forecast and 7% under the rung forecast, with fewer reorders. The question is
whether that holds across replications and across protocols drawn from this
population, and what it costs in expired stock.

---

## 3. Hypothesis

**H1 (primary).** Ordering on the rung forecast reduces the proportion of
site × DU units that experience at least one stockout, relative to ordering on
the trailing forecast.

**H0.** The two forecasts produce the same stockout rate.

Direction is pre-specified; the test is two-sided.

---

## 4. Arms

**Control: trailing.** `forecast = "trailing"`, `trailing_window_days = 60`.

**Treatment: rung.** `forecast = "rung"`, given the visit stream with the
enrollment records and the ladders built from the protocol's own dosing
schedule and titration spec (`build_ladders(dosing, titr)`).

**One lever moves.** Everything else is identical between arms:
`safety_stock_days = 30`, `target_days = 90`, `lead_time_days = 21`,
`unplanned_visit_pct = 0.10`, `oversupply_pct = 0.10`,
`enable_resupply = TRUE`, the horizon, the seeds and the depot. Both arms hold
the same safety-stock *rule*; the forecasts differ in what the rule multiplies.

**The oracle** (`forecast = "oracle"`, perfect foresight) is run on every
replication and reported as a ceiling. It is not an arm and is never compared
in a test.

### Held constant across arms

- **Site seeding.** Every cohort at every site is seeded by `seed_sites()`,
  landing 21 days before the cohort's enrollment (visit 0), drawn from the depot
  and topped up against what the site holds (METHODOLOGY §2.1a). Sites start
  empty (`opening = "seeded"`) and the as-of date, 2022-04-01, precedes every
  seed's ship date, so every seed ships inside the walk.
- **The depot.** Per Protocol × DU, 3× the study's expected demand
  (`expected_demand()` on the planned ladder), split into **four equal lots
  expiring 24, 36, 48 and 60 months after the as-of date**. Before this version
  the depot held one lot expiring a year after the horizon, so nothing could
  expire and `Total_Expired` was 0 in every run. Staggered lots let expiry
  respond to how much each forecast ships and when. The depot is never
  restocked. Measured on one control replication before this freeze: with
  the lots, 43% of site × DUs stock out against 26% with a single far lot,
  most of the difference in the month the first lot expires. Seed stock at a
  site that seldom dispenses a DU (the low-dose DU a restart pulls) expires, and
  a forecast that sees no recent demand for that DU does not replace it. That
  is a property of the forecast under test and stays in.

---

## 5. Unit of randomisation, and the interference problem

**Randomisation is at the protocol level.** Sites are the nested observation
level.

`R/inventory.R` keeps **one depot pool per Protocol × DU, shared by every site
in the protocol.** Randomising sites within a protocol would let a treated site
draw the depot down and change what a control site can get, an interference
(SUTVA) violation. Protocol-level assignment keeps each depot inside one arm,
and it is the level at which a supply lead sets a forecasting method.

**The frame** (`datasets/frame/`, built by `scripts/build_frame.R`) is 18
protocols, 9 titrating and 9 fixed dose, with 689 sites and 43,440 planned
patients. 18 is a small *n* and it is the binding constraint on power (§8).

---

## 6. Assignment mechanism

Blocked randomisation, 1:1 within block. Blocks are **titrating / fixed dose ×
above / below the median expected daily demand** within that titration group,
giving four blocks of four or five protocols. In a block of five, the fifth
protocol's arm is drawn by a fair coin. Block membership is computed from the
planned ladder and the enrollment plan before assignment.

A **balance table** on pre-treatment covariates (expected daily demand, sites,
planned patients, ladder depth, `P_Miss`, `Tolerance_Level`) is reported with
the result whatever it shows.

**Common random numbers.** Demand does not depend on the forecast. Demand is
simulated **once per `rep_seed`** and each protocol is projected under its
assigned arm against that realisation. Assignment uses a separate
`assign_seed`, re-drawn each replication. Both seeds are logged on every row.

---

## 7. Outcomes

**Primary.** The proportion of a protocol's site × DU units with at least one
stockout over the horizon (`Status == "STOCKOUT"`). Estimand: the **risk
difference**, treatment minus control.

**Secondary**, pre-specified, none promotable to primary:

1. Total stockout units (`Total_Stockout`), reported as a mean difference and
   as a difference in the 90th percentile.
2. Days to first stockout: Kaplan–Meier with a Cox model, censored at the
   horizon (see §10.3).
3. `Total_Expired`, the cost side. If the treatment reduces stockouts and
   increases expiry, both are reported with equal prominence and the trade is
   stated in units.
4. `Reorders` and `Total_Reordered`, the shipping cost.
5. The effect within titrating protocols (§9).

**Pre-specified sensitivity, not a test.** The rung forecast is given the true
titration probabilities (§10.2). The treatment arm is re-run with the forecast's
ladders misstated, `P_Miss` halved and `P_Miss` doubled (capped at 0.5), with
demand unchanged. The primary risk difference is reported for each.

---

## 8. Sample size and power

`R = 500` replications, fixed in advance. **No interim analyses and no optional
stopping.** The result is read once, after 500.

Power is computed **before** the confirmatory run from a pilot of the **control
arm** (`scripts/power_pilot.R`, 20 replications) on this implementation, with
seeding on and under the titration data-generating process. The power curve
(`scripts/power_curve.R`: protocols × effect size → power at α = 0.05) is
committed with this file before any confirmatory run begins.

**Minimum detectable effect, pre-specified:** a **5 percentage point** absolute
reduction in the site × DU stockout rate, at 80% power, α = 0.05, two-sided.

**Pre-registered contingency.** If the power calculation shows under 80% power
for that MDE at 18 protocols, the frame is expanded by generating further
synthetic protocols from the REINS phase / therapeutic-area / site-count
distribution (`scripts/build_frame.R`), up to the *n* that reaches 80%. The
expanded frame's size is reported. The decision is recorded here so it cannot
be made after an outcome is seen.

**Compute.** One replication takes about 55 s under the trailing forecast,
about 105 s under the rung forecast and about 60 s under the oracle
(2026-09-24). 500 replications of all three is about 30 hours.

---

## 9. Estimation

**Primary estimator.** Paired difference by `rep_seed` (common random numbers),
averaged across replications, with **cluster-robust standard errors at the
protocol**. Reported alongside: the same estimate with block fixed effects.
Both, always.

**Coverage validation.** A known effect of pre-specified size is injected, the
experiment is repeated across many `assign_seed`s, and the proportion of 95%
intervals covering the true effect is reported. **Coverage materially away from
95% invalidates the estimator**, and that finding is reported.

**Exactly one subgroup analysis:** the effect within titrating protocols. Any
other subgroup that is run is labelled exploratory and excluded from any claim.

---

## 10. Threats to validity

1. **It is a simulation.** The result says one forecast is better under this
   data-generating process, and the process is ours.
2. **The treatment knows the process.** The rung forecast is given the same
   titration probabilities the simulator draws from. A planner would have the
   CSP's stated probabilities, which may be wrong. §7's sensitivity measures how
   much of the effect survives a misstated `P_Miss`; it does not remove the
   concern.
3. **Informative censoring** in the time-to-event secondary: a unit that never
   stocks out is censored at the horizon, and censoring is caused by the
   treatment working. KM/Cox estimates are descriptive companions to the primary
   risk difference.
4. **Residual interference.** Protocol-level assignment removes depot sharing
   across arms. Depot capacity effects within a protocol are part of the
   treatment.
5. **Fixed nuisance parameters.** `Restart_Policy = uncapped`, `P_Revert = 0` on
   every frame ladder, `visit_window = 3`, as-of 2022-04-01, horizon 2026-12-31,
   the seeding parameters (`Seed_Buffer = 0.10`, `Seed_Lead_Days = 21`), the
   depot lots of §4, and the AT RISK rule, which does not enter any outcome.
   `Tolerance_Level` and `P_Miss` vary across protocols and are the blocking and
   sensitivity dimensions.
6. **Small protocol-level n**, with the contingency in §8.
7. **The rung forecast cannot see patients who have not enrolled.** Both arms
   rely on seeding for a cohort's start, so this is held constant, and it bounds
   what the treatment can do at a cohort's first visits.

---

## 11. What would falsify H1

- A risk difference indistinguishable from zero at 500 replications with
  adequate power.
- Stockouts fall and expired units rise by more than the stockout units avoided:
  the treatment moves the problem. Under the pre-specified reading this is a
  negative result.
- Coverage away from 95% in §9: no effect estimate from the estimator is
  reportable.

All three outcomes get written up.

---

## 12. Reproduction

```bash
Rscript tests/test_titration.R    # must all pass before any run
Rscript tests/test_seeding.R
Rscript tests/test_transit.R
Rscript tests/test_forecast.R
Rscript scripts/power_pilot.R 20   # control-arm pilot -> output/experiment/pilot.csv
Rscript scripts/power_curve.R      # power from the pilot
Rscript scripts/compare_forecasts.R 5   # the three forecasts, not randomised
# confirmatory run: script added with the results commit, not before
```

Every result row carries `rep_seed`, `assign_seed`, `arm`, `protocol`, `site`,
`du`, and the engine commit hash.

---

## History

- **2026-08-28, first freeze** at `f4c3333`. Void when site seeding landed.
- **2026-08-28, second freeze** at `e737631`. Treatment: a titration-aware
  allocation of a fixed safety-stock budget; control: a uniform 30 days. Void
  on 2026-09-24 for two reasons: the control arm ordered on the oracle forecast,
  and the engine changed (sites keyed by country, a seed per cohort drawn from
  the depot, stock in transit, lanes and disruptions). Its text is in the git
  history of this file.
- **2026-09-24, this version.** The arms became the forecast (Rafael's decision,
  2026-09-24: option (a) of `docs/remaining-work-plan-2026-09-24.md` §7). The
  safety-stock allocation question is not tested here; it could be a later
  experiment with both arms on whichever forecast wins this one.
