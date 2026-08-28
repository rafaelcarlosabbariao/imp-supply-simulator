# Product decision — dose titration, and what it cost to make it fast

**Date:** 2026-08-28
**Repo:** `imp-supply-simulator`
**Status:** decided and implemented
**Supersedes:** nothing. This is the first decision record in this repo.

---

## The decision, in one line

The demand engine models **CSP-defined dose titration** — ladders, a ratcheting
tolerance floor, missed visits that restart the window — and it does so through
a **cohort-vectorised** simulator plus an **exact forward recursion**, rather
than a per-patient loop. Restart handling is **uncapped**, deliberately.

## Why titration had to go in

The engine dispensed a constant quantity at every visit. `expand_dosing()` read
`Option1..Option6` — documented as "units dispensed" — and collapsed them to one
scalar `Qty` per (Protocol, Arm, DU), which every visit then repeated. There was
no dose state, and `Visit_Type` was hardcoded `"Planned"`, so missed visits did
not exist either.

That is not how a titrating protocol behaves, and the gap is not cosmetic. A
rung is usually a **different dispensing unit**, not a different quantity of one
— a 15 mg vial and a 100 mg bottle are separate DUs with separate lots and
separate expiry. So titration **reallocates demand across DUs**, and a patient
who misses a visit and restarts pulls the low-dose DU months after the depot
stopped forecasting for it.

The `(s, S)` reorder point keys off a **trailing average** demand rate
(`R/inventory.R:241-242`). A restart is a step change in the DU mix, and a
trailing average is precisely the estimator that lags a step change — with a
21-day lead time on top of the lag. So the engine was not merely missing
variance; it was missing a *systematic bias against the low-dose DU*, which is
the failure mode a supply manager actually gets bitten by.

## What the ladder is, and where it lives

**It lives in the schema that was already there.** Each `Dosing_Input` *row* is
a co-dispensed kit component (drug and diluent are two rows of one arm); each
`OptionJ` *column* is that component's quantity at rung *J*. A fixed-dose arm
has only `Option1` and is a ladder of length 1.

Titration **activates only for arms listed in `Titration_Input`**. An arm
without a row stays pinned to rung 1 even when several Option columns are
populated, so a stray column in a spreadsheet can never silently move a
forecast. That rule is what made this change safe to ship against existing
inputs.

Semantics, as the study lead defined them:

- The first `N` visits (usually 6) titrate: up while tolerating, hold, or down.
- A **missed visit dispenses nothing**, returns the patient to their floor, and
  **restarts the titration window**.
- The floor **ratchets** on **tolerated-once** — the patient attends *at* the
  tolerance rung and does not down-titrate. Before that, a restart goes to the
  ground; after it, to the tolerance rung.
- The tolerance rung is normally the second-to-last, occasionally the last.

## Two findings that came out of building it

### 1. The tolerance rung's effect is U-shaped, not monotone

Solving the chain exactly across the rung placement (L=6, N=6, 70/20/10,
`P_Miss` 0.15):

| tolerance rung | 1 | 2 | 3 | 4 | 5 | 6 |
|---|---|---|---|---|---|---|
| E[low-dose units/patient] | 49.8 | 43.4 | **21.6** | 22.7 | 33.2 | 43.7 |

At rung 1 the ratchet is a **no-op** — the floor already starts there — so every
restart goes to ground and low-dose exposure is maximal. At the top rung it
almost never fires before a miss knocks the patient back, so exposure climbs
again. The minimum is in the middle, where the rung is both reachable and
protective.

**A study lead who puts the tolerance dose at target to "make them prove it"
buys close to the same low-dose supply exposure as having no ratchet at all.**
That is counterintuitive, it is a direct consequence of the CSP text, and it is
invisible to a supply planner at forecast time. It is now three assertions in
`tests/test_titration.R` and a paragraph in `MODEL_THEORY.md` §2a.

Across the wider grid, the low-dose DU's share of demand swings **6.8% to
20.4%** on CSP parameters alone — a 3x range the supply organisation neither
controls nor observes. That range is the reason a uniform safety-stock rule is
worth testing against a titration-aware one.

### 2. Restarts are uncapped, on evidence

Restarts reset the titration **window**, not the visit budget, so every patient
still terminates on their cycle count or the horizon. Nothing runs away, and an
earlier worry that it might was wrong.

That left realism, so an auto-discontinue cap at `k` restarts was measured
(`P_Miss = 0.08`):

| `TOL` | k | discontinued | low-dose share | units/patient |
|---|---|---|---|---|
| 5 | 2 | 63.1% | 10.4% | 63.3 |
| 5 | 3 | 39.9% | 9.9% | 74.7 |
| 5 | ∞ | 0.0% | 9.6% | 85.2 |
| 6 | 2 | 63.1% | 12.8% | 60.0 |
| 6 | 3 | 39.9% | 12.9% | 69.9 |
| 6 | ∞ | 0.0% | 13.2% | 78.6 |

A cap of 2–3 discontinues **40–63% of the cohort** — at `P_Miss = 0.08` over 40
visits the expected miss count is ~3.2, so a low cap catches nearly everyone. No
protocol looks like that. And the cap moves total volume ~35% while moving the
**demand mix** by under a point.

**Decision: `Restart_Policy = uncapped`.** It is a nuisance parameter for any
question about the mix, so it is fixed rather than swept, and it drops
`Max_Restarts` from the input schema and one dimension from the experiment's
sensitivity grid. In the clinic this step is a human one — the study lead acts
on the site clinician's recommendation — and the simulator auto-sets it.

## The runtime decision

Titration turns the inner loop from vectorised into per-visit sequential,
because the dose at visit *t* depends on tolerance at *t−1*. Done naively that
is unaffordable inside `patients × sims × replications × arms`. Three
approaches were built and measured rather than argued about:

| 20,000 patients | seconds |
|---|---|
| A. per-patient scalar loop | 0.68 |
| B. vectorised across the cohort | 0.034 (**20x**) |
| C. exact forward recursion | 0.0006 (**684x**) |

All three agree to within Monte Carlo error (max relative difference 1.8%),
which is also how they check each other.

**Chosen: B for paths, C for the mean.** The loop runs along the axis that is
actually sequential (the visit index) and every patient advances as a vector
inside it. `expected_demand()` propagates the distribution over the ~84-state
enlarged space analytically and is **O(1) in patient count** — 1,000 patients
and 10,000,000 cost the same — which matters because `R/inventory.R:126-128`
collapses the Monte-Carlo replications to a **mean** before the `(s, S)` engine
ever sees them. The demand rate driving the reorder point was a sampling
estimate of something with a closed form.

Monte Carlo is kept where it earns its cost: a stockout is a **threshold on a
path**, and no expectation tells you how often the threshold is crossed.

Two structural fixes came with it. Output is no longer grown with
`do.call(rbind, .)`, which recopies the whole accumulated frame per call; and
more importantly the engine now emits **one frame per (arm, component)** — about
ten — instead of one per patient. And the seed moved out of
`scripts/run_simulation.R` into an argument, because a seed pinned inside the
runner makes every replication identical and destroys the between-replication
variance any experiment over this engine depends on.

Measured on the same workload, before and after:

| | before | after |
|---|---|---|
| 18,750 patients | 16.76 s | **0.27 s** |
| throughput | 35,189 rows/sec | ~2,150,000 rows/sec |
| decay with cohort size | 56k → 35k rows/sec | flat |

Row counts match the old engine within Monte Carlo noise (11,776 vs 11,776 at
one sim; 589,592 vs 589,664 at fifty), which is the evidence the rewrite is
behaviour-preserving.

**Rejected:** Rcpp — with the cohort vectorised, the inner loop already runs at
C speed through R's vectorised primitives, and there is no measured bottleneck
left for it to fix. **Deferred:** parallelism. It is the right tool for
`project_inventory()`, which is sequential in time per unit but independent
across the ~1,035 (Protocol × Site × DU) combos, and that is where the
bottleneck now sits. Algorithms first; parallelising a quadratic accumulation
would only have burned cores.

## What this unblocks

The experiment this engine exists to support: a budget-neutral A/B of a
**uniform** against a **titration-aware** safety-stock rule. Pre-registration in
[`EXPERIMENT.md`](EXPERIMENT.md).

Vectorising changed the order in which random numbers are drawn, so old seeds do
not reproduce old results. That is why this had to land **before** the
pre-registration rather than after — a pre-registration that fixes seeds is
invalidated the moment the implementation underneath it gets faster.

## Cost

About a day. Roughly a third of it was measuring things that turned out to
overturn an assumption — the U-shape, the restart cap, and a `.fast_bind`
speedup that was 3–6x rather than the ~2000x an earlier scratch benchmark had
suggested (that one had measured preallocating vectors, not concatenating
frames).
