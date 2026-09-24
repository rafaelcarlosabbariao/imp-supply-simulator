#!/usr/bin/env Rscript
# =========================================================================== #
# confirmatory_analysis.R  --  the estimation EXPERIMENT.md §9 pre-specifies
#
#   Rscript scripts/confirmatory_analysis.R [rundir] [frame.csv]
#
# Reads the per-replication files confirmatory_run.R wrote and reports, in this
# order: the primary stratified estimate with its t interval; the unstratified
# estimate; the donor-clustered standard error; the interval check; the
# secondary outcomes; the oracle ceiling; the P_Miss sensitivity; covariates by
# stratum. Nothing here is chosen after looking: every quantity is named in §7-§9.
# =========================================================================== #

suppressPackageStartupMessages({ library(dplyr); library(tidyr) })
root <- normalizePath(file.path(dirname(sub("--file=", "",
          grep("--file=", commandArgs(FALSE), value = TRUE))[1]), ".."))
args  <- commandArgs(trailingOnly = TRUE)
RUN   <- if (length(args) >= 1) args[1] else file.path(root, "output/experiment/confirmatory")
FRAME <- if (length(args) >= 2) args[2] else file.path(root, "datasets/frame_expanded/frame.csv")

files <- list.files(RUN, pattern = "^rep_\\d+\\.csv$", full.names = TRUE)
stopifnot(length(files) > 0)
x <- bind_rows(lapply(files, read.csv, stringsAsFactors = FALSE))
x$titrates <- as.logical(x$titrates)
R <- length(unique(x$rep_seed))
cat(sprintf("%d replications, %d protocols, engine %s\n\n", R, length(unique(x$Protocol)),
            paste(unique(substr(x$engine, 1, 7)), collapse = ",")))

# Per protocol: the mean over replications of treatment - control.
diffs <- function(treat, outcome = "P_Stockout") {
  x %>% filter(forecast %in% c("trailing", treat)) %>%
    select(rep_seed, Protocol, donor, titrates, forecast, y = all_of(outcome)) %>%
    pivot_wider(names_from = forecast, values_from = y) %>%
    filter(!is.na(.data[[treat]])) %>%
    mutate(d = .data[[treat]] - trailing) %>%
    group_by(Protocol, donor, titrates) %>%
    summarise(d = mean(d), .groups = "drop")
}

# Stratified mean: stratum means weighted by the stratum's share of protocols.
strat <- function(dp) {
  n <- nrow(dp)
  h <- dp %>% group_by(titrates) %>%
    summarise(n_h = n(), m_h = mean(d), v_h = var(d), .groups = "drop") %>%
    mutate(w_h = n_h / n)
  est <- sum(h$w_h * h$m_h)
  se  <- sqrt(sum(h$w_h^2 * h$v_h / h$n_h))
  df  <- n - 2
  # Donor-clustered SE of the same weighted mean.
  dp <- dp %>% left_join(h, by = "titrates") %>% mutate(w = w_h / n_h, e = w * (d - m_h))
  g  <- dp %>% group_by(donor) %>% summarise(s = sum(e), .groups = "drop")
  G  <- nrow(g)
  se_cl <- sqrt(G / (G - 1) * sum(g$s^2))
  list(est = est, se = se, df = df, lo = est - qt(.975, df) * se,
       hi = est + qt(.975, df) * se, p = 2 * pt(-abs(est / se), df),
       se_cl = se_cl, strata = h)
}
fmt <- function(v, k = 4) formatC(v, format = "f", digits = k)

cat("== Primary: stockout proportion, rung - trailing (§9) ==\n")
dp <- diffs("rung"); s <- strat(dp)
cat(sprintf("  stratified estimate  %s   95%% CI [%s, %s]   t(%d), p = %s\n",
            fmt(s$est), fmt(s$lo), fmt(s$hi), s$df, format.pval(s$p, digits = 3)))
print(as.data.frame(s$strata %>% transmute(titrating = titrates, protocols = n_h,
                                           mean_d = fmt(m_h), sd_d = fmt(sqrt(v_h)))),
      row.names = FALSE)
un <- mean(dp$d); un_se <- sd(dp$d) / sqrt(nrow(dp))
cat(sprintf("  unstratified         %s   SE %s\n", fmt(un), fmt(un_se)))
ratio <- s$se_cl / s$se
cat(sprintf("  SE %s; clustered on donor (%d clusters) %s; ratio %.2f%s\n",
            fmt(s$se), length(unique(dp$donor)), fmt(s$se_cl), ratio,
            if (abs(ratio - 1) > 0.25) "  -> both stated in the headline (§9)" else ""))
cat(sprintf("  clustered 95%% CI    [%s, %s]\n\n",
            fmt(s$est - qt(.975, length(unique(dp$donor)) - 1) * s$se_cl),
            fmt(s$est + qt(.975, length(unique(dp$donor)) - 1) * s$se_cl)))

cat("== Interval check: 2,000 stratified half-subsamples (§9) ==\n")
set.seed(20260924L)
# Each half is drawn without replacement from the frame, so its interval uses
# the finite-population correction sqrt(1 - 1/2); without it the check covers
# about 99% by construction (EXPERIMENT.md §9, note of 2026-09-24).
cover <- replicate(2000, {
  sub <- dp %>% group_by(titrates) %>% slice_sample(prop = 0.5) %>% ungroup()
  k <- strat(sub); h <- qt(.975, k$df) * k$se * sqrt(0.5)
  k$est - h <= s$est && s$est <= k$est + h
})
cat(sprintf("  share of intervals covering the full-frame estimate: %.3f%s\n\n", mean(cover),
            if (mean(cover) < 0.92 || mean(cover) > 0.98)
              "  -> outside 92-98%: not reported as a 95% confidence interval" else ""))

cat("== Secondary outcomes (§7) ==\n")
for (o in c("Stockout_Units", "Expired", "Reorders")) {
  k <- strat(diffs("rung", o))
  cat(sprintf("  %-15s mean difference per protocol %s (SE %s)\n", o, fmt(k$est, 1), fmt(k$se, 1)))
}
tot <- x %>% filter(forecast %in% c("trailing", "rung")) %>% group_by(forecast, rep_seed) %>%
  summarise(so = sum(Stockout_Units), ex = sum(Expired), ro = sum(Reorders), .groups = "drop") %>%
  group_by(forecast) %>% summarise(across(c(so, ex, ro), mean))
cat("  totals per replication:\n"); print(as.data.frame(tot), row.names = FALSE)
q90 <- x %>% filter(forecast %in% c("trailing", "rung")) %>% group_by(Protocol, forecast) %>%
  summarise(u = mean(Stockout_Units), .groups = "drop") %>% group_by(forecast) %>%
  summarise(p90 = quantile(u, 0.9))
cat(sprintf("  90th percentile of protocol stockout units: trailing %.1f, rung %.1f\n\n",
            q90$p90[q90$forecast == "trailing"], q90$p90[q90$forecast == "rung"]))

cat("== Oracle ceiling, replications with the extra walks (§4) ==\n")
print(as.data.frame(x %>% filter(forecast %in% c("trailing", "rung", "oracle"),
                                 rep_seed %in% unique(rep_seed[forecast == "oracle"])) %>%
  group_by(forecast, titrates) %>% summarise(P_Stockout = fmt(mean(P_Stockout)), .groups = "drop")),
  row.names = FALSE)

cat("\n== Sensitivity: the rung forecast with P_Miss misstated (§7) ==\n")
for (tr in c("rung_pmiss_half", "rung_pmiss_double")) {
  if (!any(x$forecast == tr)) next
  k <- strat(diffs(tr))
  cat(sprintf("  %-18s stratified estimate %s (SE %s)\n", tr, fmt(k$est), fmt(k$se)))
}

cat("\n== Covariates by stratum (§6) ==\n")
fr <- read.csv(FRAME, stringsAsFactors = FALSE)
en <- read.csv(file.path(dirname(FRAME), "enrollment_input.csv"), stringsAsFactors = FALSE)
ti <- read.csv(file.path(dirname(FRAME), "titration_input.csv"), stringsAsFactors = FALSE)
cov <- fr %>% left_join(en %>% group_by(protocol_id = Protocol) %>%
                          summarise(patients = sum(Patients), .groups = "drop"), by = "protocol_id") %>%
  left_join(ti %>% select(protocol_id = Protocol, P_Miss, Tolerance_Level), by = "protocol_id")
print(as.data.frame(cov %>% group_by(titrating = titrates) %>%
  summarise(protocols = n(), synthetic = sum(synthetic), sites = round(mean(sites_count)),
            patients = round(mean(patients)), cycle_len = round(mean(cycle_len), 1),
            P_Miss = round(mean(P_Miss), 3), Tolerance = round(mean(Tolerance_Level), 2),
            .groups = "drop")), row.names = FALSE)
