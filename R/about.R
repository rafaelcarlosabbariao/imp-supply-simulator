# =========================================================================== #
# R/about.R  --  the About page, reached from the menu at the top right.
#
# Two hand-written SVG diagrams (the pipeline, and the resupply rule) and a
# how-to that jumps to each tab. Colours come from MC2 / STATUS_FILL through
# {{token}} placeholders, so the diagrams follow R/brand.R like everything else.
# The diagrams draw what the engine runs today; docs/assets/model_diagram.svg
# still shows screening and discontinuation states the engine does not model.
# =========================================================================== #

# The tab each how-to step opens. Values are the tabPanel titles in ui.R.
MC2_TABS <- c("1. Study Configuration", "2. Visits & Demand", "3. Supply & Inventory",
              "4. Portfolio", "5. Site Map")

.mc2_tokens <- function() {
  tok <- unlist(MC2[vapply(MC2, is.character, logical(1))])
  c(tok,
    fill_stockout = STATUS_FILL[["STOCKOUT"]], fill_atrisk = STATUS_FILL[["AT RISK"]],
    fill_ok = STATUS_FILL[["OK"]])
}

.mc2_svg <- function(svg) {
  tok <- .mc2_tokens()
  for (nm in names(tok)) svg <- gsub(paste0("{{", nm, "}}"), tok[[nm]], svg, fixed = TRUE)
  HTML(svg)
}

# ---- Diagram 1: the pipeline, stage by stage, with the tab each stage lives on
.about_pipeline_svg <- function() .mc2_svg('
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1000 285" role="img"
     aria-labelledby="mc2-pipe-t mc2-pipe-d" font-family="Inter,system-ui,-apple-system,Segoe UI,Roboto,sans-serif">
  <title id="mc2-pipe-t">How MC² turns a trial plan into a stockout forecast</title>
  <desc id="mc2-pipe-d">Enrollment plan and dosing schedule feed enrollment, visits and demand,
    which repeat for each simulated trial. Averaged demand and site and depot inventory feed a
    daily inventory walk, which classifies each site and dispensing unit as OK, at risk or stockout.</desc>
  <defs>
    <marker id="mc2-ar" markerWidth="10" markerHeight="10" refX="8" refY="3" orient="auto" markerUnits="strokeWidth">
      <path d="M0,0 L8,3 L0,6 Z" fill="{{muted}}"/>
    </marker>
    <marker id="mc2-arb" markerWidth="10" markerHeight="10" refX="8" refY="3" orient="auto" markerUnits="strokeWidth">
      <path d="M0,0 L8,3 L0,6 Z" fill="{{brand}}"/>
    </marker>
    <style>
      .in  { fill: {{surface_muted}}; stroke: {{separator}}; stroke-width: 1; }
      .stg { fill: {{brand_wash}}; stroke: {{brand}}; stroke-width: 1.5; }
      .fin { fill: {{surface}}; stroke: {{ink}}; stroke-width: 1.5; }
      .out { fill: {{surface}}; stroke: {{border}}; stroke-width: 1.2; }
      .tab { fill: {{brand_soft}}; }
      .tabt { font-size: 10.5px; font-weight: 600; fill: {{brand_text}}; letter-spacing: .06em; }
      .ttl { font-size: 15px; font-weight: 700; fill: {{ink}}; }
      .sub { font-size: 12px; fill: {{text}}; }
      .lbl { font-size: 12.5px; font-weight: 500; fill: {{text}}; text-anchor: middle; }
      .cap { font-size: 12px; fill: {{brand_text}}; font-weight: 500; text-anchor: middle; }
      .e   { stroke: {{muted}}; stroke-width: 1.6; fill: none; }
      .eb  { stroke: {{brand}}; stroke-width: 1.5; fill: none; stroke-dasharray: 5 4; }
    </style>
  </defs>

  <!-- inputs -->
  <rect class="in" x="25" y="14" width="150" height="34" rx="17"/>
  <text class="lbl" x="100" y="36">Enrollment plan</text>
  <rect class="in" x="225" y="14" width="150" height="34" rx="17"/>
  <text class="lbl" x="300" y="36">Dosing schedule</text>
  <rect class="in" x="610" y="14" width="180" height="34" rx="17"/>
  <text class="lbl" x="700" y="36">Site + depot inventory</text>
  <path class="e" d="M100,48 V100" marker-end="url(#mc2-ar)"/>
  <path class="e" d="M300,48 V100" marker-end="url(#mc2-ar)"/>
  <path class="e" d="M700,48 V100" marker-end="url(#mc2-ar)"/>

  <!-- stages -->
  <g>
    <rect class="stg" x="15" y="104" width="170" height="100" rx="12"/>
    <rect class="tab" x="27" y="115" width="46" height="18" rx="9"/><text class="tabt" x="50" y="128" text-anchor="middle">TAB 1</text>
    <text class="ttl" x="27" y="155">Enrollment</text>
    <text class="sub" x="27" y="175">patients land on random</text>
    <text class="sub" x="27" y="191">dates in each site window</text>
  </g>
  <g>
    <rect class="stg" x="215" y="104" width="170" height="100" rx="12"/>
    <rect class="tab" x="227" y="115" width="46" height="18" rx="9"/><text class="tabt" x="250" y="128" text-anchor="middle">TAB 2</text>
    <text class="ttl" x="227" y="155">Visits</text>
    <text class="sub" x="227" y="175">each patient steps through</text>
    <text class="sub" x="227" y="191">their dosing cycles</text>
  </g>
  <g>
    <rect class="stg" x="415" y="104" width="170" height="100" rx="12"/>
    <rect class="tab" x="427" y="115" width="46" height="18" rx="9"/><text class="tabt" x="450" y="128" text-anchor="middle">TAB 2</text>
    <text class="ttl" x="427" y="155">Demand</text>
    <text class="sub" x="427" y="175">units per site × DU × day,</text>
    <text class="sub" x="427" y="191">averaged over the trials</text>
  </g>
  <g>
    <rect class="stg" x="615" y="104" width="170" height="100" rx="12"/>
    <rect class="tab" x="627" y="115" width="46" height="18" rx="9"/><text class="tabt" x="650" y="128" text-anchor="middle">TAB 3</text>
    <text class="ttl" x="627" y="155">Inventory walk</text>
    <text class="sub" x="627" y="175">each day: expire, receive,</text>
    <text class="sub" x="627" y="191">dispense, reorder</text>
  </g>
  <g>
    <rect class="fin" x="815" y="104" width="170" height="100" rx="12"/>
    <rect class="tab" x="827" y="115" width="46" height="18" rx="9"/><text class="tabt" x="850" y="128" text-anchor="middle">TAB 3</text>
    <text class="ttl" x="827" y="155">Status</text>
    <text class="sub" x="827" y="175">per site × DU:</text>
    <text x="827" y="192" style="font-size:11.5px;font-weight:600">
      <tspan fill="{{success}}">OK</tspan><tspan fill="{{muted}}"> · </tspan><tspan fill="{{warning}}">AT RISK</tspan><tspan fill="{{muted}}"> · </tspan><tspan fill="{{danger}}">STOCKOUT</tspan>
    </text>
  </g>
  <path class="e" d="M185,154 H211" marker-end="url(#mc2-ar)"/>
  <path class="e" d="M385,154 H411" marker-end="url(#mc2-ar)"/>
  <path class="e" d="M585,154 H611" marker-end="url(#mc2-ar)"/>
  <path class="e" d="M785,154 H811" marker-end="url(#mc2-ar)"/>

  <!-- Monte Carlo loop under stages 1-3 -->
  <path class="eb" d="M500,204 V236 H100 V210" marker-end="url(#mc2-arb)"/>
  <text class="cap" x="300" y="258">repeated for each simulated trial (the Monte Carlo loop)</text>

  <!-- outputs -->
  <path class="e" d="M900,204 V222 H760 V234" marker-end="url(#mc2-ar)"/>
  <path class="e" d="M900,222 V234" marker-end="url(#mc2-ar)"/>
  <rect class="out" x="695" y="238" width="130" height="30" rx="15"/>
  <text class="lbl" x="760" y="258">Portfolio · tab 4</text>
  <rect class="out" x="835" y="238" width="130" height="30" rx="15"/>
  <text class="lbl" x="900" y="258">Site map · tab 5</text>
</svg>')

# ---- Diagram 2: the (s, S) resupply rule as a sawtooth -----------------------
.about_resupply_svg <- function() .mc2_svg('
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 620 250" role="img"
     aria-labelledby="mc2-ss-t mc2-ss-d" font-family="Inter,system-ui,-apple-system,Segoe UI,Roboto,sans-serif">
  <title id="mc2-ss-t">The resupply rule</title>
  <desc id="mc2-ss-d">Stock on hand falls as units are dispensed. When it reaches the reorder
    point an order is placed; it arrives one lead time later and lifts stock back toward the
    order-up-to level. A dip below the safety-stock line marks the site at risk.</desc>
  <style>
    .ax  { stroke: {{separator}}; stroke-width: 1.2; }
    .lvl { stroke-width: 1.2; stroke-dasharray: 5 4; }
    .t   { font-size: 11.5px; fill: {{muted}}; }
    .tb  { font-size: 11.5px; font-weight: 600; }
  </style>
  <line class="ax" x1="50" y1="26" x2="50" y2="220"/>
  <line class="ax" x1="50" y1="220" x2="505" y2="220"/>
  <text class="t" x="0" y="0" transform="translate(30,170) rotate(-90)">units on hand</text>
  <text class="t" x="505" y="238" text-anchor="end">time</text>

  <line class="lvl" x1="50" y1="50"  x2="505" y2="50"  stroke="{{subtle}}"/>
  <text class="tb" x="513" y="54"  fill="{{text}}">order-up-to</text>
  <line class="lvl" x1="50" y1="115" x2="505" y2="115" stroke="{{brand}}"/>
  <text class="tb" x="513" y="119" fill="{{brand_text}}">reorder point</text>
  <line class="lvl" x1="50" y1="170" x2="505" y2="170" stroke="{{fill_atrisk}}"/>
  <text class="tb" x="513" y="174" fill="{{warning}}">safety stock</text>

  <path d="M50,58 L150,115 L230,160 L230,62 L335,117 L420,176 L420,66 L505,103"
        fill="none" stroke="{{ink}}" stroke-width="2.4" stroke-linejoin="round"/>

  <circle cx="150" cy="115" r="5" fill="{{surface}}" stroke="{{brand}}" stroke-width="2"/>
  <text class="t" x="142" y="134" text-anchor="end">order placed</text>
  <circle cx="335" cy="117" r="5" fill="{{surface}}" stroke="{{brand}}" stroke-width="2"/>
  <text class="t" x="327" y="136" text-anchor="end">order placed</text>

  <text class="t" x="224" y="76" text-anchor="end">shipment arrives</text>

  <line x1="150" y1="196" x2="230" y2="196" stroke="{{muted}}" stroke-width="1.2"/>
  <line x1="150" y1="190" x2="150" y2="202" stroke="{{muted}}" stroke-width="1.2"/>
  <line x1="230" y1="190" x2="230" y2="202" stroke="{{muted}}" stroke-width="1.2"/>
  <text class="t" x="190" y="213" text-anchor="middle">lead time</text>

  <circle cx="420" cy="176" r="5.5" fill="{{fill_atrisk}}" stroke="{{surface}}" stroke-width="1.5"/>
  <text class="tb" x="412" y="200" text-anchor="end" fill="{{warning}}">below safety stock: AT RISK</text>
</svg>')

# ---- page ------------------------------------------------------------------ #
.about_step <- function(n, title, body) {
  tags$div(class = "mc2-step",
    tags$div(class = "mc2-step-head",
      tags$span(class = "mc2-step-n", n),
      tags$h5(title)),
    tags$p(body),
    actionButton(paste0("about_go_", n), paste("Open tab", n),
                 icon = shiny::icon("arrow-right"), class = "btn-sm"))
}

.about_status_row <- function(status, text) {
  tags$div(class = "mc2-status-row", mc2_status_chip(status), tags$span(text))
}

mc2_about_page <- function() {
  tagList(
    mc2_page_header("About MC²",
      "What the simulator does, how its stages connect, and how to run it from start to finish."),

    mc2_panel(title = "What it does", icon = "circle-info",
      tags$p(
        "MC² forecasts when a clinical-trial site will run out of investigational drug (IMP).",
        "It takes an enrollment plan, a dosing schedule and the stock currently at each site",
        "and depot. It simulates patient demand many times over, then projects inventory",
        "forward one day at a time. Every site × dispensing unit (DU) ends up OK, AT RISK or",
        "STOCKOUT, with the date it first runs out."),
      tags$p(class = "mc2-muted",
        "MC² is a public rebuild, on synthetic data, of a clinical-supply simulator built in",
        "industry. The two sample studies, TRIAL-201 and TRIAL-118, and every file in",
        tags$code("datasets/"), "are synthetic.")),

    mc2_panel(title = "How it works", icon = "diagram-project",
      tags$div(class = "mc2-figure", .about_pipeline_svg()),
      tags$p(class = "mc2-muted",
        "Enrollment, visits and demand run once for each simulated trial; the number of trials",
        "is set on tab 1. The inventory walk then runs once, against the average demand across",
        "those trials.")),

    tags$div(class = "mc2-about-grid",
      mc2_panel(title = "The resupply rule", icon = "arrows-rotate",
        tags$div(class = "mc2-figure mc2-figure-sm", .about_resupply_svg()),
        tags$p(class = "mc2-muted",
          "A site reorders when the stock it holds plus the stock already on its way falls",
          "below the reorder point, which is the expected demand over the lead time plus the",
          "safety stock. The order is sized to cover the lead time, the target coverage and",
          "the safety stock, plus the oversupply buffer, and it is drawn from the depot.",
          "Lots that expire first are dispensed first, and expired lots are written off.")),
      mc2_panel(title = "Reading the status", icon = "traffic-light",
        .about_status_row("STOCKOUT",
          "On at least one day inside the horizon, demand at the site was more than the stock it held. The date shown is the first such day."),
        .about_status_row("AT RISK",
          "The site never ran out, but its days of supply fell below the safety-stock setting at some point."),
        .about_status_row("OK", "Neither of the above."),
        tags$p(class = "mc2-muted", style = "margin-top:12px",
          "A site on the map takes the worst status across its DUs. Days of supply is stock on",
          "hand divided by the demand rate the reorder rule is using that day."))),

    tags$div(id = "mc2-howto",
      mc2_panel(title = "How to use it", icon = "list-ol",
        tags$p(class = "mc2-muted",
          "Each step uses the output of the one before it. After changing an input, re-run",
          "that step and every step after it. Enrollment is visit 0: the patient is entered and",
          "nothing is dispensed until the first cycle."),
        tags$div(class = "mc2-steps",
          .about_step(1, "Study Configuration",
            "Check or edit the enrollment plan and dosing schedule, or upload your own (.csv, .xls, .xlsx). A titration spec is optional; Load the worked example shows one. Choose how many trials to simulate and press Run Enrollment."),
          .about_step(2, "Visits & Demand",
            "Set the visit window and the simulation end date, then press Run Visit Simulation. The chart shows units dispensed per DU per month. On a titrating arm each visit records the patient's dose status: titrating, stable, or demoted back to titrating."),
          .about_step(3, "Supply & Inventory",
            "Set the as-of date and the planning assumptions, and choose the forecast reorders are sized from. Start from the site inventory file or from empty sites stocked by seeds, and add stock on the road, lead times by country and a disruption scenario. Press Run Inventory Projection; the Shipments table lists every seed, reorder and shipment on the road."),
          .about_step(4, "Portfolio",
            "Counts of stockout, at-risk and OK site × DUs, units seeded and overdue shipments, with a rollup for each study."),
          .about_step(5, "Site Map",
            "Sites coloured by status. Click a site to see its DUs, its inbound shipments and its inventory over time. The feed on the right lists live supply-chain headlines."))),

      mc2_panel(title = "Bring your own data", icon = "file-arrow-up",
        tags$table(class = "table table-sm mc2-cols",
          tags$thead(tags$tr(tags$th("Input"), tags$th("Columns"), tags$th("Where"))),
          tags$tbody(
            tags$tr(tags$td("Enrollment plan"),
                    tags$td(tags$code("Protocol, Cohort, Arm, Patients, Enroll_Start, Enroll_End, Country, Center")),
                    tags$td("Tab 1")),
            tags$tr(tags$td("Dosing schedule"),
                    tags$td(tags$code("Protocol, Arm, DU_Description, Cycles, Cycle_Length, Option1"),
                            tags$span(class = "mc2-muted", " (Option1 is units per dispense)")),
                    tags$td("Tab 1")),
            tags$tr(tags$td("Site and depot inventory"),
                    tags$td("Protocol, center and country (or depot), DU, quantity, retest or expiry date, lot.",
                            tags$span(class = "mc2-muted",
                              " Names are matched flexibly, e.g. protocol_id, center_number, du_description, site_inventory_count, retest_date_inv.")),
                    tags$td("Tab 3")),
            tags$tr(tags$td("Titration spec (optional)"),
                    tags$td(tags$code("Protocol, Arm, Titration_Visits, P_Up, P_Stay, P_Down, P_Miss, P_Revert, Tolerance_Level"),
                            tags$span(class = "mc2-muted", " (the dose rungs are the dosing schedule's Option1..N columns)")),
                    tags$td("Tab 1")),
            tags$tr(tags$td("Stock in transit (optional)"),
                    tags$td("Protocol, center and country, DU, quantity, ship date, ETA, retest or expiry date."),
                    tags$td("Tab 3")),
            tags$tr(tags$td("Lead times (optional)"),
                    tags$td(tags$code("Country, Lead_Time_Days"), tags$span(class = "mc2-muted", " [, Protocol]")),
                    tags$td("Tab 3")),
            tags$tr(tags$td("Disruption windows (optional)"),
                    tags$td(tags$code("Country, Start, End, Delay_Days, Known"),
                            tags$span(class = "mc2-muted", " (Country * is every site; Known means planned for)")),
                    tags$td("Tab 3")))),
        tags$p(class = "mc2-muted", tags$code("Program_Inputs.xlsx"),
               "in the repository is the input template."))),

    mc2_panel(title = "Limits of this build", icon = "triangle-exclamation",
      tags$ul(class = "mc2-limits",
        tags$li("The oracle forecast knows the demand the simulation goes on to produce. It is there",
                "to score the other two against; no planner has it."),
        tags$li("The rung forecast knows only the patients already enrolled at a site. It cannot see",
                "a patient who has not enrolled yet."),
        tags$li("AT RISK is set by a single day below the safety stock. On the sample most AT RISK",
                "flags are dips of a few days just before a reorder lands (METHODOLOGY §2.5a)."),
        tags$li("Patients do not screen-fail or discontinue. Each enrolled patient runs through all",
                "their cycles or until the horizon."),
        tags$li("Inventory is projected once, against the average demand across the simulated trials."),
        tags$li("Depots are drawn down and never restocked.")),
      tags$p(class = "mc2-muted",
        tags$a(href = "https://github.com/rafaelcarlosabbariao/imp-supply-simulator",
               target = "_blank", rel = "noopener", "Source on GitHub"), " · ",
        tags$a(href = "https://github.com/rafaelcarlosabbariao/imp-supply-simulator/blob/main/docs/METHODOLOGY.md",
               target = "_blank", rel = "noopener", "Inventory methodology")))
  )
}

# ---- the menu at the top right of the navbar ------------------------------- #
mc2_menu <- function() {
  bslib::nav_menu(
    title = tagList(shiny::icon("bars"), "Menu"),
    value = "menu",
    align = "right",
    bslib::nav_panel("About MC²", value = "about", icon = shiny::icon("circle-info"),
                     mc2_about_page()),
    bslib::nav_item(actionLink("menu_howto", class = "dropdown-item",
                               tagList(shiny::icon("list-ol"), "How to use it"))),
    "----",
    bslib::nav_item(tags$a(class = "dropdown-item", target = "_blank", rel = "noopener",
                           href = "https://github.com/rafaelcarlosabbariao/imp-supply-simulator",
                           shiny::icon("github"), "Source on GitHub")),
    bslib::nav_item(tags$a(class = "dropdown-item", target = "_blank", rel = "noopener",
                           href = "https://github.com/rafaelcarlosabbariao/imp-supply-simulator/blob/main/docs/METHODOLOGY.md",
                           shiny::icon("book-open"), "Methodology"))
  )
}

# Server half: step buttons jump to their tab, the menu's how-to link scrolls.
mc2_about_server <- function(input, session) {
  lapply(seq_along(MC2_TABS), function(i) {
    observeEvent(input[[paste0("about_go_", i)]], {
      bslib::nav_select("main_nav", MC2_TABS[[i]], session = session)
      shinyjs::runjs("window.scrollTo({top: 0});")
    })
  })
  observeEvent(input$menu_howto, {
    bslib::nav_select("main_nav", "about", session = session)
    shinyjs::runjs("setTimeout(function(){ var el = document.getElementById('mc2-howto');
                    if (el) el.scrollIntoView({behavior: 'smooth', block: 'start'}); }, 150);")
  })
}

mc2_about_css <- function() {
  t <- MC2
  sprintf("
.mc2-muted { color: %1$s; }
.mc2-figure { overflow-x: auto; margin: 4px 0 12px; }
.mc2-figure svg { display: block; width: 100%%; min-width: 680px; max-width: 1080px; height: auto; margin: 0 auto; }
.mc2-figure-sm svg { min-width: 420px; max-width: 640px; }
.mc2-about-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(340px, 1fr)); gap: 20px; }
.mc2-about-grid > .mc2-panel { margin-bottom: 0; }
.mc2-about-grid { margin-bottom: 20px; }
.mc2-status-row { display: flex; gap: 12px; align-items: baseline; padding: 10px 0;
  border-bottom: 1px solid %2$s; }
.mc2-status-row .mc2-chip { min-width: 84px; text-align: center; }
.mc2-steps { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 16px; }
.mc2-step { background: %3$s; border: 1px solid %2$s; border-radius: %4$s; padding: 16px;
  display: flex; flex-direction: column; gap: 8px; }
.mc2-step p { margin: 0; flex: 1; font-size: .925rem; }
.mc2-step .btn { align-self: flex-start; }
.mc2-step-head { display: flex; align-items: center; gap: 10px; }
.mc2-step-head h5 { margin: 0; font-size: 1rem; }
.mc2-step-n { width: 28px; height: 28px; border-radius: 9999px; background: %5$s; color: %6$s;
  display: grid; place-items: center; font-weight: 700; font-size: 13px; }
.mc2-cols td { white-space: normal !important; vertical-align: top; }
.mc2-cols code, .mc2-limits code, .mc2-panel p code { color: %7$s; background: %8$s;
  padding: 1px 5px; border-radius: 6px; font-size: .85em; }
.mc2-limits li { margin-bottom: 6px; }
.navbar .dropdown-menu { border: 1px solid %2$s; border-radius: %4$s; box-shadow: %9$s; }
.navbar .dropdown-item { display: flex; align-items: center; gap: 8px; }
.navbar .dropdown-item.active, .navbar .dropdown-item:active { background: %10$s; color: %7$s; }
",
    t$muted, t$border, t$surface_alt, t$radius_card, t$brand, t$surface,
    t$brand_text, t$brand_wash, t$shadow_card, t$brand_soft)
}
