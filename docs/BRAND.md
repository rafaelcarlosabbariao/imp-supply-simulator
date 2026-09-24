# MC² brand and interface system

MC² uses the REINS system: same blue, same slate neutrals, same status pairs, type, radii,
shadows and component anatomy. The system and the reasoning behind every token are in
[REINS `docs/BRAND.md`](https://github.com/rafaelcarlosabbariao/reins/blob/main/docs/BRAND.md).
This file records how the system maps onto an R stack (Shiny, ggplot, plotly, a static
page) and the decisions specific to MC².

| File | Holds |
|---|---|
| [`R/brand.R`](../R/brand.R) | Every token (`MC2`), the status tables, the Bootstrap 5 theme, the app's CSS (generated from the tokens), the Shiny building blocks, `theme_mc2()`, and the site map. |
| [`site/index.html`](../site/index.html) | The showcase. Its `:root` block restates the tokens as CSS custom properties, because a static page cannot read R. |
| [`www/favicon.svg`](../www/favicon.svg), [`site/favicon.svg`](../site/favicon.svg) | The MC² tile. |

A component never writes a hex value of its own. `grep -nE '#[0-9A-Fa-f]{6}' ui.R server.R`
returns nothing.

---

## 1. Identity

- **Name:** MC², with the descriptor *Monte-Carlo clinical supply simulator*. The repository
  and the Netlify URL keep `imp-supply-simulator`.
- **Provenance line:** the showcase and README both say MC² is a public rebuild, on synthetic
  data, of a clinical-supply simulator built in industry. That line keeps this app from being
  read as the original tool the résumé describes.
- **Mark:** MC² has no drawn logo. Its mark is the name set in type, in a 40px tile with a
  10px radius, using the REINS mark's own pair: **`#0A3FD5` on `#BEE2FF`**. The tile is the
  favicon and the start of the navbar; the descriptor sits beside it in muted 12px type.
- **Accent:** the REINS blue `#2563EB`, unchanged, so the two clinical-operations tools read
  as one family and are told apart by name.
- **Browser title:** `MC² · Monte-Carlo clinical supply simulator`.

## 2. The repeating encoding: IMP status

REINS fixes one data encoding (resource type); MC²'s is **IMP status**. The same status is the
same colour on the map, the KPI cards, every table, the site detail, the charts and the
showcase.

| Status | Mark fill (map, chart points) | Chip / cell text on fill | Meaning |
|---|---|---|---|
| STOCKOUT | `#DC2626` | `#B91C1C` on `#FEE2E2` | a site × DU runs out inside the horizon |
| AT RISK | `#D97706` | `#B45309` on `#FEF3C7` | the forecast says stock runs out before the next shipment lands |
| OK | `#059669` | `#047857` on `#D1FAE5` | neither |

Fills clear 3:1 on white; text pairs clear 4.5:1. These are the REINS status tokens, with
the fills taken one step darker than REINS's FSP green so every marker holds against the
pale map land.

- **KPI counts** take their status colour only above zero (the REINS rule for
  over-allocation). *OK* stays ink, because a healthy count is the resting state.
- **News-feed risk** reuses the pairs: High = stockout pair, Medium = at-risk pair,
  Low = neutral (`#334155` on `#F1F5F9`), because a low-risk headline still describes a disruption.
- **Draw order:** the worst status draws last, on top. Two sites a few kilometres apart
  (TRIAL-118 and TRIAL-201, both near Los Angeles) hid the only stockout under an at-risk
  marker until this was fixed. The plotly legend is reversed so it still reads worst first.

**Categorical series** (dispensing units, protocols): `#2563EB` `#0891B2` `#7C3AED`
`#475569` `#C026D3` `#1E3A8A`, via `scale_colour_mc2()`. Stockout days are drawn in red on
top of these lines, so this palette leaves out red, amber and green, the same way REINS's
categorical palette leaves out its resource-type hues.

## 3. How each piece maps onto Shiny

| REINS piece | MC² implementation |
|---|---|
| App shell | `bslib::page_navbar`: white navbar with a `#E2E8F0` bottom rule; tabs in `TEXT` 500, the active tab `BRAND_TEXT` with a 2px `BRAND` underline. Tab labels keep their step numbers (*1. Study Configuration* …) because the tabs are a sequence. |
| Theme | `mc2_theme()`: `bs_theme(version = 5)` with the brand as `primary`, status fills as `success` / `warning` / `danger`, Inter from Google Fonts, 10px control and 16px large radii, then `bs_add_rules(mc2_css())`. |
| Page header | `mc2_page_header(title, subtitle)` at the top of every tab. |
| Panel + title | `mc2_panel(..., title, icon)`: white, 1px border, 16px radius, panel shadow, bold ink title after a brand-blue icon, hairline under the title. Every output sits in one. |
| Sidebar | `sidebarPanel` (`.well`) restyled as a `SURFACE_ALT` card; its section labels are `mc2_eyebrow()`. |
| Eyebrow | `mc2_eyebrow(text)`: 12px, 500, uppercase, 0.08em, muted. |
| Buttons | `class = "btn-primary"` is solid brand. Any other `actionButton` is the soft tint (`BRAND_WASH`, `BRAND_TEXT`, `BRAND_SOFT` border). Sidebar run buttons are full width. |
| KPI card | `mc2_kpi(label, value, icon, status)`: eyebrow, 2rem ink value, 40px brand icon tile. |
| Chips | `mc2_chip()`, `mc2_status_chip()`: 12px, 500, pill radius. |
| Tables | DataTables with muted 500 column heads on `SURFACE_ALT`, `TEXT` cells, no wrapping, `SURFACE_ALT` stripes, `BRAND_WASH` hover; captions set as eyebrows. `mc2_status_cells(dt, "Status")` fills status cells from the table in §2. |
| Charts | `theme_mc2()`: bold ink title, muted subtitle and axes, horizontal `BORDER` grid only, legend at the bottom without a title. `scale_x_every(3)` thins month and quarter labels. |
| Map | `site_status_map(d)`: `SURFACE_MUTED` land, `SEPARATOR` borders and coasts, no frame, status fills with a 1.5px white ring, white hover labels in Inter. The app's tab 5 and `site/map.html` are drawn by this one function. |
| Spinners | `options(spinner.color = MC2$brand)` in `global.R`. |
| Icons | Font Awesome through `shiny::icon`, the set Shiny ships with (REINS uses Lucide). Same rule: brand blue in titles and tiles, never emoji. |

### Pitfalls found in the port
- `actionButton()` always adds `btn-default`, even with `class = "btn-primary"`. A rule
  that styles `.btn-default` as the secondary button turns every primary button pale; the
  rule has to be `.btn-default:not(.btn-primary)`.
- DataTables (Bootstrap 5) stripes and hovers rows with an inset `box-shadow`, which paints
  over a cell's own background, so status cells went olive on striped rows. `R/brand.R`
  removes the shadow and stripes with row backgrounds, which an inline status fill overrides.
- A `text-anchor` attribute in SVG loses to a CSS class that sets `text-anchor`; use an
  inline `style` to override one label.
- Shiny does not reload `global.R` or `R/brand.R` on file change. Restart the app after
  editing tokens.

## 4. The showcase

`site/index.html` follows the system on a static page: light only, Inter, a white top bar
with the tile and a GitHub link, a `SURFACE_ALT` hero with a brand eyebrow, an 800-weight
headline, the provenance line, one solid and two soft buttons, and five stat cards in the KPI
anatomy (stockouts and at-risk take their status colour). Sections are separated by
hairlines; the map, the diagram and the images sit in panels. It has a 16px gutter at phone
width and no horizontal scroll.

The stat cards, the map and the images all come from one run
(`scripts/make_demo_assets.R`, seed 42), which prints the counts the cards should show.
The previous page said 3 stockouts and 3 at risk, taken from an older `map.html` that no
script produced. The engine gave 1 and 5 on 2026-09-23, and 1 and 6 across 9 sites from 2026-09-24, when center 1004 in the USA became its own site. Later the same day the default forecast moved from the oracle to the trailing average, and the run gives 1 stockout, 7 at risk and 1 healthy. The AT RISK rule changed the same day (METHODOLOGY §2.5a), and the run gives 1 stockout, 0 at risk and 8 healthy.

The *Context* section, added 2026-09-24, is a swimlane of the clinical supply process: eight
roles by six phases, with the four points where MC² is used in solid brand, the steps the
engine simulates in `BRAND_WASH`, and steps outside the model in white. Its SVG is inline, so
it styles off the page's own custom properties and writes no hex values. It keeps a 900px
minimum width inside a panel that scrolls sideways at phone width. The business context and
layout decisions are in [`supply-process-diagram-plan-2026-09-24.md`](supply-process-diagram-plan-2026-09-24.md).

`site/assets/model_diagram.svg` is hand-written SVG. Its colours were mapped onto the
tokens, and its loop label, which overprinted the caption, was moved beside the loop.

## 5. Known deviations and open items

- **Chart type face.** R's graphics device cannot load web fonts and Inter is not installed
  on the build machine, so ggplot PNGs use the system sans (Helvetica on macOS). Everything
  in the browser uses Inter. Installing Inter and rendering with `ragg` would close this.
- **Handsontable** (the editable enrollment and dosing grids) keeps its own styling.
- **Number formatting.** The daily projection table shows floating-point noise
  (`9.680000000000001`); a `DT::formatRound` pass would fix it.
- **Plotly click warning.** Shiny logs "The 'plotly_click' event … is not registered" once
  at startup. It predates this pass and does not affect the map.
- `scripts/make_demo_assets.R` needs the `maps` and `htmlwidgets` packages, which the README
  install line does not list.
