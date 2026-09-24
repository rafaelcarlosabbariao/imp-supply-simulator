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
  e <- tryCatch(run(d, stock, depot, modifyList(pars, list(start_date = as.Date("2026-01-01")))),
                error = function(e) conditionMessage(e))
  ok("an as-of date after the horizon stops the run, naming both dates",
     grepl("2026-01-01", e) && grepl("2025-06-01", e), e)
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

# --------------------------------------------------------------------------- #
# The rung forecast. `projection()` replays the walk's bookkeeping: apply each
# day's changes up to day ti, then read the window.
# --------------------------------------------------------------------------- #
projection <- function(ev, nd, ti) {
  proj <- numeric(nd)
  for (d in seq_len(ti)) if (!is.null(ev[[d]])) proj[ev[[d]]$land] <- proj[ev[[d]]$land] + ev[[d]]$w
  proj
}
window <- function(ev, nd, ti, h) { pr <- projection(ev, nd, ti); sum(pr[ti:min(nd, ti + h - 1)]) }
events <- function(visits, ladders, du, start, end, scale = 1, reach = 200) {
  days <- seq(start, end, by = "day")
  pv <- rung_patient_visits(visits)
  out <- list()
  for (pr in unique(pv$Protocol))
    out <- c(out, rung_events(pv[pv$Protocol == pr, ], pr, du, rung_tables(ladders),
                              start, length(days), reach, scale))
  out
}

tdose <- data.frame(Protocol = "T1", Arm = "A1", DU_Description = "DRUG",
                    Cycles = 20L, Cycle_Length = 14L, Option1 = 1, Option2 = 2, Option3 = 4,
                    stringsAsFactors = FALSE)
tspec <- data.frame(Protocol = "T1", Arm = "A1", Titration_Visits = 4L, P_Up = 0.6,
                    P_Stay = 0.3, P_Down = 0.1, P_Miss = 0.05, Tolerance_Level = 2L,
                    stringsAsFactors = FALSE)
tlad <- build_ladders(tdose, tspec)
tab  <- rung_tables(tlad)[[1]]
id   <- tab$ch$id

cat("\n== 3. a patient's projection stops at their last cycle ==\n")
{
  fd <- transform(dosing, Cycles = 5L)
  set.seed(2)
  en <- simulate_enrollment(plan, 1L)
  vv <- simulate_visits(en, fd, visit_window = 0, simulation_end_date = as.Date("2025-06-01"))
  st <- as.Date("2024-06-01"); nd <- as.integer(as.Date("2025-06-01") - st) + 1L
  ev <- events(vv, build_ladders(fd), "DRUG", st, as.Date("2025-06-01"))[[US]]
  # Visits land on 06-12, 06-26 and 07-10 after the as-of date: 3 x 10 x 4 units.
  ok("on the as-of date the forecast holds the three visits left, 120 units",
     abs(window(ev, nd, 1L, 300) - 120) < 1e-9, sprintf("%.3f", window(ev, nd, 1L, 300)))
  after <- as.integer(as.Date("2024-07-11") - st) + 1L
  ok("the day after the last cycle it holds nothing",
     abs(window(ev, nd, after, 300)) < 1e-9, sprintf("%.3f", window(ev, nd, after, 300)))
}

cat("\n== 4. the next visit is one step of the chain on, not a repeat ==\n")
{
  q <- c(1, 2, 4); pm <- 0.05
  s0 <- id(1L, 0L, 1L)                     # titrating at rung 1, window 1
  want <- (1 - pm) * (0.6 * q[2] + 0.3 * q[1] + 0.1 * q[1])
  ok("a titrating patient at rung 1 projects the up/stay/down mix at the next visit",
     abs(tab$U[[1]][s0, 1] - want) < 1e-12, sprintf("%.4f vs %.4f", tab$U[[1]][s0, 1], want))
  ok("which is more than the dose just dispensed", tab$U[[1]][s0, 1] > (1 - pm) * q[1])
}

cat("\n== 5. a stable patient holds their dose; a miss sends them to the floor ==\n")
{
  s3 <- id(3L, 1L, 4L)                     # stable at rung 3, ratcheted (floor = rung 2)
  u  <- tab$U[[1]][s3, ]
  ok("at the next visit: the stable dose, if they attend",
     abs(u[1] - 0.95 * 4) < 1e-12, sprintf("%.4f", u[1]))
  ok("a visit later: a 5% chance they missed and restart from the floor",
     abs(u[2] - 0.95 * (0.95 * 4 + 0.05 * 2)) < 1e-12, sprintf("%.4f", u[2]))
  nomiss <- build_ladders(tdose, transform(tspec, P_Miss = 0))
  u0 <- rung_tables(nomiss)[[1]]$U[[1]][id(3L, 1L, 4L), ]
  ok("with no misses and no demotion the stable dose holds at every step", all(abs(u0 - 4) < 1e-12))
  rev <- build_ladders(tdose, transform(tspec, P_Miss = 0, P_Revert = 0.2))
  ur <- rung_tables(rev)[[1]]$U[[1]][id(3L, 1L, 4L), ]
  # demoted with 0.2 at the first visit, titrating from rung 3 at the second:
  # 3 -> up (stays 3) 0.6, stay 0.3, down to 2 with 0.1
  ok("a demotion reopens titration from the current dose",
     abs(ur[2] - (0.8 * 4 + 0.2 * (0.9 * 4 + 0.1 * 2))) < 1e-12, sprintf("%.4f", ur[2]))
}

cat("\n== 6. dose status in the visit stream ==\n")
{
  big <- data.frame(Protocol = "T1", Cohort = "C1", Arm = "A1", Patients = 3000L,
                    Enroll_Start = as.Date("2024-01-01"), Enroll_End = as.Date("2024-01-01"),
                    Country = "USA", Center = "1001", stringsAsFactors = FALSE)
  rs <- transform(tspec, P_Revert = 0.1)
  set.seed(5)
  vv <- simulate_visits(simulate_enrollment(big, 1L), tdose, visit_window = 0,
                        simulation_end_date = as.Date("2025-06-01"), titration = rs)
  ok("each visit says whether the patient is titrating or stable",
     all(vv$Dose_Status %in% c("Titrating", "Stable")) &&
     all(is.na(vv$Titration_Visit[vv$Dose_Status == "Stable"])) &&
     all(vv$Titration_Visit[vv$Dose_Status == "Titrating"] %in% 1:4))
  st_v <- vv[vv$Dose_Status == "Stable", ]
  first_stable <- vv[vv$Status_Change == "stabilised", ]
  ok("a patient is marked stabilised on their first visit past the window",
     nrow(first_stable) > 0 && all(first_stable$Dose_Status == "Stable"))
  dem <- vv[grepl("^demoted", vv$Status_Change), ]
  ok("a demoted patient is back to titrating, with the cause named",
     nrow(dem) > 0 && all(dem$Dose_Status == "Titrating") &&
       all(dem$Status_Change %in% c("demoted: missed visit",
                                    "demoted: adverse event or unplanned visit")))
  rate <- sum(dem$Status_Change == "demoted: adverse event or unplanned visit") /
          sum(vv$Dose_Status == "Stable")
  ok("demotions at a visit run at about P_Revert per stable visit",
     abs(rate - 0.1) < 0.015, sprintf("%.3f", rate))
  ed <- expected_demand(build_ladders(tdose, rs))
  sim <- vv %>% group_by(Visit_Num) %>% summarise(u = sum(Qty) / 3000, .groups = "drop")
  m <- merge(sim, ed, by = "Visit_Num")
  ok("with demotion on, the simulator still matches the exact recursion",
     max(abs(m$u - m$E_Units) / m$E_Units) < 0.03,
     sprintf("worst %.3f", max(abs(m$u - m$E_Units) / m$E_Units)))
  ok("each patient's demotion count only grows",
     all(vv %>% arrange(SSID, Visit_Num) %>% group_by(SSID) %>%
           summarise(g = all(diff(Demotions) >= 0), .groups = "drop") %>% pull(g)))
}

cat("\n== 7. the forecast from enrollment is the exact expectation ==\n")
{
  big <- data.frame(Protocol = "T1", Cohort = "C1", Arm = "A1", Patients = 2000L,
                    Enroll_Start = as.Date("2024-01-01"), Enroll_End = as.Date("2024-01-01"),
                    Country = "USA", Center = "1001", stringsAsFactors = FALSE)
  set.seed(9)
  en <- simulate_enrollment(big, 1L)
  vv <- simulate_visits(en, tdose, visit_window = 0,
                        simulation_end_date = as.Date("2025-06-01"), titration = tspec)
  st <- as.Date("2024-01-01"); nd <- as.integer(as.Date("2025-06-01") - st) + 1L
  ev <- events(bind_rows(en, vv), tlad, "DRUG", st, as.Date("2025-06-01"))[["1001 · USA"]]
  ed <- expected_demand(tlad)
  # On the enrollment day, a 111-day window holds visits 1..7 (days 14..98).
  got <- window(ev, nd, 1L, 111); want <- 2000 * sum(ed$E_Units[ed$Visit_Num <= 7])
  ok("on enrollment day it equals expected_demand() over the window",
     abs(got - want) / want < 1e-9, sprintf("%.2f vs %.2f", got, want))
  # Mid-titration, from observed doses: day 46 reads visits 4..11 (days 56..154).
  got2 <- window(ev, nd, 46L, 111); want2 <- 2000 * sum(ed$E_Units[ed$Visit_Num %in% 4:11])
  ok("mid-titration, from the doses observed, it stays within 2% of the expectation",
     abs(got2 - want2) / want2 < 0.02, sprintf("%.1f vs %.1f", got2, want2))
}

cat("\n== 8. arms and simulated trials are kept apart ==\n")
{
  two <- data.frame(Protocol = "P1", Arm = c("A1", "A2"), DU_Description = "DRUG",
                    Cycles = 30L, Cycle_Length = 14L, Option1 = c(4, 6),
                    stringsAsFactors = FALSE)
  pl2 <- data.frame(Protocol = "P1", Cohort = "C1", Arm = c("A1", "A2"), Patients = 5L,
                    Enroll_Start = as.Date("2024-05-01"), Enroll_End = as.Date("2024-05-01"),
                    Country = "USA", Center = "1001", stringsAsFactors = FALSE)
  st <- as.Date("2024-06-01"); en <- as.Date("2025-06-01")
  nd <- as.integer(en - st) + 1L
  set.seed(3)
  v2 <- simulate_visits(simulate_enrollment(pl2, 1L), two, visit_window = 0,
                        simulation_end_date = en)
  ev <- events(v2, build_ladders(two), "DRUG", st, en)[[US]]
  # Next visit 06-12: 5 x 4 + 5 x 6 = 50 units.
  ok("two arms sharing a DU at one site forecast the sum of both",
     abs(window(ev, nd, 1L, 12) - 50) < 1e-9, sprintf("%.2f", window(ev, nd, 1L, 12)))
  set.seed(3)
  v3 <- simulate_visits(simulate_enrollment(pl2, 3L), two, visit_window = 0,
                        simulation_end_date = en)
  ev3 <- events(v3, build_ladders(two), "DRUG", st, en, scale = 1 / 3)[[US]]
  ok("three simulated trials with repeated patient IDs forecast their average",
     abs(window(ev3, nd, 1L, 12) - 50) < 1e-9, sprintf("%.2f", window(ev3, nd, 1L, 12)))
}

cat("\n== 9. the rung forecast in the walk ==\n")
{
  big <- data.frame(Protocol = "T1", Cohort = "C1", Arm = "A1", Patients = 40L,
                    Enroll_Start = as.Date("2024-01-01"), Enroll_End = as.Date("2024-02-15"),
                    Country = "USA", Center = "1001", stringsAsFactors = FALSE)
  set.seed(11)
  en <- simulate_enrollment(big, 1L)
  vv <- simulate_visits(en, tdose, visit_window = 3,
                        simulation_end_date = as.Date("2025-06-01"), titration = tspec)
  dd <- compute_demand(vv)
  dep <- data.frame(protocol = "T1", depot_name = "D1", du_description = "DRUG",
                    depot_inventory_count = 1e6, retest_date_inv = "2030-01-01")
  pp <- list(start_date = as.Date("2024-01-01"), horizon_end = as.Date("2025-06-01"))
  none <- data.frame(Protocol = character(0), Location = character(0), DU = character(0),
                     Qty = numeric(0), Expiry = as.Date(character(0)))
  e1 <- tryCatch(run(dd, none, dep, pp, forecast = "rung"),
                 error = function(e) conditionMessage(e))
  ok("it asks for the visits and ladders it needs", is.character(e1) && grepl("needs `visits`", e1))
  pr <- run(dd, none, dep, pp, forecast = "rung", visits = bind_rows(en, vv), ladders = tlad)
  ok("it runs, names itself, and orders", pr$forecast == "rung" && sum(pr$daily$Reorder_Qty) > 0)
  tr <- run(dd, none, dep, pp)
  ok("from empty sites it orders before the trailing forecast can",
     min(pr$daily$Date[pr$daily$Reorder_Qty > 0]) < min(tr$daily$Date[tr$daily$Reorder_Qty > 0]))
}

cat("\n== 10. stock about to expire is not counted as cover ==\n")
{
  # 600 units on hand, far above the reorder point, that expire on 2024-07-01.
  # Without the rule the site counts them until they expire, then waits a lead time.
  soon <- transform(stock, site_inventory_count = 600, retest_date_inv = "2024-07-01")
  pr <- run(d, soon, depot, modifyList(pars, list(start_date = as.Date("2024-06-01"))))
  first <- min(pr$daily$Date[pr$daily$Reorder_Qty > 0])
  ok("the site reorders before its stock expires, not after",
     first < as.Date("2024-07-01"), as.character(first))
  ok("and does not stock out when the lot expires",
     sum(pr$daily$Stockout_Units[pr$daily$Date >= as.Date("2024-07-01") &
                                 pr$daily$Date < as.Date("2024-08-01")]) == 0)
  near <- data.frame(protocol = "P1", depot_name = "D1", du_description = "DRUG",
                     depot_inventory_count = c(1e6, 1e6),
                     retest_date_inv = c("2024-07-10", "2030-01-01"))
  pr2 <- run(d, stock, near, pars)
  got <- pr2$shipments$Arrival[pr2$shipments$Source == "reorder"][1]
  ok("the depot skips a lot that would land with under 30 days left",
     sum(pr2$daily$Expired) == 0, sprintf("expired %.0f", sum(pr2$daily$Expired)))
}

cat(sprintf("\n%d passed, %d failed\n", .pass, .fail))
quit(status = if (.fail > 0L) 1L else 0L)
