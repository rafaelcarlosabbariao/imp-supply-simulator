# Plan — the forecast, the app, the experiment, and the loose ends

**Written:** 2026-09-24, after `f3d5aff`
**Status:** built on 2026-09-24 from Rafael's decisions (§7); §8 records where the build departed from the plan.
**Follows:** `docs/seeding-by-cohort-plan-2026-09-24.md`, whose Phases 1–6 are done.

The first review of the day listed nine findings. Seeding by cohort, the site key
and stock in transit closed part of finding 2 and none of the others. This plan
covers what is left, in the order it has to be done, with the decisions that need
Rafael marked **[decide]**.

---

## 1. What is left, with the evidence

| # | Item | Where it stands |
|---|---|---|
| R1 | **Every run orders on the oracle forecast.** `project_inventory()` defaults to `forecast = "oracle"` (`R/inventory.R:156`); `server.R:233`, `scripts/run_simulation.R` and `scripts/power_pilot.R` never pass a mode. `R/forecast.R:22` calls the oracle a ceiling that is never an arm. | Open. Every status flag in the app and the showcase assumes perfect foresight. |
| R2 | **The rung forecast cannot be reproduced.** Nothing committed calls `build_occupancy()`. The deep-dive's rung row (971 → 67 stockout units) came from code outside the repo. | Open. |
| R3 | **The rung forecast counts patients who have left.** `build_occupancy()` runs each patient's last visit to the horizon (`R/forecast.R:182`), and the transition matrix has no exit state. | Open. Likely inflates rung reorders (11,587 against 10,735); unconfirmed. |
| R4 | **The rung forecast runs one visit behind.** Its first projected visit uses today's occupancy, which is the dose already dispensed; the next dose is one step of `P` further on (`R/forecast.R:109`). | Open. |
| R5 | **The rung forecast keeps titrating after the window closes.** The simulator fixes the dose after `N` visits (`R/titration.R:263`); `ladder_transition()` applies up/stay/down at every step, so top-rung patients drift down. | Open. |
| R6 | **Arms are pooled in the rung forecast.** `du_forecast_index()` keys on Protocol + DU, so the last arm overwrites the others; `build_occupancy()` reads the rung count by protocol alone; SSIDs repeat across simulated trials, and occupancy is summed across trials while demand is averaged across them. | Open. The 18-protocol frame has one arm per protocol, so the deep-dive numbers are unaffected by the first two parts. |
| R7 | **The app neither titrates nor seeds**, and exposes none of in-transit, lanes, disruptions or the ledger. | Open. This is Phase 7 of the seeding plan. |
| R8 | **The experiment is void** (`docs/EXPERIMENT.md`, 2026-09-24 notice) and the pilot and power curve with it. The deep-dive also records n = 1 replication and `Total_Expired = 0`. | Open. Waits on R1–R6. |
| R9 | **Docs and comments that no longer match the code:** `R/titration.R:21` says the reorder point uses a trailing average; `R/inventory.R:165` says the start date defaults to the earliest demand date, and line 245 uses `Sys.Date()`; METHODOLOGY cites `queries.sql`, which is not in the repo; README and `MODEL_THEORY.md` describe screening, randomisation and discontinuation states the engine does not have. | Open. |
| R10 | **An as-of date after the horizon is reset without a word** to the earliest demand date (`R/inventory.R:247`). | Open. |
| R11 | **AT RISK may be firing on routine operation.** A pair is AT RISK when its minimum days of supply over the whole horizon falls below the safety stock (`R/inventory.R:555`). Stock normally reaches about the safety level just before a delivery, so one dip anywhere in five years flags the pair. 13 of 26 pairs were flagged on the sample before today's changes. | Unmeasured. |
| R12 | **`main` is 10 commits ahead of `origin`** once this plan is committed. | Waiting on Rafael. |

---

## 2. Design

### D1. The default forecast becomes `trailing` (R1)

`project_inventory()` defaults to `forecast = "trailing"`. The oracle stays a
runnable mode under its own name and is only used when asked for. The runner takes
`FORECAST=oracle|trailing|rung` from the environment, the pilot passes its mode
explicitly, and every output that reports a status carries the mode it was run
under (a `Forecast` column in `$summary` and in `output/inventory_summary.csv`).

What this changes: every stockout and AT RISK count on the sample, the showcase's
stat cards and the demo assets. They are regenerated in the same phase. The
deep-dive's measurement puts titrating protocols at a 46% stockout proportion
under `trailing` against 0.2% under the oracle, so the showcase will look worse,
and the numbers will be ones a planner could have got.

### D2. Correct the rung forecast (R3–R6)

Four changes in `R/forecast.R`, each with its own test:

1. **Exit.** A patient's span ends one cadence after their final visit, the date
   an IRT system would show them as completed. `build_occupancy()` already sees
   each patient's last visit; it uses `last_day + cadence - 1` in place of the
   horizon.
2. **Next dose.** Projected visit `k` (k = 1, 2, …) uses `occ %*% P^k`. Today's
   occupancy is the dose just dispensed and does not recur.
3. **Maintenance.** Occupancy is split into two layers per rung: patients still
   inside the titration window, and patients past it. The titrating layer steps
   through `ladder_transition()`; the maintenance layer holds its rung, except that
   a missed visit returns a patient to the floor and back into the titrating layer,
   as the simulator does at `R/titration.R:253-257`. This needs the visit stream to say which layer a
   visit belongs to: `simulate_visits()` adds a `Titrating` flag (TRUE while
   `win < N`). The flag is read from state the simulator already keeps, so random
   numbers are drawn exactly as before.
   **[decide]** The alternative is to keep one marginalised matrix and accept the
   drift. The split is recommended: an IRT system knows each patient's visit
   count, so the planner is assumed to know nothing it would not.
4. **Arms and trials.** `du_forecast_index()` keys on Protocol × Arm × DU;
   `build_occupancy()` keys on Protocol × Site × Arm, reads `L` per arm, and
   identifies a patient by Trial + SSID. Occupancy is divided by the number of
   trials, matching how demand is averaged (`R/inventory.R:188`). The forecast for
   a site × DU is the sum over the arms that use that DU.

### D3. Commit the forecast comparison (R2)

A new `scripts/compare_forecasts.R` runs the three modes on the frame against the
same simulated demand, for `R` replications (default 5), and writes one row per
replication × mode × protocol to `output/experiment/forecasts.csv`. It builds the
occupancy itself, so the rung row can be reproduced from the repo.

Its first run replaces the deep-dive's table. D2 moves the rung numbers, so the
971 → 67 figure is expected to change, in either direction. The deep-dive lives in
`~/portfolio`; its table and "Still open" line are updated from this run in a
separate commit there.

### D4. App wiring (R7, Phase 7 of the seeding plan)

**Tab 1.** An optional titration upload beside the dosing schedule. When
`datasets/titration_input.csv` is absent, the app starts with no titration and
says so under the upload. `simulate_visits()` receives the spec.

**Tab 3**, in the sidebar, grouped under three eyebrows:

- *Forecast:* a select with `trailing` (default), `rung` (offered only when a
  titration spec is loaded) and `oracle`, labelled "oracle, perfect foresight
  (ceiling)".
- *Opening stock:* a radio for snapshot or seeded, and a seed switch with the
  seed lead in days. Snapshot needs a site inventory; seeded does not.
- *Shipments and lanes:* uploads for in-transit, lanes and disruptions, each
  loaded from `datasets/` by default; a select for the scenarios in
  `datasets/scenarios/` ("none" by default).

In the main panel: a **Shipments** panel showing the ledger, with seeds, reorders
and stock in transit told apart, overdue rows marked, and dropped seeds shown with
their reason. The daily detail gains `Seed_Shipped` and `Seed_Short`.

**Tab 4.** The KPI row gains "seeded units" and "overdue shipments".

**Tab 5.** The site detail lists that site's inbound shipments with their planned
and delayed arrival; a site with an overdue shipment gets an alert row.

**About page.** The limits list drops the lines that no longer hold (oracle
forecast, no titration, no seeding, no in-transit), and "Bring your own data"
adds the titration, in-transit, lanes and disruption files.

The news feed stays as it is. Linking a headline to a disruption window is a
separate piece of work and is out of scope here.

### D5. AT RISK (R11)

Measure first, under the trailing default from D1: for each pair, the number of
days below safety stock and the longest run of them. The result goes in the
methodology. **[decide after the measurement]** Keep the rule; flag only a run
longer than a set number of days; or flag against the stock projected at the next
arrival. No change is made before the numbers are in.

### D6. Small corrections (R9, R10)

- An as-of date after the horizon stops the run with a message naming both dates.
- `start_date` defaults to the earliest demand date, as the comment says; the app
  and runner always pass one, so only direct callers see the change.
- The `titration.R:21` comment describes the current reorder rule.
- METHODOLOGY drops the `queries.sql` reference and the "one dispensing option per
  DU" limitation. README and `MODEL_THEORY.md` mark screening, randomisation and
  discontinuation as states of the theory that the engine does not run.

### D7. The experiment (R8)

`docs/EXPERIMENT.md` is rewritten after D1–D3 and D6 are committed, since each of
them changes the engine. The rewrite settles four things:

1. **The arms. [decide]** The pre-registration tests a titration-aware allocation
   of safety stock against a uniform one. The deep-dive reports the rung forecast
   against the trailing one. Three options:
   - (a) rung forecast against trailing, both with uniform safety stock.
     Recommended: it is the effect the deep-dive measured, and the one the
     showcase describes.
   - (b) the original question, both arms on the trailing forecast.
   - (c) a 2 × 2 of forecast × safety-stock rule, at twice the compute.
   The oracle is run alongside as a reported ceiling in every option, never as an
   arm.
2. **Expiry.** The pilot's depot lots expire a year after the horizon, which is why
   `Total_Expired = 0`. The rewrite gives depot lots an expiry drawn from a stated
   shelf life so expiry becomes an outcome that can move.
3. **Replication.** The confirmatory run keeps R = 500 from §8, with common random
   numbers across arms.
4. **The freeze.** The implementation hash is the commit that lands the rewrite.

Then the pilot is re-run (20 replications, about 21 minutes at the measured 62 s
each), then the power curve. The confirmatory run comes after the power curve and
is not part of this plan: at 62 s per replication per arm it needs about 17 hours
for two arms, and more if the rung forecast is slower. Where it runs is a
separate decision.

### D8. Pushing (R12) **[decide]**

Nothing has been pushed since the rebrand. Each phase below can be pushed as it
lands, or all of them at the end. Pushing updates the public repo that the
showcase's buttons link to.

---

## 3. Impacted code

| File | Change | Phase |
|---|---|---|
| `R/inventory.R` | default `trailing`; `Forecast` column; as-of check; start-date default | F1, C1 |
| `R/forecast.R` | exit, next dose, maintenance layer, arm and trial keys | F2 |
| `R/simulation.R` | `Titrating` flag on each visit | F2 |
| `scripts/compare_forecasts.R` | new | F3 |
| `scripts/run_simulation.R` | `FORECAST=`; builds occupancy for `rung` | F1, F3 |
| `scripts/power_pilot.R` | passes its mode; depot expiry from shelf life | F1, E1 |
| `scripts/make_demo_assets.R`, `site/index.html` | regenerated on the trailing default | F1 |
| `ui.R`, `server.R`, `R/about.R` | D4 | A1–A3 |
| `R/titration.R` | comment only | C1 |
| `docs/METHODOLOGY.md`, `README.md`, `docs/MODEL_THEORY.md` | D1, D2, D5, D6 | each phase |
| `docs/EXPERIMENT.md` | rewritten | E1 |
| `~/portfolio/docs/gcs_mcmc_simulator_causalinference/deep-dive.md` | table from F3 | F3 (separate repo) |

`R/seeding.R`, `R/titration.R`'s simulator and the ledger are unchanged.

---

## 4. Tests

**`tests/test_forecast.R` (new).** A hand-built ladder with known `P`:

- the default mode is `trailing`, and `oracle` runs only when named;
- a patient's occupancy ends one cadence after their last visit;
- the first projected visit equals `occ %*% P`;
- a maintenance patient keeps their rung in projection, and a miss sends them to
  the floor;
- two arms at one site sharing a DU forecast the sum of both, and neither
  overwrites the other;
- occupancy from two trials equals the average of the two, and repeated SSIDs are
  kept apart;
- on a deterministic cohort, the rung forecast's expected units over a window match
  `expected_demand()` over the same window to within 1%.

**Existing suites.** Seeding, transit and titration are re-run each phase. Checks
that assumed the oracle default get the mode passed explicitly, so what they test
is unchanged.

**App.** A `shiny::testServer` smoke test drives tab 1 → 3 with each forecast mode,
each opening mode and one scenario, and checks the ledger renders.

---

## 5. Phases

One commit each; every suite passes before a commit.

| Phase | Content | Depends on |
|---|---|---|
| **F1** | Trailing default, `Forecast` column, runner and pilot pass a mode, demo assets and showcase regenerated | — |
| **F2** | Rung corrections D2.1–D2.4, `Titrating` flag, `tests/test_forecast.R` | F1 |
| **F3** | `compare_forecasts.R`, first run, METHODOLOGY table; deep-dive update in `~/portfolio` | F2 |
| **C1** | D6 corrections; D5 measurement written up | F1 |
| **A1** | App: titration upload, forecast select | F2 |
| **A2** | App: opening mode, seeding, in-transit, lanes, disruptions, scenarios | A1 |
| **A3** | App: ledger panel, KPIs, site detail, alerts, About page; smoke test | A2 |
| **E1** | EXPERIMENT.md rewrite and freeze; pilot depot expiry | F3, C1, arms decision |
| **E2** | Pilot re-run (20 reps), power curve | E1 |

F1 comes first because every number the app, the showcase and the pilot report
depends on it. The app phases touch no engine code, so they can run before or
after E1 without voiding the freeze; they are placed before it so the freeze is
the last change to the repo before the pilot.

---

## 6. Processes this affects

- **The showcase** shows the trailing-forecast numbers from F1 onwards. Its stat
  cards and demo images change in F1 and again if D5 changes the AT RISK rule.
- **The deep-dive** gets a new forecast table in F3. Its "Carried forward" line
  about keeping the oracle as a labelled ceiling still holds.
- **The Digital Footprint board** lists the stalled experiment; the card moves
  when E2 lands.
- **Anyone running `project_inventory()` directly** gets `trailing` where they got
  `oracle`. The change is named in the commit message and the README.

---

## 7. Decisions needed

1. **Arms of the experiment** (D7.1): (a) rung against trailing [recommended],
   (b) the original safety-stock question, or (c) the 2 × 2.
2. **Maintenance layer in the rung forecast** (D2.3): split by titration window
   [recommended] or keep one matrix.
3. **Pushing** (D8): as each phase lands, or at the end.
4. **Where the confirmatory run executes** (D7): about 17 hours for two arms. Needed
   only after E2.
5. **AT RISK rule** (D5): after the measurement in C1.

---

## 8. Where the build departed from the plan

Decisions (Rafael, 2026-09-24): the experiment compares the rung forecast
against the trailing one (7.1, option a); a patient on a titrating plan carries
a status, and a stable patient can be demoted back to titrating by an
unplanned visit, a missed dose or an adverse event, so the forecast should
track that on top of visit counts (7.2); push once, at the end (7.3).

- **F1. The trailing forecast reads history from before the as-of date.** Demand
  was cut at the as-of date, so every site open at that date forecast zero on
  day one. The window now reaches back over the days the site was already
  dispensing, capped at 60.
- **F1. Two transit checks pin the oracle.** Their dates were chosen against the
  oracle's order timing (`tests/test_transit.R` §4–5); under the trailing
  forecast they no longer exercise the disruption.
- **F2. Status is the chain's full state.** D2.3 proposed two layers per rung.
  The forecast instead uses the state `expected_demand()` already solves on,
  (rung, ratchet, window position), so a titrating patient's visits left in the
  window are known too. The visit stream records it per visit: `Dose_Status`,
  `Titration_Visit`, `Ratchet`, `Demotions`, `Status_Change`.
- **F2. Demotion at a visit is new.** `P_Revert` (default 0) demotes a stable
  patient at a visit they attend, for an adverse event or an unplanned visit;
  they titrate again from their current dose. A missed visit already demoted
  them to the floor. The draw is shared with the missed-visit draw, so runs with
  `P_Revert = 0` are identical to before (checked on the frame: 2,559,686 rows,
  same rungs, dates and quantities).
- **F2. Exit.** D2.1 proposed ending a patient's span one cadence after their
  final visit. Each projection instead stops at the patient's last cycle, which
  covers a patient cut off by a missed visit too.
- **F2. Patients count from enrollment.** Following the visit-0 decision, the
  enrollment records can be passed with the visits, and a patient is projected
  from the day they are entered.
- **F2. The rung projection carries the unplanned-visit uplift** that the
  realised demand and the other two forecasts already see.
- **F2. `project_inventory(occupancy =)` became `visits =`.** Nothing committed
  called it.
- **F3.** The frame, seeds, depot and policy moved to
  `scripts/experiment_setup.R`, shared by the pilot and the comparison.
- **A1–A3 landed as one commit.** The rung forecast is offered whether or not a
  titration spec is loaded, since on a fixed-dose arm it is a headcount. The
  engine's notes (dropped seeds, seeds that left before the as-of date) show
  under the run button. The live browser click-through was not done: the Chrome
  extension did not respond. `tests/test_app.R` drives the same path.
- **E1. Blocks are halves.** 18 protocols do not split into even terciles
  within titration status, so blocks are above / below the median demand.
- **E1. Depot lots.** The depot is four lots expiring 24, 36, 48 and 60 months
  after the as-of date, so expiry can register.
- **E1. The engine learned about expiry.** Staggered depot lots at first sent
  97% of site × DUs into stockout: the reorder rule counted a lot as cover until
  the day it expired. Two rules were added before the freeze: stock expiring
  before an order placed today could land is left out of the inventory
  position, and the depot ships a lot only with `min_shelf_life_days` (30) left
  on arrival. The sample's counts are unchanged.
- **E1. A sensitivity run was added**, with the forecast's `P_Miss` misstated,
  because the rung forecast is given the true titration probabilities.
