# =========================================================================== #
# ui.R  --  Study Simulation: IMP demand + supply/inventory
# =========================================================================== #

# Libraries are loaded in global.R.

shinyUI(fluidPage(
  theme = shinytheme("spacelab"),
  shinyjs::useShinyjs(),
  titlePanel("Study Simulation - IMP Demand & Supply"),

  navbarPage(
    title = NULL, id = "main_nav",

    # ==================================================================== #
    # 1. STUDY CONFIGURATION
    # ==================================================================== #
    tabPanel(
      "1. Study Configuration",
      sidebarLayout(
        sidebarPanel(
          width = 3,
          h4("Demand settings"),
          sliderInput("num_simulations", "Number of simulations (trials)",
                      min = 1, max = 50, value = 5),
          actionButton("run_enrollment", "Run Enrollment", class = "btn-primary"),
          hr(),
          helpText("Upload or edit the enrollment plan and dosing schedule for",
                   "ANY protocol. Required enrollment columns: Protocol, Cohort,",
                   "Arm, Patients, Enroll_Start, Enroll_End, Country, Center.",
                   "Required dosing columns: Protocol, Arm, DU_Description, Cycles,",
                   "Cycle_Length, Option1 (units/dispense).")
        ),
        mainPanel(
          width = 9,
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
          ),
          hr(),
          withSpinner(plotOutput("enrolled_subjects_Plot", height = "350px")),
          withSpinner(DT::dataTableOutput("enrolled_subjects_DT"))
        )
      )
    ),

    # ==================================================================== #
    # 2. VISITS / DEMAND
    # ==================================================================== #
    tabPanel(
      "2. Visits & Demand",
      sidebarLayout(
        sidebarPanel(
          width = 3,
          h4("Visit settings"),
          sliderInput("visit_window", "Visit window (+/- days)",
                      min = 0, max = 7, value = 3),
          dateInput("sim_end_date", "Simulation End Date",
                    value = Sys.Date() + years(2), format = "yyyy-mm-dd"),
          actionButton("run_simulation", "Run Visit Simulation", class = "btn-primary"),
          hr(),
          helpText("Steps every enrolled subject through their dosing cycles and",
                   "records the IMP units dispensed at each visit. Run enrollment",
                   "on tab 1 first.")
        ),
        mainPanel(
          width = 9,
          withSpinner(plotOutput("simulated_visits_Plot", height = "380px")),
          withSpinner(DT::dataTableOutput("simulated_visits_DT"))
        )
      )
    ),

    # ==================================================================== #
    # 3. SUPPLY / INVENTORY
    # ==================================================================== #
    tabPanel(
      "3. Supply & Inventory",
      sidebarLayout(
        sidebarPanel(
          width = 3,
          h4("Planning assumptions"),
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
          fileInput("site_inv_file", "Upload Site Inventory",
                    accept = c(".csv", ".xls", ".xlsx")),
          fileInput("depot_inv_file", "Upload Depot Inventory",
                    accept = c(".csv", ".xls", ".xlsx")),
          actionButton("run_inventory", "Run Inventory Projection", class = "btn-primary"),
          hr(),
          helpText("Projects on-hand inventory forward under an order-up-to",
                   "resupply policy with FEFO consumption and lot expiry. Run the",
                   "visit simulation on tab 2 first. Inventory columns are mapped",
                   "flexibly (protocol_id/center_number/du_description/",
                   "site_inventory_count/retest_date_inv, or equivalents).")
        ),
        mainPanel(
          width = 9,
          fluidRow(column(6, withSpinner(DT::dataTableOutput("site_inv_DT"))),
                   column(6, withSpinner(DT::dataTableOutput("depot_inv_DT")))),
          hr(),
          h4("Inventory status by site x DU"),
          withSpinner(DT::dataTableOutput("inventory_summary_DT")),
          hr(),
          h4("Projected on-hand over time"),
          fluidRow(
            column(4, selectInput("inv_protocol", "Protocol", choices = NULL)),
            column(4, selectInput("inv_site", "Site (optional)", choices = NULL))),
          withSpinner(plotOutput("inventory_time_Plot", height = "360px")),
          hr(),
          h4("Daily projection detail"),
          withSpinner(DT::dataTableOutput("inventory_daily_DT"))
        )
      )
    ),

    # ==================================================================== #
    # 4. PORTFOLIO
    # ==================================================================== #
    tabPanel(
      "4. Portfolio",
      br(),
      p("IMP inventory health across ALL simulated studies and sites.",
        "Run the inventory projection on tab 3 to populate."),
      withSpinner(uiOutput("kpi_boxes")),
      br(),
      withSpinner(DT::dataTableOutput("portfolio_by_study_DT"))
    ),

    # ==================================================================== #
    # 5. SITE MAP  (geospatial IMP status + drill-down + news feed)
    # ==================================================================== #
    tabPanel(
      "5. Site Map",
      br(),
      p("Clinical sites plotted by IMP status. Marker colour = worst status",
        "across that site's dispensing units; click a site for the detail",
        "below. Run the inventory projection on tab 3 to populate."),
      fluidRow(
        column(
          width = 8,
          uiOutput("map_protocol_ui"),
          withSpinner(plotly::plotlyOutput("site_map", height = "500px"))
        ),
        column(
          width = 4,
          div(style = "display:flex;align-items:center;justify-content:space-between;",
              h4("Global supply-chain feed"),
              actionButton("refresh_news", "Refresh", class = "btn-sm btn-default")),
          p(style = "font-size:12px;color:#888;margin-top:-6px;",
            "External events that could disrupt IMP supply (live headlines)."),
          div(style = "height:452px;overflow-y:auto;border:1px solid #eee;border-radius:6px;padding:4px 8px;",
              withSpinner(uiOutput("news_feed")))
        )
      ),
      hr(),
      fluidRow(
        column(
          width = 6,
          h4("Site detail"),
          withSpinner(uiOutput("site_detail")),
          withSpinner(plotOutput("site_detail_plot", height = "300px"))
        ),
        column(
          width = 6,
          h4("Alerts"),
          withSpinner(DT::dataTableOutput("site_alerts"))
        )
      )
    )
  )
))
