# Pre-registration — does a forecast that counts patients by dose beat a trailing average?

**Written:** 2026-09-24 (fourth version; see *History* at the end)
**Status:** PRE-REGISTERED. Nothing below has been run as a confirmatory
experiment. Results, when they exist, go in a *Results* section appended to
this file; the text above it is not edited afterwards.
**Implementation frozen at:** `9d0e8ce7f8dc58fc25e5cead09af815277f0e227`
(2026-09-24)

> **The rule.** A seed means something only for one implementation, because
> any change to the engine can change the order in which random numbers are
> drawn. If the engine (`R/`), `scripts/experiment_setup.R`,
> `scripts/build_frame.R` or the frame's inputs change before the confirmatory
> run, this document is void and is rewritten, not amended.

---

## 1. What this does and does not claim

**Claims:** a paired simulation experiment with a pre-specified estimator, a
power calculation, a rule for the number of protocols and replications, and an
account of the threats.

**Does not claim:** causal identification under confounding. The
data-generating process is one we wrote. Both forecasts are run on every
protocol against the same simulated demand, so the comparison needs no
randomisation and demonstrates none.

The companion item, the Supp acquisition-spend cutoff as an interrupted time
series, is the one that addresses identification on real data.

---

## 2. Motivation

The `(s, S)` reorder rule (`R/inventory.R`, METHODOLOGY §2.4) orders when the
usable stock a site holds and has on order falls below

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

On five replications of the 18-protocol frame at `ce00c79`
(`scripts/compare_forecasts.R`, METHODOLOGY §2.4b), titrating protocols stocked
out on 73% of their site × DUs under the trailing forecast and 12% under the
rung forecast; fixed-dose protocols on 9% and 0.3%. Those numbers have been
seen. The question is whether the difference holds across protocols drawn from
this population, and what it costs in expired stock.

---

## 3. Hypothesis

**H1 (primary).** Ordering on the rung forecast reduces the proportion of
site × DU units that experience at least one stockout, relative to ordering on
the trailing forecast.

**H0.** The mean within-protocol difference is zero.

Direction is pre-specified; the test is two-sided.

---

## 4. Arms

**Control: trailing.** `forecast = "trailing"`, `trailing_window_days = 60`.

**Treatment: rung.** `forecast = "rung"`, given the protocol's visit stream with
its enrollment records and the ladders built from its own dosing schedule and
titration spec.

**One lever moves.** Everything else is identical between arms:
`safety_stock_days = 30`, `target_days = 90`, `lead_time_days = 21`,
`unplanned_visit_pct = 0.10`, `oversupply_pct = 0.10`,
`min_shelf_life_days = 30`, `enable_resupply = TRUE`, the horizon, the seeds and
the depot.

**The oracle** (`forecast = "oracle"`) is run on the first 10 replications and
reported as a ceiling. It is not an arm and enters no test.

### Held constant across arms

- **Site seeding.** Every cohort at every site is seeded by `seed_sites()`,
  landing 21 days before the cohort's enrollment (visit 0), drawn from the depot
  and topped up against what the site holds (METHODOLOGY §2.1a). Sites start
  empty (`opening = "seeded"`) and the as-of date, 2022-04-01, precedes every
  seed's ship date.
- **The depot.** Per Protocol × DU, 3× the study's expected demand
  (`expected_demand()` on the planned ladder), split into four equal lots
  expiring 24, 36, 48 and 60 months after the as-of date, never restocked.
  With lots that can expire, seed stock at a site that seldom dispenses a DU
  (the low-dose DU a restart pulls) expires, and a forecast that sees no recent
  demand for that DU does not replace it. That is a property of the forecasts
  under test and stays in.

---

## 5. Design: every protocol under both arms

Each protocol is simulated once per replication and walked twice on that one
realisation, once per arm (`run_protocol()` in `scripts/experiment_setup.R`).
The protocol is its own control.

**Why not randomise protocols to arms.** The previous version did, and its
power rested on how much the *level* of stockouts varies between protocols
(between-protocol SD 0.38). Running both arms on every protocol removes the
level and leaves only how much the *effect* varies. In a simulation both arms
can be run on the same demand at no cost to validity; a randomised allocation
would discard half of each protocol's information.

**Interference.** Each walk runs one arm for all of a protocol's sites, and
protocols share no depot, so no site's outcome depends on another protocol's
arm.

**Seeds.** A protocol's demand in replication `r` is seeded with
`rep_seed × 1000 + i`, where `rep_seed = 1000 + r` and `i` is the protocol's row
in `frame.csv`. Its demand is therefore the same whichever other protocols are
in the frame and however the work is split across processes.

**The frame.** The 18-protocol frame (`datasets/frame/`, built by
`scripts/build_frame.R` from REINS: 9 titrating, 689 sites, 43,440 planned
patients), expanded under §8 if the power calculation requires it. An expanded
frame keeps the 18 real protocols and adds synthetic ones, each resampled from a
real protocol and varied: site count and enrollment by a lognormal factor
(SD 0.25 on the log scale), duration by one with SD 0.20, start 0–180 days
later, and titration parameters (`P_Miss`, `Tolerance_Level`) assigned by the
same rule as the real rows. `frame.csv` records each protocol's donor.

---

## 6. Strata

Protocols are stratified by **titration status**, which is fixed before any run
(a protocol titrates if it is Oncology or Phase I). The comparison at `ce00c79`
showed the effect near −0.61 on titrating protocols and −0.09 on fixed-dose
ones; pooling them would put that gap into the error term.

A table of pre-treatment covariates by stratum (sites, planned patients, cycle
length, `P_Miss`, `Tolerance_Level`, real or synthetic) is reported with the
result.

---

## 7. Outcomes

**Primary.** The proportion of a protocol's site × DU units with at least one
stockout over the horizon (`Status == "STOCKOUT"`). Per protocol, the
difference `d_p` = rung − trailing, averaged over replications.

**Secondary**, pre-specified, none promotable to primary:

1. Total stockout units (`Total_Stockout`), as a mean difference and as a
   difference in the 90th percentile over protocols.
2. `Total_Expired`, the cost side. If the treatment reduces stockouts and
   increases expiry, both are reported with equal prominence and the trade is
   stated in units.
3. `Reorders`, the shipping cost.
4. The effect within titrating protocols and within fixed-dose protocols (the
   two strata).

**Pre-specified sensitivity, not a test.** The rung forecast is given the true
titration probabilities (§10.2). On the first 10 replications the treatment arm
is re-run with the forecast's ladders misstated, `P_Miss` halved and `P_Miss`
doubled (capped at 0.5), with demand unchanged. The primary difference is
reported for each.

---

## 8. Sample size and power

**Pilot.** `scripts/power_pilot.R`, 20 replications of both arms on the
18-protocol frame at the frozen implementation, before any confirmatory run.
`scripts/power_curve.R` computes from it the within-stratum between-protocol
variance of `d_p` and the within-protocol variance per replication.

**Minimum detectable effect, pre-specified:** a **5 percentage point** absolute
reduction in the stockout proportion, at 80% power, α = 0.05, two-sided, for the
stratified estimator of §9.

**Replications.** `R` is the smallest of 50, 100, 200 and 500 at which the
replication noise in a protocol's mean difference is under 5% of its variance,
as computed by `power_curve.R` from the pilot. No interim analyses and no
optional stopping: the result is read once, after `R`.

**Protocols (contingency).** If power at 18 protocols is under 80%, the frame is
expanded with `scripts/build_frame.R <reins> datasets/frame_expanded <n>` to the
`n` that `power_curve.R` reports for 80% (its `EXPAND_TO` line), before the
confirmatory run. The 5pp MDE is not restated. A reading from the comparison
already seen, not a pilot, put that `n` near 92.

**Compute, estimated.** 18 protocols take about 115 s per replication for both
arms on 4 workers. A 92-protocol frame (about 174,000 planned patients) would
take roughly 8–10 minutes per replication, so about 7–8 hours for R = 50.

---

## 9. Estimation

**Primary estimator.** The mean of `d_p` over protocols, computed within each
stratum and combined weighted by the stratum's share of protocols. Its standard
error combines the within-stratum variances of `d_p`; the test is a t test with
`n − 2` degrees of freedom. Reported alongside: the unstratified mean with its
standard error.

**Clustering by donor.** Synthetic protocols share a donor with a real one and
may resemble it. The standard error is also reported clustered on `donor`
(18 clusters). If the two standard errors differ by more than 25%, both are
stated in the headline, not only the smaller.

**Interval check.** From the confirmatory results, 2,000 stratified subsamples
of half the protocols are drawn; for each, the 95% interval is computed, and
the share of intervals covering the full-frame estimate is reported. A share
outside 92–98% means the interval is not reported as a 95% confidence interval.

---

## 10. Threats to validity

1. **It is a simulation.** The result says one forecast is better under this
   data-generating process, and the process is ours.
2. **The treatment knows the process.** The rung forecast is given the same
   titration probabilities the simulator draws from. §7's sensitivity measures
   how much of the effect survives a misstated `P_Miss`; it does not remove the
   concern.
3. **The population is the generator.** Synthetic protocols are varied
   resamples of 18 real ones. A claim about "protocols from this population" is
   a claim about that generator, and the donor-clustered standard error (§9) is
   the check on how much the synthetic rows add beyond their donors.
4. **Fixed nuisance parameters.** `Restart_Policy = uncapped`, `P_Revert = 0` on
   every frame ladder, `visit_window = 3`, as-of 2022-04-01, horizon 2026-12-31,
   the seeding parameters (`Seed_Buffer = 0.10`, `Seed_Lead_Days = 21`), the
   depot lots of §4, and every site in the USA on one lane. `Tolerance_Level` and
   `P_Miss` vary across protocols.
5. **The rung forecast cannot see patients who have not enrolled.** Both arms
   rely on seeding for a cohort's start, so this is held constant, and it bounds
   what the treatment can do at a cohort's first visits.
6. **The effect was seen before this design was chosen.** The unrandomised
   comparison (§2) was run before this version was written, and the move to a
   paired design was made after seeing that the randomised one could not reach
   power. The MDE, the estimator and the expansion rule are fixed here and are
   not tuned to the seen effect.

---

## 11. What would falsify H1

- A stratified mean difference indistinguishable from zero with adequate power.
- Stockouts fall and expired units rise by more than the stockout units avoided:
  the treatment moves the problem. Under the pre-specified reading this is a
  negative result.
- A donor-clustered standard error large enough to make the effect
  indistinguishable from zero: the effect does not generalise past the 18 real
  protocols' designs.

All three outcomes get written up.

---

## 12. Reproduction

```bash
Rscript tests/test_titration.R    # must all pass before any run
Rscript tests/test_seeding.R
Rscript tests/test_transit.R
Rscript tests/test_forecast.R
WORKERS=4 Rscript scripts/power_pilot.R 20   # both arms -> output/experiment/pilot.csv
Rscript scripts/power_curve.R                # power, R, and the frame size
Rscript scripts/build_frame.R ~/reins/app/data datasets/frame_expanded <n>   # if §8 requires
# confirmatory run: script added with the results commit, not before
```

Every result row carries `rep_seed`, `protocol`, `donor`, `forecast`, and the
engine commit hash.

---

## History

- **2026-08-28, first freeze** at `f4c3333`. Void when site seeding landed.
- **2026-08-28, second freeze** at `e737631`. A titration-aware allocation of a
  fixed safety-stock budget against a uniform 30 days. Void on 2026-09-24: the
  control arm ordered on the oracle forecast, and the engine changed.
- **2026-09-24, third freeze** at `ce00c79`. Rung against trailing, protocols
  randomised to arms in four blocks. Its power calculation (20-replication
  control pilot): between-protocol SD of the stockout proportion 0.38 (0.21
  within titration status), power 0.075 for the 5pp MDE at 18 protocols, 574
  protocols needed. The pre-registered contingency, expanding to 574 protocols
  at 500 replications, was beyond the available compute.
- **2026-09-24, this version.** Rafael chose, the same day, to run every
  protocol under both arms instead of randomising. The harness changed to run
  protocols one at a time (`9d0e8ce`), so this version is frozen there. The
  earlier texts are in the git history of this file.
