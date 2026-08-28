# =========================================================================== #
# titration.R  --  Dose-titration ladders for the demand engine
#
# Some protocols do not dose a patient at target from visit 1. The CSP defines
# a TITRATION LADDER: the first N visits step the dose up while the patient
# tolerates it, hold it where they only partly tolerate it, and step it back
# down where they do not. A missed visit dispenses nothing and sends the
# patient back to their floor, restarting the titration window.
#
# The floor RATCHETS. It starts at rung 1, and the first time a patient
# demonstrates tolerance AT the CSP's tolerance rung ("tolerated once" — they
# attend at that rung and do not down-titrate), the floor moves up to it
# permanently. A patient who has never tolerated the tolerance dose restarts
# from the ground; one who has restarts from the tolerance rung.
#
# WHY THIS MATTERS FOR SUPPLY: a rung is usually a different DISPENSING UNIT,
# not just a different quantity of one (a 15 mg vial and a 100 mg bottle are
# separate DUs with separate lots and separate expiry). So titration
# reallocates demand ACROSS DUs, and a restart pulls the low-dose DU months
# after the depot stopped forecasting for it. The (s,S) reorder point in
# inventory.R keys off a TRAILING average demand rate, which is exactly the
# estimator that lags that kind of step change.
#
# Markov property: "restart from the ground if they have NEVER tolerated the
# tolerance dose" reads as history-dependent, and is not. It is Markov on the
# enlarged state (dose, ratcheted, window). That enlargement is what both the
# simulator and the exact recursion below are built on. See docs/MODEL_THEORY.md.
#
# THE LADDER LIVES IN THE EXISTING SCHEMA. In Dosing_Input, each ROW is a
# co-dispensed kit component (drug + diluent are two rows of the same arm) and
# each OptionJ COLUMN is that component's quantity at rung J. A fixed-dose arm
# has only Option1 and is a ladder of length 1, which is the behaviour the
# engine had before titration existed.
#
# Titration only ACTIVATES for an arm that has a row in Titration_Input. An arm
# without one keeps the historical behaviour (pinned to rung 1) even if it has
# several Option columns populated.
# =========================================================================== #

suppressPackageStartupMessages({
  library(dplyr)
})

# Restart handling is uncapped by design: a restart resets the titration
# WINDOW, not the visit budget, so every patient still terminates on their
# cycle count / the horizon. Capping restarts with an auto-discontinue rule was
# measured and rejected — at P_Miss = 0.08 a cap of 2-3 discontinues 40-63% of
# the cohort and swings total volume ~35%, while moving the low-dose DU's share
# of demand by under one point. It is a nuisance parameter for any question
# about the DEMAND MIX, so it is fixed rather than swept. In the clinic this
# step is a human one (the study lead acts on the site clinician's
# recommendation); the simulator auto-sets it.
TITRATION_DEFAULTS <- list(
  Titration_Visits = 6L,     # N: length of the titration window, in visits
  P_Up             = 0.70,   # conditional on attending
  P_Stay           = 0.20,
  P_Down           = 0.10,
  P_Miss           = 0.00,   # per-visit probability of a missed visit
  Tolerance_Level  = NA,     # ratchet rung; NA => second-to-last rung
  Restart_Policy   = "uncapped"
)

TITRATION_COLS <- c("Protocol", "Arm", "Titration_Visits",
                    "P_Up", "P_Stay", "P_Down", "P_Miss",
                    "Tolerance_Level", "Restart_Policy")

# --------------------------------------------------------------------------- #
# read_titration()
# Load a titration spec from a CSV path or accept one already in memory.
# Returns NULL when there is none, which means "no arm titrates".
# --------------------------------------------------------------------------- #
read_titration <- function(x) {
  if (is.null(x)) return(NULL)
  if (is.character(x)) {
    if (!file.exists(x)) return(NULL)
    x <- utils::read.csv(x, stringsAsFactors = FALSE, check.names = TRUE)
  }
  x <- normalize_df(as.data.frame(x, stringsAsFactors = FALSE))
  if (nrow(x) == 0) return(NULL)
  require_cols(x, c("Protocol", "Arm"), "Titration spec")
  for (cl in setdiff(TITRATION_COLS, names(x))) x[[cl]] <- NA
  x
}

# --------------------------------------------------------------------------- #
# validate_ladder()
# A silently malformed ladder produces plausible-looking demand, which is worse
# than an error. Everything that can be checked at load time is checked here.
# --------------------------------------------------------------------------- #
validate_ladder <- function(lad) {
  who <- sprintf("%s / %s", lad$protocol, lad$arm)
  if (lad$L < 1L)
    stop(sprintf("Ladder %s has no dose rungs (no Option* column carries a quantity).",
                 who), call. = FALSE)
  if (lad$titrates) {
    ps <- c(lad$p_up, lad$p_stay, lad$p_down)
    if (any(is.na(ps)) || any(ps < 0))
      stop(sprintf("Ladder %s: P_Up/P_Stay/P_Down must all be present and >= 0.",
                   who), call. = FALSE)
    if (abs(sum(ps) - 1) > 1e-8)
      stop(sprintf("Ladder %s: P_Up + P_Stay + P_Down = %.6f, must sum to 1.",
                   who, sum(ps)), call. = FALSE)
    if (is.na(lad$p_miss) || lad$p_miss < 0 || lad$p_miss >= 1)
      stop(sprintf("Ladder %s: P_Miss must be in [0, 1).", who), call. = FALSE)
    if (lad$N < 1L)
      stop(sprintf("Ladder %s: Titration_Visits must be >= 1.", who), call. = FALSE)
    if (lad$tol < 1L || lad$tol > lad$L)
      stop(sprintf("Ladder %s: Tolerance_Level %d is outside the ladder (1..%d).",
                   who, lad$tol, lad$L), call. = FALSE)
    # every rung must dispense something, or the ladder has a hole in it
    per_rung <- colSums(lad$qty, na.rm = TRUE)
    if (any(per_rung <= 0))
      stop(sprintf("Ladder %s: rung(s) %s dispense nothing — Option columns must be contiguous.",
                   who, paste(which(per_rung <= 0), collapse = ", ")), call. = FALSE)
  }
  invisible(TRUE)
}

# --------------------------------------------------------------------------- #
# build_ladders()
# Turn a WIDE dosing sheet (+ optional titration spec) into one ladder object
# per Protocol x Arm, keyed for O(1) lookup by the simulator.
#
# Each ladder carries:
#   components : data.frame(DU_Description, Cycles, Cycle_Length)  -- the kit
#   qty        : matrix [n_components x L], units of each component at each rung
#   L, N, tol, p_up, p_stay, p_down, p_miss, cadence, max_cycles, titrates
# --------------------------------------------------------------------------- #
build_ladders <- function(dosing_df, titration_df = NULL) {
  dosing_df <- normalize_df(as.data.frame(dosing_df, stringsAsFactors = FALSE))
  require_cols(dosing_df,
               c("Protocol", "Arm", "DU_Description", "Cycles", "Cycle_Length"),
               "Dosing schedule")

  opt_cols <- grep("^Option", names(dosing_df), value = TRUE)
  if (length(opt_cols) == 0) {
    # An already-expanded long table has lost its Option columns and carries a
    # single resolved Qty. That is a one-rung ladder, so nothing titrates —
    # callers wanting titration must hand over the WIDE sheet.
    dosing_df$Option1 <- if ("Qty" %in% names(dosing_df)) dosing_df$Qty else 1
    opt_cols <- "Option1"
  }
  # Option columns are dose rungs and must be read in rung order, not the
  # order they happen to sit in the sheet.
  opt_cols <- opt_cols[order(suppressWarnings(
    as.integer(sub("^Option", "", opt_cols))))]

  titration_df <- read_titration(titration_df)

  dosing_df$Protocol       <- trimws(as.character(dosing_df$Protocol))
  dosing_df$Arm            <- trimws(as.character(dosing_df$Arm))
  dosing_df$DU_Description <- trimws(as.character(dosing_df$DU_Description))
  dosing_df$Cycles         <- as.integer(round(as.numeric(dosing_df$Cycles)))
  dosing_df$Cycle_Length   <- as.integer(round(as.numeric(dosing_df$Cycle_Length)))
  dosing_df <- dosing_df[!is.na(dosing_df$DU_Description) &
                           dosing_df$DU_Description != "", , drop = FALSE]

  keys <- paste(dosing_df$Protocol, dosing_df$Arm, sep = "\r")
  out  <- list()

  for (k in unique(keys)) {
    rows  <- dosing_df[keys == k, , drop = FALSE]
    proto <- rows$Protocol[1]; arm <- rows$Arm[1]

    qty <- suppressWarnings(vapply(opt_cols,
             function(cl) as.numeric(rows[[cl]]), numeric(nrow(rows))))
    if (is.null(dim(qty))) qty <- matrix(qty, nrow = nrow(rows))
    qty[is.na(qty)] <- 0
    colnames(qty) <- opt_cols

    tspec <- NULL
    if (!is.null(titration_df)) {
      hit <- which(trimws(titration_df$Protocol) == proto &
                     trimws(titration_df$Arm) == arm)
      if (length(hit)) tspec <- titration_df[hit[1], , drop = FALSE]
    }
    titrates <- !is.null(tspec)

    # Rungs actually in use. A fixed-dose arm is pinned to rung 1 so that an
    # arm with stray Option columns behaves exactly as it did before titration.
    used <- which(colSums(qty) > 0)
    L <- if (!titrates) 1L else if (length(used)) max(used) else 0L
    if (L >= 1L) qty <- qty[, seq_len(L), drop = FALSE]

    pick <- function(nm, default) {
      if (is.null(tspec)) return(default)
      v <- tspec[[nm]]
      if (is.null(v) || length(v) == 0 || is.na(v)) return(default)
      v
    }
    N   <- as.integer(pick("Titration_Visits", TITRATION_DEFAULTS$Titration_Visits))
    tol <- suppressWarnings(as.integer(pick("Tolerance_Level", NA)))
    # CSP convention: the tolerance dose is normally the second-to-last rung.
    if (is.na(tol)) tol <- max(1L, L - 1L)

    lad <- list(
      protocol = proto, arm = arm,
      components = data.frame(
        DU_Description = rows$DU_Description,
        Cycles         = rows$Cycles,
        Cycle_Length   = rows$Cycle_Length,
        stringsAsFactors = FALSE),
      qty      = qty,
      L        = L,
      N        = N,
      tol      = tol,
      p_up     = as.numeric(pick("P_Up",   TITRATION_DEFAULTS$P_Up)),
      p_stay   = as.numeric(pick("P_Stay", TITRATION_DEFAULTS$P_Stay)),
      p_down   = as.numeric(pick("P_Down", TITRATION_DEFAULTS$P_Down)),
      p_miss   = as.numeric(pick("P_Miss", TITRATION_DEFAULTS$P_Miss)),
      titrates = titrates
    )
    lad$cadence    <- max(rows$Cycle_Length, na.rm = TRUE)
    if (!is.finite(lad$cadence) || lad$cadence < 1) lad$cadence <- 1L
    lad$max_cycles <- max(rows$Cycles, na.rm = TRUE)
    if (!is.finite(lad$max_cycles) || lad$max_cycles < 1) lad$max_cycles <- 0L

    validate_ladder(lad)
    out[[k]] <- lad
  }
  out
}

# --------------------------------------------------------------------------- #
# .step_titration()
# One visit, advanced for a WHOLE COHORT at once.
#
# The chain is sequential in TIME and independent across PATIENTS, so the loop
# runs along the axis that is actually sequential (visit index) and every
# patient is updated as a vector inside it. That is the difference between
# ~0.68 s and ~0.034 s for 20,000 patients; see tests/benchmark.R.
#
# `st` is a list of integer vectors (dose, flr, win) plus the ratchet flag.
# Returns the updated state and the rung dispensed this visit (0 = no dispense).
# --------------------------------------------------------------------------- #
.step_titration <- function(st, lad, active) {
  n <- length(st$dose)
  dispensed <- integer(n)

  if (!lad$titrates) {
    dispensed[active] <- 1L
    return(list(st = st, dispensed = dispensed))
  }

  u    <- runif(n)
  miss <- active & (u < lad$p_miss)
  if (any(miss)) {                       # no dispense; back to floor; window resets
    st$dose[miss] <- st$flr[miss]
    st$win[miss]  <- 0L
  }

  att <- active & !miss
  if (!any(att)) return(list(st = st, dispensed = dispensed))
  dispensed[att] <- st$dose[att]

  tit <- att & (st$win < lad$N)
  if (any(tit)) {
    idx <- which(tit)
    v   <- runif(length(idx))
    d   <- st$dose[idx]
    f   <- st$flr[idx]

    # Ratchet: "tolerated once" — the patient is AT the tolerance rung, attends,
    # and does not down-titrate. Applied before the move, so a patient who
    # tolerates at the rung cannot then be floored below it.
    tolerated <- v < (lad$p_up + lad$p_stay)
    hit <- tolerated & (d == lad$tol)
    if (any(hit)) { st$ratch[idx[hit]] <- TRUE; f[hit] <- lad$tol }

    nd <- ifelse(v < lad$p_up,                pmin(d + 1L, lad$L),
          ifelse(v < lad$p_up + lad$p_stay,   d,
                                              pmax(d - 1L, f)))
    st$dose[idx] <- as.integer(nd)
    st$flr[idx]  <- as.integer(f)
    st$win[idx]  <- st$win[idx] + 1L
  }
  list(st = st, dispensed = dispensed)
}

# --------------------------------------------------------------------------- #
# .visit_dates()
# All visit dates for a cohort, as one n x T matrix, with no per-patient loop.
#   date[i,t] = start_i + t*cadence + cumsum(jitter_i)[t]
# The row-wise cumulative sum is a single multiply by an upper-triangular ones
# matrix (T is ~40, so this is cheap and stays in BLAS).
# --------------------------------------------------------------------------- #
.visit_dates <- function(starts, cadence, Tmax, visit_window) {
  n <- length(starts)
  # visit_window = 0 means "no jitter". Guarded because sample(0:0, ...) would
  # be read as sample.int(0) and error rather than returning zeros.
  J <- if (visit_window <= 0) matrix(0, n, Tmax)
       else matrix(sample(-visit_window:visit_window, n * Tmax, replace = TRUE),
                   nrow = n, ncol = Tmax)
  U <- upper.tri(matrix(0, Tmax, Tmax), diag = TRUE) * 1
  as.numeric(starts) + matrix(seq_len(Tmax) * cadence, n, Tmax, byrow = TRUE) + (J %*% U)
}

# --------------------------------------------------------------------------- #
# expected_demand()
# The EXACT expected units per patient at each visit index, by forward
# recursion over the enlarged state space — no Monte Carlo.
#
# Worth having because inventory.R collapses the Monte-Carlo replications to a
# MEAN before the (s,S) engine ever sees them (`Units / n_trials`), so the
# demand rate that drives the reorder point is an estimate of a quantity that
# has a closed form. The recursion is O(1) in patient count: measured at
# 0.0006 s for 1,000 patients and for 10,000,000 patients alike.
#
# Use it for the reorder-rate input and to validate the simulator. It gives the
# MEAN; a stockout is a threshold on a PATH, so the replication layer that
# drives stockout risk still needs simulated paths.
#
# Returns a data.frame: Protocol, Arm, DU_Description, Visit_Num, E_Units
# (expected units per enrolled patient). The horizon is not applied here —
# callers truncate by visit index.
# --------------------------------------------------------------------------- #
expected_demand <- function(ladders, horizon_visits = NULL) {
  res <- list()

  for (lad in ladders) {
    Tmax <- if (is.null(horizon_visits)) lad$max_cycles
            else min(lad$max_cycles, horizon_visits)
    if (Tmax < 1L) next
    nk <- nrow(lad$components)

    if (!lad$titrates) {
      # Rung 1 every visit, for each component's own Cycles budget.
      for (k in seq_len(nk)) {
        Tk <- min(Tmax, lad$components$Cycles[k])
        if (Tk < 1L) next
        res[[length(res) + 1L]] <- data.frame(
          Protocol = lad$protocol, Arm = lad$arm,
          DU_Description = lad$components$DU_Description[k],
          Visit_Num = seq_len(Tk), E_Units = lad$qty[k, 1],
          stringsAsFactors = FALSE, row.names = NULL)
      }
      next
    }

    L <- lad$L; N <- lad$N; TOL <- lad$tol
    S  <- L * 2L * (N + 1L)
    id <- function(d, r, w) ((r) * (N + 1L) + w) * L + d

    P     <- matrix(0, S, S)   # transition
    hold  <- numeric(S)        # P(attends | state) -- emission weight
    rung  <- integer(S)        # rung dispensed in that state

    for (r in 0:1) for (w in 0:N) for (d in seq_len(L)) {
      s <- id(d, r, w)
      f <- if (r == 1L) TOL else 1L
      rung[s] <- d
      hold[s] <- 1 - lad$p_miss

      # missed visit -> floor, window resets
      P[s, id(f, r, 0L)] <- P[s, id(f, r, 0L)] + lad$p_miss

      if (w >= N) {                       # maintenance: dose is fixed
        P[s, id(d, r, w)] <- P[s, id(d, r, w)] + (1 - lad$p_miss)
        next
      }
      for (br in list(list(lad$p_up, "up"), list(lad$p_stay, "stay"),
                      list(lad$p_down, "down"))) {
        pr <- br[[1]]; if (pr <= 0) next
        tolerated <- br[[2]] %in% c("up", "stay")
        r2 <- if (tolerated && d == TOL) 1L else r
        f2 <- if (r2 == 1L) TOL else 1L
        d2 <- switch(br[[2]], up = min(d + 1L, L), stay = d, down = max(d - 1L, f2))
        P[s, id(d2, r2, w + 1L)] <- P[s, id(d2, r2, w + 1L)] + (1 - lad$p_miss) * pr
      }
    }

    # P(dispensing at rung j | visit t), propagated forward
    pi_t <- numeric(S); pi_t[id(1L, 0L, 0L)] <- 1
    prung <- matrix(0, Tmax, L)
    for (t in seq_len(Tmax)) {
      w <- pi_t * hold
      for (j in seq_len(L)) prung[t, j] <- sum(w[rung == j])
      pi_t <- as.vector(pi_t %*% P)
    }

    for (k in seq_len(nk)) {
      Tk <- min(Tmax, lad$components$Cycles[k])
      if (Tk < 1L) next
      e <- as.vector(prung[seq_len(Tk), , drop = FALSE] %*% lad$qty[k, ])
      res[[length(res) + 1L]] <- data.frame(
        Protocol = lad$protocol, Arm = lad$arm,
        DU_Description = lad$components$DU_Description[k],
        Visit_Num = seq_len(Tk), E_Units = e,
        stringsAsFactors = FALSE, row.names = NULL)
    }
  }

  if (length(res) == 0)
    return(data.frame(Protocol = character(0), Arm = character(0),
                      DU_Description = character(0), Visit_Num = integer(0),
                      E_Units = numeric(0), stringsAsFactors = FALSE))
  .fast_bind(res)
}

# --------------------------------------------------------------------------- #
# .fast_bind()
# Column-wise concatenation of a list of identically-shaped data.frames.
#
# Replaces do.call(rbind, ...), which copies the whole accumulated frame on
# every call and is quadratic: measured 0.07 s at 12k rows and 2.24 s at 120k
# rows, against 0.001 s here. No new package dependency.
# --------------------------------------------------------------------------- #
.fast_bind <- function(lst) {
  lst <- lst[!vapply(lst, is.null, logical(1))]
  lst <- lst[vapply(lst, nrow, integer(1)) > 0]
  if (length(lst) == 0) return(NULL)
  if (length(lst) == 1) return(lst[[1]])
  nms <- names(lst[[1]])
  out <- lapply(nms, function(cl) unlist(lapply(lst, `[[`, cl), use.names = FALSE))
  names(out) <- nms
  # unlist() drops the Date class; restore it from the first frame.
  for (cl in nms) if (inherits(lst[[1]][[cl]], "Date")) out[[cl]] <- as.Date(out[[cl]], origin = "1970-01-01")
  structure(out, class = "data.frame", row.names = .set_row_names(length(out[[1]])))
}
