#!/usr/bin/env Rscript
# =========================================================================== #
# power_pilot.R  --  measure the outcome's variance components
#
#   Rscript scripts/power_pilot.R [reps] [outfile]
#
# EXPERIMENT.md §8 commits to a power calculation run BEFORE any confirmatory
# run, with seeding on and under the titration DGP. This produces the input it
# needs: the distribution of the primary outcome -- the proportion of a
# protocol's site x DU units that stock out -- across replications, under the
# CONTROL policy only.
#
# Only the control arm is simulated. Power depends on the outcome's variance
# and an assumed effect size, not on the treatment being implemented, and
# running the control alone keeps this document's frozen implementation hash
# valid (no engine change).
#
# Writes one tidy row per (rep, protocol): stockout proportion, unit count,
# titration status, and the size covariates the blocking uses.
# =========================================================================== #

suppressPackageStartupMessages({ library(dplyr) })
root <- normalizePath(file.path(dirname(sub("--file=", "",
          grep("--file=", commandArgs(FALSE), value = TRUE))[1]), ".."))
for (f in c("titration.R", "simulation.R", "forecast.R", "inventory.R", "seeding.R"))
  source(file.path(root, "R", f))

args    <- commandArgs(trailingOnly = TRUE)
REPS    <- if (length(args) >= 1) as.integer(args[1]) else 20L
OUT     <- if (length(args) >= 2) args[2] else file.path(root, "output/experiment/pilot.csv")
dir.create(dirname(OUT), showWarnings = FALSE, recursive = TRUE)

FRAME   <- file.path(root, "datasets/frame")
# Planning as-of must precede EVERY trial in the frame, or protocols are not
# treated alike. A trial already mid-flight at the as-of date gets seeded for a
# patient's FIRST visits (rung 1) while its actual demand is from patients who
# have already climbed the ladder -- so the high-dose DU starts with no stock
# and cannot be reordered inside the lead time. That is an artefact of the
# snapshot, not a property of the reorder rule, and in the 2024-01-01 run it
# was the entire between-protocol variance: ONC-001, the only titrating trial
# starting before that date, sat at 0.372 while every other protocol was
# <= 0.0067. Fixed-dose trials in the same position are unaffected, because a
# one-rung ladder has no mix to get wrong.
# Before the earliest SEED SHIP DATE, which is a cohort's start less the seed
# lead (21 days) less the lane (21 days): 2022-04-08 on this frame. The old
# default, 2022-05-01, was before the earliest start but after some seeds left.
AS_OF   <- as.Date(Sys.getenv("ASOF", "2022-04-01"))
HORIZON <- as.Date(Sys.getenv("HORIZON", "2026-12-31"))
SEED_PATIENTS <- NA                  # NA => each site's own planned cohort

enroll <- read.csv(file.path(FRAME, "enrollment_input.csv"), stringsAsFactors = FALSE)
dosing <- read.csv(file.path(FRAME, "dosing_input.csv"),     stringsAsFactors = FALSE)
titr   <- read_titration(file.path(FRAME, "titration_input.csv"))
frame  <- read.csv(file.path(FRAME, "frame.csv"),            stringsAsFactors = FALSE)
ladders <- build_ladders(dosing, titr)

# Site seeding is deterministic given the frame: it depends on the planned
# cohort and the planned ladder, not on any realisation. Computed once.
receipts <- seed_sites(enroll, ladders, list(Seed_Patients = SEED_PATIENTS))
cat(sprintf("frame: %d protocols, %d sites, %s patients | seed: %d shipments, %s units\n",
            nrow(frame), length(unique(enroll$Center)),
            format(sum(enroll$Patients), big.mark = ","),
            nrow(receipts), format(sum(receipts$Qty), big.mark = ",")))

# The depot is stocked generously on purpose: this experiment is about the SITE
# reorder rule, and a depot that runs dry would make depot shortfall, not site
# policy, the thing being measured.
#
# It must be sized off the WHOLE STUDY's expected demand, not off the seed
# shipment. Seeding correctly ships nothing for a high rung nobody can be on
# yet, so building the depot from the seed receipts leaves the high-dose DU
# with zero stock anywhere -- which reads as a 100% stockout on exactly one DU
# in three, flat across every titrating protocol and with zero variance across
# replications. That is a harness artefact wearing the costume of a finding.
DEPOT_FACTOR <- 3
pat <- enroll %>% group_by(Protocol, Arm) %>%
  summarise(N = sum(Patients), .groups = "drop")
depot <- expected_demand(ladders) %>%
  group_by(Protocol, Arm, DU_Description) %>%
  summarise(per_patient = sum(E_Units), .groups = "drop") %>%
  left_join(pat, by = c("Protocol", "Arm")) %>%
  group_by(Protocol, DU = DU_Description) %>%
  summarise(Qty = ceiling(sum(per_patient * N) * DEPOT_FACTOR), .groups = "drop") %>%
  transmute(Protocol, Location = "DEPOT", DU, Qty, Expiry = HORIZON + 365)

# Guard: every DU the ladders can demand must have depot stock. Without this
# the failure above is silent and looks like a result.
want <- unique(unlist(lapply(ladders, function(l) l$components$DU_Description)))
gap  <- setdiff(want, depot$DU)
if (length(gap))
  stop(sprintf("%d DU(s) have no depot stock: %s", length(gap),
               paste(head(gap, 5), collapse = ", ")), call. = FALSE)

cat(sprintf("depot: %d DU lines, %s units (%.0fx expected demand)\n",
            nrow(depot), format(sum(depot$Qty), big.mark = ","), DEPOT_FACTOR))

CONTROL <- list(safety_stock_days = 30, target_days = 90, lead_time_days = 21,
                unplanned_visit_pct = 0.10, oversupply_pct = 0.10,
                start_date = AS_OF, horizon_end = HORIZON, enable_resupply = TRUE)

empty_site_inv <- data.frame(Protocol = character(0), Location = character(0),
                             DU = character(0), Qty = numeric(0),
                             Expiry = as.Date(character(0)), stringsAsFactors = FALSE)

rows <- list()
for (rep in seq_len(REPS)) {
  t0 <- Sys.time()
  set.seed(1000L + rep)                       # rep_seed, logged on every row
  pats <- simulate_enrollment(enroll, num_simulations = 1L)
  v <- add_date_windows(simulate_visits(pats, dosing, visit_window = 3,
                                        simulation_end_date = HORIZON,
                                        titration = titr))
  d <- compute_demand(v)
  # Sites start empty and the seeds build them. The as-of date sits before the
  # earliest start, so every seed ships inside the walk, from the depot.
  pr <- project_inventory(d, empty_site_inv, depot, CONTROL,
                          initial_receipts = receipts, opening = "seeded",
                          forecast = "trailing")
  seed_short <- sum(pr$daily$Seed_Short)
  if (seed_short > 0)
    cat(sprintf("  rep %d: the depot fell %s units short of the seeds\n", rep,
                format(round(seed_short), big.mark = ",")))

  s <- pr$summary %>%
    group_by(Protocol) %>%
    summarise(Units      = n(),
              Stockouts  = sum(Status == "STOCKOUT"),
              P_Stockout = mean(Status == "STOCKOUT"),
              Expired    = sum(Total_Expired),
              Reorders   = sum(Reorders), .groups = "drop") %>%
    mutate(rep_seed = 1000L + rep)
  rows[[rep]] <- s
  cat(sprintf("  rep %2d/%d  %5.1fs  %d protocols  mean P(stockout) %.4f\n",
              rep, REPS, as.numeric(difftime(Sys.time(), t0, units = "secs")),
              nrow(s), mean(s$P_Stockout)))
  flush.console()
}

out <- bind_rows(rows) %>%
  left_join(frame %>% select(Protocol = protocol_id, phase, therapeutic_area,
                             titrates, sites_count, enrollment_target),
            by = "Protocol")
write.csv(out, OUT, row.names = FALSE)
cat(sprintf("\nwrote %d rows to %s\n", nrow(out), OUT))
