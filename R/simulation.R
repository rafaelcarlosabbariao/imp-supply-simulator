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
        Site       = r$Center,
        SSID       = paste0(r$Center, 1000 + seq_len(patients)),
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
    df_trials[[i]] <- do.call(rbind, df_list)
  }

  out <- do.call(rbind, df_trials)
  out <- out[order(out$Visit_Date), ]
  out <- out %>%
    group_by(Site, Trial) %>%
    mutate(SSID = paste0(Site, 1000 + row_number())) %>%
    ungroup()
  rownames(out) <- NULL
  out
}

# --------------------------------------------------------------------------- #
# simulate_visits()
# Step every enrolled subject forward through their dosing cycles until
# `simulation_end_date`, dispensing each DU (with its quantity) while cycles
# remain. Visit cadence is the arm's cycle length, jittered by +/- visit_window.
#
# NOTE: this replaces the original which (a) never recorded a dispensed quantity
# and (b) contained a broken `max(DU_list, FUN=...)` branch that errored whenever
# an arm mixed cycle lengths. Cadence here is the longest cycle length in the arm.
# --------------------------------------------------------------------------- #
simulate_visits <- function(patient_df, dosing_long, visit_window = 3,
                            simulation_end_date = Sys.Date() + months(6),
                            progress = NULL) {
  patient_df  <- as.data.frame(patient_df, stringsAsFactors = FALSE)
  dosing_long <- expand_dosing_if_needed(dosing_long)
  simulation_end_date <- as_date_flex(simulation_end_date)

  # Pre-split dosing by protocol+arm so each subject is an O(1) lookup, not a
  # data-frame filter. Character key avoids repeated dplyr overhead.
  dose_key <- paste(dosing_long$Protocol, dosing_long$Arm, sep = "\r")
  dose_by  <- split(dosing_long, dose_key)

  n <- nrow(patient_df)
  out <- vector("list", n)
  starts <- as_date_flex(patient_df$Visit_Date)

  for (i in seq_len(n)) {
    key <- paste(patient_df$Protocol[i], trimws(as.character(patient_df$TG[i])), sep = "\r")
    dose_opt <- dose_by[[key]]
    if (is.null(dose_opt) || nrow(dose_opt) == 0) {   # no dosing for this arm
      if (!is.null(progress)) progress(i); next
    }

    cadence    <- max(dose_opt$Cycle_Length, na.rm = TRUE)
    if (!is.finite(cadence) || cadence < 1) cadence <- 1
    max_cycles <- max(dose_opt$Cycles, na.rm = TRUE)
    if (!is.finite(max_cycles) || max_cycles < 1) { if (!is.null(progress)) progress(i); next }

    # Visit dates: `max_cycles` visits at the arm cadence, each jittered, then
    # truncated at the simulation horizon. Built as one vector, not a loop.
    jitter <- sample(-visit_window:visit_window, max_cycles, replace = TRUE)
    vdates <- starts[i] + cumsum(rep(cadence, max_cycles) + jitter)
    V <- sum(vdates <= simulation_end_date)
    if (V == 0) { if (!is.null(progress)) progress(i); next }
    vnums <- patient_df$Visit_Num[i] + seq_len(V)

    # Each DU is dispensed for its first `Cycles` visits (bounded by V).
    du_rows <- vector("list", nrow(dose_opt))
    for (k in seq_len(nrow(dose_opt))) {
      nk <- min(V, dose_opt$Cycles[k])
      if (nk < 1) next
      idx <- seq_len(nk)
      du_rows[[k]] <- data.frame(
        Protocol   = patient_df$Protocol[i],
        Cohort     = patient_df$Cohort[i],
        Country    = patient_df$Country[i],
        Site       = patient_df$Site[i],
        SSID       = patient_df$SSID[i],
        TG         = dose_opt$Arm[k],
        Visit_Num  = vnums[idx],
        Visit_Desc = paste("Cycle", vnums[idx]),
        Visit_Date = vdates[idx],
        Visit_Type = "Planned",
        DU_Desc    = dose_opt$DU_Description[k],
        Qty        = dose_opt$Qty[k],
        Kit_ID     = NA_character_,
        Lot_ID     = NA_character_,
        Trial      = patient_df$Trial[i],
        stringsAsFactors = FALSE
      )
    }
    out[[i]] <- do.call(rbind, du_rows)
    if (!is.null(progress)) progress(i)
  }

  out <- out[!vapply(out, is.null, logical(1))]
  if (length(out) == 0)
    return(patient_df[0, , drop = FALSE])
  res <- do.call(rbind, out)
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
