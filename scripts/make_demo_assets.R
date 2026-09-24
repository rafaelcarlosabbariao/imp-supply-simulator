#!/usr/bin/env Rscript
# Generate the demo images and the showcase's interactive map (site/map.html) from
# the real engine output, styled with the MC² tokens in R/brand.R.
# Usage: Rscript scripts/make_demo_assets.R
suppressPackageStartupMessages({
  library(dplyr); library(ggplot2); library(readxl); library(maps)
})
root <- normalizePath(file.path(dirname(sub("--file=", "",
          grep("--file=", commandArgs(FALSE), value = TRUE))[1]), ".."))
source(file.path(root, "R/titration.R"))
source(file.path(root, "R/simulation.R"))
source(file.path(root, "R/forecast.R"))
source(file.path(root, "R/inventory.R"))
source(file.path(root, "R/seeding.R"))
source(file.path(root, "R/brand.R"))
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

theme_set(theme_mc2(base_size = 13))

# 1. demand by DU over time
p1 <- v %>% filter(!is.na(DU_Desc)) %>%
  group_by(DU_Desc, Visit_Date_YrMo) %>% summarise(Units = sum(Qty), .groups = "drop") %>%
  ggplot(aes(Visit_Date_YrMo, Units, group = DU_Desc, color = DU_Desc)) +
  geom_line(linewidth = 0.8) +
  scale_colour_mc2() +
  scale_x_every(3) +
  labs(title = "Simulated IMP demand", subtitle = "Units dispensed per month, by dispensing unit",
       x = NULL, y = "Units") +
  theme(axis.text.x = element_text(angle = 45, hjust = 1)) +
  guides(color = guide_legend(ncol = 2))
ggsave(file.path(out, "demo_demand.png"), p1, width = 9, height = 4.6, dpi = 130)

# 2. inventory saw-tooth for one site (all sites on one axis join into a solid fill)
st <- pr$daily %>% filter(Protocol == "TRIAL-118", trimws(as.character(Site)) == "1001") %>%
  mutate(Date = as.Date(Date))
p2 <- ggplot(st, aes(Date, On_Hand_End, color = DU)) +
  geom_line(linewidth = 0.6) +
  geom_point(data = st %>% filter(Stockout_Units > 1e-9), color = STATUS_FILL[["STOCKOUT"]], size = 1) +
  scale_colour_mc2() +
  labs(title = "Projected on-hand inventory, TRIAL-118 site 1001",
       subtitle = "Order-up-to resupply with FEFO and expiry; red points are stockout days",
       x = NULL, y = "Units on hand") +
  guides(color = guide_legend(ncol = 2))
ggsave(file.path(out, "demo_inventory.png"), p2, width = 9, height = 4.6, dpi = 130)

# 3. world map of site status
d <- site_status_frame(pr$summary, loc)
d$Status <- factor(d$Status, levels = STATUS_LEVELS)
d <- d[order(d$Status, decreasing = TRUE), ]   # worst drawn last, on top
world <- map_data("world")
p3 <- ggplot() +
  geom_polygon(data = world, aes(long, lat, group = group),
               fill = MC2$surface_muted, color = MC2$separator, linewidth = 0.2) +
  geom_point(data = d, aes(longitude, latitude, color = Status), size = 4.2) +
  geom_point(data = d, aes(longitude, latitude), shape = 21, size = 4.2,
             colour = MC2$surface, stroke = .8, fill = NA) +
  scale_color_manual(values = STATUS_FILL, drop = FALSE) +
  coord_fixed(1.3, xlim = c(-130, 150), ylim = c(-45, 62)) +
  labs(title = "Clinical site IMP status", subtitle = "One marker per site; colour is the worst status across its DUs") +
  theme_void(base_size = 13) +
  theme(legend.position = "bottom", legend.title = element_blank(),
        legend.text = element_text(colour = MC2$text),
        plot.title = element_text(face = "bold", colour = MC2$ink),
        plot.subtitle = element_text(colour = MC2$muted),
        plot.background = element_rect(fill = MC2$surface, colour = NA))
ggsave(file.path(out, "demo_map.png"), p3, width = 9, height = 5.2, dpi = 130)

# 4. the showcase's interactive map, built by the same function as the app's tab 5
m <- d[!is.na(d$latitude) & !is.na(d$longitude), , drop = FALSE]
m$id <- paste(m$Protocol, m$Site, sep = "|")
m$hover <- site_status_hover(m)
widget <- plotly::config(site_status_map(m, source = "showcase"), displaylogo = FALSE)
htmlwidgets::saveWidget(widget, file.path(root, "site/map.html"), selfcontained = TRUE,
                        title = "MC² · site IMP status", background = MC2$surface)
unlink(file.path(root, "site/map_files"), recursive = TRUE)

# The showcase serves its own copies of the images
site_assets <- file.path(root, "site/assets")
invisible(file.copy(file.path(out, c("demo_demand.png", "demo_inventory.png", "demo_map.png")),
          site_assets, overwrite = TRUE))

cat("wrote demo_demand.png, demo_inventory.png, demo_map.png to", out, "and site/assets; site/map.html\n")
cat(sprintf("showcase stats: %d studies, %d sites, %s\n", length(unique(m$Protocol)), nrow(m),
            paste(names(table(m$Status)), table(m$Status), collapse = ", ")))
