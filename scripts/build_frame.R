#!/usr/bin/env Rscript
# =========================================================================== #
# build_frame.R  --  the experiment's population frame, built from REINS
#
#   Rscript scripts/build_frame.R [path/to/reins/app/data] [outdir]
#
# The simulator ships 2 studies and 8 sites, which is not a frame you can
# randomise over. REINS carries a real portfolio -- phase, therapeutic area,
# site count, enrolment target, dates -- so it supplies the population and this
# engine supplies the outcome. See docs/EXPERIMENT.md §5.
#
# TWO EXCLUSIONS, both stated rather than quietly applied:
#
#  1. Status. Only Ongoing and Planning trials enter. Completed and On Hold
#     studies have no forward demand to project.
#
#  2. NPS rows are not trials. "Non-Project Specific Activities" (NPS-001,
#     NPS-IM-001, NPS-II-001, NPS-VAC-001, NPS-ONC-001) are overhead buckets in
#     a RESOURCING model -- 0 sites, 0 enrolment, no drug. They are people-time
#     categories, not studies, and cannot be randomised to a supply policy.
#     Excluding them takes the frame from 23 rows to 18 protocols.
#
# TITRATION ASSIGNMENT is deterministic, not random: a protocol titrates if it
# is Oncology or Phase I. Dose escalation is the norm in Phase I, and oncology
# protocols commonly titrate to a tolerated dose. Fixing the rule up front is
# what lets titration status be a blocking variable rather than a confound.
# =========================================================================== #

suppressPackageStartupMessages({ library(dplyr) })

args    <- commandArgs(trailingOnly = TRUE)
reins   <- if (length(args) >= 1) args[1] else path.expand("~/reins/app/data")
outdir  <- if (length(args) >= 2) args[2] else "datasets/frame"
# EXPERIMENT.md §8 contingency: if the power calculation falls short of 80% at
# the pre-specified MDE, the frame is expanded with additional synthetic
# protocols drawn from the REINS distribution. Passing a target count here is
# how that is done. The decision to expand was recorded BEFORE any outcome was
# seen; this is only the mechanism.
n_target <- if (length(args) >= 3) as.integer(args[3]) else NA_integer_
dir.create(outdir, showWarnings = FALSE, recursive = TRUE)

trials <- read.csv(file.path(reins, "Trial.csv"), stringsAsFactors = FALSE)
sites  <- read.csv(file.path(reins, "Site.csv"),  stringsAsFactors = FALSE)

n_all <- nrow(trials)
frame <- trials %>%
  filter(status %in% c("Ongoing", "Planning"),
         !grepl("^NPS", protocol_id),
         suppressWarnings(as.numeric(sites_count)) > 0,
         suppressWarnings(as.numeric(enrollment_target)) > 0) %>%
  mutate(sites_count       = as.integer(sites_count),
         enrollment_target = as.integer(enrollment_target),
         start_date        = as.Date(start_date),
         end_date          = as.Date(end_date),
         titrates          = therapeutic_area == "Oncology" | phase == "Phase I",
         # Cadence by phase: early phase runs tighter cycles than late.
         cycle_len         = ifelse(phase %in% c("Phase I", "Phase II"), 21L, 28L))

# Two REINS trials (IM-001, VAC-002) carry no end_date. Left alone that
# propagates NA into Cycles and the protocol drops out of the frame silently --
# 2 of 18, which is 11% of the randomisation units disappearing without a word.
# Impute from the median duration of the trials that do have both dates, and
# say so: a flagged imputation is recoverable, a silent drop is not.
med_days <- median(as.numeric(trials$end_date[trials$end_date != "" &
                                              trials$start_date != ""] %>%
                     as.Date() - as.Date(trials$start_date[trials$end_date != "" &
                                              trials$start_date != ""])), na.rm = TRUE)
frame <- frame %>%
  mutate(end_imputed = is.na(end_date) | end_date <= start_date,
         end_date    = as.Date(ifelse(end_imputed, start_date + med_days, end_date),
                               origin = "1970-01-01"))
if (any(frame$end_imputed))
  cat(sprintf("  NOTE: end_date imputed as start + %d days (frame median) for: %s\n",
              as.integer(med_days), paste(frame$protocol_id[frame$end_imputed],
                                          collapse = ", ")))

cat(sprintf("REINS rows %d -> frame %d protocols (%d titrating, %d fixed)\n",
            n_all, nrow(frame), sum(frame$titrates), sum(!frame$titrates)))

# --- frame expansion (§8 contingency) --------------------------------------- #
# Synthetic protocols resample (phase, TA, site count, enrolment, duration) as
# WHOLE ROWS from the real frame, so the joint distribution is preserved rather
# than each margin being drawn independently -- a 150-site Phase I vaccine trial
# is not a thing, and independent margins would invent one. Titration status
# follows the same deterministic rule as the real rows, and the seed is fixed so
# an expanded frame is reproducible from its size alone.
#
# Each resampled row is then varied (a smoothed bootstrap): site count and
# enrolment target by a lognormal factor with SD 0.25 on the log scale, the
# study's duration by one with SD 0.20, and the start moved 0-180 days later
# (never earlier, so every seed still ships after the pilot's as-of date). A
# plain copy would differ from its donor only by random seed, and a frame of
# copies would understate how much protocols vary. `donor` records the real
# protocol each row came from, so standard errors can be clustered on it
# (EXPERIMENT.md §9).
if (!is.na(n_target) && n_target > nrow(frame)) {
  set.seed(20260828L)
  extra <- n_target - nrow(frame)
  pick  <- sample(nrow(frame), extra, replace = TRUE)
  donors <- frame[pick, ]
  donors$donor <- frame$protocol_id[pick]
  jig <- function(x, sd) pmax(1L, as.integer(round(x * exp(rnorm(length(x), 0, sd)))))
  donors$sites_count       <- jig(donors$sites_count, 0.25)
  donors$enrollment_target <- pmax(donors$sites_count, jig(donors$enrollment_target, 0.25))
  dur <- as.numeric(donors$end_date - donors$start_date) * exp(rnorm(extra, 0, 0.20))
  donors$start_date <- donors$start_date + sample(0:180, extra, replace = TRUE)
  donors$end_date   <- donors$start_date + round(dur)
  donors$protocol_id <- sprintf("SYN-%03d", seq_len(extra))
  donors$synthetic   <- TRUE
  frame$synthetic    <- FALSE
  frame$donor        <- frame$protocol_id
  frame <- bind_rows(frame, donors)
  cat(sprintf("  EXPANDED to %d protocols (%d real + %d synthetic, seed 20260828)\n",
              nrow(frame), nrow(frame) - extra, extra))
} else {
  frame$synthetic <- FALSE
  frame$donor     <- frame$protocol_id
}

# --- Enrolment plan --------------------------------------------------------- #
# Patients are spread evenly across the trial's planned centres, enrolling over
# the first 40% of the study window. Real Site.csv rows supply centre ids where
# REINS has them; the rest are synthesised as <protocol>-NNN.
enroll <- list()
for (i in seq_len(nrow(frame))) {
  tr  <- frame[i, ]
  real <- sites$site_id[sites$trial_id == tr$protocol_id]
  ids <- if (length(real) >= tr$sites_count) real[seq_len(tr$sites_count)]
         else c(real, sprintf("%s-%03d", tr$protocol_id,
                              seq_len(tr$sites_count - length(real))))
  per <- diff(round(seq(0, tr$enrollment_target, length.out = length(ids) + 1)))
  win <- max(30, as.integer(0.40 * as.numeric(tr$end_date - tr$start_date)))
  keep <- per > 0
  enroll[[i]] <- data.frame(
    Protocol = tr$protocol_id, Cohort = "C1",
    Arm = if (tr$titrates) "TITR" else "FIXED",
    Patients = per[keep], Enroll_Start = tr$start_date,
    Enroll_End = tr$start_date + win, Country = "USA",
    Center = ids[keep], stringsAsFactors = FALSE)
}
enroll <- bind_rows(enroll)

# --- Dosing schedule -------------------------------------------------------- #
# A titrating arm gets a six-rung ladder in which low rungs dispense the LOW
# DU and high rungs the HIGH one, with a background component at every rung --
# the shape that makes a restart pull a DU the depot has stopped forecasting.
# A fixed-dose arm gets a two-component kit on one rung.
dosing <- list()
for (i in seq_len(nrow(frame))) {
  tr <- frame[i, ]
  cyc <- max(4L, min(40L, as.integer(
    as.numeric(tr$end_date - tr$start_date) / tr$cycle_len)))
  tag <- tr$protocol_id
  dosing[[i]] <- if (tr$titrates) data.frame(
    Protocol = tag, Arm = "TITR",
    DU_Description = paste(tag, c("BG", "LOW", "HIGH")),
    Cycles = cyc, Cycle_Length = tr$cycle_len,
    Option1 = c(2, 2, 0), Option2 = c(2, 4, 0), Option3 = c(2, 1, 1),
    Option4 = c(2, 0, 2), Option5 = c(2, 0, 3), Option6 = c(2, 0, 4),
    stringsAsFactors = FALSE)
  else data.frame(
    Protocol = tag, Arm = "FIXED",
    DU_Description = paste(tag, c("DRUG", "DILUENT")),
    Cycles = cyc, Cycle_Length = tr$cycle_len,
    Option1 = c(3, 1), Option2 = NA, Option3 = NA,
    Option4 = NA, Option5 = NA, Option6 = NA,
    stringsAsFactors = FALSE)
}
dosing <- bind_rows(dosing)

# --- Titration spec --------------------------------------------------------- #
# Tolerance rung and missed-visit rate are the two CSP parameters the supply
# side neither controls nor observes, so they VARY across the frame and are
# carried as sensitivity dimensions (EXPERIMENT.md §10). Assignment is by a
# fixed hash of the protocol id, so the frame is reproducible without a seed.
tit <- frame %>% filter(titrates) %>%
  transmute(Protocol = protocol_id, Arm = "TITR", Titration_Visits = 6L,
            P_Up = 0.70, P_Stay = 0.20, P_Down = 0.10,
            P_Miss = c(0.02, 0.08, 0.15)[
              (vapply(protocol_id, function(x) sum(utf8ToInt(x)), integer(1)) %% 3) + 1],
            Tolerance_Level = c(5L, 6L)[
              (vapply(protocol_id, function(x) sum(utf8ToInt(x)), integer(1)) %% 2) + 1],
            Restart_Policy = "uncapped")

write.csv(enroll, file.path(outdir, "enrollment_input.csv"), row.names = FALSE)
write.csv(dosing, file.path(outdir, "dosing_input.csv"),     row.names = FALSE)
write.csv(tit,    file.path(outdir, "titration_input.csv"),  row.names = FALSE)
write.csv(frame %>% select(protocol_id, phase, therapeutic_area, status,
                           sites_count, enrollment_target, titrates, cycle_len,
                           end_imputed, synthetic, donor),
          file.path(outdir, "frame.csv"), row.names = FALSE)

cat(sprintf("  %d enrolment rows | %d sites | %s patients\n",
            nrow(enroll), length(unique(enroll$Center)),
            format(sum(enroll$Patients), big.mark = ",")))
cat(sprintf("  %d dosing rows | %d titrating arms\n", nrow(dosing), nrow(tit)))
cat(sprintf("  written to %s\n", normalizePath(outdir)))
