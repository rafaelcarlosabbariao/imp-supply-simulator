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

.map_inventory <- function(df, location_default = "SITE", key_sites = FALSE) {
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
  # Site files key a row by center AND country (see site_key()). A depot row
  # keeps its depot name; its country column names a region, not a site.
  if (key_sites) {
    ctry <- .first_present(df, c("Country", "country", "country_name"))
    out$Location <- site_key(ctry, out$Location)
  }
  out$DU <- trimws(out$DU)
  out$Qty[is.na(out$Qty)] <- 0
  out[out$Qty > 0 & !is.na(out$DU) & out$DU != "", , drop = FALSE]
}

# --------------------------------------------------------------------------- #
# .resolve_site_keys()
# A file with no country column carries bare center numbers. Map each to the
# one known site key with that center in its protocol; stop, naming them, where
# a center exists in more than one country, since picking one would silently
# merge two sites' stock. A center with no known site is kept as it is.
# --------------------------------------------------------------------------- #
.resolve_site_keys <- function(protocol, location, known, what = "Site inventory") {
  if (!length(location)) return(location)
  known <- unique(known[c("Protocol", "Site")])
  bare  <- !grepl(SITE_SEP, location, fixed = TRUE)
  if (!any(bare)) return(location)
  kc <- site_center(known$Site)
  ambiguous <- character(0)
  for (i in which(bare)) {
    hit <- known$Site[known$Protocol == protocol[i] & kc == location[i]]
    if (length(hit) == 1L) location[i] <- hit
    else if (length(hit) > 1L)
      ambiguous <- c(ambiguous, sprintf("%s center %s (%s)", protocol[i], location[i],
                                        paste(site_country(hit), collapse = ", ")))
  }
  if (length(ambiguous))
    stop(sprintf(paste0("%s has no country column, and these centers exist in more ",
                        "than one country: %s. Add a country column (country_name or ",
                        "Country) so each row reaches the right site."),
                 what, paste(unique(ambiguous), collapse = "; ")), call. = FALSE)
  location
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
# initial_receipts: seed shipments from seed_sites()
# forecast    : what the reorder rule orders on (R/forecast.R). "trailing", the
#               default, uses only demand observed up to the day; "rung" projects
#               the patients on each dose; "oracle" reads the realised future and
#               is run only as a ceiling
# opening     : "snapshot" or "seeded" (see below); NULL picks "snapshot" when
#               a site inventory is given and "seeded" when sites start empty
# in_transit  : shipments on the road at the as-of date (flexible columns, see
#               .map_in_transit); optional, a data.frame or a CSV path
# lanes       : lead time by country -- Country, Lead_Time_Days [, Protocol];
#               a site with no lane uses params$lead_time_days
# disruptions : Country ("*" = every site), Start, End, Delay_Days [, Known];
#               a shipment due to land inside a window lands Delay_Days later
#
# Returns a list:
#   $daily     : long projection, one row per Protocol x Site x DU x Date
#   $summary   : one row per Protocol x Site x DU (KPIs incl. first stockout)
#   $shipments : one row per shipment to a site -- seeds (including any dropped
#                or topped up to zero, with the reason) and reorders
#   $opening   : the opening mode used
#   $forecast  : the forecast mode used (also a column of $summary)
#   $params    : the resolved parameters used
# --------------------------------------------------------------------------- #
project_inventory <- function(demand_df, site_inv_df, depot_inv_df = NULL,
                              params = list(), initial_receipts = NULL,
                              forecast = "trailing", occupancy = NULL,
                              ladders = NULL, opening = NULL,
                              in_transit = NULL, lanes = NULL, disruptions = NULL) {
  p <- modifyList(list(
    safety_stock_days   = 30,   # buffer, in days of average demand
    target_days         = 90,   # order-up-to level, in days of average demand
    lead_time_days      = 21,   # depot -> site shipping time
    unplanned_visit_pct = 0.10, # demand uplift for unplanned visits
    oversupply_pct      = 0.10, # extra buffer added to every shipment
    start_date          = NULL, # default: earliest demand date
    horizon_end         = NULL, # default: latest demand date
    enable_resupply     = TRUE, # if FALSE, run down starting stock only
    trailing_window_days = 60   # lookback for forecast = "trailing"
  ), params)

  # REALISED demand dispenses; FORECAST demand orders. Until forecast modes
  # existed these were the same series, which made the reorder rule an oracle
  # and drove the stockout rate to ~0. See R/forecast.R.
  forecast <- match.arg(forecast, FORECAST_MODES)
  fc_idx <- if (forecast == "rung" && !is.null(ladders))
              du_forecast_index(ladders) else NULL
  if (forecast == "rung" && is.null(occupancy))
    stop("forecast = \"rung\" needs `occupancy` from build_occupancy().", call. = FALSE)

  stopifnot(nrow(demand_df) > 0)
  demand_df <- demand_df %>% mutate(Visit_Date = as_date_flex(Visit_Date))
  n_trials  <- max(1L, length(unique(demand_df$Trial)))

  # Expected daily demand = mean across trials, uplifted for unplanned visits.
  demand <- demand_df %>%
    group_by(Protocol, Site, DU = DU_Desc, Date = Visit_Date) %>%
    summarise(Units = sum(Units, na.rm = TRUE), .groups = "drop") %>%
    mutate(Units = (Units / n_trials) * (1 + p$unplanned_visit_pct))

  site_inv  <- .map_inventory(site_inv_df, "SITE", key_sites = TRUE)
  depot_inv <- .map_inventory(depot_inv_df, "DEPOT")

  # Initial site stocking: one shipment per cohort (R/seeding.R), due to land
  # before the cohort's visit 0. Each is a scheduled SHIPMENT: on its ship date
  # (arrival less the lead time) it is drawn from the depot, topped up against
  # what the site already holds, and joins the in-transit queue a reorder uses.
  # Columns: Protocol, Site, DU, Arrive_Date, Qty [, Planned_Qty, Cohort, Expiry].
  init_rx <- NULL
  if (!is.null(initial_receipts) && nrow(initial_receipts) > 0) {
    init_rx <- normalize_df(as.data.frame(initial_receipts,
                                          stringsAsFactors = FALSE))
    require_cols(init_rx, c("Protocol", "Site", "DU", "Arrive_Date", "Qty"),
                 "Initial receipts")
    init_rx$Arrive_Date <- as_date_flex(init_rx$Arrive_Date)
    init_rx$Expiry <- if ("Expiry" %in% names(init_rx))
      as_date_flex(init_rx$Expiry) else as.Date(NA)
    if (!"Planned_Qty" %in% names(init_rx)) init_rx$Planned_Qty <- init_rx$Qty
    init_rx <- init_rx[!is.na(init_rx$Planned_Qty) & init_rx$Planned_Qty > 0, , drop = FALSE]
    if (nrow(init_rx) == 0) init_rx <- NULL
  }

  # `opening` says what the position at the as-of date is made of.
  #   "snapshot": the site inventory file is the stock on hand at the as-of
  #               date. A seed shipped before it is dropped: one that landed is
  #               in the snapshot, net of what was dispensed, and one still on
  #               the road belongs in the in-transit input.
  #   "seeded"  : sites start empty and the seeds build them. A seed that
  #               landed before the as-of date is folded into on-hand; one on
  #               the road at the as-of date lands on its date. Neither is drawn
  #               from the depot, whose stock is counted as of the as-of date.
  # Folding a seed in with no snapshot counted it twice when both were given.
  opening <- if (is.null(opening)) (if (nrow(site_inv) > 0) "snapshot" else "seeded")
             else match.arg(opening, c("snapshot", "seeded"))

  # Stock on the road at the as-of date, lead time by country, and the windows
  # in which a crisis holds shipments up. See .map_in_transit(), .read_lanes()
  # and .read_disruptions() below.
  it_in <- .map_in_transit(in_transit)
  lanes <- .read_lanes(lanes)
  disr  <- .read_disruptions(disruptions)

  # Sites known from the plan: every site with demand or a seed shipment.
  known_sites <- unique(rbind(
    data.frame(Protocol = demand$Protocol, Site = demand$Site, stringsAsFactors = FALSE),
    if (!is.null(init_rx)) data.frame(Protocol = init_rx$Protocol, Site = init_rx$Site,
                                      stringsAsFactors = FALSE)))
  site_inv$Location <- .resolve_site_keys(site_inv$Protocol, site_inv$Location, known_sites)
  if (!is.null(it_in))
    it_in$Location <- .resolve_site_keys(it_in$Protocol, it_in$Location, known_sites,
                                         "In-transit input")

  # `start_date` is the planning "as-of" date: on-hand inventory is current as
  # of this day, and only demand on/after it is projected against that stock
  # (you cannot resupply the past). Demand before it is historical.
  start_date  <- as_date_flex(p$start_date  %||% Sys.Date())
  horizon_end <- as_date_flex(p$horizon_end %||% max(demand$Date, na.rm = TRUE))
  if (start_date > horizon_end) start_date <- min(demand$Date, na.rm = TRUE)
  if (horizon_end < start_date) horizon_end <- start_date
  # What was dispensed in the trailing window before the as-of date. A planner
  # has that history, so the trailing forecast reads it from day one.
  w_pre <- as.integer(p$trailing_window_days %||% 60L)
  history <- demand %>% filter(Date < start_date, Date >= start_date - w_pre)
  first_seen <- demand %>% group_by(Protocol, Site, DU) %>%
    summarise(First = min(Date), .groups = "drop")
  demand <- demand %>% filter(Date >= start_date, Date <= horizon_end)
  days <- seq(start_date, horizon_end, by = "day")
  nd   <- length(days)
  day_num <- as.numeric(days)                     # numeric compares in the loop
  day_index <- setNames(seq_len(nd), as.character(days))

  results <- list(); shipments <- list()
  start_n <- as.numeric(start_date)
  n_seed_dropped <- 0L; early_ship <- Inf

  combos <- demand %>% distinct(Protocol, DU)
  # include DUs that have stock but (as yet) no demand, so we still track them
  combos <- bind_rows(combos, site_inv %>% transmute(Protocol, DU))
  if (!is.null(init_rx))
    combos <- bind_rows(combos, init_rx %>% transmute(Protocol, DU))
  if (!is.null(it_in))
    combos <- bind_rows(combos, it_in %>% transmute(Protocol, DU))
  combos <- combos %>% distinct(Protocol, DU)

  for (ci in seq_len(nrow(combos))) {
    proto <- combos$Protocol[ci]; du <- combos$DU[ci]

    d_pd <- demand %>% filter(Protocol == proto, DU == du)
    ir_pd <- if (is.null(init_rx)) NULL
             else init_rx[init_rx$Protocol == proto & init_rx$DU == du, , drop = FALSE]
    it_pd <- if (is.null(it_in)) NULL
             else it_in[it_in$Protocol == proto & it_in$DU == du, , drop = FALSE]
    sites <- sort(unique(c(d_pd$Site,
                           site_inv$Location[site_inv$Protocol == proto & site_inv$DU == du],
                           if (is.null(ir_pd)) NULL else ir_pd$Site,
                           if (is.null(it_pd)) NULL else it_pd$Location)))
    if (length(sites) == 0) next

    # shared depot pool for this protocol x DU (vectors; expiry as day-number)
    dp <- depot_inv %>% filter(Protocol == proto, DU == du)
    depot_pool <- list(q = dp$Qty, e = as.numeric(dp$Expiry))
    # With no depot stock listed for this protocol x DU at all, a seed is
    # supplied from outside the model and keeps the expiry seed_sites() gave it.
    has_depot <- nrow(dp) > 0

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
      # Pre-as-of history, oldest first, over the days the site was dispensing.
      hs <- history[history$Protocol == proto & history$DU == du & history$Site == s, ]
      f0 <- first_seen$First[first_seen$Protocol == proto & first_seen$DU == du &
                               first_seen$Site == s]
      n_pre <- if (length(f0)) max(0L, min(w_pre, as.integer(start_date - f0[1]))) else 0L
      e$pre <- numeric(n_pre)
      if (n_pre > 0 && nrow(hs)) {
        k <- n_pre - as.integer(start_date - hs$Date) + 1L
        ok <- k >= 1L
        for (j in which(ok)) e$pre[k[j]] <- e$pre[k[j]] + hs$Units[j]
      }
      e$pool   <- list(q = p0$Qty, e = as.numeric(p0$Expiry))
      e$it_arrive <- numeric(0); e$it_q <- numeric(0); e$it_e <- numeric(0)

      # This site's lane, and the disruption windows that reach it.
      e$lt  <- .site_lead_time(lanes, proto, s, lt)
      e$dis <- .site_disruptions(disr, s)
      e$lg  <- .ledger_new()

      # Stock on the road at the as-of date. It left the depot before the
      # as-of date, so it draws nothing from the depot figure; it counts as on
      # order from day one, so the reorder rule sees it. One whose ETA has
      # already passed is overdue: it lands on the first day, later still if
      # a disruption window covers that day.
      if (!is.null(it_pd)) {
        r1 <- it_pd[it_pd$Location == s, , drop = FALSE]
        for (k in seq_len(nrow(r1))) {
          eta  <- as.numeric(r1$ETA[k])
          late <- eta < start_n
          arr  <- .arrival(e, max(eta, start_n))
          e$it_arrive <- c(e$it_arrive, arr); e$it_q <- c(e$it_q, r1$Qty[k])
          e$it_e <- c(e$it_e, as.numeric(r1$Expiry[k]))
          .ledger_add(e, "in_transit", as.numeric(r1$Ship_Date[k]), eta, arr,
                      r1$Qty[k], r1$Qty[k],
                      if (late) "overdue at the as-of date" else "", overdue = late)
        }
      }
      e$sd_day <- numeric(0); e$sd_arr <- numeric(0)
      e$sd_plan <- numeric(0); e$sd_exp <- numeric(0)
      if (!is.null(ir_pd)) {
        r0 <- ir_pd[ir_pd$Site == s, , drop = FALSE]
        for (k in seq_len(nrow(r0))) {
          arr  <- as.numeric(r0$Arrive_Date[k]); ship <- arr - e$lt
          qty  <- r0$Planned_Qty[k];            ex   <- as.numeric(r0$Expiry[k])
          if (ship >= start_n) {                  # ships during the walk
            e$sd_day  <- c(e$sd_day, ship); e$sd_arr <- c(e$sd_arr, arr)
            e$sd_plan <- c(e$sd_plan, qty); e$sd_exp <- c(e$sd_exp, ex)
          } else if (opening == "snapshot") {
            .ledger_add(e, "seed", ship, arr, NA, qty, 0,
                        "dropped: shipped before the as-of date; the site snapshot and the in-transit input hold it")
            n_seed_dropped <- n_seed_dropped + 1L
          } else if (arr < start_n) {
            e$pool <- list(q = c(e$pool$q, qty), e = c(e$pool$e, ex))
            .ledger_add(e, "seed", ship, arr, arr, qty, qty,
                        "landed before the as-of date: opening on-hand")
            early_ship <- min(early_ship, ship)
          } else {
            got <- .arrival(e, arr)
            e$it_arrive <- c(e$it_arrive, got); e$it_q <- c(e$it_q, qty)
            e$it_e <- c(e$it_e, ex)
            .ledger_add(e, "seed", ship, arr, got, qty, qty, "on the road at the as-of date")
            early_ship <- min(early_ship, ship)
          }
        }
      }
      # preallocated output columns (one slot per simulated day)
      # Rung-forecast state: what the planner can see about this site today.
      if (!is.null(fc_idx)) {
        fi <- fc_idx[[paste(proto, du, sep = "\r")]]
        if (!is.null(fi)) {
          e$occ     <- occupancy[[paste(proto, s, sep = "\r")]]
          e$P       <- fi$P
          e$qty_at  <- fi$qty_at
          e$cadence <- fi$cadence
        }
      }
      e$oh_start <- numeric(nd); e$recv <- numeric(nd); e$disp <- numeric(nd)
      e$exp <- numeric(nd); e$so <- numeric(nd); e$oh_end <- numeric(nd)
      e$on_order <- numeric(nd); e$reord <- numeric(nd); e$dshort <- numeric(nd)
      e$dos <- numeric(nd); e$seed <- numeric(nd); e$sshort <- numeric(nd)
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

        # 4. seed shipments due today. A seed tops the site up to the cohort's
        #    planned quantity: a later cohort at an open site usually holds
        #    stock from resupply, and shipping a full seed on top overstocks it.
        seed_today <- 0; seed_short <- 0
        if (length(st$sd_day) && any(st$sd_day == today_n)) {
          for (k in which(st$sd_day == today_n)) {
            position <- on_hand_end + (if (length(st$it_q)) sum(st$it_q) else 0)
            want <- max(0, ceiling(st$sd_plan[k] - position))
            shipped <- 0; short <- 0
            if (want > 0 && has_depot) {
              pull <- .pool_consume(depot_pool, want)
              depot_pool <- pull$pool
              shipped <- pull$consumed; short <- pull$shortfall
              m <- length(pull$taken_q)
              if (m) {
                st$it_arrive <- c(st$it_arrive, rep(.arrival(st, today_n + st$lt), m))
                st$it_q <- c(st$it_q, pull$taken_q); st$it_e <- c(st$it_e, pull$taken_e)
              }
            } else if (want > 0) {
              shipped <- want
              st$it_arrive <- c(st$it_arrive, .arrival(st, today_n + st$lt))
              st$it_q <- c(st$it_q, want); st$it_e <- c(st$it_e, st$sd_exp[k])
            }
            seed_today <- seed_today + shipped; seed_short <- seed_short + short
            .ledger_add(st, "seed", today_n, st$sd_arr[k], .arrival(st, today_n + st$lt),
                        st$sd_plan[k], shipped,
                        if (want == 0) "topped up to zero: the site already held the planned quantity"
                        else if (short > 0) sprintf("depot short by %s", format(short))
                        else if (want < st$sd_plan[k]) "topped up" else "")
          }
        }

        # 5. resupply decision -- forward-coverage (MRP-style) order-up-to.
        #    Size everything off demand actually coming up, not a flat average,
        #    so orders track the enrolment ramp instead of lagging it.
        on_order <- if (length(st$it_q)) sum(st$it_q) else 0
        reorder_qty <- 0; depot_short <- 0; want <- 0
        # The planner orders on this site's lane lead time, lengthened by any
        # KNOWN disruption the order would land in. An unknown one is a
        # surprise: the order is planned on the normal lane and lands late.
        lt_plan <- if (is.null(st$dis)) st$lt
                   else st$lt + .delay_for(st$dis, today_n + st$lt, known_only = TRUE)
        fc <- .forecast_window(forecast, st, ti, nd, lt_plan, tg, p)
        if (is.null(fc)) fc <- .forecast_window("trailing", st, ti, nd, lt_plan, tg, p)
        rate            <- fc$rate
        lead_demand     <- fc$lead_demand
        coverage_demand <- fc$coverage_demand
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
                st$it_arrive <- c(st$it_arrive, rep(.arrival(st, today_n + st$lt), m))
                st$it_q <- c(st$it_q, pull$taken_q)
                st$it_e <- c(st$it_e, pull$taken_e)
              }
              .ledger_add(st, "reorder", today_n, today_n + st$lt, .arrival(st, today_n + st$lt),
                          want, reorder_qty,
                          if (depot_short > 0) sprintf("depot short by %s", format(depot_short)) else "")
            }
          }
        }

        st$oh_start[ti] <- on_hand_start; st$recv[ti] <- received
        st$disp[ti] <- dispensed; st$exp[ti] <- expired
        st$so[ti] <- stockout; st$oh_end[ti] <- on_hand_end
        st$on_order[ti] <- on_order + reorder_qty; st$reord[ti] <- reorder_qty
        st$dshort[ti] <- depot_short
        st$dos[ti] <- if (rate > 0) on_hand_end / rate else Inf
        st$seed[ti] <- seed_today; st$sshort[ti] <- seed_short
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
        Seed_Shipped = st$seed, Seed_Short = st$sshort,
        Depot_Shortfall = st$dshort, Days_Of_Supply = st$dos,
        stringsAsFactors = FALSE)
      shipments[[paste(proto, du, s)]] <- .ledger_frame(st$lg, proto, s, du)
    }
  }

  if (n_seed_dropped > 0L)
    message(sprintf(paste0("%d seed shipment(s) left before the as-of date %s and were ",
                           "dropped: in snapshot mode the site inventory and the ",
                           "in-transit input hold them."), n_seed_dropped, start_date))
  if (is.finite(early_ship))
    warning(sprintf(paste0("Seeds shipped as early as %s, before the as-of date %s. They ",
                           "are counted, but the demand before %s is not simulated. Set ",
                           "the as-of date on or before %s to walk them in."),
                    as.Date(early_ship, origin = "1970-01-01"), start_date, start_date,
                    as.Date(early_ship, origin = "1970-01-01")), call. = FALSE)

  daily <- bind_rows(results)
  shipments <- bind_rows(shipments)
  if (nrow(daily) == 0)
    return(list(daily = daily, summary = daily, shipments = shipments,
                opening = opening, forecast = forecast, params = p))

  summary <- daily %>%
    group_by(Protocol, Site, DU) %>%
    summarise(
      Start_On_Hand    = round(first(On_Hand_Start), 1),
      Total_Dispensed  = round(sum(Dispensed), 1),
      Total_Expired    = round(sum(Expired), 1),
      Total_Stockout   = round(sum(Stockout_Units), 1),
      Reorders         = sum(Reorder_Qty > 0),
      Total_Reordered  = round(sum(Reorder_Qty), 1),
      Total_Seeded     = round(sum(Seed_Shipped), 1),
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
    ), Forecast = forecast) %>%
    arrange(factor(Status, levels = c("STOCKOUT", "AT RISK", "OK")),
            First_Stockout, Min_Days_Supply)

  list(daily = daily, summary = summary, shipments = shipments,
       opening = opening, forecast = forecast, params = p)
}

# --------------------------------------------------------------------------- #
# The shipment ledger: every shipment to a site, kept per site as plain vectors
# while the walk runs and assembled once at the end.
# --------------------------------------------------------------------------- #
.ledger_new <- function()
  list(src = character(0), ship = numeric(0), parr = numeric(0), arr = numeric(0),
       planned = numeric(0), qty = numeric(0), note = character(0),
       overdue = logical(0))

.ledger_add <- function(st, src, ship, parr, arr, planned, qty, note = "",
                        overdue = FALSE) {
  lg <- st$lg
  lg$src <- c(lg$src, src); lg$ship <- c(lg$ship, ship)
  lg$parr <- c(lg$parr, parr); lg$arr <- c(lg$arr, arr)
  lg$planned <- c(lg$planned, planned); lg$qty <- c(lg$qty, qty)
  lg$note <- c(lg$note, note); lg$overdue <- c(lg$overdue, overdue)
  st$lg <- lg
  invisible(NULL)
}

.ledger_frame <- function(lg, proto, site, du) {
  if (!length(lg$src)) return(NULL)
  d <- function(x) as.Date(x, origin = "1970-01-01")
  data.frame(Protocol = proto, Site = site, DU = du, Source = lg$src,
             Ship_Date = d(lg$ship), Planned_Arrival = d(lg$parr), Arrival = d(lg$arr),
             Delay_Days = lg$arr - lg$parr, Planned_Qty = lg$planned, Qty = lg$qty,
             Overdue = lg$overdue, Note = lg$note, stringsAsFactors = FALSE)
}

# --------------------------------------------------------------------------- #
# In transit, lanes and disruptions
#
# Stock already moving at the as-of date, the lead time of each country's lane,
# and the windows in which a crisis holds shipments up. All three are optional.
# --------------------------------------------------------------------------- #
.read_table <- function(x, what) {
  if (is.null(x)) return(NULL)
  if (is.character(x)) {
    if (!file.exists(x)) return(NULL)
    x <- utils::read.csv(x, stringsAsFactors = FALSE, check.names = FALSE)
  }
  x <- normalize_df(x)
  if (nrow(x) == 0) NULL else x
}

# Shipments on the road at the as-of date. Returns Protocol, Location (a site
# key, or a bare center resolved later), DU, Qty, ETA, Ship_Date, Expiry, Lot.
.map_in_transit <- function(x) {
  df <- .read_table(x, "In-transit input")
  if (is.null(df)) return(NULL)
  loc  <- as.character(.first_present(df, c("Site", "center_number", "Center", "center", "site")))
  ctry <- .first_present(df, c("Country", "country", "country_name"))
  out <- data.frame(
    Protocol  = as.character(.first_present(df, c("Protocol", "protocol", "protocol_id"))),
    Location  = ifelse(grepl(SITE_SEP, loc, fixed = TRUE), loc, site_key(ctry, loc)),
    DU        = as.character(.first_present(df, c("DU", "du_description", "DU_Description"))),
    Qty       = suppressWarnings(as.numeric(.first_present(df,
                  c("Qty", "qty", "quantity", "shipment_qty", "in_transit_count")))),
    ETA       = as_date_flex(.first_present(df, c("ETA", "eta", "expected_arrival",
                                                  "Expected_Arrival", "arrival_date"))),
    Ship_Date = as_date_flex(.first_present(df, c("Ship_Date", "ship_date", "shipped_date"))),
    Expiry    = as_date_flex(.first_present(df, c("Expiry", "expiry_date", "retest_date",
                                                  "retest_date_inv", "expiration_date"))),
    Lot       = as.character(.first_present(df, c("Lot", "lot_id", "lot_id_inv"))),
    stringsAsFactors = FALSE)
  bad <- is.na(out$Protocol) | is.na(out$Location) | out$Location == "" |
         is.na(out$DU) | is.na(out$Qty) | is.na(out$ETA)
  if (any(bad))
    stop(sprintf(paste0("In-transit input: %d row(s) lack a protocol, site, DU, ",
                        "quantity or expected arrival (ETA): rows %s."),
                 sum(bad), paste(head(which(bad), 10), collapse = ", ")), call. = FALSE)
  out[out$Qty > 0, , drop = FALSE]
}

.read_lanes <- function(x) {
  df <- .read_table(x, "Lanes")
  if (is.null(df)) return(NULL)
  require_cols(df, c("Country", "Lead_Time_Days"), "Lanes")
  if (!"Protocol" %in% names(df)) df$Protocol <- NA_character_
  df$Protocol[!is.na(df$Protocol) & df$Protocol == ""] <- NA
  df$Lead_Time_Days <- suppressWarnings(as.numeric(df$Lead_Time_Days))
  if (any(is.na(df$Lead_Time_Days) | df$Lead_Time_Days < 0))
    stop("Lanes: Lead_Time_Days must be a whole number of days, 0 or more.", call. = FALSE)
  df$Lead_Time_Days <- round(df$Lead_Time_Days)
  df
}

# A study-specific lane beats a country lane, which beats the global default.
.site_lead_time <- function(lanes, proto, site, default) {
  if (is.null(lanes)) return(default)
  ctry <- site_country(site)
  if (is.na(ctry)) return(default)
  hit <- lanes$Lead_Time_Days[lanes$Country == ctry & !is.na(lanes$Protocol) &
                                lanes$Protocol == proto]
  if (!length(hit)) hit <- lanes$Lead_Time_Days[lanes$Country == ctry & is.na(lanes$Protocol)]
  if (length(hit)) hit[1] else default
}

.read_disruptions <- function(x) {
  df <- .read_table(x, "Disruptions")
  if (is.null(df)) return(NULL)
  require_cols(df, c("Country", "Start", "End", "Delay_Days"), "Disruptions")
  df$Start <- as_date_flex(df$Start); df$End <- as_date_flex(df$End)
  df$Delay_Days <- round(suppressWarnings(as.numeric(df$Delay_Days)))
  df$Known <- if ("Known" %in% names(df))
    toupper(trimws(as.character(df$Known))) %in% c("TRUE", "T", "YES", "Y", "1")
  else FALSE
  bad <- is.na(df$Start) | is.na(df$End) | df$End < df$Start |
         is.na(df$Delay_Days) | df$Delay_Days < 0
  if (any(bad))
    stop(sprintf(paste0("Disruptions: row(s) %s need a Start and End date (End on or ",
                        "after Start) and Delay_Days of 0 or more."),
                 paste(which(bad), collapse = ", ")), call. = FALSE)
  df
}

.site_disruptions <- function(disr, site) {
  if (is.null(disr)) return(NULL)
  ctry <- site_country(site)
  d <- disr[disr$Country == "*" | (!is.na(ctry) & disr$Country == ctry), , drop = FALSE]
  if (nrow(d) == 0) return(NULL)
  list(s = as.numeric(d$Start), e = as.numeric(d$End), delay = d$Delay_Days, known = d$Known)
}

# Days added to a shipment scheduled to land on day `parr`: every window that
# covers that day adds its delay, so overlapping crises compound. A delay that
# pushes the arrival into a later window does not trigger that window too.
.delay_for <- function(dis, parr, known_only = FALSE) {
  if (is.null(dis)) return(0)
  hit <- dis$s <= parr & parr <= dis$e
  if (known_only) hit <- hit & dis$known
  sum(dis$delay[hit])
}

.arrival <- function(st, parr) if (is.null(st$dis)) parr else parr + .delay_for(st$dis, parr)

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
