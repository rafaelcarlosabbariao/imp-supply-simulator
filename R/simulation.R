# =========================================================================== #
# simulation.R  --  Protocol-agnostic DEMAND engine
#
# Turns two labelled inputs (an enrollment plan and a dosing schedule) into a
# simulated stream of subject visits and the drug units dispensed at each one.
# Works for ANY protocol as long as the required, labelled columns are present.
#
# Required columns
#   Enrollment plan : Protocol, Cohort, Arm, Patients, Enroll_Start, Enroll_End,
#                     Country, Center
#   Dosing schedule : Protocol, Arm, DU_Description, Cycles, Cycle_Length,
#                     Option1 [, Option2 ...]   (Option* = units dispensed)
#
# Used by both the Shiny app (server.R) and the headless runner
# (R/run_simulation.R), so the two can never drift apart.
# =========================================================================== #

suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
  library(lubridate)
  library(stringr)
})

# ---- small helpers -------------------------------------------------------- #

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a

.trim <- function(x) if (is.character(x) || is.factor(x)) trimws(as.character(x)) else x

# Trim column names and every character column. Trailing spaces in the real
# source data (e.g. "TRIAL-118 ") otherwise silently break joins/filters.
normalize_df <- function(df) {
  df <- as.data.frame(df, stringsAsFactors = FALSE)
  names(df) <- trimws(names(df))
  char_cols <- vapply(df, function(c) is.character(c) || is.factor(c), logical(1))
  df[char_cols] <- lapply(df[char_cols], .trim)
  df
}

# Assert that a data frame carries the columns an engine step depends on.
require_cols <- function(df, cols, what) {
  missing <- setdiff(cols, names(df))
  if (length(missing)) {
    stop(sprintf("%s is missing required column(s): %s",
                 what, paste(missing, collapse = ", ")), call. = FALSE)
  }
  invisible(TRUE)
}

# ---- site identity ---------------------------------------------------------- #
# A site is a CENTER IN A COUNTRY. Center numbers are not unique across
# countries -- TRIAL-118 runs a center 1004 in Mexico and another in the USA --
# so every join on a site uses this key and never the center number alone.
# Format: "1004 \u00b7 Mexico". A row with no country keys on the center alone.
SITE_SEP <- " \u00b7 "

site_key <- function(country, center) {
  center  <- trimws(as.character(center))
  country <- trimws(as.character(country))
  ifelse(is.na(country) | country == "", center, paste0(center, SITE_SEP, country))
}

site_center <- function(key) {
  key <- as.character(key)
  i <- regexpr(SITE_SEP, key, fixed = TRUE)
  ifelse(i > 0, substr(key, 1, i - 1), key)
}

site_country <- function(key) {
  key <- as.character(key)
  i <- regexpr(SITE_SEP, key, fixed = TRUE)
  ifelse(i > 0, substring(key, i + nchar(SITE_SEP)), NA_character_)
}

# Parse a date column that may arrive as Date, POSIXct, or "yyyy-mm-dd" string.
as_date_flex <- function(x) {
  if (inherits(x, "Date")) return(x)
  if (inherits(x, "POSIXt")) return(as.Date(x))
  suppressWarnings(as.Date(as.character(x)))
}

# --------------------------------------------------------------------------- #
# expand_dosing()
# Normalise a wide dosing schedule into one tidy row per (Protocol, Arm, DU)
# with a single dispensed-quantity column (Qty). `option` chooses which
# dispensing-option column supplies the quantity; if blank, the first non-empty
# Option* column is used.
# --------------------------------------------------------------------------- #
expand_dosing <- function(dosing_df, option = "Option1") {
  dosing_df <- normalize_df(dosing_df)
  require_cols(dosing_df,
              c("Protocol", "Arm", "DU_Description", "Cycles", "Cycle_Length"),
              "Dosing schedule")

  opt_cols <- grep("^Option", names(dosing_df), value = TRUE)
  if (length(opt_cols) == 0) {
    dosing_df$Option1 <- 1
    opt_cols <- "Option1"
  }

  # numeric matrix of the option columns
  opt_mat <- suppressWarnings(
    vapply(opt_cols, function(c) as.numeric(dosing_df[[c]]),
           numeric(nrow(dosing_df))))
  if (is.null(dim(opt_mat))) opt_mat <- matrix(opt_mat, ncol = length(opt_cols))

  pick_qty <- function(i) {
    if (option %in% opt_cols) {
      v <- opt_mat[i, which(opt_cols == option)]
      if (!is.na(v)) return(v)
    }
    row <- opt_mat[i, ]
    nz <- row[!is.na(row)]
    if (length(nz)) nz[1] else 1
  }

  dosing_df %>%
    mutate(
      Protocol      = trimws(as.character(Protocol)),
      Arm           = trimws(as.character(Arm)),
      DU_Description = trimws(as.character(DU_Description)),
      Cycles        = as.integer(round(as.numeric(Cycles))),
      Cycle_Length  = as.integer(round(as.numeric(Cycle_Length))),
      Qty           = vapply(seq_len(n()), pick_qty, numeric(1))
    ) %>%
    filter(!is.na(DU_Description), DU_Description != "") %>%
    select(Protocol, Arm, DU_Description, Cycles, Cycle_Length, Qty)
}

# --------------------------------------------------------------------------- #
# simulate_enrollment()
# For each enrollment-plan row, create `Patients` subjects with enrollment dates
# drawn uniformly across [Enroll_Start, Enroll_End]. Repeated `num_simulations`
# times to produce independent Monte-Carlo trials.
# --------------------------------------------------------------------------- #
simulate_enrollment <- function(enrollment_df, num_simulations = 1) {
  enrollment_df <- normalize_df(enrollment_df)
  require_cols(enrollment_df,
              c("Protocol", "Cohort", "Arm", "Patients",
                "Enroll_Start", "Enroll_End", "Country", "Center"),
              "Enrollment plan")

  enrollment_df <- enrollment_df %>%
    mutate(
      Patients     = as.integer(round(as.numeric(Patients))),
      Enroll_Start = as_date_flex(Enroll_Start),
      Enroll_End   = as_date_flex(Enroll_End),
      Center       = trimws(as.character(Center))
    ) %>%
    filter(!is.na(Patients), Patients > 0,
           !is.na(Enroll_Start), !is.na(Enroll_End))

  if (nrow(enrollment_df) == 0)
    stop("Enrollment plan has no valid rows after cleaning.", call. = FALSE)

  df_trials <- vector("list", num_simulations)

  for (i in seq_len(num_simulations)) {
    df_list <- vector("list", nrow(enrollment_df))
    for (j in seq_len(nrow(enrollment_df))) {
      r <- enrollment_df[j, ]
      patients   <- r$Patients
      start      <- r$Enroll_Start
      end        <- if (r$Enroll_End < r$Enroll_Start) r$Enroll_Start else r$Enroll_End
      date_range <- seq(start, end, by = "day")
      enroll_dates <- if (length(date_range) == 1) rep(date_range, patients)
                      else sample(date_range, patients, replace = TRUE)

      df_list[[j]] <- data.frame(
        Protocol   = r$Protocol,
        Cohort     = r$Cohort,
        Country    = r$Country,
        Center     = r$Center,
        Site       = site_key(r$Country, r$Center),
        SSID       = NA_character_,
        TG         = r$Arm,
        Visit_Num  = 0L,
        Visit_Desc = "Enrollment",
        Visit_Date = enroll_dates,
        Visit_Type = "Planned",
        DU_Desc    = NA_character_,
        Qty        = 0,
        Kit_ID     = NA_character_,
        Lot_ID     = NA_character_,
        Trial      = i,
        stringsAsFactors = FALSE
      )
    }
    df_trials[[i]] <- .fast_bind(df_list)
  }

  # .fast_bind (R/titration.R) instead of do.call(rbind, .), which recopies the
  # whole accumulated frame on every call and is quadratic in the row count.
  out <- .fast_bind(df_trials)
  out <- out[order(out$Visit_Date), ]
  out <- out %>%
    group_by(Site, Trial) %>%
    mutate(SSID = paste0(gsub(SITE_SEP, "-", Site, fixed = TRUE), "-",
                         1000 + row_number())) %>%
    ungroup()
  rownames(out) <- NULL
  out
}

# --------------------------------------------------------------------------- #
# simulate_visits()
# Step every enrolled subject forward through their dosing cycles until
# `simulation_end_date`, dispensing the kit for whichever DOSE RUNG the subject
# is on at that visit. Visit cadence is the arm's cycle length, jittered by
# +/- visit_window.
#
# VECTORISED ACROSS PATIENTS. The titration chain is sequential in TIME but
# independent across PATIENTS, so the loop runs along the axis that is actually
# sequential (the visit index) and every patient advances as a vector inside
# it. Cohorts are processed one arm at a time, which keeps cadence and ladder
# depth scalar within a group. Measured 20x faster than the per-patient loop at
# 20,000 patients; see tests/benchmark.R.
#
# Passing `titration` (a spec data.frame or a CSV path) activates dose
# laddering for the arms named in it. Every other arm stays pinned to rung 1,
# which is the behaviour this engine had before titration existed.
#
# NOTE: this replaces the original which (a) never recorded a dispensed quantity
# and (b) contained a broken `max(DU_list, FUN=...)` branch that errored whenever
# an arm mixed cycle lengths. Cadence here is the longest cycle length in the arm.
# --------------------------------------------------------------------------- #
simulate_visits <- function(patient_df, dosing_long, visit_window = 3,
                            simulation_end_date = Sys.Date() + months(6),
                            progress = NULL, titration = NULL) {
  patient_df <- as.data.frame(patient_df, stringsAsFactors = FALSE)
  simulation_end_date <- as_date_flex(simulation_end_date)

  ladders <- build_ladders(dosing_long, titration)
  if (length(ladders) == 0) return(patient_df[0, , drop = FALSE])

  keys    <- paste(patient_df$Protocol,
                   trimws(as.character(patient_df$TG)), sep = "\r")
  starts  <- as_date_flex(patient_df$Visit_Date)
  horizon <- as.numeric(simulation_end_date)
  base_vn <- as.integer(patient_df$Visit_Num)

  pieces <- list()
  done   <- 0L

  for (k in intersect(unique(keys), names(ladders))) {
    lad  <- ladders[[k]]
    idx  <- which(keys == k)
    n    <- length(idx)
    Tmax <- lad$max_cycles
    if (n == 0L || Tmax < 1L) {
      done <- done + n
      if (!is.null(progress)) progress(done)
      next
    }

    dates <- .visit_dates(starts[idx], lad$cadence, Tmax, visit_window)
    # `V` counts every visit landing on or before the horizon, which is the
    # original engine's semantics; the first V visits are the ones that happen.
    V <- rowSums(dates <= horizon)

    # --- advance the whole cohort one visit at a time --------------------- #
    st <- list(dose  = rep(1L, n), flr = rep(1L, n),
               win   = rep(0L, n), ratch = rep(FALSE, n))
    rung_at <- matrix(0L, n, Tmax)      # 0 = no dispense (missed or inactive)
    for (t in seq_len(Tmax)) {
      active <- t <= V
      if (!any(active)) break
      step <- .step_titration(st, lad, active)
      st <- step$st
      rung_at[, t] <- step$dispensed
    }

    # --- expand rungs into co-dispensed kit components -------------------- #
    for (ck in seq_len(nrow(lad$components))) {
      Tk <- min(Tmax, lad$components$Cycles[ck])
      if (is.na(Tk) || Tk < 1L) next
      sub <- rung_at[, seq_len(Tk), drop = FALSE]
      nz  <- sub > 0L
      if (!any(nz)) next
      q <- matrix(0, n, Tk)
      q[nz] <- lad$qty[ck, ][sub[nz]]   # units of THIS component at THAT rung
      hit <- which(q > 0, arr.ind = TRUE)
      if (nrow(hit) == 0L) next

      pi_ <- hit[, 1L]; ti_ <- hit[, 2L]
      gi  <- idx[pi_]
      vn  <- base_vn[gi] + ti_
      pieces[[length(pieces) + 1L]] <- data.frame(
        Protocol   = patient_df$Protocol[gi],
        Cohort     = patient_df$Cohort[gi],
        Country    = patient_df$Country[gi],
        Center     = patient_df$Center[gi],
        Site       = patient_df$Site[gi],
        SSID       = patient_df$SSID[gi],
        TG         = lad$arm,
        Visit_Num  = vn,
        Visit_Desc = paste("Cycle", vn),
        Visit_Date = as.Date(dates[cbind(pi_, ti_)], origin = "1970-01-01"),
        Visit_Type = "Planned",
        DU_Desc    = lad$components$DU_Description[ck],
        Rung       = sub[hit],          # dose rung this visit was made at
        Qty        = q[hit],
        Kit_ID     = NA_character_,
        Lot_ID     = NA_character_,
        Trial      = patient_df$Trial[gi],
        stringsAsFactors = FALSE)
    }

    done <- done + n
    if (!is.null(progress)) progress(done)
  }

  res <- .fast_bind(pieces)
  if (is.null(res)) return(patient_df[0, , drop = FALSE])
  res <- res[order(res$Visit_Date), , drop = FALSE]
  rownames(res) <- NULL
  res
}

# Accept either a raw wide dosing sheet or an already-expanded long table.
expand_dosing_if_needed <- function(dosing) {
  dosing <- normalize_df(dosing)
  if ("Qty" %in% names(dosing) && !any(grepl("^Option", names(dosing)))) dosing
  else expand_dosing(dosing)
}

# --------------------------------------------------------------------------- #
# add_date_windows() / compute_demand()
# --------------------------------------------------------------------------- #
add_date_windows <- function(df) {
  df %>% mutate(
    Visit_Date      = as_date_flex(Visit_Date),
    Visit_Date_YrWk  = format(Visit_Date, "%Y-%U"),
    Visit_Date_YrMo  = format(Visit_Date, "%Y-%m"),
    Visit_Date_YrQtr = paste0(year(Visit_Date), "-Q", quarter(Visit_Date))
  )
}

# Units of each DU dispensed per site per day, per trial.
compute_demand <- function(visits_df) {
  visits_df %>%
    filter(!is.na(DU_Desc), DU_Desc != "") %>%
    mutate(Visit_Date = as_date_flex(Visit_Date)) %>%
    group_by(Protocol, Country, Site, DU_Desc, Trial, Visit_Date) %>%
    summarise(Units = sum(Qty, na.rm = TRUE), .groups = "drop")
}
