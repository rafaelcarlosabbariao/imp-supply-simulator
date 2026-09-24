# Plan: a process diagram of the clinical supply chain, and where MC² is used

2026-09-24. A new section on the showcase (`site/index.html`), between *The problem* and
*Site map*: one swimlane diagram of how investigational drug (IMP) moves through a trial,
who owns each step, and the four points where a supply manager uses MC².

## 1. Business context, collated

### 1.1 The process, in order

| Phase | What happens | Owner |
|---|---|---|
| Plan | The protocol (CSP) fixes arms, dosing and any titration ladder; the study team sets the enrollment plan by cohort, country and site. The supply manager turns both into a demand forecast and a supply plan. | Study team; clinical supply |
| Make & pack | Drug product is made (and any comparator sourced), then packed into blinded kits and labelled for each country. Quantities come from the forecast. | Manufacturing / CMC, a CDMO, packaging |
| Release | Every lot is certified before it can be shipped to a trial (QA; in the EU, a Qualified Person). | Quality |
| Store & activate | Released lots go to central and regional depots. Sites open by cohort and receive seed shipments before their first patient. | Depots and logistics; study team |
| Ship & dispense | The IRT system randomises patients and assigns kits; when a site's stock falls to its trigger level it orders a resupply. Shipments clear import and customs on the way. The site pharmacy stores kits and dispenses them at each visit. | IRT; depots and couriers; regulatory / trade compliance; site pharmacy; patient |
| Close out | Unused and expired kits are returned and destroyed after the CRA reconciles drug accountability. | Site; study team (CRA) |

### 1.2 Where MC² is used, and what it reads

| # | Point of use | When | Reads | Gives the supply manager |
|---|---|---|---|---|
| 1 | Forecast demand | before first patient in, and at each reforecast | enrollment plan, dosing schedule, titration spec | units per site × DU × day (tab 2) |
| 2 | Seed and resupply rules | before sites open | the forecast, lead times | seed size per cohort (`R/seeding.R`); safety stock, reorder point *s*, order-up-to *S*, which are the IRT's trigger and resupply levels |
| 3 | Watch stock | during the study, as of a date | site and depot inventory, shipments in transit | OK / AT RISK / STOCKOUT per site × DU with the first stockout date; map and portfolio (tabs 3–5) |
| 4 | Test a disruption | when a strike or hold is announced | lanes by country, disruption windows | which sites the delay pushes into a stockout, and when (`datasets/scenarios/`) |

### 1.3 What the engine simulates and what it leaves out

Simulated: enrollment dates, visits through dosing cycles and titration, depot stock drawn
down with FEFO and lot expiry, shipments with lead times by country and disruption delays,
the (s, S) resupply rule an IRT applies, site storage and dispensing.

Outside the model (METHODOLOGY §4, MODEL_THEORY): manufacturing, packaging and labelling,
lot release, import clearance as a process (only its delay is modelled), randomisation,
screening and discontinuation, returns, reconciliation and destruction. Depots are drawn
down and never restocked from manufacturing.

The diagram has to keep these two apart, so nobody reads MC² as an end-to-end supply system.

## 2. Diagram design

- **Form:** swimlanes. Rows are the eight roles (study team, supply planning, manufacturing,
  quality and regulatory, depots and logistics, site pharmacy, IRT, patient); columns are
  the six phases in 1.1. The IRT lane sits between the site and the patient, because it is
  the information hub between them.
- **Three box fills:** solid brand blue for the four MC² points of use, numbered 1–4 to
  match the cards below the diagram; brand wash for steps the engine simulates; white for
  steps outside the model.
- **Two line styles:** solid for drug or patient moving, dashed for information. Dashed
  lines into and out of MC² are brand blue. The one crossing (seed and resupply rules
  running down to the IRT past the release → depot line) gets a white gap.
- **Colour:** inline SVG styled with the page's own CSS custom properties, so no new hex
  values (BRAND.md: a component never writes a hex of its own). Light only, like the page.
- **Phone width:** the SVG keeps a 900px minimum inside a panel that scrolls sideways; the
  page itself does not scroll horizontally. A note says to scroll.
- **Text equivalent:** `<title>`/`<desc>` on the SVG, and four cards below it that explain
  each point of use in prose.

## 3. Changes

1. `site/index.html`: the section, its CSS (legend, scroll panel, cards), the inline SVG.
2. `site/methodology.html`: rebuilt with `scripts/build_methodology_page.R`, since it copies
   the showcase's `<style>` block and `--check` would otherwise fail.
3. `docs/BRAND.md` §4: record the new section.

## 4. Verification

- Open the page in a browser at desktop and phone widths; check no label overprints a line
  or box, and that the page does not scroll sideways.
- `Rscript scripts/build_methodology_page.R --check` passes.
- `grep` the new markup for hex values: none.
