# =========================================================================== #
# seeding.R  --  Initial site stocking (the startup shipment)
#
# A site cannot dispense to its first patient out of an empty cupboard. Studies
# run in COHORTS: a site is activated, an initial shipment is sent, and only
# then does the first patient walk in. Until this file existed the engine took
# starting on-hand as an arbitrary given (datasets/site_inventory.csv) with no
# stated relationship to how many patients the site was about to see.
#
# seed_sites() derives it instead: stock every COHORT at a site for
# `Seed_Patients` patients through their first `Seed_Visits` dispensing visits,
# and land that shipment before the cohort's enrollment start. Enrollment is
# visit 0: the patient is entered into the database and nothing is dispensed;
# the first dispense is one cycle later.
#
# WHY THE LADDER MAKES THIS INTERESTING. Every patient starts on rung 1. So the
# first few visits of a titrating arm are dominated by the LOW-dose DU, in a
# proportion nothing like that DU's share of the study as a whole. Seed a site
# off average study demand and you under-ship the low-dose DU at exactly the
# moment there is no trailing average to lean on — the (s,S) rate in
# inventory.R has no history at day zero, and the first resupply is a lead time
# away. That is a second and quite separate way titration breaks a naive supply
# rule: the restart echo bites in the middle of a study, this bites at the start.
#
# The seed quantity is computed from expected_demand() truncated to the first
# `Seed_Visits` visits, which is exact and needs no simulation.
# =========================================================================== #

suppressPackageStartupMessages({
  library(dplyr)
})

SEEDING_DEFAULTS <- list(
  Seed_Patients   = NA,    # patients to stock for; NA => the whole cohort at that site
  Seed_Visits     = NA,    # visits of coverage; NA => enough to outlast one lead time
  Seed_Buffer     = 0.10,  # proportional over-ship on the initial shipment
  Seed_Lead_Days  = 21,    # shipment lands this many days before the cohort's visit 0
  Seed_Shelf_Life = 730    # retest for a seed with no depot to ship from (see inventory.R)
)

# --------------------------------------------------------------------------- #
# seed_sites()
# Returns one row per (Protocol, Site, Cohort, DU) initial shipment:
#   Protocol, Site, Cohort, DU, Arrive_Date, Planned_Qty, Qty, Expiry
# Planned_Qty is what the cohort needs; Qty is what ships, which the inventory
# walk tops up against stock the site already holds (Qty = Planned_Qty here).
#
# `Seed_Visits` defaults to the number of visits that spans one resupply lead
# time, plus one — i.e. stock the site so it can survive until the first
# reorder can physically arrive. That ties the seed to the constraint that
# actually governs it rather than to a round number.
# --------------------------------------------------------------------------- #
seed_sites <- function(enrollment_df, ladders, params = list()) {
  p <- modifyList(SEEDING_DEFAULTS, params)

  enrollment_df <- normalize_df(as.data.frame(enrollment_df,
                                              stringsAsFactors = FALSE))
  require_cols(enrollment_df,
               c("Protocol", "Arm", "Patients", "Enroll_Start", "Center"),
               "Enrollment plan")

  if (!"Country" %in% names(enrollment_df)) enrollment_df$Country <- NA_character_
  if (!"Cohort" %in% names(enrollment_df))  enrollment_df$Cohort  <- "C1"
  enr <- enrollment_df %>%
    mutate(Protocol = trimws(as.character(Protocol)),
           Arm      = trimws(as.character(Arm)),
           Cohort   = trimws(as.character(Cohort)),
           Site     = site_key(Country, Center),
           Patients = as.integer(round(as.numeric(Patients))),
           Enroll_Start = as_date_flex(Enroll_Start)) %>%
    filter(!is.na(Patients), Patients > 0, !is.na(Enroll_Start))
  if (nrow(enr) == 0) return(.empty_receipts())

  # One shipment per cohort at each site and arm, dated to that cohort's own
  # enrollment start. Seeding the whole site once, off its first cohort, shipped
  # every future cohort's stock years early and let it expire on the shelf.
  cohorts <- enr %>%
    group_by(Protocol, Site, Arm, Cohort) %>%
    summarise(Cohort_Patients = sum(Patients),
              First_Visit     = min(Enroll_Start), .groups = "drop")

  out <- list()
  for (i in seq_len(nrow(cohorts))) {
    row <- cohorts[i, ]
    lad <- ladders[[paste(row$Protocol, row$Arm, sep = "\r")]]
    if (is.null(lad) || lad$max_cycles < 1L) next

    n_seed <- if (is.na(p$Seed_Patients)) row$Cohort_Patients
              else min(as.integer(p$Seed_Patients), row$Cohort_Patients)
    if (is.na(n_seed) || n_seed < 1L) next

    # Visits of cover: enough to outlast one resupply lead time.
    k <- if (!is.na(p$Seed_Visits)) as.integer(p$Seed_Visits)
         else as.integer(ceiling(p$Seed_Lead_Days / max(1L, lad$cadence)) + 1L)
    k <- max(1L, min(k, lad$max_cycles))

    # Exact expected units over the FIRST k visits -- rung 1 heavy for a ladder.
    e <- expected_demand(setNames(list(lad), "x"), horizon_visits = k)
    if (nrow(e) == 0) next
    need <- e %>%
      group_by(DU_Description) %>%
      summarise(Units = sum(E_Units), .groups = "drop") %>%
      # A DU that the seed window does not reach — a high rung nobody can be on
      # yet — must not generate an empty shipment line. Dropping it here is the
      # point of seeding off the ladder rather than off study-average demand.
      filter(Units > 0)
    if (nrow(need) == 0) next

    arrive <- row$First_Visit - p$Seed_Lead_Days
    out[[length(out) + 1L]] <- data.frame(
      Protocol    = row$Protocol,
      Site        = row$Site,
      Cohort      = row$Cohort,
      DU          = need$DU_Description,
      Arrive_Date = arrive,
      Planned_Qty = ceiling(n_seed * need$Units * (1 + p$Seed_Buffer)),
      Expiry      = arrive + p$Seed_Shelf_Life,
      stringsAsFactors = FALSE, row.names = NULL)
  }

  res <- .fast_bind(out)
  if (is.null(res)) return(.empty_receipts())
  # One arm's kit can share a DU with another arm's in the same cohort and site.
  res %>%
    group_by(Protocol, Site, Cohort, DU, Arrive_Date, Expiry) %>%
    summarise(Planned_Qty = sum(Planned_Qty), .groups = "drop") %>%
    mutate(Qty = Planned_Qty) %>%
    select(Protocol, Site, Cohort, DU, Arrive_Date, Planned_Qty, Qty, Expiry) %>%
    as.data.frame(stringsAsFactors = FALSE)
}

.empty_receipts <- function()
  data.frame(Protocol = character(0), Site = character(0), Cohort = character(0),
             DU = character(0), Arrive_Date = as.Date(character(0)),
             Planned_Qty = numeric(0), Qty = numeric(0),
             Expiry = as.Date(character(0)), stringsAsFactors = FALSE)

# --------------------------------------------------------------------------- #
# seed_mix_check()
# The diagnostic the whole file exists for: how different is the DU mix a site
# needs for its first k visits from the mix it needs over the whole study?
#
# Returns one row per (Protocol, Arm, DU) with the DU's share of units in the
# seed window against its share across the study, and the ratio between them.
# A ratio far from 1 is a DU that a study-average seeding rule gets wrong.
# --------------------------------------------------------------------------- #
seed_mix_check <- function(ladders, seed_visits = NULL, lead_days = 21) {
  rows <- list()
  for (lad in ladders) {
    k <- if (!is.null(seed_visits)) as.integer(seed_visits)
         else as.integer(ceiling(lead_days / max(1L, lad$cadence)) + 1L)
    k <- max(1L, min(k, lad$max_cycles))
    one <- setNames(list(lad), "x")

    early <- expected_demand(one, horizon_visits = k) %>%
      group_by(DU_Description) %>% summarise(Early = sum(E_Units), .groups = "drop")
    whole <- expected_demand(one) %>%
      group_by(DU_Description) %>% summarise(Whole = sum(E_Units), .groups = "drop")
    m <- merge(early, whole, by = "DU_Description")
    if (nrow(m) == 0) next
    m$Seed_Share  <- m$Early / sum(m$Early)
    m$Study_Share <- m$Whole / sum(m$Whole)
    m$Ratio       <- m$Seed_Share / m$Study_Share
    rows[[length(rows) + 1L]] <- data.frame(
      Protocol = lad$protocol, Arm = lad$arm, Seed_Visits = k,
      DU = m$DU_Description, Seed_Share = round(m$Seed_Share, 4),
      Study_Share = round(m$Study_Share, 4), Ratio = round(m$Ratio, 3),
      stringsAsFactors = FALSE, row.names = NULL)
  }
  res <- .fast_bind(rows)
  if (is.null(res)) return(NULL)
  res[order(-res$Ratio), , drop = FALSE]
}
