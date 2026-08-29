#!/usr/bin/env Rscript
# =========================================================================== #
# run_simulation.R  --  Headless end-to-end run of the demand + supply model
#
# Runs the full pipeline for EVERY protocol found in the inputs, with no Shiny
# UI required, and writes results to output/. Handy for batch/portfolio runs and
# for verifying the engine independently of the app.
#
#   Rscript scripts/run_simulation.R [num_simulations] [sim_end_date YYYY-MM-DD] \
#                                     [as_of_date] [seed] [seed_patients]
#
# Inputs read (repo root):
#   Program_Inputs.xlsx  (Enrollment_Input, Dosing_Input sheets)   -- OR --
#   datasets/*.csv       (falls back to these if the workbook is absent)
#   datasets/site_inventory.csv, datasets/depot_inventory.csv
# Outputs written (output/):
#   simulated_visits.csv, inventory_daily.csv, inventory_summary.csv,
#   portfolio_by_study.csv
# =========================================================================== #

suppressPackageStartupMessages({
  library(dplyr); library(readxl); library(readr)
})

script_path <- tryCatch(sub("--file=", "",
              grep("--file=", commandArgs(FALSE), value = TRUE)),
              error = function(e) "scripts/run_simulation.R")
here <- if (length(script_path) && nzchar(script_path[1])) dirname(script_path[1]) else "scripts"
root <- normalizePath(file.path(here, ".."), mustWork = FALSE)
engine <- file.path(root, "R")

source(file.path(engine, "titration.R"))
source(file.path(engine, "simulation.R"))
source(file.path(engine, "forecast.R"))
source(file.path(engine, "inventory.R"))
source(file.path(engine, "seeding.R"))

args <- commandArgs(trailingOnly = TRUE)
num_simulations <- if (length(args) >= 1) as.integer(args[1]) else 5L
sim_end_date    <- if (length(args) >= 2) as.Date(args[2]) else as.Date("2026-12-31")
# planning "as-of" date: on-hand inventory in the sample data is current as of
# 2024-01-01, so project forward from there.
as_of_date      <- if (length(args) >= 3) as.Date(args[3]) else as.Date("2024-01-01")
seed            <- if (length(args) >= 4) as.integer(args[4]) else 42L
# Initial site stocking. Opt-in: absent, sites start from
# datasets/site_inventory.csv exactly as before. Given, every site is stocked
# for this many patients through their first visits and the shipment lands
# before the site's first patient walks in (R/seeding.R).
seed_patients   <- if (length(args) >= 5) as.integer(args[5]) else NA_integer_

# The seed is an ARGUMENT, not a constant. A seed pinned inside the runner
# makes every replication identical, which destroys the between-replication
# variance any experiment over this engine depends on.
set.seed(seed)

# ---- load inputs ---------------------------------------------------------- #
inputs_xlsx <- file.path(root, "Program_Inputs.xlsx")
if (file.exists(inputs_xlsx)) {
  enrollment <- read_excel(inputs_xlsx, sheet = "Enrollment_Input")
  dosing     <- read_excel(inputs_xlsx, sheet = "Dosing_Input")
} else {
  enrollment <- read_csv(file.path(root, "datasets/enrollment_input.csv"), show_col_types = FALSE)
  dosing     <- read_csv(file.path(root, "datasets/dosing_input.csv"), show_col_types = FALSE)
}

# Optional: CSP-defined dose-titration ladders. Absent => every arm is fixed
# dose at rung 1, exactly as before titration existed.
titration_csv <- file.path(root, "datasets/titration_input.csv")
titration <- if (file.exists(titration_csv)) read_titration(titration_csv) else NULL
site_inv  <- read_csv(file.path(root, "datasets/site_inventory.csv"),  show_col_types = FALSE)
depot_inv <- read_csv(file.path(root, "datasets/depot_inventory.csv"), show_col_types = FALSE)

enrollment <- normalize_df(enrollment)
# The WIDE sheet is what carries the dose rungs (Option1..OptionN). Expanding
# it here would collapse them to one quantity and throw the ladder away, so
# simulate_visits() is handed the wide sheet and expands it itself.

protocols <- sort(unique(trimws(as.character(enrollment$Protocol))))
cat(sprintf("Protocols: %s\n", paste(protocols, collapse = ", ")))
cat(sprintf("Simulations/trials: %d   Horizon: %s   Seed: %d\n", num_simulations, sim_end_date, seed))
cat(sprintf("Titrating arms: %d\n", if (is.null(titration)) 0L else nrow(titration)))
cat(sprintf("Site seeding: %s\n\n",
            if (is.na(seed_patients)) "off (using datasets/site_inventory.csv)"
            else sprintf("%d patients/site", seed_patients)))

# ---- DEMAND: enrollment -> visits (all protocols together) ---------------- #
cat("Simulating enrollment ...\n")
enroll <- simulate_enrollment(enrollment, num_simulations = num_simulations)
cat(sprintf("  %d enrollment records across %d trials\n",
            nrow(enroll), num_simulations))

cat("Simulating visits / dispensing ...\n")
visits <- simulate_visits(enroll, dosing,          # WIDE sheet: keeps the rungs
                          visit_window = 3, simulation_end_date = sim_end_date,
                          titration = titration)
visits <- add_date_windows(visits)
cat(sprintf("  %d dispensing visit records\n", nrow(visits)))

demand <- compute_demand(visits)
cat(sprintf("  %d site/DU/day demand points; %s total units (all trials)\n\n",
            nrow(demand), format(round(sum(demand$Units)), big.mark = ",")))

# ---- SUPPLY: project inventory across all sites --------------------------- #
# ---- SEED: stock each site before its first patient visit ----------------- #
initial_receipts <- NULL
if (!is.na(seed_patients)) {
  ladders <- build_ladders(dosing, titration)
  initial_receipts <- seed_sites(enrollment, ladders,
                                 list(Seed_Patients = seed_patients))
  cat(sprintf("Seeding %d shipments across %d sites (%s units) ...\n",
              nrow(initial_receipts), length(unique(initial_receipts$Site)),
              format(sum(initial_receipts$Qty), big.mark = ",")))
  mix <- seed_mix_check(ladders)
  skew <- mix[abs(mix$Ratio - 1) > 0.25, , drop = FALSE]
  if (!is.null(skew) && nrow(skew)) {
    cat("  DUs whose startup mix differs from their study mix:\n")
    print(utils::head(skew[, c("Protocol", "Arm", "DU", "Seed_Share",
                               "Study_Share", "Ratio")], 8), row.names = FALSE)
  }
  cat("\n")
}

cat("Projecting inventory (FEFO + expiry + resupply) ...\n")
proj <- project_inventory(
  demand, site_inv, depot_inv,
  params = list(safety_stock_days = 30, target_days = 90,
                lead_time_days = 21, unplanned_visit_pct = 0.10,
                oversupply_pct = 0.10, start_date = as_of_date,
                horizon_end = sim_end_date),
  initial_receipts = initial_receipts)

port <- portfolio_summary(proj)

# ---- write outputs -------------------------------------------------------- #
outdir <- file.path(root, "output"); dir.create(outdir, showWarnings = FALSE)
write_csv(visits,        file.path(outdir, "simulated_visits.csv"))
write_csv(proj$daily,    file.path(outdir, "inventory_daily.csv"))
write_csv(proj$summary,  file.path(outdir, "inventory_summary.csv"))
if (!is.null(port$by_study))
  write_csv(port$by_study, file.path(outdir, "portfolio_by_study.csv"))

# ---- console report ------------------------------------------------------- #
cat("\n================ PORTFOLIO ================\n")
print(as.data.frame(port$overall))
cat("\n---- By study ----\n")
print(as.data.frame(port$by_study))
cat("\n---- Sites needing attention (STOCKOUT / AT RISK) ----\n")
attn <- proj$summary %>% filter(Status != "OK") %>%
  select(Protocol, Site, DU, Status, Start_On_Hand, Min_Days_Supply, First_Stockout)
if (nrow(attn)) print(as.data.frame(attn), row.names = FALSE) else cat("  none\n")

cat(sprintf("\nOutputs written to %s\n", outdir))
