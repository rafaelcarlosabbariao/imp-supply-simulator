#!/usr/bin/env Rscript
# Generate demo images for the README / site from the real engine output.
# Usage: Rscript scripts/make_demo_assets.R
suppressPackageStartupMessages({
  library(dplyr); library(ggplot2); library(readxl); library(maps)
})
root <- normalizePath(file.path(dirname(sub("--file=", "",
          grep("--file=", commandArgs(FALSE), value = TRUE))[1]), ".."))
source(file.path(root, "R/simulation.R"))
source(file.path(root, "R/inventory.R"))
out <- file.path(root, "docs/assets"); dir.create(out, showWarnings = FALSE)
set.seed(42)

enr <- read_excel(file.path(root, "Program_Inputs.xlsx"), sheet = "Enrollment_Input")
dos <- expand_dosing(read_excel(file.path(root, "Program_Inputs.xlsx"), sheet = "Dosing_Input"))
si  <- read.csv(file.path(root, "datasets/site_inventory.csv"))
di  <- read.csv(file.path(root, "datasets/depot_inventory.csv"))
loc <- read.csv(file.path(root, "datasets/site_locations.csv"))

e <- simulate_enrollment(enr, 5)
v <- add_date_windows(simulate_visits(e, dos, 3, as.Date("2026-12-31")))
dem <- compute_demand(v)
pr <- project_inventory(dem, si, di, list(start_date = as.Date("2024-01-01"),
                                          horizon_end = as.Date("2026-12-31")))

theme_set(theme_minimal(base_size = 13))
STATUS <- c("STOCKOUT" = "#B00020", "AT RISK" = "#E08A00", "OK" = "#2E7D32")

# 1. demand by DU over time
p1 <- v %>% filter(!is.na(DU_Desc)) %>%
  group_by(DU_Desc, Visit_Date_YrMo) %>% summarise(Units = sum(Qty), .groups = "drop") %>%
  ggplot(aes(Visit_Date_YrMo, Units, group = DU_Desc, color = DU_Desc)) +
  geom_line(linewidth = 0.8) +
  labs(title = "Simulated IMP demand", subtitle = "Units dispensed per month, by dispensing unit",
       x = NULL, y = "Units") +
  theme(legend.position = "bottom", axis.text.x = element_text(angle = 45, hjust = 1)) +
  guides(color = guide_legend(ncol = 2, title = NULL))
ggsave(file.path(out, "demo_demand.png"), p1, width = 9, height = 4.6, dpi = 130)

# 2. inventory saw-tooth for one study
st <- pr$daily %>% filter(Protocol == "TRIAL-118") %>% mutate(Date = as.Date(Date))
p2 <- ggplot(st, aes(Date, On_Hand_End, color = DU)) +
  geom_line(linewidth = 0.6) +
  geom_point(data = st %>% filter(Stockout_Units > 1e-9), color = "#B00020", size = 0.8) +
  labs(title = "Projected on-hand inventory (TRIAL-118)",
       subtitle = "Order-up-to resupply with FEFO + expiry; red = stockout days",
       x = NULL, y = "Units on hand") +
  theme(legend.position = "bottom") + guides(color = guide_legend(ncol = 2, title = NULL))
ggsave(file.path(out, "demo_inventory.png"), p2, width = 9, height = 4.6, dpi = 130)

# 3. world map of site status
s <- pr$summary; s$Site <- trimws(as.character(s$Site))
loc$center <- trimws(as.character(loc$center)); loc$protocol <- trimws(as.character(loc$protocol))
agg <- s %>% group_by(Protocol, Site) %>% summarise(
  Status = ifelse(any(Status == "STOCKOUT"), "STOCKOUT",
           ifelse(any(Status == "AT RISK"), "AT RISK", "OK")), .groups = "drop")
d <- merge(agg, loc, by.x = c("Protocol", "Site"), by.y = c("protocol", "center"))
d$Status <- factor(d$Status, levels = names(STATUS))
world <- map_data("world")
p3 <- ggplot() +
  geom_polygon(data = world, aes(long, lat, group = group),
               fill = "#f2f2f2", color = "#dcdcdc", linewidth = 0.2) +
  geom_point(data = d, aes(longitude, latitude, color = Status), size = 4, alpha = 0.9) +
  scale_color_manual(values = STATUS) +
  coord_fixed(1.3, xlim = c(-130, 150), ylim = c(-45, 62)) +
  labs(title = "Clinical site IMP status", subtitle = "One marker per site; colour = worst status across its DUs") +
  theme_void(base_size = 13) + theme(legend.position = "bottom",
        plot.title = element_text(face = "bold"), plot.subtitle = element_text(color = "#5b6b7d"))
ggsave(file.path(out, "demo_map.png"), p3, width = 9, height = 5.2, dpi = 130)

cat("wrote demo_demand.png, demo_inventory.png, demo_map.png to", out, "\n")
