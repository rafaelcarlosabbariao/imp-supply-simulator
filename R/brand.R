# =========================================================================== #
# R/brand.R  --  MC² design tokens and the themed builders that use them.
#
# The system is the REINS one: ~/reins/docs/BRAND.md (github.com/rafaelcarlosabbariao/
# reins/blob/main/docs/BRAND.md) explains every token. docs/BRAND.md in this repo records
# how it maps onto Shiny, ggplot and plotly. Every colour, radius and shadow the app,
# the charts and the demo assets use comes from MC2 below; the app's CSS is generated
# from the same list, so there is no second copy to keep in step.
# =========================================================================== #

MC2 <- list(
  # Brand: shared with REINS. MARK / MARK_GROUND draw the MC² tile and nothing else.
  mark          = "#0A3FD5",
  mark_ground   = "#BEE2FF",
  brand         = "#2563EB",   # buttons, active tab, focus, the first chart series
  brand_hover   = "#1D4ED8",
  brand_text    = "#1D4ED8",   # blue text and icons on white or a tint
  brand_soft    = "#DBEAFE",
  brand_wash    = "#EFF6FF",

  # Ink and neutrals: Tailwind slate, and only slate
  ink           = "#0F172A",   # headings, values
  text          = "#334155",   # body copy, table cells
  muted         = "#64748B",   # captions, labels, eyebrows, column heads
  subtle        = "#94A3B8",   # decoration only (2.6:1), never text
  separator     = "#CBD5E1",
  border        = "#E2E8F0",
  surface       = "#FFFFFF",
  surface_alt   = "#F8FAFC",   # sidebars, table heads, panels that hold cards
  surface_muted = "#F1F5F9",   # neutral chips, map land

  # Status pairs (text, fill); each clears 4.5:1
  success = "#047857", success_bg = "#D1FAE5",
  warning = "#B45309", warning_bg = "#FEF3C7",
  danger  = "#B91C1C", danger_bg  = "#FEE2E2",

  # Shape
  radius_panel   = "16px",
  radius_card    = "12px",
  radius_control = "10px",
  radius_tag     = "8px",
  shadow_control = "0 1px 2px rgba(15,23,42,.05)",
  shadow_card    = "0 6px 18px rgba(15,23,42,.06)",
  shadow_panel   = "0 10px 24px rgba(15,23,42,.08)",
  shadow_hover   = "0 14px 32px rgba(15,23,42,.12)",
  motion         = "transform .18s ease, box-shadow .18s ease",
  tracking       = ".08em",
  font_stack     = "Inter, system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif"
)

# ---- IMP status: MC²'s one repeating data encoding ------------------------- #
# REINS fixes resource type; MC² fixes status. The same status is the same colour on
# the map, the KPI cards, the tables, the site detail and the charts.
STATUS_LEVELS <- c("STOCKOUT", "AT RISK", "OK")
STATUS_FILL <- c("STOCKOUT" = "#DC2626", "AT RISK" = "#D97706", "OK" = "#059669") # marks, >= 3:1 on white
STATUS_FG   <- c("STOCKOUT" = MC2$danger,    "AT RISK" = MC2$warning,    "OK" = MC2$success)
STATUS_BG   <- c("STOCKOUT" = MC2$danger_bg, "AT RISK" = MC2$warning_bg, "OK" = MC2$success_bg)

# News-feed risk reuses the status pairs; Low is neutral, since it is not a clearance.
RISK_FG <- c(High = MC2$danger,    Medium = MC2$warning,    Low = MC2$text)
RISK_BG <- c(High = MC2$danger_bg, Medium = MC2$warning_bg, Low = MC2$surface_muted)

# Categorical series with no fixed meaning (dispensing units, protocols). Stockout days
# are drawn in STATUS_FILL on top of these lines, so the palette avoids red, amber and
# green; every hue clears 3:1 on white.
CHART_CATEGORICAL <- c("#2563EB", "#0891B2", "#7C3AED", "#475569", "#C026D3", "#1E3A8A")

# ---- Shiny: Bootstrap 5 theme + component rules ---------------------------- #
mc2_css <- function() {
  t <- MC2
  sprintf("
body { background: %1$s; color: %2$s; }
h1, h2, h3, h4, h5 { color: %3$s; font-weight: 700; letter-spacing: -.01em; }
a { color: %4$s; text-decoration: none; }

/* App shell */
.navbar { background: %1$s !important; border-bottom: 1px solid %5$s; box-shadow: none; }
.navbar .nav-link { color: %2$s; font-weight: 500; border-bottom: 2px solid transparent; }
.navbar .nav-link:hover { color: %3$s; }
.navbar .nav-link.active { color: %4$s !important; border-bottom-color: %6$s; }
.mc2-brand { display: flex; align-items: center; gap: 12px; }
.mc2-tile { width: 40px; height: 40px; border-radius: %7$s; background: %8$s; color: %9$s;
  display: grid; place-items: center; font-weight: 800; font-size: 15px; letter-spacing: -.02em; }
.container-fluid > .tab-content > .tab-pane { padding: 0 12px 40px; max-width: 1600px; margin: 0 auto; }
.mc2-descriptor { font-size: 12px; line-height: 1.25; color: %10$s; max-width: 11rem; white-space: normal; }

/* Page header, eyebrow, panels */
.mc2-page-header { margin: 24px 0 20px; }
.mc2-page-header h2 { font-size: 2rem; margin: 0 0 6px; }
.mc2-page-header p { color: %10$s; font-size: 1rem; margin: 0; max-width: 60rem; }
.mc2-eyebrow { font-size: 12px; font-weight: 500; color: %10$s; text-transform: uppercase;
  letter-spacing: %11$s; margin: 0 0 8px; }
.mc2-eyebrow.brand { color: %4$s; }
.mc2-panel { background: %1$s; border: 1px solid %5$s; border-radius: %12$s;
  box-shadow: %13$s; padding: 16px; margin-bottom: 20px; }
.mc2-panel-title { font-size: 1rem; font-weight: 700; color: %3$s; margin: 0 0 12px;
  padding-bottom: 12px; border-bottom: 1px solid %5$s; display: flex; align-items: center; gap: 8px; }
.mc2-panel-title .fa, .mc2-panel-title svg { color: %4$s; }
.well { background: %14$s; border: 1px solid %5$s; border-radius: %12$s; box-shadow: none; padding: 18px; }
.help-block, .form-text { color: %10$s; font-size: .875rem; }
.control-label { color: %2$s; font-weight: 500; font-size: .875rem; }
hr { border-color: %5$s; opacity: 1; }

/* Buttons: primary is solid brand (from the theme); secondary is the soft brand tint.
   Shiny's actionButton always adds btn-default, so the tint must skip btn-primary. */
.btn { border-radius: %7$s; font-weight: 500; }
.btn-default:not(.btn-primary), .btn-secondary { background: %15$s; color: %4$s; border: 1px solid %16$s; }
.btn-default:not(.btn-primary):hover, .btn-secondary:hover { background: %16$s; color: %4$s; border-color: %16$s; }
.form-control, .form-select, .selectize-input { border-radius: %7$s; border-color: %5$s; box-shadow: none; }

/* KPI cards */
.mc2-kpis { display: grid; grid-template-columns: repeat(auto-fit, minmax(170px, 1fr)); gap: 16px; margin-bottom: 20px; }
.mc2-kpi { background: %1$s; border: 1px solid %5$s; border-radius: %12$s; box-shadow: %13$s;
  padding: 18px 20px; display: flex; justify-content: space-between; align-items: flex-start;
  transition: %17$s; }
.mc2-kpi:hover { transform: translateY(-2px); box-shadow: %18$s; }
.mc2-kpi .value { font-size: 2rem; font-weight: 700; line-height: 1.1; color: %3$s; }
.mc2-icon-tile { width: 40px; height: 40px; min-width: 40px; border-radius: %12$s; background: %15$s;
  border: 1px solid %16$s; color: %4$s; display: grid; place-items: center; font-size: 16px; }

/* Chips */
.mc2-chip { display: inline-block; padding: 2px 8px; border-radius: 9999px; font-size: 12px;
  font-weight: 500; line-height: 1.5; white-space: nowrap; }

/* Tables */
table.dataTable thead th, .table thead th { color: %10$s; font-weight: 500; font-size: .875rem;
  background: %14$s; border-bottom: 1px solid %5$s !important; }
table.dataTable tbody td, .table td { color: %2$s; border-color: %5$s; white-space: nowrap; }
/* DataTables stripes and hovers with an inset box-shadow, which tints over the status
   cells' own fill. Use row backgrounds instead, which an inline status fill overrides. */
table.dataTable > tbody > tr > td { box-shadow: none !important; }
table.dataTable > tbody > tr:nth-child(odd) > td { background-color: %14$s; }
table.dataTable > tbody > tr:hover > td { background-color: %15$s; }
table.dataTable > tbody, .table > :not(caption) + tbody { border-top: 1px solid %5$s !important; }
table.dataTable caption, .dataTables_wrapper caption { color: %10$s; font-size: 12px; font-weight: 500;
  text-transform: uppercase; letter-spacing: %11$s; caption-side: top; }
table.dataTable.no-footer { border-bottom: 1px solid %5$s; }

/* News feed */
.mc2-feed { height: 452px; overflow-y: auto; }
.mc2-feed-item { padding: 10px 2px; border-bottom: 1px solid %5$s; }
.mc2-feed-item:last-child { border-bottom: 0; }
.mc2-feed-meta { font-size: 12px; color: %10$s; margin-top: 2px; }
",
    t$surface, t$text, t$ink, t$brand_text, t$border, t$brand,           # 1-6
    t$radius_control, t$mark_ground, t$mark, t$muted, t$tracking,        # 7-11
    t$radius_panel, t$shadow_panel, t$surface_alt, t$brand_wash,         # 12-15
    t$brand_soft, t$motion, t$shadow_hover)                              # 16-18
}

mc2_theme <- function() {
  bslib::bs_theme(
    version = 5,
    bg = MC2$surface, fg = MC2$ink,
    primary = MC2$brand, secondary = MC2$surface_muted,
    success = STATUS_FILL[["OK"]], warning = STATUS_FILL[["AT RISK"]],
    danger = STATUS_FILL[["STOCKOUT"]], info = CHART_CATEGORICAL[2],
    base_font = bslib::font_collection(bslib::font_google("Inter", wght = c(400, 500, 600, 700)),
                                       "system-ui", "-apple-system", "Segoe UI", "Roboto", "sans-serif"),
    heading_font = bslib::font_collection(bslib::font_google("Inter", wght = c(600, 700)),
                                          "system-ui", "sans-serif"),
    "body-color" = MC2$text,
    "border-color" = MC2$border,
    "border-radius" = MC2$radius_control,
    "border-radius-lg" = MC2$radius_panel,
    "link-color" = MC2$brand_text
  ) |>
    bslib::bs_add_rules(mc2_css())
}

# ---- Shiny building blocks (REINS ui.py, restated for Shiny) --------------- #
mc2_brand <- function() {
  tags$div(class = "mc2-brand",
    tags$div(class = "mc2-tile", role = "img", `aria-label` = "MC²", "MC²"),
    tags$div(class = "mc2-descriptor", "Monte-Carlo clinical supply simulator"))
}

mc2_eyebrow <- function(text, brand = FALSE) {
  tags$p(class = paste("mc2-eyebrow", if (brand) "brand"), text)
}

mc2_page_header <- function(title, subtitle = NULL) {
  tags$div(class = "mc2-page-header", tags$h2(title), if (!is.null(subtitle)) tags$p(subtitle))
}

mc2_panel <- function(..., title = NULL, icon = NULL) {
  tags$div(class = "mc2-panel",
    if (!is.null(title)) tags$div(class = "mc2-panel-title",
                                  if (!is.null(icon)) shiny::icon(icon), title),
    ...)
}

mc2_chip <- function(text, fg = MC2$text, bg = MC2$surface_muted, min_width = NULL) {
  tags$span(class = "mc2-chip",
            style = sprintf("color:%s;background:%s;%s", fg, bg,
                            if (is.null(min_width)) "" else paste0("min-width:", min_width, ";text-align:center;")),
            text)
}

mc2_status_chip <- function(status) mc2_chip(status, STATUS_FG[[status]], STATUS_BG[[status]])

# KPI card: eyebrow, value in ink, brand icon tile. A status count takes its status
# colour only when it is above zero, the rule REINS applies to over-allocation.
mc2_kpi <- function(label, value, icon, status = NULL) {
  colour <- if (!is.null(status) && is.finite(as.numeric(value)) && as.numeric(value) > 0)
    STATUS_FG[[status]] else MC2$ink
  tags$div(class = "mc2-kpi",
    tags$div(mc2_eyebrow(label), tags$div(class = "value", style = paste0("color:", colour), value)),
    tags$div(class = "mc2-icon-tile", shiny::icon(icon)))
}

# DataTables: tint a status column with the status pairs.
mc2_status_cells <- function(dt, column) {
  DT::formatStyle(dt, column,
    color = DT::styleEqual(STATUS_LEVELS, unname(STATUS_FG[STATUS_LEVELS])),
    backgroundColor = DT::styleEqual(STATUS_LEVELS, unname(STATUS_BG[STATUS_LEVELS])),
    fontWeight = "500")
}

# ---- ggplot ---------------------------------------------------------------- #
# The R graphics device cannot load web fonts, so plots use the system sans; the
# colours, weights and rules are the system's.
theme_mc2 <- function(base_size = 12) {
  ggplot2::theme_minimal(base_size = base_size) +
    ggplot2::theme(
      plot.title = ggplot2::element_text(face = "bold", colour = MC2$ink, size = ggplot2::rel(1.15)),
      plot.subtitle = ggplot2::element_text(colour = MC2$muted, margin = ggplot2::margin(b = 8)),
      plot.title.position = "plot",
      axis.title = ggplot2::element_text(colour = MC2$muted, size = ggplot2::rel(.9)),
      axis.text = ggplot2::element_text(colour = MC2$muted),
      panel.grid.major = ggplot2::element_line(colour = MC2$border, linewidth = .4),
      panel.grid.minor = ggplot2::element_blank(),
      panel.grid.major.x = ggplot2::element_blank(),
      legend.text = ggplot2::element_text(colour = MC2$text),
      legend.title = ggplot2::element_blank(),
      legend.position = "bottom",
      plot.background = ggplot2::element_rect(fill = MC2$surface, colour = NA))
}

# A month or quarter axis stored as text labels every step; keep every nth so they stay legible.
scale_x_every <- function(n = 3) {
  ggplot2::scale_x_discrete(breaks = function(x) x[seq(1, length(x), by = n)])
}

scale_colour_mc2 <- function(...) {
  ggplot2::discrete_scale("colour", palette = function(n) rep_len(CHART_CATEGORICAL, n), ...)
}

# ---- plotly: the site status map (the app's tab 5 and site/map.html) ------- #
site_status_map <- function(d, source = "site_map") {
  # Traces draw in level order, so OK goes first and STOCKOUT last, on top: two sites a
  # few km apart must not hide a stockout under an at-risk marker. The legend is reversed
  # so it still reads worst first.
  d$Status <- factor(d$Status, levels = rev(STATUS_LEVELS))
  font <- list(family = MC2$font_stack, color = MC2$text, size = 12)
  plotly::plot_geo(d, lat = ~latitude, lon = ~longitude, source = source) |>
    plotly::add_markers(
      color = ~Status, colors = STATUS_FILL,
      text = ~hover, hoverinfo = "text", customdata = ~id,
      marker = list(size = 13, line = list(width = 1.5, color = MC2$surface))) |>
    plotly::layout(
      font = font,
      hoverlabel = list(bgcolor = MC2$surface, bordercolor = MC2$border,
                        font = list(family = MC2$font_stack, color = MC2$ink, size = 12)),
      geo = list(showland = TRUE, landcolor = MC2$surface_muted,
                 showcountries = TRUE, countrycolor = MC2$separator,
                 showcoastlines = TRUE, coastlinecolor = MC2$separator,
                 showframe = FALSE, bgcolor = MC2$surface,
                 projection = list(type = "natural earth")),
      paper_bgcolor = MC2$surface,
      legend = list(orientation = "h", x = 0, y = -0.05, font = font, traceorder = "reversed"),
      margin = list(l = 0, r = 0, t = 0, b = 0))
}

# Per-site rollup of an inventory summary, joined to coordinates, with hover text.
# Shared by the app and scripts/make_demo_assets.R.
site_status_frame <- function(summary, loc) {
  s <- summary
  s$Site <- trimws(as.character(s$Site))
  loc$center <- trimws(as.character(loc$center))
  loc$protocol <- trimws(as.character(loc$protocol))
  agg <- s |>
    dplyr::group_by(Protocol, Site) |>
    dplyr::summarise(
      DUs          = dplyr::n(),
      Stockout_DUs = sum(Status == "STOCKOUT"),
      AtRisk_DUs   = sum(Status == "AT RISK"),
      Min_Days_Supply = suppressWarnings(min(Min_Days_Supply, na.rm = TRUE)),
      Earliest_Stockout = {
        v <- First_Stockout[!is.na(First_Stockout)]
        if (length(v)) min(v) else as.Date(NA)
      },
      .groups = "drop") |>
    dplyr::mutate(Status = ifelse(Stockout_DUs > 0, "STOCKOUT",
                          ifelse(AtRisk_DUs > 0, "AT RISK", "OK")))
  merge(agg, loc, by.x = c("Protocol", "Site"), by.y = c("protocol", "center"), all.x = TRUE)
}

site_status_hover <- function(d) {
  esd <- ifelse(is.na(d$Earliest_Stockout), "—",
                as.character(as.Date(d$Earliest_Stockout, origin = "1970-01-01")))
  sprintf(
    "<b>%s — site %s</b> (%s)<br>Status: %s<br>Min days of supply: %s<br>Earliest stockout: %s<br>%d DU(s): %d stockout, %d at risk",
    d$Protocol, d$Site, d$country_name, as.character(d$Status),
    ifelse(is.finite(d$Min_Days_Supply), round(d$Min_Days_Supply, 1), "∞"),
    esd, d$DUs, d$Stockout_DUs, d$AtRisk_DUs)
}
