#!/usr/bin/env Rscript
# =========================================================================== #
# test_forecast.R  --  what the reorder rule orders on
#
#   Rscript tests/test_forecast.R
#
# A fixed-dose protocol with enrollment on a single day and no visit jitter,
# so demand is deterministic and every check below reads an exact date.
# =========================================================================== #

suppressPackageStartupMessages({ library(dplyr) })
root <- normalizePath(file.path(dirname(sub("--file=", "",
          grep("--file=", commandArgs(FALSE), value = TRUE))[1]), ".."))
source(file.path(root, "R/titration.R"))
source(file.path(root, "R/simulation.R"))
source(file.path(root, "R/forecast.R"))
source(file.path(root, "R/inventory.R"))
source(file.path(root, "R/seeding.R"))

.pass <- 0L; .fail <- 0L
ok <- function(label, cond, detail = "") {
  if (isTRUE(cond)) { .pass <<- .pass + 1L; cat(sprintf("  ok   %s\n", label)) }
  else { .fail <<- .fail + 1L; cat(sprintf("  FAIL %s  %s\n", label, detail)) }
}

dosing <- data.frame(Protocol = "P1", Arm = "A1", DU_Description = "DRUG",
                     Cycles = 30L, Cycle_Length = 14L, Option1 = 4,
                     stringsAsFactors = FALSE)
plan <- data.frame(Protocol = "P1", Cohort = "C1", Arm = "A1", Patients = 10L,
                   Enroll_Start = as.Date("2024-05-01"), Enroll_End = as.Date("2024-05-01"),
                   Country = "USA", Center = "1001", stringsAsFactors = FALSE)
US <- "1001 · USA"

set.seed(1)
d <- compute_demand(simulate_visits(simulate_enrollment(plan, 1L), dosing, visit_window = 0,
                                    simulation_end_date = as.Date("2025-06-01")))
depot <- data.frame(protocol = "P1", depot_name = "D1", du_description = "DRUG",
                    depot_inventory_count = 1e6, retest_date_inv = "2030-01-01")
stock <- data.frame(protocol_id = "P1", center_number = "1001", country_name = "USA",
                    du_description = "DRUG", site_inventory_count = 60,
                    retest_date_inv = "2030-01-01")
pars <- list(start_date = as.Date("2024-06-01"), horizon_end = as.Date("2025-06-01"),
             unplanned_visit_pct = 0)
run <- function(...) suppressWarnings(suppressMessages(project_inventory(...)))
at <- function(pr, date, col) pr$daily[[col]][pr$daily$Date == as.Date(date)]

cat("\n== 1. the default is the trailing forecast ==\n")
{
  pr <- run(d, stock, depot, pars)
  ok("a run that names no mode orders on the trailing forecast",
     pr$forecast == "trailing" && all(pr$summary$Forecast == "trailing"))
  orc <- run(d, stock, depot, pars, forecast = "oracle")
  ok("the oracle runs when named, and says so",
     orc$forecast == "oracle" && all(orc$summary$Forecast == "oracle"))
  ok("an unknown mode stops the run",
     inherits(tryCatch(run(d, stock, depot, pars, forecast = "psychic"),
                       error = function(e) e), "error"))
}

cat("\n== 2. the trailing forecast reads what was dispensed before the as-of date ==\n")
{
  # Visits on 05-15 and 05-29 dispense 40 units each, before the 06-01 as-of
  # date. A planner holding 60 units on 06-01 has seen 80 go in 18 days.
  pr <- run(d, stock, depot, pars)
  ok("a site open before the as-of date reorders on day one",
     at(pr, "2024-06-01", "Reorder_Qty") > 0,
     sprintf("day-one reorder %.0f", at(pr, "2024-06-01", "Reorder_Qty")))
  later <- run(d, stock, depot, modifyList(pars, list(start_date = as.Date("2024-04-01"))))
  ok("a site with no history orders nothing until it dispenses",
     sum(later$daily$Reorder_Qty[later$daily$Date < as.Date("2024-05-15")]) == 0)
  short <- run(d, stock, depot, modifyList(pars, list(trailing_window_days = 2)))
  ok("the window is capped at trailing_window_days",
     at(short, "2024-06-01", "Reorder_Qty") == 0,
     "2 days back from 06-01 reaches 05-31 and misses both visits")
}

cat(sprintf("\n%d passed, %d failed\n", .pass, .fail))
quit(status = if (.fail > 0L) 1L else 0L)
