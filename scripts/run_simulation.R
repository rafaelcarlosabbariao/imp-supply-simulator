#!/usr/bin/env Rscript
# =========================================================================== #
# run_simulation.R  --  Headless end-to-end run of the demand + supply model
#
# Runs the full pipeline for EVERY protocol found in the inputs, with no Shiny
# UI required, and writes results to output/. Handy for batch/portfolio runs and
# for verifying the engine independently of the app.
#
#   Rscript scripts/run_simulation.R [num_simulations] [sim_end_date YYYY-MM-DD]
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

source(file.path(engine, "simulation.R"))
source(file.path(engine, "inventory.R"))

args <- commandArgs(trailingOnly = TRUE)
num_simulations <- if (length(args) >= 1) as.integer(args[1]) else 5L
sim_end_date    <- if (length(args) >= 2) as.Date(args[2]) else as.Date("2026-12-31")
# planning "as-of" date: on-hand inventory in the sample data is current as of
# 2024-01-01, so project forward from there.
as_of_date      <- if (length(args) >= 3) as.Date(args[3]) else as.Date("2024-01-01")

set.seed(42)  # reproducible demo run

# ---- load inputs ---------------------------------------------------------- #
inputs_xlsx <- file.path(root, "Program_Inputs.xlsx")
if (file.exists(inputs_xlsx)) {
  enrollment <- read_excel(inputs_xlsx, sheet = "Enrollment_Input")
  dosing     <- read_excel(inputs_xlsx, sheet = "Dosing_Input")
} else {
  enrollment <- read_csv(file.path(root, "datasets/enrollment_input.csv"), show_col_types = FALSE)
  dosing     <- read_csv(file.path(root, "datasets/dosing_input.csv"), show_col_types = FALSE)
}
site_inv  <- read_csv(file.path(root, "datasets/site_inventory.csv"),  show_col_types = FALSE)
depot_inv <- read_csv(file.path(root, "datasets/depot_inventory.csv"), show_col_types = FALSE)

enrollment <- normalize_df(enrollment)
dosing_long <- expand_dosing(dosing)

protocols <- sort(unique(trimws(as.character(enrollment$Protocol))))
cat(sprintf("Protocols: %s\n", paste(protocols, collapse = ", ")))
cat(sprintf("Simulations/trials: %d   Horizon: %s\n\n", num_simulations, sim_end_date))

# ---- DEMAND: enrollment -> visits (all protocols together) ---------------- #
cat("Simulating enrollment ...\n")
enroll <- simulate_enrollment(enrollment, num_simulations = num_simulations)
cat(sprintf("  %d enrollment records across %d trials\n",
            nrow(enroll), num_simulations))

cat("Simulating visits / dispensing ...\n")
visits <- simulate_visits(enroll, dosing_long,
                          visit_window = 3, simulation_end_date = sim_end_date)
visits <- add_date_windows(visits)
cat(sprintf("  %d dispensing visit records\n", nrow(visits)))

demand <- compute_demand(visits)
cat(sprintf("  %d site/DU/day demand points; %s total units (all trials)\n\n",
            nrow(demand), format(round(sum(demand$Units)), big.mark = ",")))

# ---- SUPPLY: project inventory across all sites --------------------------- #
cat("Projecting inventory (FEFO + expiry + resupply) ...\n")
proj <- project_inventory(
  demand, site_inv, depot_inv,
  params = list(safety_stock_days = 30, target_days = 90,
                lead_time_days = 21, unplanned_visit_pct = 0.10,
                oversupply_pct = 0.10, start_date = as_of_date,
                horizon_end = sim_end_date))

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
