# Plan — seed each cohort, key sites by country, draw seeds from the depot

**Written:** 2026-09-24
**Status:** APPROVED 2026-09-24, with Rafael's decisions recorded in §8. In progress.
**Base:** `94520a4` (MC² rebrand) and the About page commit that follows it.

This is the implementation plan for the four seeding defects found in the review of
2026-09-23, and for the in-transit, lane and disruption inputs Rafael added when deciding
D5. Each section names the code it touches, the decision behind it, and how it is tested.

---

## 1. The defects, with the evidence

| # | Defect | Where | Evidence on the sample data |
|---|---|---|---|
| 1 | Country is never part of a site's identity. Sites are keyed by center number alone. | `simulate_enrollment()` sets `Site = Center`; `seed_sites()`, `project_inventory()`, `.map_inventory()` and `site_status_frame()` all key on it. | TRIAL-118 center 1004 enrolls in Mexico (arm Combo5) and the USA (arm Combo7). Both share one stock pool, and the map draws that pool at the Mexico coordinates. |
| 2 | Only the first cohort at a site is seeded, sized for every patient the site will ever enroll. | `seed_sites()` groups by Protocol × Site × Arm, so cohorts collapse into one shipment dated to the earliest `Enroll_Start`. | TRIAL-201 site 1001: 157 patients over five cohorts (2023-03 to 2027-12) get one shipment of 519 vials on 2023-02-10, expiring 2025-02-09, before the Optimization and Pivotal cohorts (114 patients) enroll. |
| 3 | Seed stock is created outside the depot. | `project_inventory()` pushes `initial_receipts` onto the site's in-transit queue; `depot_pool` is never drawn down. | Depot stock is overstated by the full seeded quantity. Seeded lots take an invented expiry (`arrive + Seed_Shelf_Life`) instead of a real lot's. |
| 4 | A seed that landed before the as-of date is added on top of a site-inventory snapshot taken at that date. | `project_inventory()` folds pre-as-of receipts into opening on-hand unconditionally. | `run_simulation.R` with a seed argument: TRIAL-118 site 1001 opens with the 723 Compound-B bottles in `site_inventory.csv` plus the 339 seeded on 2022-09-24. |

The Shiny app does not call `seed_sites()` at all, so today these defects reach
`scripts/run_simulation.R` (when given a seed argument) and `scripts/power_pilot.R`.

## 2. Scope

**In scope:** defects 1–4, the tests that cover them, the scripts that call the changed
functions, regenerated demo assets, and the docs that describe seeding.

**Added in scope by Rafael (D5):** an in-transit input, lead times by country, and
disruption windows that delay shipments (§3 D7–D9), with a shipment ledger so every
shipment on the road can be seen (D10). Rafael's reason: in global clinical supply,
oversight of stock in transit matters for crisis response and for geography-specific lead
times, and through both of those for demand planning.

**Later, Phase 7:** exposing seeding, in-transit, lanes and disruptions in the app (tab 3).

**Out of scope, recorded so they are not lost:**
- Routing depots to countries. `depot_inventory.csv` names regional depots (EMEA Depot …),
  and the engine pools every depot per Protocol × DU. Seeds will draw from that pool.
- The forecast findings from the same review (the app defaulting to `oracle`, the
  unreachable `rung` forecast, and its occupancy carry-forward). Separate plan.
- Turning news-feed headlines into disruption rows. The feed already tags risk; linking a
  headline to a lane is a separate piece of work.

## 3. Design decisions

### D1. Site identity is Protocol × Country × Center (decided: recommendation)

Add one helper, `site_key(country, center)`, and apply it wherever a site enters the
engine: the enrollment plan, the site-inventory file and the site-locations file. `Site`
becomes that key everywhere downstream; `Country` and `Center` stay as their own columns
for display and export.

- **Recommended format:** `"<Center> · <Country>"`, e.g. `1004 · Mexico`. It reads well in
  tables, the map hover and the site selectors, and it sorts by center first.
- **Files without a country column** (an uploaded inventory extract may have none): match
  on center alone when that center is unique within its protocol, and stop with an error
  that names the centers when it is not. Silent matching is how defect 1 happened.
- **Patient IDs** (`SSID`) stay unique per Site × Trial, built from the new key.
- **The sample data.** TRIAL-118 `1004 · USA` has two enrollment rows (cohort C3, arm
  Combo7) and no inventory or location row. After this change it becomes its own site with
  no starting stock and no map position. Two options: add a USA 1004 inventory and
  location row in `scripts/generate_sample_datasets.py`, or treat the row as a data error
  and relabel it Mexico. **Recommended:** add the rows, since two countries sharing a
  center number is the case this change exists to handle, and the sample should exercise
  it. **Decided: add the rows.** The generator keys sites by (protocol, center) and keeps
  the first country it sees, which is how USA 1004 lost its rows; it will key by
  (protocol, center, country). The trailing spaces (`"TRIAL-118 "`, `"Japan "`) come from
  `Program_Inputs.xlsx` itself, which the generator does not write; `normalize_df()` trims
  them on the way in, and the source file is left as it is.

### D2. One seed per cohort

`seed_sites()` groups by **Protocol × Site × Arm × Cohort**. Each cohort's shipment is sized
for `min(Seed_Patients, cohort patients)` patients through its first `Seed_Visits` visits and
lands `Seed_Lead_Days` before that cohort's `Enroll_Start`. The output gains `Cohort` and a
`Planned_Qty` column; `Qty` becomes the quantity actually shipped, which D3 can reduce.

Arms at the same site that share a DU are still summed, within a cohort.

**Decided: enrollment start is visit 0.** Rafael: no drug is dispensed at visit 0; the
patient is entered into the database. The engine already works this way:
`.visit_dates()` places the first dispensing visit at `start + cadence`, and
`simulate_enrollment()` writes visit 0 with no DU and no quantity. The seed stays anchored
to the cohort's `Enroll_Start` and lands `Seed_Lead_Days` before it, so the site holds
stock before its first patient is entered. The docs and the About page will say visit 0
dispenses nothing.

### D3. A later cohort's seed tops the site up (decided: top-up)

A site opening its third cohort usually holds stock already, from resupply. Shipping a full
seed on top would overstock it and push lots toward expiry.

- **Recommended, top-up:** on the ship date, for each DU, ship
  `max(0, Planned_Qty − (on hand + on order))`. The first cohort at a new site has nothing
  on hand, so it receives the full seed, as today.
- **Alternative, additive:** ship `Planned_Qty` regardless. Simpler, and the current
  behaviour; it overstates stock whenever cohorts overlap or follow closely.

Either way, `Planned_Qty` and the shipped quantity are both reported, so a zero shipment is
visible as a top-up that found the site already stocked.

### D4. Seeds are shipped from the depot inside the daily walk

A seed stops being a pre-built receipt and becomes a scheduled shipment the day loop acts
on:

- **Ship date** = `Arrive_Date − lead_time_days`. `project_inventory()` computes it, because
  only it knows the lead time.
- On the ship date, the seed is drawn from the shared depot pool with the same FEFO
  `.pool_consume()` a reorder uses. Each lot keeps its **real depot expiry**, and any
  shortfall goes to `Depot_Shortfall`. The shipment joins the in-transit queue and lands
  one lead time later, as a reorder does.
- **Order within a day:** seeds are processed before reorders, since a seed was committed
  in advance. Sites are still processed in order against the shared depot, which is the
  existing allocation limitation (METHODOLOGY §4).
- **Accounting:** new daily columns `Seed_Shipped` and `Seed_Short`, and `Total_Seeded` in
  the summary. Seeds are kept out of `Reorder_Qty` and `Reorders`, so the reorder rule's
  counts measure the reorder rule.
- **No depot supplied** for that Protocol × DU (the seeding tests pass `depot = NULL`):
  the seed is treated as supplied from outside, with `Seed_Shelf_Life` as its expiry. This
  is the only remaining use of `Seed_Shelf_Life`.

### D5. What happens to seeds dated before the as-of date (decided: in-transit input)

A new `opening` argument to `project_inventory()` states what the opening position is:

| `opening` | When | Seed arrived before as-of | Seed shipped before as-of, landing after | Seed ships on/after as-of |
|---|---|---|---|---|
| `"snapshot"` | a site-inventory snapshot is given (the app, `run_simulation.R`) | dropped: the snapshot counts it, net of what was dispensed | dropped: the in-transit input (D7) is the record of what is on the road | D4 |
| `"seeded"` | no snapshot; sites start empty (`power_pilot.R`, the tests) | folded into opening on-hand, as today | joins the in-transit queue, no depot draw | D4 |

**Default:** `"snapshot"` when the site inventory has rows, `"seeded"` otherwise, with an
explicit override. Every dropped seed is reported, with its reason, in the shipment ledger
(D10).

In seeded mode a seed that lands before the as-of date is folded in without simulating the
demand that came before the as-of date. The engine warns when the as-of date falls after
the earliest seed ship date. `power_pilot.R` sets the as-of date before the earliest start.

### D6. The app (decided: later, Phase 7)

Tab 3 gains a "Seed each cohort before it opens" switch, a seed-patients input, and
uploads for in-transit, lanes and disruptions. Off by default, so the app's output is
unchanged until someone turns them on. The About page's "Limits of this build" is updated
when this lands.

### D7. In-transit input

Shipments already on the road at the as-of date, read from an optional file
(`datasets/in_transit.csv` for the sample) with flexible column names, as the inventory
files have:

| Field | Accepted names | Required |
|---|---|---|
| Protocol | `Protocol`, `protocol`, `protocol_id` | yes |
| Site | `Site` (a site key), or country + center (`country_name`/`Country`, `center_number`/`Center`) | yes |
| DU | `DU`, `du_description`, `DU_Description` | yes |
| Quantity | `Qty`, `quantity`, `shipment_qty`, `in_transit_count` | yes |
| Expected arrival | `ETA`, `eta`, `expected_arrival`, `arrival_date` | yes |
| Ship date | `Ship_Date`, `ship_date`, `shipped_date` | no |
| Expiry | `Expiry`, `retest_date`, `retest_date_inv`, `expiry_date` | no |
| Lot, origin | `Lot`/`lot_id`, `Origin`/`depot_name` | no |

- A shipment joins its site's in-transit queue at the start of the walk and counts in the
  inventory position (on hand + on order) from day one, so the reorder rule sees it.
- It does not draw from the depot; it left the depot before the as-of date.
- **Overdue:** a shipment whose ETA is before the as-of date is still on the road. It lands
  on the first day of the walk, later delays applied (D9), and the ledger marks it overdue.
- Its expected arrival passes through the disruption windows (D9), so a crisis can hold up
  stock that is already moving.

### D8. Lead times by country

An optional lanes table (`datasets/lanes.csv`): `Country, Lead_Time_Days`, with an
optional `Protocol` column for a study-specific lane. A site's lead time is its country's
lane, else the global `lead_time_days`. It applies everywhere a lead time is used: the
arrival of a reorder, the lead-time demand in the reorder point, the forecast windows, and
the ship date of a seed (arrival minus the site's lane).

### D9. Disruption windows

An optional disruptions table (`datasets/disruptions.csv`):
`Country, Start, End, Delay_Days, Known`, with `Country = "*"` for every site.

- Any shipment to a site in that country whose scheduled arrival falls inside
  `[Start, End]` arrives `Delay_Days` later. This covers seeds, reorders and in-transit
  stock alike: a port strike holds up whatever is due to land during it.
- `Known = FALSE` (the default): planners keep ordering on the normal lane lead time, and
  the delay is a surprise. This is the crisis case.
- `Known = TRUE`: the planner sees the delay, and an order whose arrival would fall inside
  the window is planned on the lengthened lead time, so the reorder point rises to cover
  it. Comparing the two runs is the measure of what advance warning is worth.
- Windows are applied once per shipment, in date order; a delay that pushes an arrival
  into a later window is not delayed again.

### D10. The shipment ledger

`project_inventory()` returns a fourth element, `$shipments`: one row per shipment, with
`Protocol, Site, DU, Source (in_transit | seed | reorder), Ship_Date, Planned_Arrival,
Arrival, Delay_Days, Qty, Overdue`, plus seeds that were dropped or topped up to zero with
the reason. It is the oversight view of everything on the road, and the tests read it.

## 4. Impacted code

| File | Function / area | Change | Phase |
|---|---|---|---|
| `R/simulation.R` | new `site_key()`; `simulate_enrollment()`, `simulate_visits()` | `Site = site_key(Country, Center)`; keep a `Center` column; SSID from the key | 1 |
| `R/simulation.R` | `compute_demand()` | none (already groups by Country and Site) | — |
| `R/inventory.R` | `.map_inventory()`, new `.resolve_site_keys()` | build `Location` from the site key; country column candidates; files without a country resolve by center or stop | 1 |
| `R/brand.R` | `site_status_frame()`, `site_status_hover()` | merge locations on Protocol + site key | 1 |
| `server.R` | site detail (`enr$Center == site`) | filter the enrollment plan by site key | 1 |
| `scripts/generate_sample_datasets.py` | site enumeration | key sites by (protocol, center, country); regenerate `datasets/` | 1 |
| `R/seeding.R` | `seed_sites()` | group by cohort; add `Cohort`, `Planned_Qty`; `Seed_Shelf_Life` only for the no-depot case | 2 |
| `R/inventory.R` | `project_inventory()` | `opening`; seed events on ship dates; depot draw; top-up; `Seed_Shipped`, `Seed_Short`, `Total_Seeded`; seeds kept out of reorder counts | 3 |
| `R/inventory.R` | `project_inventory()`, new `.map_in_transit()`, `.site_lead_time()`, `.delay_arrival()` | in-transit input; lanes; disruption windows (known and unknown); `$shipments` ledger | 4 |
| `R/forecast.R` | `.forecast_window()` | none; it already takes the lead time as an argument, and the walk passes the site's | — |
| `R/forecast.R` | `build_occupancy()` | none; it inherits the new site key | — |
| `scripts/generate_sample_datasets.py` | new outputs | `in_transit.csv`, `lanes.csv`, `disruptions.csv` for the sample | 4 |
| `scripts/run_simulation.R` | inputs and report | read the optional in-transit, lanes and disruptions files; pass `opening`; print planned vs shipped seeds, dropped seeds, delayed and overdue shipments; write `shipments.csv` | 5 |
| `scripts/power_pilot.R` | seeding and depot | `opening = "seeded"`; report depot shortfalls (the depot is 3× expected demand) | 5 |
| `scripts/build_frame.R` | — | none. One cohort per site, every row USA. Six protocol–center rows repeat (695 rows, 689 unique); seeding already sums them. | — |
| `scripts/make_demo_assets.R`, `site/index.html` | — | re-run; update the stat cards | 5 |
| `README.md`, `docs/METHODOLOGY.md`, seeding addendum, `EXPERIMENT.md`, `R/about.R` | docs | §2.1a seeding; new §2.x for in-transit, lanes and disruptions; visit 0 dispenses nothing | 6 |
| `server.R`, `ui.R`, `R/about.R` | tab 3 | the app controls (D6) | 7 |

## 5. Tests

`tests/test_seeding.R` has 19 checks in six sections today. Sections 1, 2 and 5 are kept
(5 passes no depot, so it uses the D4 fallback). Sections 3 and 4 gain the `Cohort`
column; section 6 is rewritten around the `opening` modes.

**New checks in `tests/test_seeding.R`:**
1. Two cohorts at one site produce two shipments, each dated to its own cohort.
2. One center number in two countries gives two sites, two stock pools and two seeds.
3. A seed drawn from the depot lowers depot stock by the shipped quantity, carries the
   depot lot's expiry, and records a shortfall when the depot is short.
4. Top-up: a site holding at least the planned quantity ships zero; a partly stocked site
   ships the difference.
5. Snapshot mode drops a seed that arrived before the as-of date; opening on-hand equals
   the snapshot.
6. Seeded mode: a seed shipped before the as-of date and landing after it arrives on its
   date without drawing from the depot.
7. An inventory file without a country column resolves by center when unambiguous and
   stops when it is not.
8. Seeds do not appear in `Reorders` or `Reorder_Qty`.
9. The site key change draws no random numbers: demand is unchanged for a fixed seed.

**New file `tests/test_transit.R`:**
1. An in-transit shipment lands on its ETA, counts as on order until then, and leaves the
   depot untouched.
2. An overdue shipment lands on the first day and is marked overdue in the ledger.
3. A country lane of 42 days makes that site's reorders land 42 days after they ship,
   while other countries keep the global lead time.
4. A disruption window delays every arrival inside it, for seeds, reorders and in-transit
   stock, and leaves arrivals outside it alone.
5. An unknown disruption leaves the reorder point unchanged; a known one raises it for
   orders that would land inside the window.
6. The ledger lists every shipment exactly once, and its quantities add up to what the
   daily table received.

`tests/test_titration.R` should pass unchanged. `tests/benchmark.R` is re-run after
Phase 4.

## 6. Phases

Each phase is one commit, and every test suite passes before it goes in.

1. **Site key.** D1, the regenerated sample data, checks 2, 7 and 9.
2. **Per-cohort seeds.** D2, check 1.
3. **Seeds in the walk.** D3, D4, D5, checks 3–6 and 8.
4. **In transit, lanes, disruptions, ledger.** D7–D10, the sample files,
   `tests/test_transit.R`.
5. **Scripts and assets.** Runner, pilot, regenerated demo images and `site/map.html`,
   showcase stat cards.
6. **Docs.** METHODOLOGY, README, the seeding addendum, EXPERIMENT.md, the About page's
   limits.
7. **App wiring (later).** D6.

## 7. Processes this affects

- **The experiment.** `EXPERIMENT.md` says any engine change voids the pre-registration and
  it must be rewritten, not amended. The deep-dive already records it as void, so this
  adds to a rewrite that is owed. §4 "Site seeding is held constant across arms" still
  holds. On the 18-protocol frame Phases 1 and 2 change nothing; Phase 3 changes results,
  because seeds come out of the depot and carry depot expiry. Phase 4 changes nothing there
  unless the frame is given lanes or disruptions. The pilot and the power curve are re-run
  after Phase 5, and the implementation hash is re-frozen then.
- **A new experiment becomes possible.** Known against unknown disruptions, on the same
  frame and seeds, measures what advance warning of a lane delay is worth in stockouts.
  Not pre-registered here.
- **Reproducibility.** No phase changes how random numbers are drawn, so a given seed gives
  the same demand before and after (check 9). Inventory results differ from Phase 3 on.
- **The sample data.** Regenerating with USA 1004 as its own site shifts the generator's
  random draws for every site after it, so most starting quantities in `datasets/` change
  in Phase 1. The generator stays deterministic.
- **The showcase.** Stat cards, `site/map.html` and the README images change in Phase 5.
  `1004 · USA` gets its own marker.
- **Uploads.** An inventory or in-transit file whose centers repeat across countries must
  carry a country column. The error message says so.
- **Tracking.** The work lands in this repo's history and docs. The Digital Footprint board
  reads open tasks from the portfolio arm's `TODO.md`; a line there can track it if wanted.

## 8. Decisions (Rafael, 2026-09-24)

| | Decision |
|---|---|
| D1 | Key `"<Center> · <Country>"`; add USA 1004 inventory and location rows |
| D2 | Anchor seeds to enrollment start. Enrollment is visit 0: the patient is entered into the database and no drug is dispensed |
| D3 | Top-up |
| D5 | Build an in-transit input (D7), with lead times by country (D8) and disruption windows (D9), for oversight of crisis and geography-specific lead times in demand planning |
| D6 | App wiring after the engine and scripts |
