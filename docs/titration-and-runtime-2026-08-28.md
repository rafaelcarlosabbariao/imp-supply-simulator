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

---

# Addendum — initial site stocking

**Same day, separate decision.** Raised by the study lead: studies are enacted
in **cohorts**, so a site is activated and shipped an initial supply *before*
its first patient visit. The engine had no such concept — starting on-hand was
whatever `datasets/site_inventory.csv` said, with no stated relationship to how
many patients the site was about to see.

## The decision

`seed_sites()` (`R/seeding.R`) derives the startup shipment: stock each site for
`Seed_Patients` patients through their first `Seed_Visits` visits, landing
`Seed_Lead_Days` before that site's first patient visit. `Seed_Visits` defaults
to `ceil(lead_time / cadence) + 1` — enough to survive until the first reorder
can physically arrive, which ties the seed to the constraint that governs it
rather than to a round number. Quantities come from `expected_demand()`
truncated to the seed window, so they are exact and cost nothing to compute.

**Opt-in.** Absent a `Seed_Patients` argument the runner behaves exactly as
before, so the shipped sample and its committed figures are unchanged.

## The finding this exposed

Every patient starts on rung 1. So a titrating arm's first visits are dominated
by the **low-dose** DU in a proportion nothing like its share of the study.
On the worked example:

| DU | seed-window share | study share | ratio |
|---|---|---|---|
| Compound-C 25 mg (low) | 56.9% | 19.4% | **2.94** |
| Compound-C 100 mg (high) | 0.0% | 40.4% | **0.00** |
| any DU on a fixed-dose arm | — | — | **1.00** |

Seeding that site off study-average demand ships **zero units of the DU that is
40% of the study** — correctly, since nobody can be on rung 3 yet — while
under-shipping the low-dose DU roughly three-fold. The fixed-dose arms sitting
at exactly 1.00 are the control that says this is the ladder's doing and not an
artefact.

**This is a second and distinct mechanism.** The restart echo bites in the
middle of a study, when a trailing average exists and lags. This bites at day
zero, when there is no history at all and the first resupply is a lead time
away. `seed_mix_check()` reports the ratio per DU so a planner can see which
DUs a study-average rule gets wrong before shipping anything.

## Implementation note

The engine already had a per-site in-transit queue (`it_arrive` / `it_q` /
`it_e`) that reorders push onto and the daily walk drains. Seed shipments join
that same queue, so the day loop needed no special case — the mechanism existed,
it just was not exposed as an input. A shipment dated before the planning as-of
date has already landed and is folded into opening on-hand rather than being
silently dropped by a loop that starts after it.

## Two bugs the tests caught

- `seed_sites()` emitted **zero-quantity shipment lines** for DUs the seed
  window does not reach. Filtering them is the whole point of seeding off the
  ladder rather than off study-average demand.
- A titration spec naming an arm whose dosing rows carry only `Option1` failed
  with "Tolerance_Level 5 is outside the ladder (1..1)", which is correct but
  says nothing about the cause. The message now names it: the arm has one
  populated Option column, so either populate `Option2..OptionN` or drop it from
  `Titration_Input`.

## Effect on the experiment

Seeding is **held constant across arms** — both get ladder-derived seeding — so
the contrast still isolates the reorder rule. Ladder-derived seeding is correct
forecasting of the first *k* visits, not a policy choice, and giving the control
arm a naive seed would confound the treatment effect with a startup effect.
Seeding as a *second factor* (a 2x2 with the reorder rule) is a real experiment
and is noted in `EXPERIMENT.md` as a pre-specified extension, deliberately not
folded into this one.

## Follow-up, 2026-09-24 — seeding by cohort

The review of 2026-09-23 found four defects in the seeding described above, and
`docs/seeding-by-cohort-plan-2026-09-24.md` records the fix. Sites are keyed by
center and country (a center number repeats across countries). Every cohort
gets its own seed, dated to its visit 0; before, a site was seeded once for
every patient it would ever enrol and the stock expired before later cohorts
opened. A seed ships from the depot on its ship date, topped up against what the
site holds. A seed shipped before the as-of date is dropped when a site snapshot
is given, where before it was counted on top of the snapshot.

The mix finding above is unchanged. It comes from the ladder, and the ladder
did not change.
