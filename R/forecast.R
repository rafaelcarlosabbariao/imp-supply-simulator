# =========================================================================== #
# forecast.R  --  what the planner KNOWS when the order is placed
#
# The reorder rule in inventory.R was, until now, an oracle. Its rate came from
#
#     fwd(st$csum, ti, ti + lt + tg - 1)
#
# which sums the REALISED demand forward from today through lead time plus
# coverage. That is not a forecast, it is the answer. Orders sized off it track
# demand perfectly, nothing stocks out, and a titration ladder -- which
# reallocates demand across DUs and would wrong-foot any real planner -- costs
# nothing at all. Measured: a 0.18% stockout rate across 18 protocols, which is
# not a supply model, it is a supply model with the answers in the back.
#
# This file separates the two things that were conflated:
#
#   REALISED demand   drives dispensing. Reality.
#   FORECAST demand   drives ordering.   What the planner believed.
#
# Three modes, in increasing order of what the planner is assumed to know:
#
#   "oracle"    the old behaviour. Perfect foresight. Kept as a benchmark
#               CEILING -- the best any forecast could possibly do -- and never
#               as an experimental arm. Runs only when asked for by name.
#
#   "trailing"  a causal moving average of demand actually observed at this
#               site x DU up to today, projected flat, including what the site
#               dispensed before the as-of date. The classic MRP default and the
#               default here (since 2026-09-24): it uses nothing the planner
#               lacks.
#
#   "rung"      projects every patient enrolled at the site forward from
#               what an IRT system knows about them today: their dose rung,
#               their status (titrating, or stable past the titration window),
#               the ratchet, and their visit number. Each patient is propagated
#               through the CSP's own titration chain (.ladder_chain() in
#               R/titration.R), one step per scheduled visit, and stops at their
#               last cycle.
#
# The "rung" mode is the one the ladder makes possible. Demand for a dose is a
# headcount: the units needed at rung d next visit come from the patients at
# the rungs ADJACENT to d, d itself included:
#
#     E[N_d(t+1)] = N_{d-1}(t) * P(up)
#                 + N_d(t)     * P(stay)
#                 + N_{d+1}(t) * P(down)
#                 + (restart inflow from anyone who misses)
#
# for titrating patients, while a stable patient holds their dose unless they
# miss a visit or are demoted back to titrating (P_Revert). A trailing average
# cannot see a cohort about to step up together; a rung forecast can, because
# it counts people rather than smoothing units.
#
# The rung forecast knows only the patients already enrolled. A patient who
# enrolls tomorrow is in no forecast but the oracle's.
# =========================================================================== #

suppressPackageStartupMessages({ library(dplyr) })

FORECAST_MODES <- c("oracle", "trailing", "rung")

# --------------------------------------------------------------------------- #
# .forecast_window()
# Demand the planner EXPECTS over [from, to] (1-indexed days), given what mode
# says they know at day `ti`. Called from the reorder decision in inventory.R.
#
#   st    per-site state (demand vector, cumulative sum, rung occupancy)
#   ti    today
#   lt    lead time in days
#   tg    target coverage in days
#
# Returns list(rate, lead_demand, coverage_demand).
# --------------------------------------------------------------------------- #
.forecast_window <- function(mode, st, ti, nd, lt, tg, p) {
  fwd <- function(csum, a, b) {
    a <- max(1L, a); b <- min(nd, b)
    if (b < a) return(0)
    csum[b] - if (a > 1) csum[a - 1] else 0
  }

  if (mode == "oracle") {
    window_days <- max(1, min(nd - ti + 1, lt + tg))
    return(list(rate            = fwd(st$csum, ti, ti + lt + tg - 1) / window_days,
                lead_demand     = fwd(st$csum, ti, ti + lt - 1),
                coverage_demand = fwd(st$csum, ti + lt, ti + lt + tg - 1)))
  }

  if (mode == "trailing") {
    # STRICTLY CAUSAL: only days up to and including today. A site with no
    # history yet forecasts zero and orders nothing, which is correct -- that
    # is what the initial seed shipment is for, and it is exactly where a
    # titrating protocol is most exposed.
    # The window reaches back before the as-of date into `st$pre`, the days
    # this site was already dispensing, so a site open at the as-of date does
    # not start from zero.
    w      <- as.integer(p$trailing_window_days %||% 60L)
    n_pre  <- length(st$pre)
    from   <- max(1L - n_pre, ti - w + 1L)
    before <- if (from < 1L) sum(st$pre[(n_pre + from):n_pre]) else 0
    rate   <- (fwd(st$csum, max(1L, from), ti) + before) / (ti - from + 1L)
    return(list(rate            = rate,
                lead_demand     = rate * lt,
                coverage_demand = rate * tg))
  }

  if (mode == "rung") {
    # st$proj[t] holds the units the planner expects on day t from every patient
    # enrolled at the site as of today; the walk keeps it current (see
    # rung_events()). The windows are read straight off it.
    if (is.null(st$proj)) return(NULL)
    seg <- function(a, b) {
      a <- max(1L, a); b <- min(nd, b)
      if (b < a) 0 else max(0, sum(st$proj[a:b]))
    }
    lead <- seg(ti, ti + lt - 1L)
    cov  <- seg(ti + lt, ti + lt + tg - 1L)
    return(list(rate = (lead + cov) / max(1, lt + tg),
                lead_demand = lead, coverage_demand = cov))
  }

  stop(sprintf("unknown forecast mode: %s", mode), call. = FALSE)
}

`%||%` <- function(a, b) if (is.null(a)) b else a

# --------------------------------------------------------------------------- #
# rung_tables()
# For each arm: its chain, and U[[component]][s, k], the expected units of that
# component dispensed at the k-th visit after a visit the patient attended in
# state s. k = 1 steps through the chain given attendance (A); each later step
# through the full chain (P), missed visits included. U0[[component]][k] is the
# same from enrollment (visit 0), where every patient starts at rung 1,
# titrating, and nothing is dispensed.
# --------------------------------------------------------------------------- #
rung_tables <- function(ladders) {
  out <- list()
  for (lad in ladders) {
    ch <- .ladder_chain(lad)
    K  <- max(1L, lad$max_cycles)
    nk <- nrow(lad$components)
    em <- vapply(seq_len(nk), function(ck) ch$hold * lad$qty[ck, ch$rung],
                 numeric(ch$S))
    em <- matrix(em, ch$S, nk)
    U  <- replicate(nk, matrix(0, ch$S, K), simplify = FALSE)
    U0 <- replicate(nk, numeric(K), simplify = FALSE)
    D  <- ch$A
    d0 <- numeric(ch$S); d0[ch$id(1L, 0L, 0L)] <- 1
    for (k in seq_len(K)) {
      E <- D %*% em; E0 <- as.vector(d0 %*% em)
      for (ck in seq_len(nk)) { U[[ck]][, k] <- E[, ck]; U0[[ck]][k] <- E0[ck] }
      D  <- D %*% ch$P
      d0 <- as.vector(d0 %*% ch$P)
    }
    out[[paste(lad$protocol, lad$arm, sep = "\r")]] <- list(
      lad = lad, ch = ch, U = U, U0 = U0, du = lad$components$DU_Description,
      cycles = lad$components$Cycles)
  }
  out
}

# --------------------------------------------------------------------------- #
# rung_patient_visits()
# One row per attended patient visit (the visit stream has one row per
# dispensed component), carrying the status simulate_visits() records.
# Enrollment records (Visit_Num 0, from simulate_enrollment()) are kept when
# passed in with the visits: an enrolled patient is in the IRT database from
# visit 0, before their first dispense.
# --------------------------------------------------------------------------- #
rung_patient_visits <- function(visits_df) {
  need <- c("Dose_Status", "Titration_Visit", "Ratchet", "Rung")
  miss <- setdiff(need, names(visits_df))
  if (length(miss))
    stop(sprintf(paste0("The rung forecast reads each patient's dose status, and the visit ",
                        "stream has no %s column. Pass the output of simulate_visits()."),
                 paste(miss, collapse = ", ")), call. = FALSE)
  enr <- as.integer(visits_df$Visit_Num) == 0L & is.na(visits_df$Rung)
  v <- visits_df[enr | (!is.na(visits_df$Rung) & visits_df$Rung > 0),
                 c("Protocol", "Site", "Trial", "SSID", "TG", "Visit_Num", "Visit_Date",
                   "Rung", "Ratchet", "Titration_Visit", "Dose_Status")]
  v$TG <- trimws(as.character(v$TG))
  v <- v[!duplicated(v[c("Trial", "SSID", "Visit_Num")]), , drop = FALSE]
  v$Visit_Date <- as_date_flex(v$Visit_Date)
  v
}

# --------------------------------------------------------------------------- #
# rung_events()
# For one Protocol x DU: per site, the changes to the planner's projection on
# each day of the walk.
#
# A patient's attended visit on day a is what the planner knows about them
# until their next attended visit (day b + 1). While it stands, it projects
# units onto day a + k * cadence for each later visit k the patient still has,
# up to their last cycle. On day a those projections are added; on day b + 1
# they are replaced by the next visit's. The walk applies the day's changes and
# reads the lead-time and coverage windows off the running total.
#
#   pv      : rung_patient_visits() rows for this protocol
#   reach   : the longest window the planner will read (lead time + delays +
#             coverage), so a projection is built only as far as it is read
#   scale   : (1 + unplanned visit uplift) / number of simulated trials, the
#             same scaling the realised demand gets
#
# Returns list(site = list of length nd, each NULL or list(land, w)).
# --------------------------------------------------------------------------- #
rung_events <- function(pv, proto, du, tabs, start_date, nd, reach, scale) {
  if (is.null(pv) || nrow(pv) == 0) return(list())
  pv$a <- as.integer(pv$Visit_Date - start_date) + 1L
  pv <- pv[order(pv$Trial, pv$SSID, pv$a), , drop = FALSE]
  same <- c(pv$Trial[-1] == pv$Trial[-nrow(pv)] & pv$SSID[-1] == pv$SSID[-nrow(pv)], FALSE)
  pv$b <- ifelse(same, c(pv$a[-1], NA) - 1L, nd)
  pv <- pv[pv$b >= 1L & pv$a <= nd, , drop = FALSE]
  if (nrow(pv) == 0) return(list())

  pts <- list()
  for (arm in unique(pv$TG)) {
    tb <- tabs[[paste(proto, arm, sep = "\r")]]
    if (is.null(tb)) next
    ck <- match(du, tb$du)
    if (is.na(ck)) next
    r   <- pv[pv$TG == arm, , drop = FALSE]
    lad <- tb$lad; cad <- lad$cadence
    t   <- as.integer(r$Visit_Num)
    enr <- t == 0L
    s <- if (!lad$titrates) rep(1L, nrow(r)) else
      tb$ch$id(as.integer(r$Rung), as.integer(as.logical(r$Ratchet)),
               ifelse(r$Dose_Status == "Stable", lad$N, as.integer(r$Titration_Visit) - 1L))
    s[enr] <- 1L
    Kj <- pmin(tb$cycles[ck] - t, ncol(tb$U[[ck]]),
               ceiling((r$b - r$a + reach) / cad))
    Kj[is.na(Kj)] <- 0L
    if (!any(Kj >= 1L)) next
    for (k in seq_len(max(Kj))) {
      on <- which(Kj >= k)
      if (!length(on)) break
      land <- r$a[on] + k * cad
      w <- ifelse(enr[on], tb$U0[[ck]][k], tb$U[[ck]][s[on], k]) * scale
      keep <- land >= 1L & land <= nd & w > 0
      if (!any(keep)) next
      on <- on[keep]
      pts[[length(pts) + 1L]] <- data.frame(
        Site = r$Site[on], a = pmax(1L, r$a[on]), b1 = r$b[on] + 1L,
        land = as.integer(land[keep]), w = w[keep], stringsAsFactors = FALSE)
    }
  }
  if (!length(pts)) return(list())
  pts <- do.call(rbind, pts)

  # A projection landing before its replacement day is never read again.
  rm <- pts[pts$b1 <= nd & pts$land >= pts$b1, , drop = FALSE]
  ev <- rbind(data.frame(Site = pts$Site, day = pts$a, land = pts$land, w = pts$w),
              data.frame(Site = rm$Site, day = rm$b1, land = rm$land, w = -rm$w))
  out <- list()
  for (site in unique(ev$Site)) {
    e <- ev[ev$Site == site, , drop = FALSE]
    key <- e$day * (nd + 1) + e$land
    agg <- rowsum(e$w, key, reorder = TRUE)
    kk  <- as.numeric(rownames(agg))
    day <- as.integer(kk %/% (nd + 1)); land <- as.integer(kk %% (nd + 1))
    lst <- vector("list", nd)
    for (g in split(seq_along(day), day))
      lst[[day[g[1]]]] <- list(land = land[g], w = agg[g, 1])
    out[[site]] <- lst
  }
  out
}
