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

# The frame, its seeds, the depot and the control policy: shared with
# scripts/compare_forecasts.R so the two measure the same experiment.
source(file.path(root, "scripts/experiment_setup.R"))

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
