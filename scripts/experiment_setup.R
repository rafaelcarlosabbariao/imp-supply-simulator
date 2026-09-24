# =========================================================================== #
# experiment_setup.R  --  the experiment's frame, seeds, depot and policy
#
# Sourced by scripts/power_pilot.R and scripts/compare_forecasts.R after the
# engine, with `root` set. Defines: AS_OF, HORIZON, enroll, dosing, titr,
# frame, ladders, receipts, depot, CONTROL, empty_site_inv.
# =========================================================================== #

# EXP_FRAME points at an expanded frame (EXPERIMENT.md §8); the default is the
# 18-protocol frame built from REINS.
FRAME   <- Sys.getenv("EXP_FRAME", file.path(root, "datasets/frame"))
# Planning as-of must precede EVERY trial in the frame, or protocols are not
# treated alike. A trial already mid-flight at the as-of date gets seeded for a
# patient's FIRST visits (rung 1) while its actual demand is from patients who
# have already climbed the ladder -- so the high-dose DU starts with no stock
# and cannot be reordered inside the lead time. That is an artefact of the
# snapshot, not a property of the reorder rule, and in the 2024-01-01 run it
# was the entire between-protocol variance: ONC-001, the only titrating trial
# starting before that date, sat at 0.372 while every other protocol was
# <= 0.0067. Fixed-dose trials in the same position are unaffected, because a
# one-rung ladder has no mix to get wrong.
# Before the earliest SEED SHIP DATE, which is a cohort's start less the seed
# lead (21 days) less the lane (21 days): 2022-04-08 on this frame. The old
# default, 2022-05-01, was before the earliest start but after some seeds left.
AS_OF   <- as.Date(Sys.getenv("ASOF", "2022-04-01"))
HORIZON <- as.Date(Sys.getenv("HORIZON", "2026-12-31"))
SEED_PATIENTS <- NA                  # NA => each site's own planned cohort

enroll <- read.csv(file.path(FRAME, "enrollment_input.csv"), stringsAsFactors = FALSE)
dosing <- read.csv(file.path(FRAME, "dosing_input.csv"),     stringsAsFactors = FALSE)
titr   <- read_titration(file.path(FRAME, "titration_input.csv"))
frame  <- read.csv(file.path(FRAME, "frame.csv"),            stringsAsFactors = FALSE)
ladders <- build_ladders(dosing, titr)

# Site seeding is deterministic given the frame: it depends on the planned
# cohort and the planned ladder, not on any realisation. Computed once.
receipts <- seed_sites(enroll, ladders, list(Seed_Patients = SEED_PATIENTS))
cat(sprintf("frame: %d protocols, %d sites, %s patients | seed: %d shipments, %s units\n",
            nrow(frame), length(unique(enroll$Center)),
            format(sum(enroll$Patients), big.mark = ","),
            nrow(receipts), format(sum(receipts$Qty), big.mark = ",")))

# The depot is stocked generously on purpose: this experiment is about the SITE
# reorder rule, and a depot that runs dry would make depot shortfall, not site
# policy, the thing being measured.
#
# It must be sized off the WHOLE STUDY's expected demand, not off the seed
# shipment. Seeding correctly ships nothing for a high rung nobody can be on
# yet, so building the depot from the seed receipts leaves the high-dose DU
# with zero stock anywhere -- which reads as a 100% stockout on exactly one DU
# in three, flat across every titrating protocol and with zero variance across
# replications. That is a harness artefact wearing the costume of a finding.
DEPOT_FACTOR <- 3
pat <- enroll %>% group_by(Protocol, Arm) %>%
  summarise(N = sum(Patients), .groups = "drop")
depot <- expected_demand(ladders) %>%
  group_by(Protocol, Arm, DU_Description) %>%
  summarise(per_patient = sum(E_Units), .groups = "drop") %>%
  left_join(pat, by = c("Protocol", "Arm")) %>%
  group_by(Protocol, DU = DU_Description) %>%
  summarise(Qty = ceiling(sum(per_patient * N) * DEPOT_FACTOR), .groups = "drop")

# Four equal lots per DU, expiring 24, 36, 48 and 60 months after the as-of
# date (EXPERIMENT.md §4). One lot expiring after the horizon left nothing able
# to expire, and Total_Expired was 0 in every run.
DEPOT_LOT_MONTHS <- c(24, 36, 48, 60)
depot <- depot %>%
  tidyr::crossing(Months = DEPOT_LOT_MONTHS) %>%
  transmute(Protocol, Location = "DEPOT", DU,
            Qty = ceiling(Qty / length(DEPOT_LOT_MONTHS)),
            Expiry = seq(AS_OF, by = "month", length.out = max(DEPOT_LOT_MONTHS) + 1)[Months + 1])

# Guard: every DU the ladders can demand must have depot stock. Without this
# the failure above is silent and looks like a result.
want <- unique(unlist(lapply(ladders, function(l) l$components$DU_Description)))
gap  <- setdiff(want, depot$DU)
if (length(gap))
  stop(sprintf("%d DU(s) have no depot stock: %s", length(gap),
               paste(head(gap, 5), collapse = ", ")), call. = FALSE)

cat(sprintf("depot: %d lots, %s units (%.0fx expected demand), expiring %s\n",
            nrow(depot), format(sum(depot$Qty), big.mark = ","), DEPOT_FACTOR,
            paste(sort(unique(depot$Expiry)), collapse = ", ")))

CONTROL <- list(safety_stock_days = 30, target_days = 90, lead_time_days = 21,
                unplanned_visit_pct = 0.10, oversupply_pct = 0.10,
                start_date = AS_OF, horizon_end = HORIZON, enable_resupply = TRUE)

empty_site_inv <- data.frame(Protocol = character(0), Location = character(0),
                             DU = character(0), Qty = numeric(0),
                             Expiry = as.Date(character(0)), stringsAsFactors = FALSE)


# --------------------------------------------------------------------------- #
# One protocol, one replication, both arms.
#
# Each protocol is simulated on its own, seeded from the replication and the
# protocol's position in the frame, so its demand does not depend on which other
# protocols are in the frame or how the work is split across processes. The
# two arms are walked on that one realisation (common random numbers).
# --------------------------------------------------------------------------- #
ARMS <- c(control = "trailing", treatment = "rung")

run_protocol <- function(proto, rep_seed, forecasts = ARMS) {
  idx <- match(proto, frame$protocol_id)
  set.seed(rep_seed * 1000L + idx)
  pats <- simulate_enrollment(enroll[enroll$Protocol == proto, ], num_simulations = 1L)
  v <- simulate_visits(pats, dosing[dosing$Protocol == proto, ], visit_window = 3,
                       simulation_end_date = HORIZON,
                       titration = titr[titr$Protocol == proto, , drop = FALSE])
  d <- compute_demand(v)
  lad <- ladders[vapply(ladders, function(l) l$protocol == proto, logical(1))]
  out <- lapply(forecasts, function(m) {
    pr <- suppressMessages(project_inventory(
      d, empty_site_inv, depot[depot$Protocol == proto, ], CONTROL,
      initial_receipts = receipts[receipts$Protocol == proto, ],
      opening = "seeded", forecast = m,
      visits = if (m == "rung") bind_rows(pats, v), ladders = if (m == "rung") lad))
    s <- pr$summary
    data.frame(rep_seed = rep_seed, Protocol = proto, forecast = m,
               Units = nrow(s), Stockouts = sum(s$Status == "STOCKOUT"),
               P_Stockout = mean(s$Status == "STOCKOUT"),
               Stockout_Units = sum(s$Total_Stockout), Expired = sum(s$Total_Expired),
               Reorders = sum(s$Reorders), Seed_Short = sum(pr$daily$Seed_Short),
               stringsAsFactors = FALSE)
  })
  do.call(rbind, out)
}
