#!/usr/bin/env Rscript
# =========================================================================== #
# test_titration.R  --  correctness gate for the titration engine
#
#   Rscript tests/test_titration.R
#
# The chain is small and finite, so most of what it does has a closed form.
# These tests check the simulator against that closed form rather than against
# a recorded snapshot: a mis-threaded state machine produces demand that still
# looks plausible, and only an analytic check catches it.
# =========================================================================== #

suppressPackageStartupMessages({ library(dplyr) })
root <- normalizePath(file.path(dirname(sub("--file=", "",
          grep("--file=", commandArgs(FALSE), value = TRUE))[1]), ".."))
source(file.path(root, "R/titration.R"))
source(file.path(root, "R/simulation.R"))

# ---- tiny harness --------------------------------------------------------- #
.pass <- 0L; .fail <- 0L
ok <- function(label, cond, detail = "") {
  if (isTRUE(cond)) { .pass <<- .pass + 1L; cat(sprintf("  ok   %s\n", label)) }
  else { .fail <<- .fail + 1L; cat(sprintf("  FAIL %s  %s\n", label, detail)) }
}
near <- function(a, b, tol = 1e-9) all(abs(a - b) <= tol)
errors_with <- function(expr, pattern) {
  e <- tryCatch({ force(expr); NULL }, error = function(e) conditionMessage(e))
  !is.null(e) && grepl(pattern, e, fixed = TRUE)
}

cohort <- function(n, protocol = "P1", arm = "A1", start = as.Date("2024-01-01")) {
  simulate_enrollment(data.frame(
    Protocol = protocol, Cohort = "C1", Arm = arm, Patients = n,
    Enroll_Start = start, Enroll_End = start, Country = "USA", Center = "1001",
    stringsAsFactors = FALSE), num_simulations = 1L)
}

# A three-component kit on a six-rung ladder. Low rungs dispense DU-LOW, high
# rungs dispense DU-HIGH, and DU-BG is background at every rung — the shape
# that makes a restart pull a DU the depot has stopped forecasting.
dosing6 <- data.frame(
  Protocol = "P1", Arm = "A1",
  DU_Description = c("DU-BG", "DU-LOW", "DU-HIGH"),
  Cycles = 40L, Cycle_Length = 21L,
  Option1 = c(2, 2, 0), Option2 = c(2, 4, 0), Option3 = c(2, 1, 1),
  Option4 = c(2, 0, 2), Option5 = c(2, 0, 3), Option6 = c(2, 0, 4),
  stringsAsFactors = FALSE)

spec <- function(...) {
  base <- data.frame(Protocol = "P1", Arm = "A1", Titration_Visits = 6L,
                     P_Up = 0.70, P_Stay = 0.20, P_Down = 0.10, P_Miss = 0.08,
                     Tolerance_Level = 5L, Restart_Policy = "uncapped",
                     stringsAsFactors = FALSE)
  ov <- list(...); for (nm in names(ov)) base[[nm]] <- ov[[nm]]
  base
}

FAR <- as.Date("2099-01-01")   # horizon far enough that every cycle happens
qty_of <- function(v, du) sum(v$Qty[v$DU_Desc == du])

cat("\n== 1. fixed-dose arms are untouched by titration ==\n")
{
  # No titration spec at all: every arm sits on rung 1 for its whole Cycles
  # budget, which is what the engine did before ladders existed.
  fixed <- data.frame(Protocol = "P1", Arm = "A1",
                      DU_Description = c("DU-A", "DU-B"),
                      Cycles = c(20L, 5L), Cycle_Length = 15L,
                      Option1 = c(1, 3), stringsAsFactors = FALSE)
  n <- 50L
  set.seed(1); p <- cohort(n)
  v <- simulate_visits(p, fixed, visit_window = 0, simulation_end_date = FAR)
  ok("DU-A dispensed Cycles x patients", qty_of(v, "DU-A") == 20 * n * 1)
  ok("DU-B honours its own shorter Cycles", qty_of(v, "DU-B") == 5 * n * 3)
  ok("every row is rung-1 quantity",
     all(v$Qty[v$DU_Desc == "DU-A"] == 1) && all(v$Qty[v$DU_Desc == "DU-B"] == 3))
  ok("row count is exact, not approximate", nrow(v) == n * (20 + 5))

  # An arm with several Option columns but NO titration row must still pin to
  # rung 1 — stray columns in a sheet cannot silently change a forecast.
  v2 <- simulate_visits(p, dosing6, visit_window = 0, simulation_end_date = FAR)
  ok("unlisted arm pins to rung 1 despite 6 populated Options",
     qty_of(v2, "DU-HIGH") == 0 && qty_of(v2, "DU-LOW") == 40 * n * 2)
}

cat("\n== 2. deterministic climb: P_Up = 1, P_Miss = 0 ==\n")
{
  # With certain up-titration the rung at visit t is exactly min(t, L), so
  # every dispensed quantity has a closed form.
  n <- 40L; L <- 6L; TT <- 40L
  s <- spec(P_Up = 1, P_Stay = 0, P_Down = 0, P_Miss = 0)
  set.seed(2); p <- cohort(n)
  v <- simulate_visits(p, dosing6, visit_window = 0,
                       simulation_end_date = FAR, titration = s)
  rungs <- pmin(seq_len(TT), L)
  for (k in seq_len(3)) {
    du  <- dosing6$DU_Description[k]
    lad <- as.numeric(dosing6[k, paste0("Option", 1:6)])
    ok(sprintf("%-7s totals match closed form", du),
       near(qty_of(v, du), n * sum(lad[rungs])))
  }
  # ...and the exact recursion must agree with the same closed form.
  e <- expected_demand(build_ladders(dosing6, s))
  for (k in seq_len(3)) {
    du  <- dosing6$DU_Description[k]
    lad <- as.numeric(dosing6[k, paste0("Option", 1:6)])
    ok(sprintf("%-7s exact recursion matches", du),
       near(sum(e$E_Units[e$DU_Description == du]), sum(lad[rungs]), 1e-8))
  }
}

cat("\n== 3. Monte Carlo converges on the exact recursion ==\n")
{
  # The simulator and the forward recursion are independent implementations of
  # the same chain. Agreement at scale is the real correctness check.
  n <- 20000L
  s <- spec()
  set.seed(3); p <- cohort(n)
  v <- simulate_visits(p, dosing6, visit_window = 0,
                       simulation_end_date = FAR, titration = s)
  e <- expected_demand(build_ladders(dosing6, s))
  for (du in c("DU-BG", "DU-LOW", "DU-HIGH")) {
    mc  <- qty_of(v, du) / n
    ex  <- sum(e$E_Units[e$DU_Description == du])
    rel <- abs(mc - ex) / ex
    ok(sprintf("%-7s MC within 3%% of exact (rel = %.4f)", du, rel), rel < 0.03,
       sprintf("mc=%.3f exact=%.3f", mc, ex))
  }
}

cat("\n== 4. the ratchet and the restart ==\n")
{
  n <- 4000L
  # Where the CSP puts the tolerance rung drives low-dose exposure, and it does
  # so NON-MONOTONICALLY. At rung 1 the ratchet is a no-op, because the floor
  # already starts there — so restarts always go to ground and low-dose demand
  # is at its maximum. At the top rung the ratchet almost never fires before a
  # miss knocks the patient back, so exposure climbs again. The minimum is in
  # the middle, where the rung is both reachable and protective.
  #
  # This is worth pinning down: a study lead who sets the tolerance dose at
  # target to "make them prove it" buys nearly the same low-dose supply
  # exposure as having no ratchet at all.
  ex_low <- vapply(1:6, function(tol) {
    e <- expected_demand(build_ladders(dosing6, spec(Tolerance_Level = tol,
                                                    P_Miss = 0.15)))
    sum(e$E_Units[e$DU_Description == "DU-LOW"])
  }, numeric(1))
  ok("rung 1 is a no-op ratchet, so it maximises low-dose demand",
     which.max(ex_low) == 1L,
     sprintf("E[DU-LOW] by rung: %s", paste(round(ex_low, 1), collapse = " ")))
  ok("the effect is U-shaped, with an interior minimum",
     which.min(ex_low) > 1L && which.min(ex_low) < 6L,
     sprintf("minimum at rung %d", which.min(ex_low)))
  ok("the top rung is nearly as exposed as no ratchet at all",
     ex_low[6] > ex_low[which.min(ex_low)] * 1.5)

  # ...and the simulator reproduces the exact recursion's ordering.
  set.seed(4); p <- cohort(n)
  mc1 <- simulate_visits(p, dosing6, visit_window = 0, simulation_end_date = FAR,
                         titration = spec(Tolerance_Level = 1L, P_Miss = 0.15))
  mc4 <- simulate_visits(p, dosing6, visit_window = 0, simulation_end_date = FAR,
                         titration = spec(Tolerance_Level = which.min(ex_low),
                                          P_Miss = 0.15))
  ok("MC agrees with the exact ordering",
     qty_of(mc1, "DU-LOW") > qty_of(mc4, "DU-LOW"),
     sprintf("tol=1 -> %.0f, tol=%d -> %.0f",
             qty_of(mc1, "DU-LOW"), which.min(ex_low), qty_of(mc4, "DU-LOW")))

  # A missed visit dispenses nothing, so as P_Miss -> 1 all demand vanishes.
  set.seed(5)
  none <- simulate_visits(p, dosing6, visit_window = 0, simulation_end_date = FAR,
                          titration = spec(P_Miss = 0.999))
  ok("near-certain misses dispense almost nothing",
     is.null(none) || nrow(none) < n * 0.5)

  # Restarts reset the WINDOW, never the visit budget: no patient can be given
  # more visits by missing them.
  set.seed(6)
  v <- simulate_visits(p, dosing6, visit_window = 0, simulation_end_date = FAR,
                       titration = spec(P_Miss = 0.30))
  per <- tapply(v$Visit_Num, v$SSID, max)
  ok("restarts never extend the visit budget", all(per <= 40))
}

cat("\n== 5. malformed ladders are refused, not absorbed ==\n")
{
  ok("probabilities must sum to 1",
     errors_with(build_ladders(dosing6, spec(P_Up = 0.9)), "must sum to 1"))
  ok("tolerance rung must lie on the ladder",
     errors_with(build_ladders(dosing6, spec(Tolerance_Level = 9L)),
                 "outside the ladder"))
  ok("P_Miss must be a probability",
     errors_with(build_ladders(dosing6, spec(P_Miss = 1.4)),
                 "must be in [0, 1)"))
  holed <- dosing6; holed$Option3 <- 0
  ok("a hole in the ladder is refused",
     errors_with(build_ladders(holed, spec()), "dispense nothing"))
  ok("a well-formed ladder builds", {
     l <- build_ladders(dosing6, spec()); length(l) == 1 && l[[1]]$L == 6L })
}

cat("\n== 6. .fast_bind is a faithful rbind ==\n")
{
  mk <- function(i) data.frame(a = i, d = as.Date("2024-01-01") + i,
                               s = letters[i], stringsAsFactors = FALSE)
  L <- lapply(1:25, mk)
  fb <- .fast_bind(L); rb <- do.call(rbind, L)
  ok("same shape", nrow(fb) == nrow(rb) && identical(names(fb), names(rb)))
  ok("Date class survives", inherits(fb$d, "Date") && all(fb$d == rb$d))
  ok("values identical", all(fb$a == rb$a) && all(fb$s == rb$s))
  ok("empty input returns NULL", is.null(.fast_bind(list())))
}

cat(sprintf("\n%d passed, %d failed\n", .pass, .fail))
quit(status = if (.fail > 0L) 1L else 0L)
