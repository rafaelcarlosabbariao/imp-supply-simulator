# Pre-registration — does titration-aware safety stock beat a uniform rule?

**Written:** 2026-08-28
**Status:** PRE-REGISTERED. Nothing below has been run. Results, when they
exist, go in a *Results* section appended to this file — this text is not
edited afterwards.
**Implementation frozen at:** `f4c3333d7d7cf26da225e084df4434fdb3b7d987`
(2026-08-28T16:55:38-04:00)

> **Why the hash is here.** Vectorising the demand engine changed the order in
> which random numbers are drawn, so a seed does not mean the same thing before
> and after `f4c3333`. A pre-registration that fixes seeds is void the moment
> the implementation underneath it changes. If the engine is modified before the
> confirmatory run, this document is void and must be rewritten, not amended.

---

## 1. What this does and does not claim

**Claims:** an experiment-design result. Randomisation, blocking, a
pre-specified estimator, a power calculation, and an honest account of the
threats — on a question where the answer is not obvious in advance.

**Does not claim:** causal identification under confounding. The data-generating
process here is one we wrote. There is no unobserved confounding to defeat, so
nothing about propensity matching or synthetic controls is demonstrated. A
randomised experiment inside your own simulator is not an identification
strategy, and this document should never be described as one.

That limitation is also the one advantage: because the true effect is known by
construction, the estimator's **coverage can be validated against ground truth**
(§9), which no real-data study can do.

The companion item — the Supp acquisition-spend cutoff as an interrupted time
series — is what addresses identification on real data. These two are a pair,
not substitutes.

---

## 2. Motivation

The `(s, S)` reorder point sets

```
reorder_point = lead_demand + safety_stock_days × rate        # R/inventory.R:241-242
```

where `rate` is a **trailing average** daily demand. Under a titration ladder a
missed visit restarts a patient at their floor, which is a **step change in the
DU mix** — and a trailing average is precisely the estimator that lags a step
change, with a 21-day lead time on top of the lag. The lag falls hardest on the
low-dose DU, which the depot has typically stopped forecasting for by the time
restarts start pulling it.

How much demand that DU carries is not something the supply organisation
controls or observes. Across the CSP parameter grid its share of total units
swings **6.8% to 20.4%** — a 3x range driven entirely by the tolerance rung and
the missed-visit rate (`docs/titration-and-runtime-2026-08-28.md`).

So: a safety-stock rule calibrated on a demand mix that can be off by 3x on
exactly the rung most exposed to restart echo. The question is whether spending
the same safety-stock budget *differently* fixes it.

---

## 3. Hypothesis

**H1 (primary).** Reallocating a fixed portfolio safety-stock budget across
dispensing units in proportion to ladder-induced demand variability reduces the
proportion of site × DU units that experience at least one stockout, relative to
spreading the same budget uniformly.

**H0.** The two allocations produce the same stockout rate.

Direction is pre-specified; the test is two-sided.

---

## 4. Arms

Both arms hold the **same total days of safety stock across the portfolio**.
This is the load-bearing design choice: a treatment that simply holds more stock
everywhere would of course win, and the result would be uninteresting and
confounded. Budget neutrality isolates *targeting* from *quantity*.

**Control — uniform.** `safety_stock_days = 30` for every (Protocol, Site, DU),
which is the current shipped rule.

**Treatment — titration-aware.** For each (Protocol, DU),

```
ss_days(DU) = 30 × (1 + κ · [CV(DU) − CV̄]) ,   κ pre-set so that
Σ ss_days(DU) · rate(DU)  ==  Σ 30 · rate(DU)
```

where `CV(DU)` is the coefficient of variation of per-patient total units for
that DU under its arm's ladder, computed from `expected_demand()` on the
*planned* ladder — i.e. from information a supply planner genuinely has before
the study runs, not from the realised demand. `κ` is fixed at 1.0 and is not
tuned; the normalisation solves for budget neutrality exactly.

Everything else is identical between arms: `lead_time_days = 21`,
`target_days = 90`, `unplanned_visit_pct = 0.10`, `oversupply_pct = 0.10`,
`enable_resupply = TRUE`, same horizon, same starting inventory.

**One lever moves.** Two would make this uninterpretable.

---

## 5. Unit of randomisation, and the interference problem

**Randomisation is at the PROTOCOL level.** Sites are the nested observation
level.

This is not the obvious choice — site is the larger *n* — and it is forced by
the engine. `R/inventory.R:160` maintains **one depot pool per Protocol × DU,
shared by every site in that protocol.** Randomising sites within a protocol
would let a treated site draw the depot down and starve a control site: the
control site's outcome would depend on its neighbour's assignment, which is an
interference (SUTVA) violation and would bias the contrast in an unknown
direction.

Protocol-level assignment puts the shared depot entirely inside one arm. It is
also the level at which a supply lead actually sets a resupply rule, so the
estimand is policy-relevant rather than an artefact of the analysis.

**Cost, stated up front:** the frame carries **23 protocols** (the Ongoing and
Planning trials in REINS `Trial.csv`, after removing the 3 Completed and 1 On
Hold, and after resolving the duplicated `ONC-001`). That is a small *n*, and it
is the binding constraint on power. See §8.

---

## 6. Assignment mechanism

Blocked randomisation, 1:1 within block. Blocks are

**titrating / fixed-dose × tercile of baseline expected daily demand.**

Titration status is the dominant effect modifier and demand rate dominates
stockout risk, so blocking on both buys precision cheaply. Block membership is
computed from the planned ladder and the enrolment plan **before** assignment.

A **balance table** on pre-treatment covariates — start on-hand, expected daily
demand, expiry headroom, country lead time, ladder depth — is reported with the
result regardless of what it shows.

**Common random numbers.** The treatment is a *supply* policy; demand does not
depend on it. Demand is therefore simulated **once per `rep_seed`** and both arms
are projected against the identical realisation. This is a paired design: it
removes demand variance from the contrast, and it halves the compute. Assignment
uses a separate `assign_seed`, re-drawn each replication. Both seeds are logged
on every row.

---

## 7. Outcomes

**Primary.** Proportion of site × DU units within a protocol experiencing at
least one stockout over the horizon (`Status == "STOCKOUT"`, equivalently
`First_Stockout` non-missing). Estimand: the **risk difference**, treatment
minus control.

**Secondary**, all pre-specified, none promotable to primary:

1. Total stockout units (`Total_Stockout`). Heavy mass at zero, so reported as
   both a mean difference and a difference in the 90th percentile.
2. Days to first stockout — Kaplan–Meier with a Cox model, **censored at the
   horizon**. Censoring is informative here and is discussed in §10.
3. `Total_Expired`. **The cost side, and it is not optional.** More safety stock
   trades stockouts for expiry; a result that reports only the win is not a
   result. If the treatment reduces stockouts while increasing expiry, both
   numbers are reported with equal prominence and the trade is stated in units.
4. `Reorders` and `Total_Reordered` — shipment count, the operational cost.

---

## 8. Sample size and power

`R = 500` replications, fixed in advance. **No interim analyses and no optional
stopping.** The result is read once, after 500.

Power is computed **before** the confirmatory run, under the **titration**
data-generating process — not the fixed-dose one, which would be optimistic
because titration adds a large per-patient variance component. The power curve
(protocols × effect size → power at α = 0.05) is generated from this same engine
and committed alongside this file before any confirmatory run begins.

**Minimum detectable effect, pre-specified:** a **5 percentage point** absolute
reduction in the site × DU stockout rate, at 80% power, α = 0.05, two-sided.

**Pre-registered contingency.** If the power calculation shows < 80% power for
that MDE at 23 protocols, the frame is expanded by generating additional
synthetic protocols from the REINS phase / therapeutic-area / site-count
distribution, up to whatever *n* reaches 80%. That decision is recorded here,
*before* any outcome is seen, precisely so it cannot be made afterwards in
response to a disappointing p-value. The expanded frame's size is reported.

---

## 9. Estimation

**Primary estimator.** Paired difference by `rep_seed` (common random numbers),
averaged across replications, with **cluster-robust standard errors at the
protocol**. Reported alongside: the same estimate with block fixed effects.
Both, always — not whichever is smaller.

**Coverage validation.** The DGP is known, so the estimator can be audited
against ground truth in a way real data never permits. A known effect of
pre-specified size is injected, the entire experiment is repeated across many
`assign_seed`s, and the proportion of 95% intervals covering the true effect is
reported. **Coverage materially away from 95% invalidates the estimator, and
that finding is reported whether or not it is convenient.**

**Exactly one subgroup analysis:** the effect within titrating protocols. One
named subgroup is defensible; three is fishing. No others will be run, and if
one is run anyway it will be labelled exploratory and excluded from any claim.

---

## 10. Threats to validity

1. **It is a simulation.** No external validity beyond the modelled mechanism.
   The result says a rule is better *under this DGP*, and the DGP is ours. §9's
   coverage check addresses estimator correctness, not realism.
2. **Shared machinery between treatment and outcome.** The treatment is defined
   from `expected_demand()`, and the outcome is produced by the inventory engine
   whose reorder point uses a trailing average of the same demand. The
   comparison is fair — both arms face the same engine — but the treatment is
   "informed by the model that generates the outcome", and that is a weaker
   claim than "informed by data a planner could collect". Stated, not hidden.
3. **Informative censoring** in the time-to-event secondary: a unit that never
   stocks out is censored at the horizon, and censoring is *caused by* the
   treatment working. The KM/Cox estimates are therefore reported as descriptive
   companions to the primary risk difference, never as the headline.
4. **Residual interference.** Protocol-level assignment removes depot sharing
   across arms. It does not remove *depot capacity* effects within a protocol,
   which are part of the treatment and intended.
5. **Fixed nuisance parameters.** `Restart_Policy = uncapped`,
   `lead_time_days = 21`, `visit_window = 3`, horizon 2026-12-31, planning
   as-of 2024-01-01. The restart policy is fixed on measured evidence
   (`docs/titration-and-runtime-2026-08-28.md`): a cap moves total volume ~35%
   but the demand *mix* by under a point, so it is a nuisance parameter for this
   question. `Tolerance_Level` and `P_Miss` are **not** fixed — they are the
   blocking and sensitivity dimensions.
6. **Small protocol-level n.** Acknowledged in §8 with a contingency decided in
   advance.

---

## 11. What would falsify H1

- Risk difference indistinguishable from zero at 500 replications with adequate
  power: the uniform rule is not improved on by reallocation, and the trailing
  average's lag is not costly enough to be worth targeting.
- Stockouts fall but expired units rise by more than the stockouts avoided, in
  units: the treatment moves the problem rather than solving it. Under the
  pre-specified reading **this is a negative result**, not a qualified positive.
- Coverage away from 95% in §9: the estimator is wrong and no effect estimate
  from it is reportable.

All three outcomes get written up. A pre-registration whose null result would go
unpublished is not doing any work.

---

## 12. Reproduction

```bash
Rscript tests/test_titration.R    # 29 checks, must pass before any run
Rscript tests/benchmark.R         # runtime baseline
# confirmatory run — script added with the results commit, not before
```

Every result row carries `rep_seed`, `assign_seed`, `arm`, `protocol`, `site`,
`du`, and the engine commit hash.
