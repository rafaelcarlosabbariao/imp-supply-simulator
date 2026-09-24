# Methodology — IMP Demand & Supply Model

This document explains, in detail, how the model turns an enrollment plan and a
dosing schedule into a demand forecast, and how it projects inventory forward to
catch stockouts. It covers the math, the assumptions, and the limitations.

The implementation lives in two modules:

- `R/simulation.R` — **demand** (enrollment → visits → dispensing)
- `R/inventory.R` — **supply** (inventory projection, resupply, expiry)

Both are pure functions with no Shiny dependency, so the app, the notebook, and
the headless runner all share exactly one implementation.

---

## 1. Demand model

### 1.1 Inputs

- **Enrollment plan** — one row per `(Protocol, Cohort, Arm, Country, Center)`
  giving `Patients` and an enrollment window `[Enroll_Start, Enroll_End]`.
- **Dosing schedule** — one row per `(Protocol, Arm, DU_Description)` giving the
  number of `Cycles`, the `Cycle_Length` (days), and the quantity dispensed per
  visit (`Option1…Option6`; the first non-empty option is used, or a chosen
  option index).

### 1.2 Enrollment simulation (`simulate_enrollment`)

For each enrollment row and each Monte-Carlo trial `i = 1…N`:

- Create `Patients` subjects.
- Draw each subject's enrollment date **uniformly at random** from the day
  sequence `[Enroll_Start, Enroll_End]` (with replacement).
- Emit an enrollment record (visit 0) per subject.

Running `N` trials yields `N` independent realizations of *when* patients arrive,
capturing enrollment-timing uncertainty. Subject IDs (`SSID`) are assigned per
site and trial.

### 1.3 Visit / dispensing simulation (`simulate_visits`)

Each enrolled subject is stepped forward from their enrollment date until the
simulation horizon or until all their DUs run out of cycles:

- **Cadence** = the longest `Cycle_Length` among the DUs in the subject's arm.
- Each visit date = previous date + cadence + a uniform **visit-window** jitter
  `∈ [−w, +w]` days.
- At each visit, **every DU with cycles remaining** is dispensed at the
  quantity for the subject's current **dose rung**, and that DU's
  remaining-cycle counter decrements. Without a titration ladder every subject
  sits on rung 1 for the whole study, which is the fixed-dose behaviour.

**Dose rungs.** In `Dosing_Input`, each *row* is a co-dispensed kit component
(drug and diluent are two rows of one arm) and each `OptionJ` *column* is that
component's quantity at rung `J`. An arm titrates only if it has a row in
`Titration_Input`; otherwise it is pinned to rung 1 even when several Option
columns are populated, so a stray column in a sheet can never silently move a
forecast. Rungs, the ratchet and the restart rule are set out in
[`MODEL_THEORY.md` §2a](MODEL_THEORY.md).

| `Titration_Input` column | Meaning |
|---|---|
| `Protocol`, `Arm` | joins to `Dosing_Input` |
| `Titration_Visits` | `N`, the length of the titration window |
| `P_Up`, `P_Stay`, `P_Down` | per-visit transitions, conditional on attending; validated to sum to 1 |
| `P_Miss` | per-visit probability of a missed visit |
| `Tolerance_Level` | the ratchet rung; defaults to the second-to-last |
| `Restart_Policy` | `uncapped` — see below |

**Restarts are uncapped, by design.** A restart resets the titration *window*,
not the visit budget, so every patient still terminates on their cycle count or
the horizon and nothing runs away. Auto-discontinuing after `k` restarts was
measured and rejected: at `P_Miss = 0.08`, a cap of 2–3 discontinues 40–63% of
the cohort and swings total volume ~35%, while moving the low-dose DU's share
of demand by under a point. It is a nuisance parameter for any question about
the demand *mix*. In the clinic this step is a human one — the study lead acts
on the site clinician's recommendation — and the simulator auto-sets it.

**`expected_demand()`** solves the same ladder exactly by forward recursion, with
no Monte Carlo and in O(1) time regardless of patient count. Use it for the
reorder-point rate; use simulated paths for stockout risk.

The result is a per-subject stream of `(Protocol, Site, DU, Date, Qty, Trial)`
dispensing events.

> **Fix vs. the original prototype.** The original `simulateVisits` (a) never
> recorded a dispensed *quantity* — so demand could not be converted to units —
> and (b) contained a `max(DU_list, FUN = …)` call that is not valid R and threw
> whenever an arm mixed cycle lengths. Both are corrected here: quantity is
> tracked, and the cadence is simply the arm's longest cycle length.

### 1.4 Demand aggregation (`compute_demand`)

Dispensing events are summed to **units per `(Protocol, Site, DU, Date, Trial)`**.
Downstream, the supply model reduces across trials to an expected daily demand.

---

## 2. Supply model (`project_inventory`)

The supply engine answers: *given what is on the shelf today, when and where does
each site run out, and how much should be shipped to prevent it?*

### 2.1 Expected demand

For each `(Protocol, Site, DU, Date)` it computes

```
expected_units(day) = (Σ units over trials / N_trials) × (1 + unplanned_visit_pct)
```

i.e. the mean daily demand across Monte-Carlo trials, uplifted for unplanned
(unscheduled) visits.

### 2.1a Initial site stocking (`seed_sites`)

A site cannot dispense to its first patient out of an empty cupboard. Studies
run in **cohorts**: a site is activated, an initial shipment is sent, and only
then does the first patient walk in. Starting on-hand used to be an arbitrary
given (`datasets/site_inventory.csv`) with no stated relationship to how many
patients the site was about to see.

`seed_sites()` derives it. **Each cohort at each site** (Protocol × Site × Arm ×
Cohort, where a site is a center in a country) is stocked for `Seed_Patients`
patients through their first `Seed_Visits` dispensing visits, and the shipment
lands `Seed_Lead_Days` **before the cohort's enrollment start**. Enrollment is
visit 0: the patient is entered into the database and nothing is dispensed; the
first dispense is one cycle later. Quantities come from `expected_demand()`
truncated to the seed window, so they are exact and need no simulation.

Until 2026-09-24 a site was seeded once, for every patient it would ever enrol,
dated to its first cohort. TRIAL-201 site 1001 was shipped 519 vials in February
2023 for five cohorts running to December 2027; they expired in February 2025,
before its last two cohorts (114 patients) enrolled.

| Parameter | Default | Meaning |
|---|---|---|
| `Seed_Patients` | the whole cohort | patients to stock for, capped by the cohort's planned enrolment |
| `Seed_Visits` | enough to outlast one lead time | dispensing visits of cover |
| `Seed_Buffer` | 0.10 | proportional over-ship |
| `Seed_Lead_Days` | 21 | days before the cohort's visit 0 that the shipment lands |
| `Seed_Shelf_Life` | 730 | retest for a seed with no depot to ship from |

`Seed_Visits` defaults to `ceil(Seed_Lead_Days / cadence) + 1` — stock the site
so it survives until the first reorder can physically arrive. That ties the seed
to the constraint that actually governs it rather than to a round number.

**A seed is a scheduled shipment.** On its ship date (arrival less the site's
lane lead time, §2.6) the walk tops it up and draws it from the depot:

- **Top-up.** It ships `max(0, planned − (on hand + on order))` of each DU. A
  later cohort at an open site usually holds stock from resupply, and shipping a
  full seed on top would overstock it. A new site holds nothing and gets the
  whole seed.
- **From the depot.** The quantity is drawn FEFO from the depot pool, so each lot
  keeps its real expiry, and a short depot records `Seed_Short`. With no depot
  stock listed for that protocol × DU, the seed is supplied from outside and
  takes `Seed_Shelf_Life`.
- **Before the reorder.** Seeds are processed before the day's reorder decision
  and are kept out of `Reorders` and `Reorder_Qty`.

**Seeds dated before the as-of date** depend on the `opening` mode (§2.2).

**Why the ladder makes this matter.** Every patient starts on rung 1, so a
titrating arm's first visits are dominated by the *low-dose* DU in a proportion
nothing like that DU's share of the study. On the worked example
(`datasets/example_titration/`), over the seed window:

| DU | seed-window share | study share | ratio |
|---|---|---|---|
| Compound-C 25 mg (low) | 56.9% | 19.4% | **2.94** |
| Compound-C 100 mg (high) | 0.0% | 40.4% | **0.00** |
| every DU on a fixed-dose arm | — | — | 1.00 |

Seed that site off study-average demand and you ship **zero units of the DU that
is 40% of the study** — which is correct, nobody can be on rung 3 yet — while
under-shipping the low-dose DU roughly three-fold. And this bites at day zero,
when the `(s,S)` rate has no history to lean on and the first resupply is a lead
time away. `seed_mix_check()` reports this ratio per DU; a value far from 1 is a
DU a study-average rule gets wrong.

This is a *separate* mechanism from the restart echo in §1.3. The restart echo
bites in the middle of a study; this bites at the start.

### 2.2 Planning horizon and the "as-of" date

Inventory on hand is *current as of* a planning date (`start_date`). The model
projects from that date forward to `horizon_end`; demand **before** the as-of
date is historical and is not consumed against current stock (you cannot
resupply the past). This is a key correctness point — projecting current stock
against already-elapsed demand produces meaningless day-one stockouts.

`opening` states what the position at the as-of date is made of:

| `opening` | Used when | Seed landed before as-of | Seed on the road at as-of | Seed ships on or after as-of |
|---|---|---|---|---|
| `snapshot` (default with a site inventory) | the app, `run_simulation.R` | dropped: the snapshot counts it | dropped: the in-transit input (§2.6) records it | shipped in the walk |
| `seeded` (default with none) | `power_pilot.R`, the tests | folded into opening on-hand | lands on its date, no depot draw | shipped in the walk |

Before 2026-09-24 a landed seed was folded in even with a snapshot, so a site
open before the as-of date had its stock counted twice. In `seeded` mode the
engine warns when a seed shipped before the as-of date, since the demand before
it is not simulated; set the as-of date on or before the earliest ship date.

### 2.3 Lots, FEFO, and expiry

On-hand stock is tracked as **lots** `(quantity, expiry)` at each site, and as a
shared **depot** pool per `(Protocol, DU)`.

Each simulated day, per site:

1. **Expire** — lots whose expiry (retest date) `≤ today` are removed and
   counted as `Expired` (they are *not* available to dispense). Depot stock
   expires the same way.
2. **Receive** — shipments scheduled to arrive today (seeds, reorders and stock
   that was on the road at the as-of date) are added to the site's lots, each
   keeping its own real expiry.
3. **Dispense** — the day's expected demand is consumed **first-expiry-first-out**.
   Any unmet demand is recorded as `Stockout_Units` and on-hand floors at zero.
4. **Seed** — any cohort seed due to ship today, topped up (§2.1a).
5. **Reorder** — see the policy below.

### 2.4 Resupply policy — forward-coverage order-up-to (s, S)

At each site on each day the policy asks a forecast for the demand expected
over the lead time and over the coverage window after it (`R/forecast.R`):

```
lead_demand      = forecast demand over the next  lead_time            days
coverage_demand  = forecast demand over the following  target          days (after lead)
rate             = mean daily forecast demand over the (lead + target) window
safety_stock     = safety_stock_days × rate
reorder_point    = lead_demand + safety_stock            # in inventory-position units
order_up_to (S)  = (lead_demand + coverage_demand + safety_stock) × (1 + oversupply_pct)
inventory_position = on_hand + on_order
```

If `inventory_position < reorder_point`, an order for `ceil(S − position)` units
is placed. It is pulled from the depot pool (FEFO, respecting depot lot expiry),
each shipped lot carrying its own expiry, and arrives after `lead_time` days. If
the depot cannot fully cover the order, the shortfall is recorded
(`Depot_Shortfall`).

This is a standard MRP-style forward-coverage `(s, S)` policy: `s` = reorder
point, `S` = order-up-to level, both demand-driven and time-varying.

**The forecast** is one of three modes, set by `forecast =`:

| Mode | What the planner is assumed to know |
|---|---|
| `trailing` (default) | The site × DU's dispensing over the last `trailing_window_days` (60), including the days before the as-of date, averaged and projected flat. |
| `rung` | The patients enrolled at the site, each at their dose, their titration status and their visit number, projected forward through the protocol's titration probabilities (§2.4a). |
| `oracle` | The demand the simulation goes on to produce. Perfect foresight, run only as a ceiling to score the other two against. |

Until 2026-09-24 the default was `oracle`, so every status the app, the runner and
the showcase reported assumed the planner knew future demand. On the sample
(as-of 2024-01-01, 5 trials) the switch to `trailing` moves the at-risk count
from 15 to 18 of 30 site × DUs and leaves stockouts at 0. `$summary` carries a
`Forecast` column naming the mode each row was run under.

### 2.5 Outputs

**Daily** — one row per `(Protocol, Site, DU, Date)`:
`On_Hand_Start, Received, Dispensed, Expired, Stockout_Units, On_Hand_End,
On_Order, Reorder_Qty, Depot_Shortfall, Days_Of_Supply`
(`Days_Of_Supply = on_hand / forward daily rate`).

**Summary** — one row per `(Protocol, Site, DU)` with totals, the minimum
days-of-supply, the **first stockout date**, and a status:

| Status | Condition |
|---|---|
| `STOCKOUT` | at least one day with unmet demand |
| `AT RISK` | never stocks out, but min days-of-supply < `safety_stock_days` |
| `OK` | otherwise |

**Portfolio** (`portfolio_summary`) — rolls the summary up by study and overall:
counts of STOCKOUT / AT RISK / OK, earliest stockout per study, total expired.

The daily table also carries `Seed_Shipped` and `Seed_Short`, and the summary
`Total_Seeded`.

**Shipments** (`$shipments`) — one row per shipment to a site: `Source` (`seed`,
`reorder` or `in_transit`), `Ship_Date`, `Planned_Arrival`, `Arrival`,
`Delay_Days`, `Planned_Qty`, `Qty`, `Overdue` and a `Note` (a seed dropped
before the as-of date, topped up to zero, or short at the depot). Every unit
received appears in it once. `run_simulation.R` writes it to
`output/shipments.csv`.

### 2.6 Stock in transit, lead time by country, and disruptions

Three optional inputs to `project_inventory()` cover what the engine could not
see before: stock already moving at the as-of date, lanes that take longer or
shorter than the global lead time, and windows in which a crisis holds shipments
up.

**In transit** (`in_transit`; sample `datasets/in_transit.csv`). Shipments on the
road at the as-of date: protocol, site (country + center, or a site key), DU,
quantity, expected arrival (ETA), and optionally ship date, expiry and lot. Column
names are matched flexibly, as for the inventory files. Each joins its site's
in-transit queue and counts as on order from day one, so the reorder rule sees
it. It draws nothing from the depot, which it left before the as-of date. A
shipment whose ETA has passed is **overdue**: it lands on the first day, later if
a disruption covers that day, and the ledger marks it.

**Lanes** (`lanes`; sample `datasets/lanes.csv`). `Country, Lead_Time_Days`, with an
optional `Protocol` for a study-specific lane. A site's lane replaces the global
`lead_time_days` everywhere it is used: the arrival of reorders and seeds, the
lead-time demand in the reorder point, the forecast windows, and a seed's ship
date. A study lane beats a country lane, which beats the global value.

**Disruptions** (`disruptions`; scenarios in `datasets/scenarios/`).
`Country` (`*` for every site), `Start`, `End`, `Delay_Days`, and optionally
`Known`. A shipment of any kind scheduled to land inside a window lands
`Delay_Days` later. Overlapping windows add their delays; a delay that pushes an
arrival into a later window does not trigger that window as well.

- `Known = FALSE` (the default) is the surprise: planners keep ordering on the
  normal lane, and the stock lands late.
- `Known = TRUE`: an order that would land inside the window is planned on the
  lengthened lead time, so the reorder point rises to cover it.

Running a scenario both ways, on the same seed, gives the stockouts that advance
warning of that delay would have avoided. `run_simulation.R` takes a scenario as
`DISRUPTIONS=datasets/scenarios/<file>.csv`.

---

## 3. Assumptions & parameters

| Parameter | Default | Meaning |
|---|---|---|
| `num_trials` | 10 (app) / 5 (runner) | Monte-Carlo enrollment realizations |
| `visit_window` | 3 days | ± jitter on scheduled visit dates |
| `unplanned_visit_pct` | 10% | demand uplift for unscheduled visits |
| `lead_time_days` | 21 | depot → site shipping time |
| `safety_stock_days` | 30 | buffer, in days of forward demand |
| `target_days` | 90 | order-up-to coverage horizon |
| `oversupply_pct` | 10% | extra buffer added to each order |
| `as_of_date` | 2024-01-01 (sample) | planning date; on-hand is current as of here |

---

## 4. Limitations & possible extensions

- **Expected-demand planning.** Inventory is projected against the *mean* demand
  across trials. A conservative percentile (e.g. P80/P90) per day would give a
  service-level-based buffer; the trial machinery already exists to support it.
- **Depot replenishment is out of scope.** Depots are modelled as a bulk,
  long-dated buffer that is drawn down but not restocked from manufacturing. For
  multi-year horizons, add a manufacturing/packaging inbound stream to the depot.
- **One dispensing option per DU.** The `Option1…6` columns encode alternative
  dispensing combinations; the model currently uses one selected option. Titration
  / flexible-dose path switching could be modelled by making the option a
  function of cycle or subject state.
- **Screening / discontinuation.** Enrollment is modelled from the plan; active
  subjects, screen-fail and discontinuation dynamics (available in
  `visit_details`) are not yet fed into the forward projection.
- **Depot → site allocation.** When a depot cannot cover all its sites, orders
  are filled in site-processing order (FEFO on the depot). A fair-share or
  priority allocation rule could replace this.

---

## 5. Data sources (production)

In production the six input tables are extracted from the UDDM warehouse; see
`queries.sql` for the canonical queries (study info, enrollment, dosing/visit
container types, orders, site inventory, depot inventory, subject visits). The
committed `datasets/` are **synthetic** stand-ins produced by
`scripts/generate_sample_datasets.py` so the tool runs without warehouse access.
