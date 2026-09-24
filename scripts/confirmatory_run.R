#!/usr/bin/env Rscript
# =========================================================================== #
# confirmatory_run.R  --  the run EXPERIMENT.md pre-registers
#
#   EXP_FRAME=datasets/frame_expanded WORKERS=6 Rscript scripts/confirmatory_run.R [R] [outdir]
#
# For each replication r (rep_seed = 1000 + r) and each protocol, one simulated
# demand, walked under:
#   trailing, rung                      every replication (the two arms)
#   oracle                              replications 1-10 (a ceiling, §4)
#   rung, P_Miss halved / doubled       replications 1-10 (the sensitivity, §7)
#
# The simulation and the two arms follow run_protocol() in
# scripts/experiment_setup.R exactly (same seed, same calls); the extra walks
# reuse the same demand. One CSV per replication is written to `outdir`, and a
# replication already on disk is skipped, so an interrupted run resumes.
# =========================================================================== #

suppressPackageStartupMessages({ library(dplyr) })
root <- normalizePath(file.path(dirname(sub("--file=", "",
          grep("--file=", commandArgs(FALSE), value = TRUE))[1]), ".."))
for (f in c("titration.R", "simulation.R", "forecast.R", "inventory.R", "seeding.R"))
  source(file.path(root, "R", f))
if (!nzchar(Sys.getenv("EXP_FRAME")))
  Sys.setenv(EXP_FRAME = file.path(root, "datasets/frame_expanded"))
source(file.path(root, "scripts/experiment_setup.R"))

args    <- commandArgs(trailingOnly = TRUE)
R_CONF  <- if (length(args) >= 1) as.integer(args[1]) else 50L
OUTDIR  <- if (length(args) >= 2) args[2] else file.path(root, "output/experiment/confirmatory")
EXTRA_R <- as.integer(Sys.getenv("EXTRA_REPS", "10"))
WORKERS <- as.integer(Sys.getenv("WORKERS", "6"))
dir.create(OUTDIR, showWarnings = FALSE, recursive = TRUE)
ENGINE  <- tryCatch(system2("git", c("-C", root, "rev-parse", "HEAD"), stdout = TRUE),
                    error = function(e) NA_character_)

# The forecast's ladders with P_Miss misstated (§7). Demand is unchanged.
mis_ladders <- function(factor) {
  t2 <- titr
  t2$P_Miss <- pmin(0.5, as.numeric(t2$P_Miss) * factor)
  build_ladders(dosing, t2)
}
LAD_HALF <- mis_ladders(0.5); LAD_DOUBLE <- mis_ladders(2)
of_proto <- function(lads, proto) lads[vapply(lads, function(l) l$protocol == proto, logical(1))]

one_protocol <- function(proto, rep_seed, extra) {
  idx <- match(proto, frame$protocol_id)
  set.seed(rep_seed * 1000L + idx)                       # as run_protocol()
  pats <- simulate_enrollment(enroll[enroll$Protocol == proto, ], num_simulations = 1L)
  v <- simulate_visits(pats, dosing[dosing$Protocol == proto, ], visit_window = 3,
                       simulation_end_date = HORIZON,
                       titration = titr[titr$Protocol == proto, , drop = FALSE])
  d <- compute_demand(v)
  vis <- bind_rows(pats, v)
  walk <- function(label, m, lad = NULL) {
    pr <- suppressMessages(project_inventory(
      d, empty_site_inv, depot[depot$Protocol == proto, ], CONTROL,
      initial_receipts = receipts[receipts$Protocol == proto, ],
      opening = "seeded", forecast = m,
      visits = if (m == "rung") vis, ladders = lad))
    s <- pr$summary
    data.frame(rep_seed = rep_seed, Protocol = proto, forecast = label,
               Units = nrow(s), Stockouts = sum(s$Status == "STOCKOUT"),
               P_Stockout = mean(s$Status == "STOCKOUT"),
               Stockout_Units = sum(s$Total_Stockout), Expired = sum(s$Total_Expired),
               Reorders = sum(s$Reorders), Seed_Short = sum(pr$daily$Seed_Short),
               stringsAsFactors = FALSE)
  }
  lad <- of_proto(ladders, proto)
  out <- list(walk("trailing", "trailing"), walk("rung", "rung", lad))
  if (extra) {
    out[[3]] <- walk("oracle", "oracle")
    if (isTRUE(frame$titrates[idx])) {
      out[[4]] <- walk("rung_pmiss_half", "rung", of_proto(LAD_HALF, proto))
      out[[5]] <- walk("rung_pmiss_double", "rung", of_proto(LAD_DOUBLE, proto))
    } else {                              # no P_Miss to misstate: the rung walk stands
      out[[4]] <- transform(out[[2]], forecast = "rung_pmiss_half")
      out[[5]] <- transform(out[[2]], forecast = "rung_pmiss_double")
    }
  }
  do.call(rbind, out)
}

cat(sprintf("confirmatory: %d protocols, R = %d, extra walks on reps 1-%d, %d workers, engine %s\n",
            nrow(frame), R_CONF, EXTRA_R, WORKERS, substr(ENGINE, 1, 7)))
for (r in seq_len(R_CONF)) {
  f <- file.path(OUTDIR, sprintf("rep_%04d.csv", r))
  if (file.exists(f)) { cat(sprintf("  rep %2d on disk, skipped\n", r)); next }
  t0 <- Sys.time(); rep_seed <- 1000L + r
  res <- parallel::mclapply(frame$protocol_id, function(p)
           tryCatch(one_protocol(p, rep_seed, r <= EXTRA_R), error = function(e) conditionMessage(e)),
           mc.cores = WORKERS, mc.preschedule = FALSE)
  bad <- !vapply(res, is.data.frame, logical(1))
  if (any(bad)) stop(sprintf("rep %d: %s", r, paste(unique(unlist(res[bad])), collapse = "; ")),
                     call. = FALSE)
  s <- do.call(rbind, res) %>%
    left_join(frame %>% select(Protocol = protocol_id, donor, titrates, synthetic), by = "Protocol") %>%
    mutate(engine = ENGINE)
  write.csv(s, paste0(f, ".part"), row.names = FALSE)
  file.rename(paste0(f, ".part"), f)
  m <- tapply(s$P_Stockout, s$forecast, mean)
  cat(sprintf("  rep %2d/%d  %5.1f min  trailing %.4f  rung %.4f\n", r, R_CONF,
              as.numeric(difftime(Sys.time(), t0, units = "mins")), m[["trailing"]], m[["rung"]]))
  flush.console()
}
cat("done\n")
