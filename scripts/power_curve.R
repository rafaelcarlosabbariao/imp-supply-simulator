#!/usr/bin/env Rscript
# =========================================================================== #
# power_curve.R  --  the calculation EXPERIMENT.md §8 commits to
#
#   Rscript scripts/power_curve.R [pilot.csv]
#
# THE DESIGN IS PAIRED. Every protocol runs under both arms on the same
# simulated demand, so each protocol yields a difference
#
#     d_p = P(stockout | rung) - P(stockout | trailing)
#
# and the estimand is the mean of d_p over protocols drawn from this
# population, stratified by titration status (§9). Two variances govern it:
#
#   sigma2_between  how much d_p varies across protocols within a stratum.
#                   Only more protocols reduce it.
#   sigma2_within   how much one replication's difference varies around the
#                   protocol's mean. R replications divide it by R.
#
#     Var(estimate) = (sigma2_between + sigma2_within / R) / n
#
# The script reports power at the frame's n, the n that reaches 80% for the
# pre-specified MDE, and the R that §8's rule picks: the smallest of 50, 100,
# 200, 500 at which sigma2_within / R is under 5% of the total.
# =========================================================================== #

suppressPackageStartupMessages({ library(dplyr) })
root <- normalizePath(file.path(dirname(sub("--file=", "",
          grep("--file=", commandArgs(FALSE), value = TRUE))[1]), ".."))
args  <- commandArgs(trailingOnly = TRUE)
PILOT <- if (length(args) >= 1) args[1] else file.path(root, "output/experiment/pilot.csv")

ALPHA  <- 0.05      # two-sided (§8)
MDE    <- 0.05      # pre-specified 5pp absolute reduction (§8)
TARGET <- 0.80      # pre-specified power (§8)
R_GRID <- c(50L, 100L, 200L, 500L)

pilot <- read.csv(PILOT, stringsAsFactors = FALSE)
pairs <- pilot %>%
  select(rep_seed, Protocol, titrates, forecast, P_Stockout) %>%
  tidyr::pivot_wider(names_from = forecast, values_from = P_Stockout) %>%
  mutate(d = rung - trailing)
n_prot <- length(unique(pairs$Protocol))
n_rep  <- length(unique(pairs$rep_seed))
cat(sprintf("pilot: %d protocols x %d replications, both arms\n\n", n_prot, n_rep))

by_prot <- pairs %>% group_by(Protocol, titrates) %>%
  summarise(d = mean(d), v_within = var(rung - trailing), .groups = "drop")
s2_within <- mean(by_prot$v_within, na.rm = TRUE)
strata <- by_prot %>% group_by(titrates) %>%
  summarise(n = n(), mean_d = mean(d), sd_d = sd(d), .groups = "drop")
s2_strat <- with(strata, sum((n - 1) * sd_d^2) / sum(n - 1))
s2_plain <- var(by_prot$d)

cat("outcome: within-protocol difference in the stockout proportion, rung - trailing\n")
cat(sprintf("  mean difference                          %.4f\n", mean(by_prot$d)))
cat(sprintf("  between-protocol SD                      %.4f\n", sqrt(s2_plain)))
cat(sprintf("  between-protocol SD, within strata       %.4f\n", sqrt(s2_strat)))
cat(sprintf("  within-protocol SD per replication       %.4f\n\n", sqrt(s2_within)))
print(as.data.frame(strata %>% mutate(across(c(mean_d, sd_d), ~ round(.x, 4)))),
      row.names = FALSE)
cat("\n")

# R: the smallest in the grid at which replication noise is under 5% of the
# variance of a protocol's mean difference.
share <- function(R) (s2_within / R) / (s2_strat + s2_within / R)
R_CONF <- R_GRID[which(vapply(R_GRID, share, numeric(1)) < 0.05)[1]]
if (is.na(R_CONF)) R_CONF <- max(R_GRID)
cat(sprintf("replications: R = %d (replication noise %.1f%% of the variance)\n\n",
            R_CONF, 100 * share(R_CONF)))

# Two-sided t test on the stratified mean of protocol differences, df = n - 2.
power_at <- function(n, delta, s2, R = R_CONF) {
  if (n < 4) return(NA_real_)
  se <- sqrt((s2 + s2_within / R) / n)
  df <- n - 2
  tc <- qt(1 - ALPHA / 2, df)
  pt(-tc, df, delta / se) + (1 - pt(tc, df, delta / se))
}
need <- function(s2) {
  for (n in 4:5000) if (power_at(n, MDE, s2) >= TARGET) return(n)
  NA_integer_
}
mde_at <- function(n, s2) {
  for (d in seq(0.005, 0.60, by = 0.005)) if (power_at(n, d, s2) >= TARGET) return(d)
  NA_real_
}

grid <- expand.grid(n = seq(6, 200, by = 2), delta = seq(0.01, 0.20, by = 0.005)) %>%
  mutate(power_unstratified = mapply(power_at, n, delta, MoreArgs = list(s2 = s2_plain)),
         power_stratified   = mapply(power_at, n, delta, MoreArgs = list(s2 = s2_strat)))
outdir <- file.path(root, "output/experiment")
dir.create(outdir, showWarnings = FALSE, recursive = TRUE)
write.csv(grid, file.path(outdir, "power_curve.csv"), row.names = FALSE)

p_s <- power_at(n_prot, MDE, s2_strat); p_u <- power_at(n_prot, MDE, s2_plain)
n_s <- need(s2_strat); n_u <- need(s2_plain)
cat(sprintf("PRE-SPECIFIED MDE: %.0fpp, %.0f%% power, alpha %.2f two-sided, R = %d\n\n",
            MDE * 100, TARGET * 100, ALPHA, R_CONF))
cat(sprintf("  power at the frame's %d protocols, stratified     %.3f\n", n_prot, p_s))
cat(sprintf("  power at the frame's %d protocols, unstratified   %.3f\n", n_prot, p_u))
cat(sprintf("  protocols needed for %.0f%% power, stratified      %s\n", TARGET * 100, n_s))
cat(sprintf("  protocols needed for %.0f%% power, unstratified    %s\n", TARGET * 100, n_u))
cat(sprintf("  smallest effect detectable at %d protocols, stratified: %.1fpp\n",
            n_prot, 100 * mde_at(n_prot, s2_strat)))
verdict <- if (p_s >= TARGET) "MET" else "NOT MET"
cat(sprintf("\nVERDICT: %s at the pre-specified 5pp MDE.\n", verdict))
if (verdict == "NOT MET")
  cat(sprintf("  §8's contingency: expand the frame to %d protocols (scripts/build_frame.R).\n", n_s))
cat(sprintf("EXPAND_TO=%s R_CONF=%d\n", if (verdict == "MET") n_prot else n_s, R_CONF))

# ---- chart ----------------------------------------------------------------- #
if (requireNamespace("ggplot2", quietly = TRUE)) {
  library(ggplot2)
  CREAM <- "#F2EEE4"; INK <- "#1A1813"; RULE <- "#CBC3B0"
  IND <- "#2F4C9B"; VERD <- "#17805C"; MAD <- "#BC4A2E"
  d <- grid %>% filter(round(delta, 3) %in% c(0.03, 0.05, 0.10)) %>%
    mutate(delta = factor(sprintf("%.0fpp effect", round(delta * 100)),
                          levels = c("3pp effect", "5pp effect", "10pp effect")))
  p <- ggplot(d, aes(n, power_stratified, colour = delta)) +
    geom_hline(yintercept = TARGET, colour = RULE, linewidth = .5, linetype = "22") +
    geom_vline(xintercept = n_prot, colour = RULE, linewidth = .5, linetype = "22") +
    geom_line(linewidth = .9) +
    annotate("text", x = n_prot + 2, y = .04, label = sprintf("frame = %d", n_prot),
             hjust = 0, size = 3.1, colour = INK) +
    annotate("text", x = 198, y = TARGET + .03, label = "80%", hjust = 1,
             size = 3.1, colour = INK) +
    scale_colour_manual(values = c(IND, VERD, MAD), name = NULL) +
    scale_y_continuous(labels = scales::percent, limits = c(0, 1)) +
    labs(title = "Power of the paired design by number of protocols",
         subtitle = sprintf("Both arms on every protocol, stratified by titration status, R = %d, alpha 0.05 two-sided.", R_CONF),
         x = "protocols", y = "power") +
    theme_minimal(base_size = 11) +
    theme(plot.background = element_rect(fill = CREAM, colour = NA),
          panel.background = element_rect(fill = CREAM, colour = NA),
          panel.grid.minor = element_blank(),
          panel.grid.major = element_line(colour = RULE, linewidth = .25),
          text = element_text(colour = INK), axis.text = element_text(colour = INK),
          plot.title = element_text(face = "bold", size = 12),
          plot.subtitle = element_text(size = 8.5, colour = INK),
          legend.position = "top")
  ggsave(file.path(root, "docs/assets/power_curve.png"), p,
         width = 7.2, height = 4.4, dpi = 150, bg = CREAM)
  cat("\nchart -> docs/assets/power_curve.png\n")
}
cat(sprintf("curve -> %s\n", file.path(outdir, "power_curve.csv")))
