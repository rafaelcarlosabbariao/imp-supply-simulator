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
#               as an experimental arm.
#
#   "trailing"  a causal moving average of demand actually observed at this
#               site x DU up to today, projected flat. The classic MRP default,
#               and the honest baseline: it uses nothing the planner lacks.
#
#   "rung"      propagates the site's CURRENT DOSE-RUNG OCCUPANCY forward
#               through the CSP's own titration probabilities.
#
# The "rung" mode is the one the ladder makes possible, and the reason it can
# beat a trailing average is that demand for a dose is not a smooth series --
# it is a headcount. The units needed at rung d next visit come from the
# patients at the rungs ADJACENT to d, d itself included:
#
#     E[N_d(t+1)] = N_{d-1}(t) * P(up)
#                 + N_d(t)     * P(stay)
#                 + N_{d+1}(t) * P(down)
#                 + (restart inflow from anyone who misses)
#
# That is one step of the same Markov chain the demand engine runs, and every
# term on the right is observable: an IRT system knows who is on what dose
# today. A trailing average cannot see a cohort about to step up together; a
# rung forecast can, because it is counting people rather than smoothing units.
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
    w    <- as.integer(p$trailing_window_days %||% 60L)
    from <- max(1L, ti - w + 1L)
    rate <- fwd(st$csum, from, ti) / (ti - from + 1L)
    return(list(rate            = rate,
                lead_demand     = rate * lt,
                coverage_demand = rate * tg))
  }

  if (mode == "rung") {
    # Headcount, not a smoothed series. st$occ is a [days x rungs] matrix of
    # patients observed at each rung; st$qty_at is units of THIS DU per patient
    # at each rung. Occupancy is rolled forward one visit at a time through the
    # CSP transition matrix st$P, and each projected visit contributes its
    # rung-weighted units.
    if (is.null(st$occ) || is.null(st$P)) return(NULL)
    occ <- st$occ[ti, ]
    if (sum(occ) <= 0) {
      return(list(rate = 0, lead_demand = 0, coverage_demand = 0))
    }
    cadence <- max(1L, as.integer(st$cadence))
    horizon <- lt + tg
    n_steps <- ceiling(horizon / cadence)
    units_by_step <- numeric(n_steps)
    cur <- occ
    for (k in seq_len(n_steps)) {
      units_by_step[k] <- sum(cur * st$qty_at)
      cur <- as.vector(cur %*% st$P)
    }
    # Spread each visit's units over the cadence it covers, then split the
    # horizon into lead time and coverage.
    per_day <- rep(units_by_step / cadence, each = cadence)[seq_len(horizon)]
    per_day[is.na(per_day)] <- 0
    return(list(rate            = sum(per_day) / horizon,
                lead_demand     = sum(per_day[seq_len(min(lt, horizon))]),
                coverage_demand = if (horizon > lt)
                                    sum(per_day[(lt + 1):horizon]) else 0))
  }

  stop(sprintf("unknown forecast mode: %s", mode), call. = FALSE)
}

`%||%` <- function(a, b) if (is.null(a)) b else a

# --------------------------------------------------------------------------- #
# rung_occupancy()
# Patients observed at each dose rung, per (Protocol, Site, Date).
#
# Built from the visit stream, which carries the rung each dispensing event was
# made at. A patient counts at the rung of their most recent visit until their
# next one -- which is precisely what an IRT system reports.
# --------------------------------------------------------------------------- #
rung_occupancy <- function(visits_df, days) {
  if (!"Rung" %in% names(visits_df))
    stop("visit stream carries no Rung column; simulate_visits() must emit it.",
         call. = FALSE)
  v <- visits_df %>%
    filter(!is.na(Rung), Rung > 0) %>%
    distinct(Protocol, Site, SSID, Visit_Date, Rung)
  if (nrow(v) == 0) return(NULL)
  v$day <- match(as.character(v$Visit_Date), as.character(days))
  v <- v[!is.na(v$day), , drop = FALSE]
  v
}

# --------------------------------------------------------------------------- #
# build_occupancy()
# Patients at each dose rung, per (Protocol, Site), as a [days x rungs] matrix.
#
# A patient occupies the rung of their most recent visit until their next one,
# which is what an IRT system reports when a planner asks "who is on what dose
# today". Carry-forward, not interpolation: nothing is assumed about a patient
# between visits.
# --------------------------------------------------------------------------- #
build_occupancy <- function(visits_df, days, ladders) {
  if (!"Rung" %in% names(visits_df)) return(NULL)
  nd <- length(days)
  day_of <- setNames(seq_len(nd), as.character(days))
  L_of <- vapply(ladders, function(l) l$L, integer(1))
  names(L_of) <- vapply(ladders, function(l) l$protocol, character(1))

  v <- visits_df[!is.na(visits_df$Rung) & visits_df$Rung > 0, , drop = FALSE]
  if (nrow(v) == 0) return(NULL)
  v <- v[!duplicated(v[c("Protocol", "Site", "SSID", "Visit_Date")]), , drop = FALSE]
  v$day <- day_of[as.character(v$Visit_Date)]
  v <- v[!is.na(v$day), , drop = FALSE]
  if (nrow(v) == 0) return(NULL)

  out <- list()
  key <- paste(v$Protocol, v$Site, sep = "\r")
  for (k in unique(key)) {
    rows <- v[key == k, , drop = FALSE]
    L <- L_of[[rows$Protocol[1]]]
    if (is.null(L) || is.na(L)) next
    M <- matrix(0, nd, L)
    # order by patient then day so each patient's spans are contiguous
    rows <- rows[order(rows$SSID, rows$day), , drop = FALSE]
    nxt <- c(rows$day[-1], nd + 1L)
    same <- c(rows$SSID[-1] == rows$SSID[-nrow(rows)], FALSE)
    upto <- ifelse(same, nxt - 1L, nd)          # last visit runs to the horizon
    for (i in seq_len(nrow(rows))) {
      a <- rows$day[i]; b <- min(upto[i], nd); r <- rows$Rung[i]
      if (b >= a && r >= 1L && r <= L) M[a:b, r] <- M[a:b, r] + 1
    }
    out[[k]] <- M
  }
  out
}

# --------------------------------------------------------------------------- #
# du_forecast_index()
# For each (Protocol, DU): the transition matrix, the units of that DU at each
# rung, and the arm's cadence -- everything the "rung" forecast needs.
# --------------------------------------------------------------------------- #
du_forecast_index <- function(ladders) {
  idx <- list()
  for (lad in ladders) {
    P <- ladder_transition(lad)
    for (k in seq_len(nrow(lad$components))) {
      key <- paste(lad$protocol, lad$components$DU_Description[k], sep = "\r")
      idx[[key]] <- list(P = P, qty_at = as.numeric(lad$qty[k, ]),
                         cadence = lad$cadence, L = lad$L)
    }
  }
  idx
}

# --------------------------------------------------------------------------- #
# ladder_transition()
# The one-visit transition matrix over dose rungs for a titrating arm --
# the P in E[N(t+1)] = N(t) P. Marginalised over the ratchet and window states,
# because a planner sees rungs, not the latent state behind them.
# --------------------------------------------------------------------------- #
ladder_transition <- function(lad) {
  L <- lad$L
  P <- matrix(0, L, L)
  if (!lad$titrates || L < 2L) { P[1, 1] <- 1; return(P) }
  for (d in seq_len(L)) {
    # miss -> back to the floor. Marginalised: a planner does not know which
    # patients have ratcheted, so the floor is taken as the tolerance rung for
    # anyone at or above it and rung 1 below.
    f <- if (d >= lad$tol) lad$tol else 1L
    P[d, f] <- P[d, f] + lad$p_miss
    P[d, min(d + 1L, L)] <- P[d, min(d + 1L, L)] + (1 - lad$p_miss) * lad$p_up
    P[d, d]              <- P[d, d]              + (1 - lad$p_miss) * lad$p_stay
    P[d, max(d - 1L, f)] <- P[d, max(d - 1L, f)] + (1 - lad$p_miss) * lad$p_down
  }
  P
}
