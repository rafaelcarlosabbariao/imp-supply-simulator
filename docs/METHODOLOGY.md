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
- At each visit, **every DU with cycles remaining** is dispensed at its `Qty`,
  and that DU's remaining-cycle counter decrements.

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

### 2.2 Planning horizon and the "as-of" date

Inventory on hand is *current as of* a planning date (`start_date`). The model
projects from that date forward to `horizon_end`; demand **before** the as-of
date is historical and is not consumed against current stock (you cannot
resupply the past). This is a key correctness point — projecting current stock
against already-elapsed demand produces meaningless day-one stockouts.

### 2.3 Lots, FEFO, and expiry

On-hand stock is tracked as **lots** `(quantity, expiry)` at each site, and as a
shared **depot** pool per `(Protocol, DU)`.

Each simulated day, per site:

1. **Expire** — lots whose expiry (retest date) `≤ today` are removed and
   counted as `Expired` (they are *not* available to dispense). Depot stock
   expires the same way.
2. **Receive** — shipments scheduled to arrive today are added to the site's
   lots (each shipped lot keeps its own real expiry).
3. **Dispense** — the day's expected demand is consumed **first-expiry-first-out**.
   Any unmet demand is recorded as `Stockout_Units` and on-hand floors at zero.
4. **Reorder** — see the policy below.

### 2.4 Resupply policy — forward-coverage order-up-to (s, S)

Rather than sizing off a flat average (which lags the enrollment ramp), the
policy looks at demand actually coming up. At each site on each day, using the
known expected-demand curve:

```
lead_demand      = Σ demand over the next  lead_time            days
coverage_demand  = Σ demand over the following  target          days (after lead)
rate             = mean daily demand over the next (lead + target) window
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
