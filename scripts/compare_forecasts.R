#!/usr/bin/env Rscript
# =========================================================================== #
# compare_forecasts.R  --  the three forecasts on the same simulated demand
#
#   Rscript scripts/compare_forecasts.R [reps] [outfile]
#
# For each replication the frame's demand is simulated once and the inventory
# walk is run three times on it, once per forecast mode (R/forecast.R):
#
#   trailing   the site's own dispensing, averaged over 60 days
#   rung       every enrolled patient projected from their dose and status
#   oracle     the demand the simulation goes on to produce (a ceiling)
#
# Same demand, same seeds, same depot, same policy; only what the reorder rule
# knows changes. The frame, seeds and depot are the experiment's own
# (scripts/experiment_setup.R).
#
# Writes one row per (rep, forecast, protocol) to
# output/experiment/forecasts.csv and prints the comparison by forecast and by
# whether the protocol titrates.
# =========================================================================== #

suppressPackageStartupMessages({ library(dplyr) })
root <- normalizePath(file.path(dirname(sub("--file=", "",
          grep("--file=", commandArgs(FALSE), value = TRUE))[1]), ".."))
for (f in c("titration.R", "simulation.R", "forecast.R", "inventory.R", "seeding.R"))
  source(file.path(root, "R", f))

args <- commandArgs(trailingOnly = TRUE)
REPS <- if (length(args) >= 1) as.integer(args[1]) else 5L
OUT  <- if (length(args) >= 2) args[2] else file.path(root, "output/experiment/forecasts.csv")
dir.create(dirname(OUT), showWarnings = FALSE, recursive = TRUE)

source(file.path(root, "scripts/experiment_setup.R"))
MODES <- c("trailing", "rung", "oracle")

rows <- list()
for (rep in seq_len(REPS)) {
  set.seed(1000L + rep)                       # the pilot's rep_seed
  pats <- simulate_enrollment(enroll, num_simulations = 1L)
  v <- simulate_visits(pats, dosing, visit_window = 3,
                       simulation_end_date = HORIZON, titration = titr)
  d <- compute_demand(v)
  for (m in MODES) {
    t0 <- Sys.time()
    pr <- suppressMessages(project_inventory(
      d, empty_site_inv, depot, CONTROL, initial_receipts = receipts,
      opening = "seeded", forecast = m,
      visits = if (m == "rung") bind_rows(pats, v),
      ladders = if (m == "rung") ladders))
    secs <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
    s <- pr$summary %>%
      group_by(Protocol) %>%
      summarise(Units          = n(),
                Stockouts      = sum(Status == "STOCKOUT"),
                P_Stockout     = mean(Status == "STOCKOUT"),
                Stockout_Units = sum(Total_Stockout),
                Reorders       = sum(Reorders),
                Expired        = sum(Total_Expired), .groups = "drop") %>%
      mutate(rep_seed = 1000L + rep, forecast = m)
    rows[[length(rows) + 1L]] <- s
    cat(sprintf("  rep %d/%d  %-8s %5.1fs  mean P(stockout) %.4f  stockout units %s\n",
                rep, REPS, m, secs, mean(s$P_Stockout),
                format(round(sum(s$Stockout_Units)), big.mark = ",")))
    flush.console()
  }
}

out <- bind_rows(rows) %>%
  left_join(frame %>% select(Protocol = protocol_id, titrates), by = "Protocol")
write.csv(out, OUT, row.names = FALSE)

cat(sprintf("\n%d replications, %d protocols (%d titrating)\n", REPS,
            length(unique(out$Protocol)),
            length(unique(out$Protocol[as.logical(out$titrates)]))))
tab <- out %>%
  group_by(forecast, rep_seed) %>%
  summarise(fixed     = mean(P_Stockout[!as.logical(titrates)]),
            titrating = mean(P_Stockout[as.logical(titrates)]),
            units     = sum(Stockout_Units),
            reorders  = sum(Reorders), .groups = "drop") %>%
  group_by(forecast) %>%
  summarise(`P(stockout) fixed`     = sprintf("%.4f", mean(fixed)),
            `P(stockout) titrating` = sprintf("%.4f", mean(titrating)),
            `stockout units`        = sprintf("%s (sd %s)",
                                              format(round(mean(units)), big.mark = ","),
                                              format(round(sd(units)), big.mark = ",")),
            reorders                = format(round(mean(reorders)), big.mark = ","),
            .groups = "drop") %>%
  arrange(match(forecast, MODES))
print(as.data.frame(tab), row.names = FALSE)
cat(sprintf("\nwrote %d rows to %s\n", nrow(out), OUT))
