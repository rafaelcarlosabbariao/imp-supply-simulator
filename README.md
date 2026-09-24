<p align="center"><img src="www/favicon.svg" width="72" alt="MC²"/></p>

<h1 align="center">MC² — Monte-Carlo clinical supply simulator</h1>

MC² is a public rebuild, on synthetic data, of a clinical-supply simulator built in
industry. It lives in this repository as `imp-supply-simulator`.

**Monte-Carlo demand forecasting and inventory-stockout prediction for clinical
trials.** Give it an enrollment plan and a dosing schedule for *any* protocol,
and it simulates patient demand, projects drug (IMP) inventory forward at every
site and depot, and tells you **where and when a site will run out** — with a
world map, a portfolio dashboard, and a live supply-chain news feed.

🔗 **Live showcase:** **[imp-supply-chain-simulator.netlify.app](https://imp-supply-chain-simulator.netlify.app)** · 📄 **Write-up:** _coming soon_

![Clinical site IMP status map](docs/assets/demo_map.png)

---

## Why this exists

In a clinical trial, running out of investigational drug at a site is a serious
event: patients can miss doses, visits get rescheduled, and the study slips.
Supply planning is hard because demand is *stochastic* — patients enroll at
random times, progress through dosing cycles at their own pace, and sometimes
discontinue — while supply is constrained by **lot expiry**, **shipping lead
times**, and **depot capacity**.

This tool models both sides end to end so a supply manager can see problems
*before* they happen instead of reacting to them.

## What it does

| | |
|---|---|
| **Simulate demand** | Monte-Carlo enrollment → each patient walks a Markov chain of dosing cycles → units dispensed per site / DU / day, over many trials. |
| **Seed the sites** | Studies run in cohorts: every cohort at every site is stocked for `N` patients through their first dispensing visits, and the shipment lands **before the cohort's visit 0** (enrollment, when nothing is dispensed). It is sized off the ladder, drawn from the depot, and topped up against stock the site already holds. |
| **See stock on the road** | Shipments in transit at the as-of date, **lead times by country**, and **disruption windows** (a port strike, a customs hold) that delay whatever is due to land inside them — known in advance or a surprise. Every shipment is in a ledger with its planned and actual arrival. |
| **Project supply** | An **(s, S) inventory policy** rolls stock forward day-by-day with **FEFO** consumption, **lot expiry**, depot resupply, safety stock, and lead times. |
| **Flag risk** | Every site × dispensing-unit is classified **OK / AT&nbsp;RISK / STOCKOUT** with the exact date it first runs dry. |
| **Map & drill down** | An interactive world map colours sites by status; click one for its per-DU detail and inventory-over-time chart. |
| **Portfolio view** | KPI rollup across **all** studies and sites at once. |
| **News feed** | Live supply-chain headlines (port strikes, recalls, cold-chain failures), risk-tagged, alongside your projections. |

<p align="center">
  <img src="docs/assets/demo_inventory.png" width="49%" alt="Inventory projection"/>
  <img src="docs/assets/demo_demand.png" width="49%" alt="Simulated demand"/>
</p>

## How it works

A **Markov chain** describes one patient's trajectory (Screening →
Randomization → Cycle *k* → Completed, with Discontinued/Screen-fail as
absorbing states); dispensing happens on the transitions. The engine runs the
cycle states: every enrolled patient goes through each cycle to completion or
the horizon. Screening, randomisation and discontinuation are in the theory
([`MODEL_THEORY.md`](docs/MODEL_THEORY.md)) and are not simulated. A **Monte-Carlo**
loop runs that chain across all patients `N` times and averages, turning
uncertainty into an expected daily-demand curve. That curve feeds the inventory
engine.

![Model diagram](docs/assets/model_diagram.svg)

Where the CSP defines one, a **dose-titration ladder** rides on top of that
chain: the first `N` visits step the dose up while the patient tolerates it,
down where they do not, and a **missed visit dispenses nothing and restarts the
window** from the patient's floor. That floor *ratchets* — once a patient has
tolerated the CSP's tolerance dose, they never restart below it again. Because
a rung is usually a different DU (a 15 mg vial and a 100 mg bottle are separate
lots with separate expiry), titration reallocates demand **across DUs**, and a
restart pulls the low-dose DU months after the depot stopped forecasting for
it — exactly the step change a trailing-average reorder point lags.

The ladder's state space is small enough to solve **exactly**:
`expected_demand()` propagates the distribution forward analytically instead of
sampling it, in O(1) time regardless of patient count. Use it for the
reorder-point rate; keep Monte Carlo for stockout risk, which is a threshold on
a path and genuinely needs one.

- **Full model theory** (Monte Carlo + Markov chain, dose titration, and how it
  differs from formal MCMC): [`docs/MODEL_THEORY.md`](docs/MODEL_THEORY.md)
- **Inventory-engine methodology** (the (s, S) policy, expiry, resupply, and the
  bugs found along the way): [`docs/METHODOLOGY.md`](docs/METHODOLOGY.md)
- **Why titration and site seeding are modelled the way they are, and what it cost to make the engine fast**:
  [`docs/titration-and-runtime-2026-08-28.md`](docs/titration-and-runtime-2026-08-28.md)
- **Pre-registration** for the forecast experiment this engine exists to
  support, rung against trailing (written before the run, results appended after):
  [`docs/EXPERIMENT.md`](docs/EXPERIMENT.md)

## Quickstart

**Prerequisites:** R ≥ 4.2. Install packages:

```r
install.packages(c(
  "shiny","shinyjs","bslib","shinycssloaders","DT","rhandsontable",
  "ggplot2","plotly","dplyr","tidyr","lubridate","stringr","readxl","readr",
  "xml2","httr"
))
```

**Run the app:**

```bash
R -e 'shiny::runApp(".", launch.browser = TRUE)'
```

It loads two sample studies (TRIAL-201, TRIAL-118) so you can click through
immediately: **Study Configuration → Visits & Demand → Supply & Inventory →
Portfolio → Site Map.** Tab 1 takes an optional titration spec (**Load the
worked example** shows one). Tab 3 chooses the forecast, starts from the site
inventory file or from empty sites stocked by seeds, and takes stock in
transit, lead times by country and a disruption scenario; its Shipments table
lists every seed, reorder and shipment on the road. The **Menu** at the top right opens an About page with
diagrams of the pipeline and the resupply rule, and a step-by-step guide.

**Run headless (batch / all protocols):**

```bash
Rscript scripts/run_simulation.R 5 2026-12-31 2024-01-01
#                                 │  │          └ inventory "as-of" date
#                                 │  └ horizon
#                                 └ number of Monte-Carlo trials
```

It reads `datasets/in_transit.csv` and `datasets/lanes.csv` when present, and a
disruption scenario when given one:

```bash
DISRUPTIONS=datasets/scenarios/global_port_strike.csv \
  Rscript scripts/run_simulation.R 5 2026-12-31 2024-01-01
```

`output/shipments.csv` lists every seed, reorder and shipment on the road, with
its planned and actual arrival.

Reorders are sized from a forecast. The default, `trailing`, averages each
site's dispensing over the last 60 days. `FORECAST=rung` projects the patients
on each dose forward through the titration probabilities, and `FORECAST=oracle`
reads the demand the simulation goes on to produce, as a ceiling to compare the
other two against ([METHODOLOGY §2.4](docs/METHODOLOGY.md)).

## Bring your own protocol

The engine is **protocol-agnostic** — it keys off column *names*, not study
codes. Supply an enrollment plan (`Protocol, Cohort, Arm, Patients,
Enroll_Start, Enroll_End, Country, Center`) and a dosing schedule (`Protocol,
Arm, DU_Description, Cycles, Cycle_Length, Option1…`); inventory columns are
mapped flexibly. `Program_Inputs.xlsx` is the input template.

A site is a **center in a country** (`1004 · Mexico`), because center numbers
repeat across countries. An inventory or in-transit file whose centers repeat
must carry a country column (`country_name` or `Country`); without one, a
center is matched to its only site, and the run stops if it has more than one.

## Repository layout

```
├── global.R · ui.R · server.R      # Shiny app (5 tabs)
├── R/
│   ├── simulation.R                 # DEMAND: enrollment → visits → dispensing (Markov + Monte Carlo)
│   ├── titration.R                  # dose ladders, the vectorised visit engine, exact recursion
│   ├── seeding.R                    # initial site stocking, sized off the ladder
│   ├── inventory.R                  # SUPPLY: (s,S) projection, FEFO, expiry, resupply
│   ├── newsfeed.R                   # supply-chain news (Google News RSS + risk tagging)
│   ├── brand.R                      # design tokens + themed builders (see docs/BRAND.md)
│   └── about.R                      # the About page and the top-right menu (diagrams, how-to)
├── scripts/
│   ├── run_simulation.R             # headless end-to-end runner
│   ├── generate_sample_datasets.py  # (re)generates datasets/ deterministically
│   └── make_demo_assets.R           # regenerates the README images and site/map.html
├── tests/
│   ├── test_titration.R             # correctness gate: simulator vs closed form
│   ├── test_seeding.R               # site identity, per-cohort seeds, top-up, opening modes
│   ├── test_transit.R               # stock in transit, lanes, disruptions, the ledger
│   ├── test_forecast.R              # the forecast modes the reorder rule orders on
│   ├── test_app.R                   # the app driven from tab 1 to tab 5 (shiny::testServer)
│   └── benchmark.R                  # runtime regression baseline
├── datasets/                        # SYNTHETIC sample data (safe, no real patient data)
│   ├── in_transit.csv · lanes.csv   # stock on the road at 2024-01-01; lead time by country
│   ├── scenarios/                   # disruption windows (opt-in, via DISRUPTIONS=)
│   └── example_titration/           # a worked six-rung ladder (opt-in, see its README)
├── docs/                            # MODEL_THEORY.md · METHODOLOGY.md · BRAND.md · assets/
├── site/                            # static showcase site (Netlify)
├── www/                             # Shiny static files (favicon)
└── Program_Inputs.xlsx              # input template
```

## Tests & benchmarks

```bash
Rscript tests/test_titration.R   # 29 checks; exits non-zero on failure
Rscript tests/test_seeding.R     # 41 checks
Rscript tests/test_transit.R     # 17 checks
Rscript tests/test_forecast.R    # 31 checks
Rscript tests/test_app.R         # 15 checks
Rscript tests/benchmark.R        # runtime baseline
```

The chain is small and finite, so most of what it does has a closed form, and
the tests check the simulator against that closed form rather than against a
recorded snapshot — a mis-threaded state machine still produces plausible
demand, and only an analytic check catches it. The simulator and
`expected_demand()` are independent implementations of the same chain, so their
agreement at scale is the real gate.

`simulate_visits()` is **vectorised across the cohort**: the chain is sequential
in *time* and independent across *patients*, so the loop runs along the axis
that is actually sequential and every patient advances as a vector inside it.
Measured on the same workload, that took the engine from 35,189 to ~2,150,000
dispensing rows/sec (16.76 s → 0.27 s at 18,750 patients), and removed the
decay with cohort size that came from growing output with `rbind`.

> **Seeds.** `scripts/run_simulation.R` takes the seed as an argument
> (`Rscript scripts/run_simulation.R [sims] [end_date] [as_of] [seed]`) rather
> than pinning it internally. Note that vectorising changed the order in which
> random numbers are drawn, so a given seed does not reproduce results from
> before that change.

## Data & privacy

All committed data in `datasets/` is **synthetic**, generated deterministically
by `scripts/generate_sample_datasets.py`. No real patient-level or
proprietary trial data is included in this repository.

## Tech

R · Shiny · plotly · ggplot2 · dplyr · DT · rhandsontable · a hand-rolled
(s, S) inventory engine · Google News RSS. Python (openpyxl) for sample-data
generation.

---

_Built as a portfolio project by [Rafael Carlos Abbariao](https://github.com/rafaelcarlosabbariao)._
