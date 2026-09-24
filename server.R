# =========================================================================== #
# server.R  --  MC²: Monte-Carlo IMP demand + supply/inventory
#
# Demand (enrollment -> visits -> dispensing) AND supply (inventory projection
# with expiry, resupply, stockout detection) for ANY protocol whose inputs use
# the required, labelled columns. All the modelling lives in R/simulation.R and
# R/inventory.R; this file just wires it to the UI.
# =========================================================================== #

# Libraries and the shared demand+supply engine are loaded in global.R.

# Make a data frame safe for rhandsontable <-> hot_to_r round-trips:
#   * date/datetime columns -> ISO "yyyy-mm-dd" strings. rhandsontable renders
#     Date-typed columns as blank and hot_to_r then reads them back as NA, which
#     silently wipes the enrollment dates. Strings display and round-trip
#     cleanly; the engine parses them via as_date_flex().
#   * all-NA logical columns (e.g. empty Excel Option5/Option6) -> character, so
#     hot_to_r doesn't fail coercing edited text into an NA logical column.
sanitize_hot <- function(df) {
  df <- as.data.frame(df, stringsAsFactors = FALSE)
  for (nm in names(df)) {
    col <- df[[nm]]
    if (inherits(col, "POSIXt") || inherits(col, "Date"))
      df[[nm]] <- format(as.Date(col), "%Y-%m-%d")
    else if (is.logical(col))
      df[[nm]] <- as.character(col)
  }
  df
}

# ---- default sample data (so the app is usable out of the box) ------------ #
load_default_enrollment <- function() {
  if (file.exists("Program_Inputs.xlsx"))
    as.data.frame(read_excel("Program_Inputs.xlsx", sheet = "Enrollment_Input"))
  else data.frame(Protocol = "", Cohort = "", Arm = "", Patients = NA_integer_,
                  Enroll_Start = Sys.Date(), Enroll_End = Sys.Date() + 30,
                  Country = "", Center = "", stringsAsFactors = FALSE)
}
load_default_dosing <- function() {
  if (file.exists("Program_Inputs.xlsx"))
    as.data.frame(read_excel("Program_Inputs.xlsx", sheet = "Dosing_Input"))
  else data.frame(Protocol = "", Arm = "", DU_Description = "",
                  Cycles = NA_integer_, Cycle_Length = NA_integer_,
                  Option1 = NA_real_, stringsAsFactors = FALSE)
}
load_default_csv <- function(path) {
  if (file.exists(path)) read.csv(path, stringsAsFactors = FALSE, check.names = FALSE)
  else data.frame()
}

read_upload <- function(file_path) {
  ext <- tolower(tools::file_ext(file_path))
  if (ext == "csv") read.csv(file_path, stringsAsFactors = FALSE, check.names = FALSE)
  else if (ext %in% c("xls", "xlsx")) as.data.frame(readxl::read_excel(file_path))
  else NULL
}

shinyServer(function(input, output, session) {

  # Editable tables keep TWO values to avoid a render<->edit feedback loop:
  #   *_src drives the rhandsontable render (changed only by default/upload)
  #   *_cur holds the latest edits (changed by edits; read by the simulation)
  # If edits wrote back to the render source, re-rendering would re-emit the
  # edit input and spin forever.
  rv <- reactiveValues(
    enrollment_src = sanitize_hot(load_default_enrollment()),
    enrollment_cur = sanitize_hot(load_default_enrollment()),
    dosing_src     = sanitize_hot(load_default_dosing()),
    dosing_cur     = sanitize_hot(load_default_dosing()),
    site_inv       = load_default_csv("datasets/site_inventory.csv"),
    depot_inv      = load_default_csv("datasets/depot_inventory.csv"),
    site_loc       = load_default_csv("datasets/site_locations.csv"),
    selected_site  = NULL
  )

  # ======================================================================== #
  # STUDY CONFIGURATION : Enrollment plan
  # ======================================================================== #
  output$enrollment_DT <- renderRHandsontable({
    rhandsontable(rv$enrollment_src, height = 260, width = "100%") %>%
      hot_context_menu(allowRowEdit = TRUE, allowColEdit = FALSE)
  })

  observeEvent(input$enrollment_file, {
    req(input$enrollment_file)
    df <- read_upload(input$enrollment_file$datapath)
    if (is.null(df)) { showNotification("Upload a CSV or Excel file.", type = "warning"); return() }
    df <- sanitize_hot(df)
    rv$enrollment_src <- df; rv$enrollment_cur <- df
  })

  observeEvent(input$enrollment_DT, {
    updated <- tryCatch(hot_to_r(input$enrollment_DT), error = function(e) NULL)
    if (!is.null(updated)) rv$enrollment_cur <- sanitize_hot(updated)  # edits only
  }, ignoreInit = TRUE, ignoreNULL = TRUE)

  # ---- Dosing schedule --------------------------------------------------- #
  output$dosing_DT <- renderRHandsontable({
    rhandsontable(rv$dosing_src, height = 260, width = "100%") %>%
      hot_context_menu(allowRowEdit = TRUE, allowColEdit = FALSE)
  })

  observeEvent(input$dosing_file, {
    req(input$dosing_file)
    df <- read_upload(input$dosing_file$datapath)
    if (is.null(df)) { showNotification("Upload a CSV or Excel file.", type = "warning"); return() }
    df <- sanitize_hot(df)
    rv$dosing_src <- df; rv$dosing_cur <- df
  })

  observeEvent(input$dosing_DT, {
    updated <- tryCatch(hot_to_r(input$dosing_DT), error = function(e) NULL)
    if (!is.null(updated)) rv$dosing_cur <- sanitize_hot(updated)  # edits only
  }, ignoreInit = TRUE, ignoreNULL = TRUE)

  # ======================================================================== #
  # DEMAND : enrollment simulation
  # ======================================================================== #
  enrollment_data <- eventReactive(input$run_enrollment, {
    validate(need(nrow(rv$enrollment_cur) > 0, "Add at least one enrollment row."))
    withProgress(message = "Simulating enrollment...", value = 0.5, {
      out <- simulate_enrollment(rv$enrollment_cur, num_simulations = input$num_simulations)
      add_date_windows(out)
    })
  })

  output$enrolled_subjects_Plot <- renderPlot({
    req(input$run_enrollment > 0)
    enrollment_data() %>%
      group_by(Protocol, Trial, Visit_Date_YrQtr) %>%
      summarise(Count = n(), .groups = "drop") %>%
      ggplot(aes(Visit_Date_YrQtr, Count, group = interaction(Protocol, Trial),
                 color = Protocol)) +
      geom_line(alpha = 0.6) +
      scale_colour_mc2() +
      labs(title = "Patients enrolled over time",
           subtitle = "One line per simulated trial",
           x = "Quarter", y = "Patients enrolled") +
      theme_mc2() + theme(axis.text.x = element_text(angle = 45, hjust = 1))
  }, width = 760, height = 360, res = 96)

  output$enrolled_subjects_DT <- DT::renderDataTable({
    req(input$run_enrollment > 0)
    datatable(enrollment_data(), caption = "Simulated Enrolled Subjects",
              rownames = FALSE, filter = "top",
              extensions = c("Buttons", "Scroller"),
              options = list(dom = "Bfrtip", scrollX = TRUE, scrollY = "250px",
                             scrollCollapse = TRUE, buttons = c("copy", "csv", "excel")))
  })

  # ======================================================================== #
  # DEMAND : visit / dispensing simulation
  # ======================================================================== #
  visit_data <- eventReactive(input$run_simulation, {
    patients <- enrollment_data()
    validate(need(nrow(patients) > 0, "Run enrollment first."))
    n <- nrow(patients)
    withProgress(message = "Simulating visits & dispensing...", min = 0, max = n, value = 0, {
      out <- simulate_visits(
        patients, rv$dosing_cur,
        visit_window = input$visit_window,
        simulation_end_date = input$sim_end_date,
        progress = function(i) setProgress(value = i))
      validate(need(nrow(out) > 0,
        "No dispensing generated - check that dosing Arms match enrollment Arms."))
      add_date_windows(out)
    })
  })

  output$simulated_visits_Plot <- renderPlot({
    req(input$run_simulation > 0)
    visit_data() %>%
      filter(!is.na(DU_Desc)) %>%
      group_by(DU_Desc, Visit_Date_YrMo) %>%
      summarise(Units = sum(Qty), .groups = "drop") %>%
      ggplot(aes(Visit_Date_YrMo, Units, group = DU_Desc, color = DU_Desc)) +
      geom_line(linewidth = .7) +
      scale_colour_mc2() +
      scale_x_every(3) +
      labs(title = "IMP units dispensed over time",
           subtitle = "Summed across simulated trials; the table shows the average",
           x = "Month", y = "Units dispensed") +
      theme_mc2() +
      theme(axis.text.x = element_text(angle = 45, hjust = 1)) +
      guides(color = guide_legend(ncol = 2))
  }, width = 760, height = 380, res = 96)

  output$simulated_visits_DT <- DT::renderDataTable({
    req(input$run_simulation > 0)
    v <- visit_data()
    cap <- 5000L
    caption <- if (nrow(v) > cap)
      sprintf("Simulated Visits & Dispensing (showing first %s of %s rows; use the headless runner for the full export)",
              format(cap, big.mark = ","), format(nrow(v), big.mark = ",")) else
      "Simulated Visits & Dispensing"
    datatable(utils::head(v, cap), caption = caption,
              rownames = FALSE, filter = "top",
              extensions = c("Buttons", "Scroller"),
              options = list(dom = "Bfrtip", scrollX = TRUE, scrollY = "350px",
                             scrollCollapse = TRUE, buttons = c("copy", "csv", "excel")))
  })

  # ======================================================================== #
  # SUPPLY : inventory tables (upload / preview)
  # ======================================================================== #
  observeEvent(input$site_inv_file, {
    req(input$site_inv_file)
    df <- read_upload(input$site_inv_file$datapath)
    if (!is.null(df)) rv$site_inv <- df
  })
  observeEvent(input$depot_inv_file, {
    req(input$depot_inv_file)
    df <- read_upload(input$depot_inv_file$datapath)
    if (!is.null(df)) rv$depot_inv <- df
  })

  output$site_inv_DT <- DT::renderDataTable({
    datatable(rv$site_inv, caption = "Current Site Inventory (on hand)",
              rownames = FALSE, options = list(scrollX = TRUE, pageLength = 5))
  })
  output$depot_inv_DT <- DT::renderDataTable({
    datatable(rv$depot_inv, caption = "Current Depot Inventory (on hand)",
              rownames = FALSE, options = list(scrollX = TRUE, pageLength = 5))
  })

  # ---- run the inventory projection -------------------------------------- #
  projection <- eventReactive(input$run_inventory, {
    v <- visit_data()
    demand <- compute_demand(v)
    validate(need(nrow(demand) > 0, "No demand to project - run the visit simulation first."))
    validate(need(nrow(rv$site_inv) > 0, "Provide site inventory."))
    withProgress(message = "Projecting inventory (FEFO + expiry + resupply)...", value = 0.5, {
      project_inventory(
        demand, rv$site_inv, rv$depot_inv,
        params = list(
          safety_stock_days   = input$safety_stock_days,
          target_days         = input$target_days,
          lead_time_days      = input$lead_time_days,
          unplanned_visit_pct = input$unplanned_visit_pct / 100,
          oversupply_pct      = input$oversupply_pct / 100,
          start_date          = input$as_of_date,
          horizon_end         = input$sim_end_date))
    })
  })

  # ---- KPI value boxes --------------------------------------------------- #
  output$kpi_boxes <- renderUI({
    req(input$run_inventory > 0)
    port <- portfolio_summary(projection())
    o <- port$overall
    div(class = "mc2-kpis",
        mc2_kpi("Studies", o$Studies, "flask"),
        mc2_kpi("Site × DU tracked", o$Site_DU_Tracked, "location-dot"),
        mc2_kpi("Stockout", o$Stockouts, "circle-xmark", status = "STOCKOUT"),
        mc2_kpi("At risk", o$At_Risk, "triangle-exclamation", status = "AT RISK"),
        mc2_kpi("OK", o$OK, "circle-check"),
        mc2_kpi("Units expired", round(o$Total_Expired), "hourglass-end"))
  })

  output$portfolio_by_study_DT <- DT::renderDataTable({
    req(input$run_inventory > 0)
    port <- portfolio_summary(projection())
    datatable(port$by_study, rownames = FALSE, options = list(scrollX = TRUE, dom = "t"))
  })

  # ---- site x DU status board (colour-coded) ----------------------------- #
  output$inventory_summary_DT <- DT::renderDataTable({
    req(input$run_inventory > 0)
    s <- projection()$summary
    datatable(s, caption = "Inventory status by site x DU (worst first)",
              rownames = FALSE, filter = "top",
              extensions = c("Buttons"),
              options = list(dom = "Bfrtip", scrollX = TRUE, pageLength = 15,
                             buttons = c("copy", "csv", "excel"))) %>%
      mc2_status_cells("Status")
  })

  # ---- inventory over time (drill-down) ---------------------------------- #
  observeEvent(projection(), {
    d <- projection()$daily
    updateSelectInput(session, "inv_protocol", choices = sort(unique(d$Protocol)))
  })
  observeEvent(input$inv_protocol, {
    d <- projection()$daily
    sites <- sort(unique(d$Site[d$Protocol == input$inv_protocol]))
    updateSelectInput(session, "inv_site", choices = sites)
  })

  output$inventory_time_Plot <- renderPlot({
    req(input$run_inventory > 0)
    d <- projection()$daily
    req(input$inv_protocol)
    d <- d %>% filter(Protocol == input$inv_protocol)
    if (!is.null(input$inv_site) && nzchar(input$inv_site))
      d <- d %>% filter(Site == input$inv_site)
    d <- d %>% mutate(Date = as.Date(Date))
    ss_line <- input$safety_stock_days
    ggplot(d, aes(Date, On_Hand_End, color = DU)) +
      geom_line(linewidth = .6) +
      geom_point(data = d %>% filter(Stockout_Units > 1e-9),
                 aes(Date, On_Hand_End), color = STATUS_FILL[["STOCKOUT"]], size = 1.2) +
      scale_colour_mc2() +
      labs(title = paste("Projected on-hand inventory,", input$inv_protocol,
                         if (nzchar(input$inv_site %||% "")) paste("site", input$inv_site) else ""),
           subtitle = "Red points are stockout days",
           x = NULL, y = "Units on hand (site)") +
      theme_mc2() +
      guides(color = guide_legend(ncol = 2))
  }, width = 760, height = 360, res = 96)

  output$inventory_daily_DT <- DT::renderDataTable({
    req(input$run_inventory > 0)
    d <- projection()$daily
    cap <- 5000L
    caption <- if (nrow(d) > cap)
      sprintf("Daily inventory projection (showing first %s of %s rows)",
              format(cap, big.mark = ","), format(nrow(d), big.mark = ",")) else
      "Daily inventory projection"
    datatable(utils::head(d, cap), caption = caption,
              rownames = FALSE, filter = "top",
              extensions = c("Buttons", "Scroller"),
              options = list(dom = "Bfrtip", scrollX = TRUE, scrollY = "300px",
                             scrollCollapse = TRUE, buttons = c("copy", "csv", "excel")))
  })

  # ======================================================================== #
  # SITE MAP : geospatial view of IMP status, timelines, alerts
  # ======================================================================== #
  # Per-site rollup of the projection, joined to coordinates + enrollment plan.
  site_map_df <- reactive({
    req(input$run_inventory > 0)
    site_status_frame(projection()$summary, rv$site_loc)
  })

  output$map_protocol_ui <- renderUI({
    req(input$run_inventory > 0)
    protos <- sort(unique(projection()$summary$Protocol))
    selectInput("map_protocol", "Protocol", choices = c("All studies" = "All", protos))
  })

  output$site_map <- renderPlotly({
    d <- site_map_df()
    if (!is.null(input$map_protocol) && input$map_protocol != "All")
      d <- d[d$Protocol == input$map_protocol, , drop = FALSE]
    d <- d[!is.na(d$latitude) & !is.na(d$longitude), , drop = FALSE]
    validate(need(nrow(d) > 0, "No mapped sites for this selection."))

    d$id <- paste(d$Protocol, d$Site, sep = "|")
    d$hover <- site_status_hover(d)
    site_status_map(d) %>%
      event_register("plotly_click")
  })

  observeEvent(event_data("plotly_click", source = "site_map"), {
    cd <- event_data("plotly_click", source = "site_map")$customdata
    if (!is.null(cd) && length(cd)) rv$selected_site <- cd[[1]]
  })

  # ---- site drill-down detail -------------------------------------------- #
  output$site_detail <- renderUI({
    req(input$run_inventory > 0)
    sel <- rv$selected_site
    if (is.null(sel)) return(helpText("Click a site on the map to see its IMP detail."))
    parts <- strsplit(sel, "\\|")[[1]]
    proto <- parts[1]; site <- parts[2]

    s <- projection()$summary %>%
      filter(Protocol == proto, trimws(as.character(Site)) == site)
    enr <- rv$enrollment_cur
    enr <- enr[trimws(as.character(enr$Protocol)) == proto &
               site_key(enr$Country, enr$Center) == site, , drop = FALSE]

    worst <- if (any(s$Status == "STOCKOUT")) "STOCKOUT" else
             if (any(s$Status == "AT RISK")) "AT RISK" else "OK"
    du_rows <- lapply(seq_len(nrow(s)), function(i) {
      tags$tr(
        tags$td(s$DU[i]),
        tags$td(style = "text-align:right", s$Start_On_Hand[i]),
        tags$td(style = "text-align:right",
                ifelse(is.finite(s$Min_Days_Supply[i]), round(s$Min_Days_Supply[i], 1), "∞")),
        tags$td(ifelse(is.na(s$First_Stockout[i]), "—", as.character(s$First_Stockout[i]))),
        tags$td(mc2_status_chip(s$Status[i]))
      )
    })
    cohorts <- if (nrow(enr)) paste(unique(enr$Cohort), collapse = ", ") else "—"
    planned <- if (nrow(enr)) sum(as.numeric(enr$Patients), na.rm = TRUE) else NA
    window  <- if (nrow(enr)) sprintf("%s → %s", min(enr$Enroll_Start), max(enr$Enroll_End)) else "—"

    tagList(
      tags$h4(style = "font-size:1.125rem;display:flex;align-items:center;gap:8px;",
              sprintf("%s — Site %s", proto, site), mc2_status_chip(worst)),
      tags$p(tags$b("Enrollment: "),
             sprintf("%s planned patient(s); cohorts: %s; window: %s",
                     ifelse(is.na(planned), "—", planned), cohorts, window)),
      tags$table(class = "table table-sm",
        tags$thead(tags$tr(tags$th("DU"), tags$th("On hand"),
                           tags$th("Days supply"), tags$th("First stockout"), tags$th("Status"))),
        tags$tbody(du_rows))
    )
  })

  output$site_detail_plot <- renderPlot({
    req(input$run_inventory > 0, rv$selected_site)
    parts <- strsplit(rv$selected_site, "\\|")[[1]]
    d <- projection()$daily %>%
      filter(Protocol == parts[1], trimws(as.character(Site)) == parts[2]) %>%
      mutate(Date = as.Date(Date))
    validate(need(nrow(d) > 0, "No projection for this site."))
    ggplot(d, aes(Date, On_Hand_End, color = DU)) +
      geom_line(linewidth = .6) +
      geom_point(data = d %>% filter(Stockout_Units > 1e-9), color = STATUS_FILL[["STOCKOUT"]], size = 1.2) +
      scale_colour_mc2() +
      labs(title = sprintf("On-hand inventory, %s site %s", parts[1], parts[2]),
           x = NULL, y = "Units on hand") +
      theme_mc2(base_size = 11) +
      guides(color = guide_legend(ncol = 1))
  }, width = 520, height = 300, res = 96)

  # ---- alerts board ------------------------------------------------------- #
  output$site_alerts <- DT::renderDataTable({
    req(input$run_inventory > 0)
    d <- site_map_df() %>%
      filter(Status != "OK") %>%
      mutate(Earliest_Stockout = as.Date(Earliest_Stockout, origin = "1970-01-01"),
             Min_Days_Supply = round(Min_Days_Supply, 1)) %>%
      arrange(factor(Status, levels = c("STOCKOUT", "AT RISK")), Earliest_Stockout) %>%
      select(Protocol, Site, Country = country_name, Status,
             Min_Days_Supply, Earliest_Stockout, Stockout_DUs, AtRisk_DUs)
    datatable(d, rownames = FALSE,
              caption = "Sites needing attention, worst first",
              options = list(dom = "t", scrollX = TRUE, pageLength = 20)) %>%
      mc2_status_cells("Status")
  })

  # ======================================================================== #
  # GLOBAL SUPPLY-CHAIN NEWS FEED
  # ======================================================================== #
  news_data <- reactiveVal(NULL)
  refresh_news <- function() {
    withProgress(message = "Fetching supply-chain news...", value = 0.5, {
      news_data(fetch_supply_chain_news(queries = NEWS_QUERIES[1:3],
                                        max_items = 20, timeout = 4))
    })
  }
  observeEvent(input$refresh_news, refresh_news())
  # Lazy load: fetch only when the Site Map tab is first opened, so the network
  # call never blocks app startup or competes with a running simulation.
  observeEvent(input$main_nav, {
    if (grepl("Site Map", input$main_nav %||% "") && is.null(isolate(news_data())))
      refresh_news()
  })

  output$news_feed <- renderUI({
    nd <- news_data()
    if (is.null(nd)) return(helpText("Loading supply-chain news..."))
    items <- lapply(seq_len(nrow(nd)), function(i) {
      when <- if (!is.na(nd$PublishedAt[i]))
        format(nd$PublishedAt[i], "%b %d") else ""
      risk <- nd$Risk[i]
      tags$div(class = "mc2-feed-item",
        tags$div(style = "margin-bottom:4px;",
                 mc2_chip(risk, RISK_FG[[risk]], RISK_BG[[risk]], min_width = "58px")),
        tags$a(href = nd$Link[i], target = "_blank", nd$Title[i]),
        tags$div(class = "mc2-feed-meta",
                 paste(nd$Source[i], if (nzchar(when)) paste("·", when) else "")))
    })
    tagList(items)
  })
  # ---- About page: step buttons and the menu's how-to link (R/about.R) -- #
  mc2_about_server(input, session)
})
