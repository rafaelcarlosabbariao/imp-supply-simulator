# =========================================================================== #
# inventory.R  --  Protocol-agnostic SUPPLY engine
#
# The piece that was missing from the original app. Takes simulated DEMAND
# (units of each DU dispensed per site per day, from simulation.R) plus the
# current on-hand inventory at sites and depots, and projects inventory forward
# in time under an order-up-to (s, S) resupply policy with:
#
#   * FEFO (first-expiry-first-out) consumption
#   * lot expiry (retest date) -> expired units are removed, not dispensed
#   * depot -> site replenishment with a shipping lead time
#   * safety stock, reorder point, oversupply buffer, unplanned-visit uplift
#   * stockout detection and days-of-supply at every site x DU x day
#
# The whole point: keep on top of IMP inventory across every study and site,
# and flag where/when a site will run dry before it happens.
#
# Column names in the inventory inputs are mapped flexibly (see .map_inventory)
# so real UDDM extracts, the sample datasets, or a hand-built upload all work.
# =========================================================================== #

suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
  library(lubridate)
})

# --------------------------------------------------------------------------- #
# Flexible column mapping for inventory tables.
# Returns a tidy frame: Protocol, Location, DU, Qty, Expiry, Lot
# --------------------------------------------------------------------------- #
.first_present <- function(df, candidates, default = NA) {
  hit <- intersect(candidates, names(df))
  if (length(hit)) df[[hit[1]]] else rep(default, nrow(df))
}

.map_inventory <- function(df, location_default = "SITE") {
  if (is.null(df) || nrow(df) == 0)
    return(data.frame(Protocol = character(), Location = character(),
                      DU = character(), Qty = numeric(),
                      Expiry = as.Date(character()), Lot = character(),
                      stringsAsFactors = FALSE))
  df <- normalize_df(df)
  out <- data.frame(
    Protocol = as.character(.first_present(df, c("Protocol", "protocol", "protocol_id", "prt_code", "study_number", "study_id"))),
    Location = as.character(.first_present(df, c("Location", "center_number", "Center", "site", "center", "depot_name", "Depot"), default = location_default)),
    DU       = as.character(.first_present(df, c("DU", "du_description", "DU_Description", "desc_cnt", "du_def_desc"))),
    Qty      = suppressWarnings(as.numeric(.first_present(df, c("Qty", "site_inventory_count", "depot_inventory_count", "inventory_count", "quantity", "count"), default = 0))),
    Expiry   = as_date_flex(.first_present(df, c("Expiry", "retest_date_inv", "retest_date", "expiry_date", "expiration_date"), default = NA)),
    Lot      = as.character(.first_present(df, c("Lot", "lot_id_inv", "lot_id", "source_packaged_lot"), default = NA)),
    stringsAsFactors = FALSE
  )
  out$Location <- trimws(out$Location)
  out$DU <- trimws(out$DU)
  out$Qty[is.na(out$Qty)] <- 0
  out[out$Qty > 0 & !is.na(out$DU) & out$DU != "", , drop = FALSE]
}

# --------------------------------------------------------------------------- #
# Lot helpers (FEFO). A "lot pool" is a data.frame(qty, expiry) kept sorted by
# expiry ascending. NA expiry sorts last (treated as non-expiring).
# --------------------------------------------------------------------------- #
# A pool is list(q = quantities, e = expiries as numeric day-numbers, NA = never
# expires). Plain vectors (not data.frames) keep the day-by-day loop fast.
.pool_qty <- function(p) if (length(p$q)) sum(p$q) else 0

.pool_expire <- function(p, today_n) {           # drop lots at/after retest
  if (!length(p$q)) return(list(pool = p, expired = 0))
  dead <- !is.na(p$e) & p$e <= today_n
  if (!any(dead)) return(list(pool = p, expired = 0))
  list(pool = list(q = p$q[!dead], e = p$e[!dead]), expired = sum(p$q[dead]))
}

.pool_consume <- function(p, qty) {              # FEFO draw of `qty` units
  nL <- length(p$q)
  if (nL == 0 || qty <= 0)
    return(list(pool = p, consumed = 0, shortfall = max(0, qty),
                taken_q = numeric(0), taken_e = numeric(0)))
  ord <- order(is.na(p$e), p$e)                  # first-expiry-first-out
  q <- p$q[ord]; e <- p$e[ord]
  need <- qty; tq <- numeric(0); te <- numeric(0); i <- 1L
  while (need > 1e-9 && i <= nL) {
    take <- if (q[i] < need) q[i] else need
    tq <- c(tq, take); te <- c(te, e[i])
    q[i] <- q[i] - take; need <- need - take; i <- i + 1L
  }
  keep <- q > 1e-9
  list(pool = list(q = q[keep], e = e[keep]),
       consumed = qty - need, shortfall = need, taken_q = tq, taken_e = te)
}

# --------------------------------------------------------------------------- #
# project_inventory()
#
# demand_df   : output of compute_demand() (Protocol, Country, Site, DU_Desc,
#               Trial, Visit_Date, Units)
# site_inv_df : current on-hand at sites   (flexible columns, see .map_inventory)
# depot_inv_df: current on-hand at depots   (flexible columns; optional)
# params      : list of policy assumptions (see defaults below)
#
# Returns a list:
#   $daily    : long projection, one row per Protocol x Site x DU x Date
#   $summary  : one row per Protocol x Site x DU (KPIs incl. first stockout)
#   $params   : the resolved parameters used
# --------------------------------------------------------------------------- #
project_inventory <- function(demand_df, site_inv_df, depot_inv_df = NULL,
                              params = list()) {
  p <- modifyList(list(
    safety_stock_days   = 30,   # buffer, in days of average demand
    target_days         = 90,   # order-up-to level, in days of average demand
    lead_time_days      = 21,   # depot -> site shipping time
    unplanned_visit_pct = 0.10, # demand uplift for unplanned visits
    oversupply_pct      = 0.10, # extra buffer added to every shipment
    start_date          = NULL, # default: earliest demand date
    horizon_end         = NULL, # default: latest demand date
    enable_resupply     = TRUE  # if FALSE, run down starting stock only
  ), params)

  stopifnot(nrow(demand_df) > 0)
  demand_df <- demand_df %>% mutate(Visit_Date = as_date_flex(Visit_Date))
  n_trials  <- max(1L, length(unique(demand_df$Trial)))

  # Expected daily demand = mean across trials, uplifted for unplanned visits.
  demand <- demand_df %>%
    group_by(Protocol, Site, DU = DU_Desc, Date = Visit_Date) %>%
    summarise(Units = sum(Units, na.rm = TRUE), .groups = "drop") %>%
    mutate(Units = (Units / n_trials) * (1 + p$unplanned_visit_pct))

  site_inv  <- .map_inventory(site_inv_df, "SITE")
  depot_inv <- .map_inventory(depot_inv_df, "DEPOT")

  # `start_date` is the planning "as-of" date: on-hand inventory is current as
  # of this day, and only demand on/after it is projected against that stock
  # (you cannot resupply the past). Demand before it is historical.
  start_date  <- as_date_flex(p$start_date  %||% Sys.Date())
  horizon_end <- as_date_flex(p$horizon_end %||% max(demand$Date, na.rm = TRUE))
  if (start_date > horizon_end) start_date <- min(demand$Date, na.rm = TRUE)
  if (horizon_end < start_date) horizon_end <- start_date
  demand <- demand %>% filter(Date >= start_date, Date <= horizon_end)
  days <- seq(start_date, horizon_end, by = "day")
  nd   <- length(days)
  day_num <- as.numeric(days)                     # numeric compares in the loop
  day_index <- setNames(seq_len(nd), as.character(days))

  results <- list()

  combos <- demand %>% distinct(Protocol, DU)
  # include DUs that have stock but (as yet) no demand, so we still track them
  combos <- bind_rows(combos, site_inv %>% transmute(Protocol, DU)) %>%
    distinct(Protocol, DU)

  for (ci in seq_len(nrow(combos))) {
    proto <- combos$Protocol[ci]; du <- combos$DU[ci]

    d_pd <- demand %>% filter(Protocol == proto, DU == du)
    sites <- sort(unique(c(d_pd$Site,
                           site_inv$Location[site_inv$Protocol == proto & site_inv$DU == du])))
    if (length(sites) == 0) next

    # shared depot pool for this protocol x DU (vectors; expiry as day-number)
    dp <- depot_inv %>% filter(Protocol == proto, DU == du)
    depot_pool <- list(q = dp$Qty, e = as.numeric(dp$Expiry))

    lt <- p$lead_time_days; tg <- p$target_days

    # per-site state held in environments (reference semantics -> the shared-
    # depot day loop can mutate a site in place without copying its vectors)
    site_state <- list()
    for (s in sites) {
      dv <- numeric(nd)
      ds <- d_pd %>% filter(Site == s)
      if (nrow(ds)) {
        idx <- day_index[as.character(ds$Date)]
        keep <- !is.na(idx)
        dv[idx[keep]] <- dv[idx[keep]] + ds$Units[keep]
      }
      p0 <- site_inv %>% filter(Protocol == proto, DU == du, Location == s)

      e <- new.env(parent = emptyenv())
      e$demand <- dv
      e$csum   <- cumsum(dv)
      e$pool   <- list(q = p0$Qty, e = as.numeric(p0$Expiry))
      e$it_arrive <- numeric(0); e$it_q <- numeric(0); e$it_e <- numeric(0)
      # preallocated output columns (one slot per simulated day)
      e$oh_start <- numeric(nd); e$recv <- numeric(nd); e$disp <- numeric(nd)
      e$exp <- numeric(nd); e$so <- numeric(nd); e$oh_end <- numeric(nd)
      e$on_order <- numeric(nd); e$reord <- numeric(nd); e$dshort <- numeric(nd)
      e$dos <- numeric(nd)
      site_state[[s]] <- e
    }

    # forward sum of a site's demand over days [a, b] (1-indexed, inclusive)
    fwd <- function(csum, a, b) {
      a <- max(1L, a); b <- min(nd, b)
      if (b < a) return(0)
      csum[b] - if (a > 1) csum[a - 1] else 0
    }

    # ---- daily walk (sites share the depot pool, processed in order) ------- #
    for (ti in seq_len(nd)) {
      today_n <- day_num[ti]
      # depot stock expires over time too (can't ship expired material)
      dex <- .pool_expire(depot_pool, today_n); depot_pool <- dex$pool
      for (s in sites) {
        st <- site_state[[s]]

        # 1. expire
        ex <- .pool_expire(st$pool, today_n); st$pool <- ex$pool
        expired <- ex$expired

        # 2. receive scheduled shipments
        if (length(st$it_arrive)) {
          arriving <- st$it_arrive == today_n
          if (any(arriving)) {
            received <- sum(st$it_q[arriving])
            st$pool <- list(q = c(st$pool$q, st$it_q[arriving]),
                            e = c(st$pool$e, st$it_e[arriving]))
            keep <- !arriving
            st$it_arrive <- st$it_arrive[keep]; st$it_q <- st$it_q[keep]; st$it_e <- st$it_e[keep]
          } else received <- 0
        } else received <- 0
        on_hand_start <- .pool_qty(st$pool)

        # 3. dispense today's demand (FEFO)
        cons <- .pool_consume(st$pool, st$demand[ti])
        st$pool <- cons$pool
        dispensed  <- cons$consumed
        stockout   <- cons$shortfall
        on_hand_end <- .pool_qty(st$pool)

        # 4. resupply decision -- forward-coverage (MRP-style) order-up-to.
        #    Size everything off demand actually coming up, not a flat average,
        #    so orders track the enrolment ramp instead of lagging it.
        on_order <- if (length(st$it_q)) sum(st$it_q) else 0
        reorder_qty <- 0; depot_short <- 0
        window_units <- fwd(st$csum, ti, ti + lt + tg - 1)
        window_days  <- max(1, min(nd - ti + 1, lt + tg))
        rate <- window_units / window_days
        lead_demand     <- fwd(st$csum, ti, ti + lt - 1)
        coverage_demand <- fwd(st$csum, ti + lt, ti + lt + tg - 1)
        ss_units      <- p$safety_stock_days * rate
        reorder_point <- lead_demand + ss_units
        S_units       <- (lead_demand + coverage_demand + ss_units) * (1 + p$oversupply_pct)
        if (p$enable_resupply && rate > 0) {
          position <- on_hand_end + on_order
          if (position < reorder_point) {
            want <- ceiling(S_units - position)
            if (want > 0) {
              pull <- .pool_consume(depot_pool, want)
              depot_pool <- pull$pool
              reorder_qty <- pull$consumed
              depot_short <- pull$shortfall
              if (reorder_qty > 0) {
                # each shipped lot keeps its own real expiry (FEFO from depot)
                m <- length(pull$taken_q)
                st$it_arrive <- c(st$it_arrive, rep(today_n + lt, m))
                st$it_q <- c(st$it_q, pull$taken_q)
                st$it_e <- c(st$it_e, pull$taken_e)
              }
            }
          }
        }

        st$oh_start[ti] <- on_hand_start; st$recv[ti] <- received
        st$disp[ti] <- dispensed; st$exp[ti] <- expired
        st$so[ti] <- stockout; st$oh_end[ti] <- on_hand_end
        st$on_order[ti] <- on_order + reorder_qty; st$reord[ti] <- reorder_qty
        st$dshort[ti] <- depot_short
        st$dos[ti] <- if (rate > 0) on_hand_end / rate else Inf
      }
    }

    # assemble one data frame per site from its preallocated columns
    for (s in sites) {
      st <- site_state[[s]]
      results[[paste(proto, du, s)]] <- data.frame(
        Protocol = proto, Site = s, DU = du, Date = days,
        On_Hand_Start = st$oh_start, Received = st$recv,
        Dispensed = st$disp, Expired = st$exp,
        Stockout_Units = st$so, On_Hand_End = st$oh_end,
        On_Order = st$on_order, Reorder_Qty = st$reord,
        Depot_Shortfall = st$dshort, Days_Of_Supply = st$dos,
        stringsAsFactors = FALSE)
    }
  }

  daily <- bind_rows(results)
  if (nrow(daily) == 0)
    return(list(daily = daily, summary = daily, params = p))

  summary <- daily %>%
    group_by(Protocol, Site, DU) %>%
    summarise(
      Start_On_Hand    = round(first(On_Hand_Start), 1),
      Total_Dispensed  = round(sum(Dispensed), 1),
      Total_Expired    = round(sum(Expired), 1),
      Total_Stockout   = round(sum(Stockout_Units), 1),
      Reorders         = sum(Reorder_Qty > 0),
      Total_Reordered  = round(sum(Reorder_Qty), 1),
      Depot_Shortfalls = sum(Depot_Shortfall > 0),
      End_On_Hand      = round(last(On_Hand_End), 1),
      Min_Days_Supply  = round(suppressWarnings(min(Days_Of_Supply)), 1),
      First_Stockout   = {
        so <- Date[Stockout_Units > 1e-9]
        if (length(so)) min(so) else as.Date(NA)
      },
      .groups = "drop"
    ) %>%
    mutate(Status = case_when(
      !is.na(First_Stockout)              ~ "STOCKOUT",
      Min_Days_Supply < params_num(p, "safety_stock_days") ~ "AT RISK",
      TRUE                                ~ "OK"
    )) %>%
    arrange(factor(Status, levels = c("STOCKOUT", "AT RISK", "OK")),
            First_Stockout, Min_Days_Supply)

  list(daily = daily, summary = summary, params = p)
}

params_num <- function(p, key) suppressWarnings(as.numeric(p[[key]]))

# --------------------------------------------------------------------------- #
# portfolio_summary()
# Roll the per-site projection up to a study-level and portfolio-level view so
# you can see IMP health across ALL studies and sites at a glance.
# --------------------------------------------------------------------------- #
portfolio_summary <- function(projection) {
  s <- projection$summary
  if (is.null(s) || nrow(s) == 0) return(list(by_study = NULL, overall = NULL))

  by_study <- s %>%
    group_by(Protocol) %>%
    summarise(
      Site_DU_Tracked = n(),
      Stockouts       = sum(Status == "STOCKOUT"),
      At_Risk         = sum(Status == "AT RISK"),
      OK              = sum(Status == "OK"),
      Earliest_Stockout = suppressWarnings(min(First_Stockout, na.rm = TRUE)),
      Total_Expired   = round(sum(Total_Expired), 1),
      .groups = "drop"
    ) %>%
    mutate(Earliest_Stockout = as.Date(ifelse(is.finite(Earliest_Stockout),
                                              Earliest_Stockout, NA),
                                       origin = "1970-01-01")) %>%
    arrange(desc(Stockouts), desc(At_Risk))

  overall <- data.frame(
    Studies          = length(unique(s$Protocol)),
    Site_DU_Tracked  = nrow(s),
    Stockouts        = sum(s$Status == "STOCKOUT"),
    At_Risk          = sum(s$Status == "AT RISK"),
    OK               = sum(s$Status == "OK"),
    Total_Expired    = sum(s$Total_Expired),
    stringsAsFactors = FALSE
  )
  list(by_study = by_study, overall = overall)
}
