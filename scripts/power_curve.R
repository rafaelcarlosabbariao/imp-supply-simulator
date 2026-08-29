#!/usr/bin/env Rscript
# =========================================================================== #
# power_curve.R  --  the calculation EXPERIMENT.md §8 commits to
#
#   Rscript scripts/power_curve.R [pilot.csv]
#
# WHICH VARIANCE GOVERNS. In a simulation experiment you can always buy
# precision with more replications, so "power" needs saying carefully. There
# are two different questions and only one of them is science:
#
#   1. How tightly can the effect be estimated FOR THIS FRAME? Replications
#      answer that, and 500 of them make it arbitrarily tight. Not interesting.
#   2. Does the effect hold across PROTOCOLS drawn from this population? That
#      is limited by the number of protocols, and no number of replications
#      fixes it.
#
# (2) is the estimand. Protocol is the random effect, so
#
#     Var(mean_T - mean_C) = 4 * (sigma2_between + sigma2_within / R) / n
#
# and with R = 500 the second term is negligible: power is governed by
# sigma_between and n, and replications cannot rescue it. That is what makes
# the §8 contingency -- expand the frame if power falls short -- the only lever
# that actually moves the number.
#
# CONSERVATIVE BY CONSTRUCTION. This ignores the variance reduction from common
# random numbers (§6), because the pairing correlation cannot be measured until
# the treatment arm exists. CRN can only help, so every figure here is a LOWER
# BOUND on the power the confirmatory run will have.
# =========================================================================== #

suppressPackageStartupMessages({ library(dplyr) })
root <- normalizePath(file.path(dirname(sub("--file=", "",
          grep("--file=", commandArgs(FALSE), value = TRUE))[1]), ".."))
args  <- commandArgs(trailingOnly = TRUE)
PILOT <- if (length(args) >= 1) args[1] else file.path(root, "output/experiment/pilot.csv")

R_CONF <- 500L      # replications the confirmatory run is committed to (§8)
ALPHA  <- 0.05      # two-sided (§8)
MDE    <- 0.05      # pre-specified 5pp absolute reduction (§8)
TARGET <- 0.80      # pre-specified power (§8)

pilot <- read.csv(PILOT, stringsAsFactors = FALSE)
n_prot <- length(unique(pilot$Protocol))
n_rep  <- length(unique(pilot$rep_seed))
cat(sprintf("pilot: %d protocols x %d replications = %d rows\n\n",
            n_prot, n_rep, nrow(pilot)))

# ---- variance decomposition ----------------------------------------------- #
by_prot <- pilot %>%
  group_by(Protocol, titrates) %>%
  summarise(mean_p = mean(P_Stockout), var_within = var(P_Stockout),
            .groups = "drop")

s2_within  <- mean(by_prot$var_within, na.rm = TRUE)
s2_between <- var(by_prot$mean_p)
# Blocking on titration status removes that main effect from the between-
# protocol variance; what is left is what a blocked design actually faces.
s2_blocked <- by_prot %>% group_by(titrates) %>%
  summarise(v = var(mean_p), n = n(), .groups = "drop") %>%
  summarise(v = sum(v * (n - 1)) / sum(n - 1)) %>% pull(v)

cat("outcome: proportion of a protocol's site x DU units that stock out\n")
cat(sprintf("  grand mean                       %.4f\n", mean(by_prot$mean_p)))
cat(sprintf("  between-protocol SD              %.4f\n", sqrt(s2_between)))
cat(sprintf("  between-protocol SD, blocked     %.4f  (titration main effect removed)\n",
            sqrt(s2_blocked)))
cat(sprintf("  within-protocol SD (per rep)     %.4f\n", sqrt(s2_within)))
cat(sprintf("  within-protocol SD over R=%d    %.5f  <- vanishes; not the constraint\n\n",
            R_CONF, sqrt(s2_within / R_CONF)))

cat("by titration status:\n")
# NB: compute the SD before collapsing the column it reads. dplyr evaluates
# summarise() arguments in order, so `mean_p = mean(mean_p)` first would leave
# `sd(mean_p)` taking the SD of a scalar -- silently NA, not an error.
print(as.data.frame(by_prot %>% group_by(titrates) %>%
        summarise(protocols = n(),
                  sd_p   = round(sd(mean_p), 4),
                  lo     = round(min(mean_p), 4),
                  hi     = round(max(mean_p), 4),
                  mean_p = round(mean(mean_p), 4), .groups = "drop")),
      row.names = FALSE)
cat("\n")

# ---- power ----------------------------------------------------------------- #
# Two-sided t test on protocol-level means, n/2 per arm, df = n-2.
power_at <- function(n, delta, s2) {
  if (n < 4) return(NA_real_)
  se <- sqrt(4 * (s2 + s2_within / R_CONF) / n)
  df <- n - 2
  tc <- qt(1 - ALPHA / 2, df)
  ncp <- delta / se
  pt(-tc, df, ncp) + (1 - pt(tc, df, ncp))
}

grid <- expand.grid(n = seq(6, 120, by = 2),
                    delta = seq(0.01, 0.20, by = 0.005)) %>%
  mutate(power_unblocked = mapply(power_at, n, delta, MoreArgs = list(s2 = s2_between)),
         power_blocked   = mapply(power_at, n, delta, MoreArgs = list(s2 = s2_blocked)))

outdir <- file.path(root, "output/experiment")
dir.create(outdir, showWarnings = FALSE, recursive = TRUE)
write.csv(grid, file.path(outdir, "power_curve.csv"), row.names = FALSE)

# ---- the answers §8 asks for ----------------------------------------------- #
p18_u <- power_at(n_prot, MDE, s2_between)
p18_b <- power_at(n_prot, MDE, s2_blocked)
need  <- function(s2) {
  for (n in seq(6, 2000, by = 2)) if (!is.na(power_at(n, MDE, s2)) &&
      power_at(n, MDE, s2) >= TARGET) return(n)
  NA_integer_
}
n_u <- need(s2_between); n_b <- need(s2_blocked)

cat(sprintf("PRE-SPECIFIED MDE: %.0fpp absolute reduction, %.0f%% power, alpha %.2f two-sided\n\n",
            MDE * 100, TARGET * 100, ALPHA))
cat(sprintf("  power at the frame's %d protocols, unblocked   %.3f\n", n_prot, p18_u))
cat(sprintf("  power at the frame's %d protocols, blocked     %.3f\n", n_prot, p18_b))
cat(sprintf("  protocols needed for %.0f%% power, unblocked    %s\n", TARGET * 100,
            ifelse(is.na(n_u), ">2000", n_u)))
cat(sprintf("  protocols needed for %.0f%% power, blocked      %s\n\n", TARGET * 100,
            ifelse(is.na(n_b), ">2000", n_b)))

# Detectable effect at the frame we have.
mde_at <- function(n, s2) {
  for (d in seq(0.005, 0.60, by = 0.005))
    if (!is.na(power_at(n, d, s2)) && power_at(n, d, s2) >= TARGET) return(d)
  NA_real_
}
cat(sprintf("  smallest effect detectable at %d protocols, blocked: %.1fpp\n",
            n_prot, 100 * mde_at(n_prot, s2_blocked)))

verdict <- if (!is.na(p18_b) && p18_b >= TARGET) "MET" else "NOT MET"
cat(sprintf("\nVERDICT: %s at the pre-specified 5pp MDE.\n", verdict))
if (verdict == "NOT MET")
  cat(sprintf("  §8's contingency triggers: expand the frame to ~%s protocols,\n  or restate the MDE at %.1fpp, and record which was chosen.\n",
              ifelse(is.na(n_b), ">2000", n_b), 100 * mde_at(n_prot, s2_blocked)))

# ---- chart ----------------------------------------------------------------- #
ok <- requireNamespace("ggplot2", quietly = TRUE)
if (ok) {
  library(ggplot2)
  CREAM <- "#F2EEE4"; INK <- "#1A1813"; RULE <- "#CBC3B0"
  IND <- "#2F4C9B"; VERD <- "#17805C"; MAD <- "#BC4A2E"
  d <- grid %>% filter(n <= 120) %>%
    tidyr::pivot_longer(c(power_unblocked, power_blocked),
                        names_to = "design", values_to = "power") %>%
    filter(delta %in% c(0.03, 0.05, 0.10), design == "power_blocked") %>%
    mutate(delta = factor(sprintf("%.0fpp effect", delta * 100),
                          levels = c("3pp effect", "5pp effect", "10pp effect")))
  p <- ggplot(d, aes(n, power, colour = delta)) +
    geom_hline(yintercept = TARGET, colour = RULE, linewidth = .5, linetype = "22") +
    geom_vline(xintercept = n_prot, colour = RULE, linewidth = .5, linetype = "22") +
    geom_line(linewidth = .9) +
    annotate("text", x = n_prot + 2, y = .04, label = sprintf("frame = %d", n_prot),
             hjust = 0, size = 3.1, colour = INK) +
    annotate("text", x = 118, y = TARGET + .03, label = "80%", hjust = 1,
             size = 3.1, colour = INK) +
    scale_colour_manual(values = c(IND, VERD, MAD), name = NULL) +
    scale_y_continuous(labels = scales::percent, limits = c(0, 1)) +
    labs(title = "Power is governed by protocols, not replications",
         subtitle = sprintf("Blocked design, %d replications, alpha 0.05 two-sided. Lower bound: no credit for common random numbers.", R_CONF),
         x = "protocols randomised", y = "power") +
    theme_minimal(base_size = 11) +
    theme(plot.background = element_rect(fill = CREAM, colour = NA),
          panel.background = element_rect(fill = CREAM, colour = NA),
          panel.grid.minor = element_blank(),
          panel.grid.major = element_line(colour = RULE, linewidth = .25),
          text = element_text(colour = INK), axis.text = element_text(colour = INK),
          plot.title = element_text(face = "bold", size = 12),
          plot.subtitle = element_text(size = 8.5, colour = INK),
          legend.position = "top")
  dir.create(file.path(root, "docs/assets"), showWarnings = FALSE, recursive = TRUE)
  ggsave(file.path(root, "docs/assets/power_curve.png"), p,
         width = 7.2, height = 4.4, dpi = 150, bg = CREAM)
  cat("\nchart -> docs/assets/power_curve.png\n")
}
cat(sprintf("curve -> %s\n", file.path(outdir, "power_curve.csv")))
