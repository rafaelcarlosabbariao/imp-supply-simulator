#!/usr/bin/env Rscript
# =========================================================================== #
# power_pilot.R  --  measure the variance the paired design's power rests on
#
#   Rscript scripts/power_pilot.R [reps] [outfile]
#   WORKERS=6 Rscript scripts/power_pilot.R 20      # protocols in parallel
#
# EXPERIMENT.md §8 commits to a power calculation run BEFORE any confirmatory
# run. The design is paired: every protocol runs under both arms, trailing and
# rung, on the same simulated demand. Power therefore rests on how much the
# within-protocol difference varies across protocols, and this pilot measures
# it: one row per (rep, protocol, arm).
#
# Protocols are simulated one at a time (run_protocol() in
# scripts/experiment_setup.R), so the pilot can run them in parallel and a
# larger frame does not need more memory per process.
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

WORKERS <- as.integer(Sys.getenv("WORKERS", "4"))
rows <- list()
for (rep in seq_len(REPS)) {
  t0 <- Sys.time()
  rep_seed <- 1000L + rep
  res <- parallel::mclapply(frame$protocol_id, function(p)
           tryCatch(run_protocol(p, rep_seed), error = function(e) conditionMessage(e)),
           mc.cores = WORKERS, mc.preschedule = FALSE)
  bad <- !vapply(res, is.data.frame, logical(1))
  if (any(bad)) stop(sprintf("rep %d: %s", rep, paste(unique(unlist(res[bad])), collapse = "; ")),
                     call. = FALSE)
  s <- do.call(rbind, res)
  rows[[rep]] <- s
  if (sum(s$Seed_Short) > 0)
    cat(sprintf("  rep %d: the depot fell %s units short of the seeds\n", rep,
                format(round(sum(s$Seed_Short)), big.mark = ",")))
  m <- tapply(s$P_Stockout, s$forecast, mean)
  cat(sprintf("  rep %2d/%d  %5.1fs  %d protocols  mean P(stockout) trailing %.4f  rung %.4f\n",
              rep, REPS, as.numeric(difftime(Sys.time(), t0, units = "secs")),
              length(unique(s$Protocol)), m[["trailing"]], m[["rung"]]))
  flush.console()
}

out <- bind_rows(rows) %>%
  left_join(frame %>% select(Protocol = protocol_id, phase, therapeutic_area,
                             titrates, sites_count, enrollment_target, synthetic),
            by = "Protocol")
write.csv(out, OUT, row.names = FALSE)
cat(sprintf("\nwrote %d rows to %s\n", nrow(out), OUT))
