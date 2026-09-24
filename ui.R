# =========================================================================== #
# ui.R  --  MC²: Monte-Carlo IMP demand + supply/inventory
# =========================================================================== #

# Libraries are loaded in global.R; tokens and building blocks in R/brand.R.

shinyUI(page_navbar(
  title = mc2_brand(),
  window_title = "MC² · Monte-Carlo clinical supply simulator",
  id = "main_nav",
  theme = mc2_theme(),
  fillable = FALSE,
  header = tagList(
    shinyjs::useShinyjs(),
    tags$head(tags$link(rel = "icon", type = "image/svg+xml", href = "favicon.svg"))
  ),

  # ==================================================================== #
  # 1. STUDY CONFIGURATION
  # ==================================================================== #
  tabPanel(
    "1. Study Configuration",
    mc2_page_header("Study Configuration",
      "The enrollment plan and dosing schedule for any protocol. Running enrollment simulates who enrolls, where, and when."),
    sidebarLayout(
      sidebarPanel(
        width = 3,
        mc2_eyebrow("Demand settings"),
        sliderInput("num_simulations", "Number of simulations (trials)",
                    min = 1, max = 50, value = 5),
        actionButton("run_enrollment", "Run Enrollment", class = "btn-primary w-100"),
        hr(),
        helpText("Upload or edit the enrollment plan and dosing schedule for",
                 "any protocol. Required enrollment columns: Protocol, Cohort,",
                 "Arm, Patients, Enroll_Start, Enroll_End, Country, Center.",
                 "Required dosing columns: Protocol, Arm, DU_Description, Cycles,",
                 "Cycle_Length, Option1 (units/dispense).")
      ),
      mainPanel(
        width = 9,
        mc2_panel(
          tabsetPanel(
            tabPanel("Enrollment Plan",
              br(),
              fileInput("enrollment_file", "Upload Enrollment File",
                        accept = c(".csv", ".xls", ".xlsx")),
              withSpinner(rHandsontableOutput("enrollment_DT"))),
            tabPanel("Dosing Schedule",
              br(),
              fileInput("dosing_file", "Upload Dosing Schedule",
                        accept = c(".csv", ".xls", ".xlsx")),
              withSpinner(rHandsontableOutput("dosing_DT")))
          )
        ),
        mc2_panel(title = "Simulated enrollment", icon = "users",
          withSpinner(plotOutput("enrolled_subjects_Plot", height = "350px")),
          withSpinner(DT::dataTableOutput("enrolled_subjects_DT")))
      )
    )
  ),

  # ==================================================================== #
  # 2. VISITS / DEMAND
  # ==================================================================== #
  tabPanel(
    "2. Visits & Demand",
    mc2_page_header("Visits & Demand",
      "Each enrolled subject stepped through their dosing cycles, with the IMP units dispensed at every visit."),
    sidebarLayout(
      sidebarPanel(
        width = 3,
        mc2_eyebrow("Visit settings"),
        sliderInput("visit_window", "Visit window (+/- days)",
                    min = 0, max = 7, value = 3),
        dateInput("sim_end_date", "Simulation End Date",
                  value = Sys.Date() + years(2), format = "yyyy-mm-dd"),
        actionButton("run_simulation", "Run Visit Simulation", class = "btn-primary w-100"),
        hr(),
        helpText("Steps every enrolled subject through their dosing cycles and",
                 "records the IMP units dispensed at each visit. Run enrollment",
                 "on tab 1 first.")
      ),
      mainPanel(
        width = 9,
        mc2_panel(title = "Units dispensed", icon = "chart-line",
          withSpinner(plotOutput("simulated_visits_Plot", height = "380px")),
          withSpinner(DT::dataTableOutput("simulated_visits_DT")))
      )
    )
  ),

  # ==================================================================== #
  # 3. SUPPLY / INVENTORY
  # ==================================================================== #
  tabPanel(
    "3. Supply & Inventory",
    mc2_page_header("Supply & Inventory",
      "On-hand inventory projected forward under an order-up-to resupply policy, with FEFO consumption and lot expiry."),
    sidebarLayout(
      sidebarPanel(
        width = 3,
        mc2_eyebrow("Planning assumptions"),
        dateInput("as_of_date", "Inventory as-of date",
                  value = as.Date("2024-01-01"), format = "yyyy-mm-dd"),
        numericInput("lead_time_days", "Resupply lead time (days)", value = 21, min = 0),
        numericInput("safety_stock_days", "Safety stock (days)", value = 30, min = 0),
        numericInput("target_days", "Order-up-to target (days)", value = 90, min = 1),
        sliderInput("unplanned_visit_pct", "Unplanned visit uplift (%)",
                    min = 0, max = 50, value = 10),
        sliderInput("oversupply_pct", "Oversupply buffer (%)",
                    min = 0, max = 50, value = 10),
        hr(),
        mc2_eyebrow("Inventory files"),
        fileInput("site_inv_file", "Upload Site Inventory",
                  accept = c(".csv", ".xls", ".xlsx")),
        fileInput("depot_inv_file", "Upload Depot Inventory",
                  accept = c(".csv", ".xls", ".xlsx")),
        actionButton("run_inventory", "Run Inventory Projection", class = "btn-primary w-100"),
        hr(),
        helpText("Projects on-hand inventory forward under an order-up-to",
                 "resupply policy with FEFO consumption and lot expiry. Run the",
                 "visit simulation on tab 2 first. Inventory columns are mapped",
                 "flexibly (protocol_id/center_number/du_description/",
                 "site_inventory_count/retest_date_inv, or equivalents).")
      ),
      mainPanel(
        width = 9,
        mc2_panel(title = "Starting inventory", icon = "boxes-stacked",
          fluidRow(column(6, withSpinner(DT::dataTableOutput("site_inv_DT"))),
                   column(6, withSpinner(DT::dataTableOutput("depot_inv_DT"))))),
        mc2_panel(title = "Inventory status by site × DU", icon = "table-list",
          withSpinner(DT::dataTableOutput("inventory_summary_DT"))),
        mc2_panel(title = "Projected on-hand over time", icon = "chart-line",
          fluidRow(
            column(4, selectInput("inv_protocol", "Protocol", choices = NULL)),
            column(4, selectInput("inv_site", "Site (optional)", choices = NULL))),
          withSpinner(plotOutput("inventory_time_Plot", height = "360px"))),
        mc2_panel(title = "Daily projection detail", icon = "calendar-days",
          withSpinner(DT::dataTableOutput("inventory_daily_DT")))
      )
    )
  ),

  # ==================================================================== #
  # 4. PORTFOLIO
  # ==================================================================== #
  tabPanel(
    "4. Portfolio",
    mc2_page_header("Portfolio",
      "IMP inventory health across every simulated study and site. Run the inventory projection on tab 3 to populate."),
    withSpinner(uiOutput("kpi_boxes")),
    mc2_panel(title = "Portfolio status by study", icon = "flask",
      withSpinner(DT::dataTableOutput("portfolio_by_study_DT")))
  ),

  # ==================================================================== #
  # 5. SITE MAP  (geospatial IMP status + drill-down + news feed)
  # ==================================================================== #
  tabPanel(
    "5. Site Map",
    mc2_page_header("Site Map",
      "Clinical sites coloured by the worst IMP status across their dispensing units. Select a site for its detail below. Run the inventory projection on tab 3 to populate."),
    fluidRow(
      column(
        width = 8,
        mc2_panel(title = "Sites by IMP status", icon = "location-dot",
          uiOutput("map_protocol_ui"),
          withSpinner(plotly::plotlyOutput("site_map", height = "500px")))
      ),
      column(
        width = 4,
        mc2_panel(
          tags$div(class = "mc2-panel-title", style = "justify-content:space-between;",
            tags$span(shiny::icon("newspaper"), " Global supply-chain feed"),
            actionButton("refresh_news", "Refresh", class = "btn-sm btn-default")),
          helpText("External events that could disrupt IMP supply (live headlines)."),
          tags$div(class = "mc2-feed", withSpinner(uiOutput("news_feed"))))
      )
    ),
    fluidRow(
      column(
        width = 6,
        mc2_panel(title = "Site detail", icon = "hospital",
          withSpinner(uiOutput("site_detail")),
          withSpinner(plotOutput("site_detail_plot", height = "300px")))
      ),
      column(
        width = 6,
        mc2_panel(title = "Alerts", icon = "triangle-exclamation",
          withSpinner(DT::dataTableOutput("site_alerts")))
      )
    )
  )
))
