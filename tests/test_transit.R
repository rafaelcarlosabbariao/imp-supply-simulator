#!/usr/bin/env Rscript
# =========================================================================== #
# test_transit.R  --  stock on the road, lead time by country, disruptions
#
#   Rscript tests/test_transit.R
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
                   Country = c("USA", "Japan"), Center = c("1001", "2001"),
                   stringsAsFactors = FALSE)
US <- "1001 · USA"; JP <- "2001 · Japan"

set.seed(1)
d <- compute_demand(simulate_visits(simulate_enrollment(plan, 1L), dosing, visit_window = 0,
                                    simulation_end_date = as.Date("2025-06-01")))
none <- data.frame(Protocol = character(0), Location = character(0), DU = character(0),
                   Qty = numeric(0), Expiry = as.Date(character(0)))
depot <- data.frame(protocol = "P1", depot_name = "D1", du_description = "DRUG",
                    depot_inventory_count = 1e6, retest_date_inv = "2030-01-01")
stock <- data.frame(protocol_id = "P1", center_number = c("1001", "2001"),
                    country_name = c("USA", "Japan"), du_description = "DRUG",
                    site_inventory_count = 200, retest_date_inv = "2030-01-01")
pars <- function(resupply = TRUE, asof = "2024-06-01")
  list(start_date = as.Date(asof), horizon_end = as.Date("2025-06-01"),
       enable_resupply = resupply, unplanned_visit_pct = 0)
run <- function(...) suppressWarnings(suppressMessages(project_inventory(...)))
at <- function(pr, site, date, col) pr$daily[[col]][pr$daily$Site == site &
                                                     pr$daily$Date == as.Date(date)]

cat("\n== 1. a shipment on the road lands on its ETA ==\n")
{
  it <- data.frame(protocol_id = "P1", center_number = "1001", country_name = "USA",
                   du_description = "DRUG", quantity = 50, ship_date = "2024-05-25",
                   eta = "2024-06-10", retest_date = "2026-01-01")
  pr <- run(d, none, NULL, pars(resupply = FALSE), in_transit = it)
  ok("it is received on its ETA", at(pr, US, "2024-06-10", "Received") == 50)
  ok("and counts as on order until then",
     at(pr, US, "2024-06-01", "On_Order") == 50 && at(pr, US, "2024-06-10", "On_Order") == 0)
  ok("it needs no depot: it left before the as-of date",
     nrow(pr$shipments) == 1 && pr$shipments$Source == "in_transit")
}

cat("\n== 2. an overdue shipment ==\n")
{
  it <- data.frame(Protocol = "P1", Site = US, DU = "DRUG", Qty = 30,
                   ETA = as.Date("2024-05-20"))
  pr <- run(d, none, NULL, pars(resupply = FALSE), in_transit = it)
  ok("lands on the first day of the walk", at(pr, US, "2024-06-01", "Received") == 30)
  ok("and is marked overdue in the ledger",
     isTRUE(pr$shipments$Overdue) && pr$shipments$Delay_Days == 12)
}

cat("\n== 3. lead time by country ==\n")
{
  lanes <- data.frame(Country = "Japan", Lead_Time_Days = 42)
  pr <- run(d, stock, depot, pars(), lanes = lanes)
  r <- pr$shipments[pr$shipments$Source == "reorder", ]
  ok("a Japan reorder lands 42 days after it ships",
     nrow(r[r$Site == JP, ]) > 0 && all(r$Arrival[r$Site == JP] - r$Ship_Date[r$Site == JP] == 42))
  ok("a USA reorder keeps the global 21 days",
     nrow(r[r$Site == US, ]) > 0 && all(r$Arrival[r$Site == US] - r$Ship_Date[r$Site == US] == 21))
  lanes2 <- rbind(lanes, data.frame(Country = "Japan", Lead_Time_Days = 7))
  lanes2$Protocol <- c(NA, "P1")
  r2 <- run(d, stock, depot, pars(), lanes = lanes2)$shipments
  ok("a study-specific lane beats the country lane",
     all((r2$Arrival - r2$Ship_Date)[r2$Site == JP & r2$Source == "reorder"] == 7))
}

cat("\n== 4. a disruption window holds up what is due inside it ==\n")
{
  win <- data.frame(Country = "Japan", Start = "2024-07-01", End = "2024-09-30",
                    Delay_Days = 20)
  it <- data.frame(Protocol = "P1", Site = c(JP, US), DU = "DRUG", Qty = 10,
                   ETA = as.Date("2024-08-15"))
  # The dates below were chosen against the oracle's order timing.
  pr <- run(d, stock, depot, pars(), in_transit = it, disruptions = win,
            forecast = "oracle")
  sh <- pr$shipments
  inside <- sh$Site == JP & sh$Planned_Arrival >= as.Date("2024-07-01") &
            sh$Planned_Arrival <= as.Date("2024-09-30")
  ok("reorders and stock on the road due inside the window land 20 days late",
     any(inside & sh$Source == "reorder") && any(inside & sh$Source == "in_transit") &&
       all(sh$Delay_Days[inside] == 20))
  ok("arrivals outside the window, or in another country, are on time",
     all(sh$Delay_Days[!inside & !sh$Overdue] == 0))
}

cat("\n== 5. a known disruption is planned for; an unknown one is a surprise ==\n")
{
  win <- data.frame(Country = "Japan", Start = "2024-07-01", End = "2024-12-31",
                    Delay_Days = 45)
  lean <- stock; lean$site_inventory_count <- 60
  unk <- run(d, lean, depot, pars(), disruptions = win, forecast = "oracle")
  kn  <- run(d, lean, depot, pars(), disruptions = transform(win, Known = TRUE),
             forecast = "oracle")
  so <- function(pr) sum(pr$summary$Total_Stockout[pr$summary$Site == JP])
  ok("an unknown 45-day delay causes stockouts at the Japan site", so(unk) > 0,
     sprintf("%.0f units", so(unk)))
  ok("the same delay, known in advance, causes fewer",
     so(kn) < so(unk), sprintf("known %.0f vs unknown %.0f", so(kn), so(unk)))
  ok("the USA site is untouched either way",
     identical(unk$daily[unk$daily$Site == US, ], kn$daily[kn$daily$Site == US, ]))
}

cat("\n== 6. the ledger is the whole record ==\n")
{
  it <- data.frame(Protocol = "P1", Site = US, DU = "DRUG", Qty = 25,
                   ETA = as.Date("2024-06-20"))
  win <- data.frame(Country = "*", Start = "2024-10-01", End = "2024-10-31", Delay_Days = 9)
  pr <- run(d, stock, depot, pars(), in_transit = it, disruptions = win,
            lanes = data.frame(Country = "Japan", Lead_Time_Days = 35))
  sh <- pr$shipments
  landed <- sh$Qty[!is.na(sh$Arrival) & sh$Arrival <= as.Date("2025-06-01")]
  ok("every unit received appears in the ledger, once",
     abs(sum(pr$daily$Received) - sum(landed)) < 1e-6,
     sprintf("received %.0f, ledger %.0f", sum(pr$daily$Received), sum(landed)))
  ok("and on-order at the end is what the ledger has still on the road",
     abs(sum(pr$daily$On_Order[pr$daily$Date == as.Date("2025-06-01")]) -
         sum(sh$Qty[sh$Arrival > as.Date("2025-06-01")])) < 1e-6)
}

cat("\n== 7. input errors are named ==\n")
{
  bad <- data.frame(Protocol = "P1", Site = US, DU = "DRUG", Qty = 5, ETA = NA)
  e1 <- tryCatch({ run(d, none, NULL, pars(), in_transit = bad); "" },
                 error = function(e) conditionMessage(e))
  ok("an in-transit row with no ETA stops the run", grepl("expected arrival", e1), e1)
  e2 <- tryCatch({ run(d, none, NULL, pars(), disruptions = data.frame(
                     Country = "USA", Start = "2024-09-01", End = "2024-08-01", Delay_Days = 5)); "" },
                 error = function(e) conditionMessage(e))
  ok("a disruption that ends before it starts stops the run", grepl("End on or", e2), e2)
}

cat(sprintf("\n%d passed, %d failed\n", .pass, .fail))
quit(status = if (.fail > 0L) 1L else 0L)
