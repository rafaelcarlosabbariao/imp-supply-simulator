#!/usr/bin/env Rscript
# =========================================================================== #
# test_app.R  --  the app, driven from tab 1 to tab 5 without a browser
#
#   Rscript tests/test_app.R
#
# shiny::testServer runs server.R against the sample data: enrollment, visits
# (with the worked titration example), then the inventory projection under
# each forecast, each opening mode and a disruption scenario.
# =========================================================================== #

root <- normalizePath(file.path(dirname(sub("--file=", "",
          grep("--file=", commandArgs(FALSE), value = TRUE))[1]), ".."))
setwd(root)
suppressPackageStartupMessages(source("global.R"))

.pass <- 0L; .fail <- 0L
ok <- function(label, cond, detail = "") {
  if (isTRUE(cond)) { .pass <<- .pass + 1L; cat(sprintf("  ok   %s\n", label)) }
  else { .fail <<- .fail + 1L; cat(sprintf("  FAIL %s  %s\n", label, detail)) }
}
tried <- function(expr) tryCatch(expr, error = function(e) e)

server <- local({ source("server.R", local = TRUE)$value })

shiny::testServer(server, {
  base <- list(num_simulations = 2, visit_window = 3, sim_end_date = as.Date("2026-12-31"),
               as_of_date = as.Date("2024-01-01"), lead_time_days = 21,
               safety_stock_days = 30, target_days = 90, unplanned_visit_pct = 10,
               oversupply_pct = 10, forecast_mode = "trailing", opening_mode = "snapshot",
               seed_on = FALSE, seed_patients = NA, seed_lead_days = 21, scenario = "")
  do.call(session$setInputs, base)

  cat("\n== tab 1: titration ==\n")
  session$setInputs(titration_example = 1)
  ok("the worked example loads a titration spec and its dosing schedule",
     !is.null(rv$titration) && any(grepl("^Option6", names(rv$dosing_cur))))

  cat("\n== tabs 1-2: enrollment and visits ==\n")
  session$setInputs(run_enrollment = 1)
  session$setInputs(run_simulation = 1)
  v <- tried(visit_data())
  ok("visits simulate with the ladder and carry dose status",
     !inherits(v, "error") && any(v$Dose_Status %in% "Stable"),
     if (inherits(v, "error")) conditionMessage(v) else "")

  cat("\n== tab 3: the projection ==\n")
  runs <- 0
  for (m in c("trailing", "rung", "oracle")) {
    runs <- runs + 1
    session$setInputs(forecast_mode = m, run_inventory = runs)
    pr <- tried(projection())
    ok(sprintf("the %s forecast runs and names itself", m),
       !inherits(pr, "error") && pr$forecast == m,
       if (inherits(pr, "error")) conditionMessage(pr) else "")
  }
  runs <- runs + 1
  session$setInputs(forecast_mode = "trailing", opening_mode = "seeded", run_inventory = runs)
  pr <- tried(projection())
  sd <- if (inherits(pr, "error")) NULL else pr$shipments[pr$shipments$Source == "seed", ]
  ok("empty sites stocked by seeds: the site file is set aside and every seed counts",
     !inherits(pr, "error") && pr$opening == "seeded" && nrow(sd) > 0 &&
       !any(grepl("^dropped", sd$Note)),
     if (inherits(pr, "error")) conditionMessage(pr) else "")
  ok("seeds that shipped before the as-of date are reported on the page",
     any(grepl("before the as-of date", rv$proj_notes)))
  runs <- runs + 1
  session$setInputs(opening_mode = "snapshot", seed_on = TRUE,
                    scenario = "global_port_strike.csv", run_inventory = runs)
  pr <- tried(projection())
  ok("a snapshot with seeding on drops the seeds that left before the as-of date",
     !inherits(pr, "error") && any(grepl("^dropped", pr$shipments$Note)))
  ok("the port strike scenario delays shipments", any(pr$shipments$Delay_Days == 14))
  ok("the sample in-transit file is loaded, with its overdue shipments",
     any(pr$shipments$Source == "in_transit") && any(pr$shipments$Overdue))

  cat("\n== outputs ==\n")
  ok("the shipment ledger renders", !inherits(tried(output$shipments_DT), "error"))
  ok("the portfolio KPIs render", !inherits(tried(output$kpi_boxes), "error"))
  ok("the alerts render", !inherits(tried(output$site_alerts), "error"))
  rv$selected_site <- paste("TRIAL-118", "1005 · Argentina", sep = "|"); session$flushReact()
  det <- tried(output$site_detail)
  html <- if (inherits(det, "error")) conditionMessage(det) else paste(unlist(det), collapse = " ")
  ok("a site's detail lists its inbound shipments", grepl("Inbound shipments", html),
     substr(html, 1, 300))

  cat("\n== errors reach the page ==\n")
  session$setInputs(as_of_date = as.Date("2030-01-01"), run_inventory = runs + 1)
  e <- tried(projection())
  ok("an as-of date after the horizon is reported, not a crash",
     inherits(e, "error") && grepl("after the horizon", conditionMessage(e)))
})

cat(sprintf("\n%d passed, %d failed\n", .pass, .fail))
quit(status = if (.fail > 0L) 1L else 0L)
