#!/usr/bin/env Rscript
# =========================================================================== #
# test_seeding.R  --  initial site stocking
#
#   Rscript tests/test_seeding.R
#
# The claim under test is that seeding a site off STUDY-AVERAGE demand is wrong
# for a titrating arm, because every patient starts on rung 1 and the first few
# visits look nothing like the study as a whole. A fixed-dose arm is the
# control: for it, the seed-window mix and the study mix must be identical.
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

# A six-rung ladder where the high-dose DU only appears from rung 3.
dosing6 <- data.frame(
  Protocol = "P1", Arm = "A1",
  DU_Description = c("DU-BG", "DU-LOW", "DU-HIGH"),
  Cycles = 40L, Cycle_Length = 21L,
  Option1 = c(2, 2, 0), Option2 = c(2, 4, 0), Option3 = c(2, 1, 1),
  Option4 = c(2, 0, 2), Option5 = c(2, 0, 3), Option6 = c(2, 0, 4),
  stringsAsFactors = FALSE)
tspec <- data.frame(Protocol = "P1", Arm = "A1", Titration_Visits = 6L,
                    P_Up = 0.70, P_Stay = 0.20, P_Down = 0.10, P_Miss = 0.08,
                    Tolerance_Level = 5L, Restart_Policy = "uncapped",
                    stringsAsFactors = FALSE)
fixed <- data.frame(Protocol = "P2", Arm = "A1",
                    DU_Description = c("F-DRUG", "F-DILUENT"),
                    Cycles = 40L, Cycle_Length = 21L, Option1 = c(3, 1),
                    stringsAsFactors = FALSE)

enr <- function(protocol, n = 6L, site = "1001",
                start = as.Date("2024-06-01")) data.frame(
  Protocol = protocol, Cohort = "C1", Arm = "A1", Patients = n,
  Enroll_Start = start, Enroll_End = start, Country = "USA", Center = site,
  stringsAsFactors = FALSE)

cat("\n== 1. a fixed-dose arm needs no special seeding ==\n")
{
  m <- seed_mix_check(build_ladders(fixed, NULL))
  ok("every DU's seed share equals its study share",
     all(abs(m$Ratio - 1) < 1e-6),
     paste(round(m$Ratio, 4), collapse = " "))
}

cat("\n== 2. a titrating arm's first visits are nothing like its study ==\n")
{
  m <- seed_mix_check(build_ladders(dosing6, tspec))
  hi <- m[m$DU == "DU-HIGH", ]; lo <- m[m$DU == "DU-LOW", ]
  ok("the high-dose DU is absent from the seed window entirely",
     hi$Seed_Share == 0 && hi$Study_Share > 0.2,
     sprintf("seed %.3f vs study %.3f", hi$Seed_Share, hi$Study_Share))
  ok("the low-dose DU is over-represented at startup",
     lo$Ratio > 1.5, sprintf("ratio %.2f", lo$Ratio))
  ok("shares still sum to 1 in both windows",
     abs(sum(m$Seed_Share) - 1) < 1e-9 && abs(sum(m$Study_Share) - 1) < 1e-9)
}

cat("\n== 3. seed_sites lands stock before the first visit ==\n")
{
  lad <- build_ladders(dosing6, tspec)
  e <- enr("P1", n = 6L)
  rx <- seed_sites(e, lad, list(Seed_Patients = 6L, Seed_Lead_Days = 21))
  ok("one row per DU that the seed window actually needs", nrow(rx) == 2,
     sprintf("got %d rows: %s", nrow(rx), paste(rx$DU, collapse = ", ")))
  ok("no DU-HIGH is shipped, because nobody can be on rung 3 yet",
     !("DU-HIGH" %in% rx$DU))
  ok("every shipment is a positive quantity", all(rx$Qty > 0))
  ok("it arrives before the first patient visit",
     all(rx$Arrive_Date == as.Date("2024-06-01") - 21))
  ok("lots carry an expiry", all(!is.na(rx$Expiry) & rx$Expiry > rx$Arrive_Date))
}

cat("\n== 4. the seed scales with the cohort, and is capped by it ==\n")
{
  lad <- build_ladders(dosing6, tspec)
  # Shipments are whole units, so ceiling() makes small cohorts round up
  # proportionally more. Proportionality is checked where rounding is noise.
  r30 <- seed_sites(enr("P1", 200L), lad, list(Seed_Patients = 30L))
  r60 <- seed_sites(enr("P1", 200L), lad, list(Seed_Patients = 60L))
  ok("doubling the seeded cohort doubles the shipment",
     abs(sum(r60$Qty) / sum(r30$Qty) - 2) < 0.02,
     sprintf("ratio %.4f", sum(r60$Qty) / sum(r30$Qty)))
  r3 <- seed_sites(enr("P1", 12L), lad, list(Seed_Patients = 3L))
  r6 <- seed_sites(enr("P1", 12L), lad, list(Seed_Patients = 6L))
  ok("...and small cohorts round up, never down",
     sum(r6$Qty) / sum(r3$Qty) <= 2 && sum(r6$Qty) > sum(r3$Qty),
     sprintf("ratio %.3f", sum(r6$Qty) / sum(r3$Qty)))
  big <- seed_sites(enr("P1", 4L), lad, list(Seed_Patients = 99L))
  ok("you cannot seed for more patients than the site will enrol",
     sum(big$Qty) == sum(seed_sites(enr("P1", 4L), lad,
                                    list(Seed_Patients = 4L))$Qty))
  ok("a site with no ladder is skipped, not guessed at",
     nrow(seed_sites(enr("NOPE", 6L), lad, list())) == 0)
}

cat("\n== 5. seeded stock actually reaches the inventory engine ==\n")
{
  lad <- build_ladders(dosing6, tspec)
  e   <- enr("P1", 6L)
  set.seed(11)
  pats <- simulate_enrollment(e, 1L)
  v <- add_date_windows(simulate_visits(pats, dosing6, visit_window = 0,
                                        simulation_end_date = as.Date("2025-06-01"),
                                        titration = tspec))
  d <- compute_demand(v)
  empty_inv <- data.frame(Protocol = character(0), Location = character(0),
                          DU = character(0), Qty = numeric(0),
                          Expiry = as.Date(character(0)), stringsAsFactors = FALSE)
  pars <- list(start_date = as.Date("2024-05-01"),
               horizon_end = as.Date("2025-06-01"), enable_resupply = FALSE)

  bare <- project_inventory(d, empty_inv, NULL, pars)
  rx   <- seed_sites(e, lad, list(Seed_Patients = 6L))
  fed  <- project_inventory(d, empty_inv, NULL, pars, initial_receipts = rx)

  ok("with no stock and no resupply, everything stocks out",
     all(bare$summary$Status == "STOCKOUT"))
  ok("seeding dispenses units that were otherwise short",
     sum(fed$summary$Total_Dispensed) > sum(bare$summary$Total_Dispensed),
     sprintf("%.0f vs %.0f", sum(fed$summary$Total_Dispensed),
             sum(bare$summary$Total_Dispensed)))
  ok("seeding reduces total stockout units",
     sum(fed$summary$Total_Stockout) < sum(bare$summary$Total_Stockout))
  ok("received units equal what was shipped",
     abs(sum(fed$daily$Received) - sum(rx$Qty)) < 1e-6,
     sprintf("received %.0f, shipped %.0f", sum(fed$daily$Received), sum(rx$Qty)))
}

cat("\n== 6. a shipment due before the as-of date is not lost ==\n")
{
  lad <- build_ladders(dosing6, tspec)
  e   <- enr("P1", 6L)
  set.seed(12)
  pats <- simulate_enrollment(e, 1L)
  v <- add_date_windows(simulate_visits(pats, dosing6, visit_window = 0,
                                        simulation_end_date = as.Date("2025-06-01"),
                                        titration = tspec))
  d <- compute_demand(v)
  empty_inv <- data.frame(Protocol = character(0), Location = character(0),
                          DU = character(0), Qty = numeric(0),
                          Expiry = as.Date(character(0)), stringsAsFactors = FALSE)
  rx <- seed_sites(e, lad, list(Seed_Patients = 6L))
  # as-of date AFTER the shipment landed: it is history, so it must show up as
  # opening on-hand rather than being dropped by a day loop that starts later.
  late <- project_inventory(d, empty_inv, NULL,
            list(start_date = as.Date("2024-07-01"),
                 horizon_end = as.Date("2025-06-01"), enable_resupply = FALSE),
            initial_receipts = rx)
  ok("it is folded into opening on-hand",
     sum(late$summary$Start_On_Hand) > 0,
     sprintf("start on hand %.0f", sum(late$summary$Start_On_Hand)))
  ok("and is not double-counted as a receipt", sum(late$daily$Received) == 0)
}

cat("\n== 7. a site is a center in a country ==\n")
{
  lad <- build_ladders(dosing6, tspec)
  two <- rbind(enr("P1", 6L, site = "1004"), enr("P1", 4L, site = "1004"))
  two$Country <- c("Mexico", "USA")
  rx <- seed_sites(two, lad, list(Seed_Patients = 99L))
  ok("one center number in two countries is two sites",
     setequal(unique(rx$Site), c("1004 \u00b7 Mexico", "1004 \u00b7 USA")),
     paste(unique(rx$Site), collapse = " | "))
  ok("each is seeded for its own patients",
     all(rx$Qty[rx$Site == "1004 \u00b7 Mexico"] > rx$Qty[rx$Site == "1004 \u00b7 USA"]))

  set.seed(71)
  v <- simulate_visits(simulate_enrollment(two, 1L), dosing6, visit_window = 0,
                       simulation_end_date = as.Date("2025-06-01"), titration = tspec)
  d <- compute_demand(v)
  inv <- data.frame(protocol_id = "P1", center_number = "1004",
                    country_name = c("Mexico", "USA"), du_description = "DU-LOW",
                    site_inventory_count = c(500, 7), retest_date_inv = "2026-01-01",
                    stringsAsFactors = FALSE)
  pr <- project_inventory(d, inv, NULL, list(start_date = as.Date("2024-05-01"),
            horizon_end = as.Date("2025-06-01"), enable_resupply = FALSE))
  st <- pr$summary[pr$summary$DU == "DU-LOW", ]
  ok("and holds its own stock pool",
     st$Start_On_Hand[st$Site == "1004 \u00b7 Mexico"] == 500 &&
     st$Start_On_Hand[st$Site == "1004 \u00b7 USA"] == 7)

  bare <- inv[, setdiff(names(inv), "country_name")]
  err <- tryCatch({ project_inventory(d, bare, NULL, list(start_date = as.Date("2024-05-01"),
                      horizon_end = as.Date("2025-06-01"))); "" },
                  error = function(e) conditionMessage(e))
  ok("a file with no country column stops where a center is ambiguous",
     grepl("more than one country", err) && grepl("1004", err), err)

  one <- enr("P1", 6L)
  set.seed(72)
  d1 <- compute_demand(simulate_visits(simulate_enrollment(one, 1L), dosing6,
          visit_window = 0, simulation_end_date = as.Date("2025-06-01"), titration = tspec))
  inv1 <- data.frame(protocol_id = "P1", center_number = "1001", du_description = "DU-LOW",
                     site_inventory_count = 40, retest_date_inv = "2026-01-01")
  pr1 <- project_inventory(d1, inv1, NULL, list(start_date = as.Date("2024-05-01"),
           horizon_end = as.Date("2025-06-01"), enable_resupply = FALSE))
  ok("...and resolves by center where it is not",
     pr1$summary$Start_On_Hand[pr1$summary$Site == "1001 \u00b7 USA" &
                               pr1$summary$DU == "DU-LOW"] == 40)

  noc <- one; noc$Country <- ""
  set.seed(73); a <- compute_demand(simulate_visits(simulate_enrollment(one, 1L), dosing6,
          visit_window = 3, simulation_end_date = as.Date("2025-06-01"), titration = tspec))
  set.seed(73); b <- compute_demand(simulate_visits(simulate_enrollment(noc, 1L), dosing6,
          visit_window = 3, simulation_end_date = as.Date("2025-06-01"), titration = tspec))
  ok("the site key draws no random numbers: same seed, same demand",
     identical(a$Units, b$Units) && identical(a$Visit_Date, b$Visit_Date))
}

cat("\n== 8. every cohort at a site gets its own seed ==\n")
{
  lad <- build_ladders(dosing6, tspec)
  plan <- rbind(enr("P1", 6L, start = as.Date("2024-06-01")),
                enr("P1", 20L, start = as.Date("2026-03-01")))
  plan$Cohort <- c("Dose-finding", "Expansion")
  rx <- seed_sites(plan, lad, list(Seed_Patients = NA))
  ok("two cohorts at one site, two shipments per DU",
     nrow(rx) == 4 && setequal(unique(rx$Cohort), plan$Cohort), sprintf("%d rows", nrow(rx)))
  ok("each dated to its own cohort's visit 0, less the seed lead",
     setequal(unique(rx$Arrive_Date), plan$Enroll_Start - 21))
  ok("each sized for its own cohort",
     all(rx$Planned_Qty[rx$Cohort == "Expansion"] > rx$Planned_Qty[rx$Cohort == "Dose-finding"]))
  ok("the early cohort is no longer shipped the later cohort's stock",
     sum(rx$Planned_Qty[rx$Cohort == "Dose-finding"]) ==
       sum(seed_sites(plan[1, ], lad, list())$Planned_Qty))
}

cat(sprintf("\n%d passed, %d failed\n", .pass, .fail))
quit(status = if (.fail > 0L) 1L else 0L)
