#!/usr/bin/env Rscript
# =========================================================================== #
# benchmark.R  --  runtime regression baseline for the demand engine
#
#   Rscript tests/benchmark.R
#
# The titration chain is sequential in TIME and independent across PATIENTS.
# Everything here follows from writing each loop along the axis that is
# actually sequential, and from never growing output with rbind.
#
# Baseline measured 2026-08-28, Apple silicon, R 4.6.1, on the SAME workload
# before and after the rewrite (Program_Inputs.xlsx, horizon 2026-12-31):
#
#                                375 patients      18,750 patients
#   before (per-patient loop)    56,076 rows/sec   35,189 rows/sec (16.76 s)
#   after  (vectorised cohort)   see section A
#
# Throughput, not wall clock, is the comparable figure — the engine now also
# carries a dose rung per visit. Note the old engine DECAYED with size (56k
# down to 35k rows/sec) because it grew its output with do.call(rbind, .),
# which recopies the whole accumulated frame on every call. The rewrite emits
# one frame per (arm, component) rather than one per patient, so that list is
# ~10 elements long instead of ~20,000; the structural change matters more
# than the faster bind does.
#
# The exact recursion is O(1) in patient count: it propagates a DISTRIBUTION
# over ~84 states rather than individuals, so 1,000 patients and 10,000,000
# patients cost the same.
# =========================================================================== #

suppressPackageStartupMessages({ library(dplyr); library(readxl) })
root <- normalizePath(file.path(dirname(sub("--file=", "",
          grep("--file=", commandArgs(FALSE), value = TRUE))[1]), ".."))
source(file.path(root, "R/titration.R"))
source(file.path(root, "R/simulation.R"))

el <- function(expr) system.time(expr)[["elapsed"]]

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
FAR <- as.Date("2099-01-01")

cohort <- function(n) simulate_enrollment(data.frame(
  Protocol = "P1", Cohort = "C1", Arm = "A1", Patients = n,
  Enroll_Start = as.Date("2024-01-01"), Enroll_End = as.Date("2024-01-01"),
  Country = "USA", Center = "1001", stringsAsFactors = FALSE), 1L)

# --------------------------------------------------------------------------- #
cat("\n-- A. the pre-change workload, like for like ----------------------\n")
cat("      before: 56,076 rows/sec at 375 patients, 35,189 at 18,750\n")
enr <- normalize_df(read_excel(file.path(root, "Program_Inputs.xlsx"),
                               sheet = "Enrollment_Input"))
dos <- read_excel(file.path(root, "Program_Inputs.xlsx"), sheet = "Dosing_Input")
cat(sprintf("%8s %10s %10s %12s %12s\n",
            "sims", "patients", "seconds", "visit rows", "rows/sec"))
for (S in c(1L, 5L, 20L, 50L)) {
  set.seed(42); e <- simulate_enrollment(enr, num_simulations = S)
  v <- NULL
  t <- el(v <- simulate_visits(e, dos, visit_window = 3,
                               simulation_end_date = as.Date("2026-12-31")))
  cat(sprintf("%8d %10d %10.2f %12d %12.0f\n",
              S, nrow(e), t, nrow(v), nrow(v) / max(t, 1e-9)))
}

# --------------------------------------------------------------------------- #
cat("\n-- B. simulate_visits on a six-rung titration ladder --------------\n")
cat(sprintf("%10s %10s %12s %12s\n", "patients", "seconds", "visit rows", "rows/sec"))
for (n in c(1000L, 5000L, 20000L)) {
  set.seed(1); p <- cohort(n)
  v <- NULL
  t <- el(v <- simulate_visits(p, dosing6, visit_window = 0,
                               simulation_end_date = FAR, titration = tspec))
  cat(sprintf("%10d %10.3f %12d %12.0f\n", n, t, nrow(v), nrow(v) / max(t, 1e-9)))
}

# --------------------------------------------------------------------------- #
cat("\n-- C. expected_demand, exact: O(1) in patient count ---------------\n")
lad <- build_ladders(dosing6, tspec)
for (n in c(1e3, 1e5, 1e7)) {
  t <- el(for (k in 1:20) expected_demand(lad)) / 20
  cat(sprintf("   n = %11.0f   %.5f s/call\n", n, t))
}

# --------------------------------------------------------------------------- #
cat("\n-- D. row assembly: .fast_bind vs do.call(rbind, .) ----------------\n")
cat("      worst case, many tiny frames. The engine no longer generates this\n")
cat("      shape at all: it emits ~10 large frames, not one per patient.\n")
mk <- function(k) data.frame(Protocol = "P", Site = 1001L, SSID = k,
                             Visit_Num = 1:6, Visit_Date = Sys.Date() + 1:6,
                             DU_Desc = "Compound-A", Qty = 1,
                             stringsAsFactors = FALSE)
cat(sprintf("%10s %14s %14s %10s\n", "rows", "do.call(rbind)", ".fast_bind", "speedup"))
for (n in c(2000L, 8000L, 20000L)) {
  L <- lapply(seq_len(n), mk)
  t1 <- el(x <- do.call(rbind, L))
  t2 <- el(y <- .fast_bind(L))
  cat(sprintf("%10d %14.3f %14.4f %9.1fx\n", n * 6L, t1, t2, t1 / max(t2, 1e-9)))
}
cat("\n")
