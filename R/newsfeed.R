# =========================================================================== #
# newsfeed.R  --  Global supply-chain news feed for clinical-trial risk
#
# Pulls recent headlines from Google News RSS (no API key required), tags each
# by how likely it is to disrupt IMP supply, and returns a tidy feed. If the
# network is unavailable it falls back to a small curated set so the app always
# has something to show.
#
# The feed is advisory context, not part of the simulation: it surfaces external
# events (port strikes, cold-chain failures, recalls, shortages, tariffs) that a
# supply manager would want on the same screen as their stockout projections.
# =========================================================================== #

suppressPackageStartupMessages({
  library(xml2)
  library(httr)
})

# Search queries -> Google News RSS. Kept broad but supply-relevant.
NEWS_QUERIES <- c(
  "pharmaceutical supply chain",
  "clinical trial drug shortage",
  "cold chain logistics disruption",
  "cargo port strike delay",
  "drug manufacturing recall"
)

# Risk lexicon: presence of these words bumps a headline's risk tag.
.RISK_HIGH <- c("shortage", "recall", "strike", "shutdown", "halt", "ban",
                "disruption", "contamination", "closure", "grounded", "seized",
                "cold chain", "cold-chain", "port congestion", "force majeure")
.RISK_MED  <- c("delay", "tariff", "customs", "backlog", "congestion", "freight",
                "logistics", "shipping", "weather", "hurricane", "flood",
                "capacity", "export", "import", "sanction")

.tag_risk <- function(title) {
  t <- tolower(title %||% "")
  if (any(vapply(.RISK_HIGH, function(k) grepl(k, t, fixed = TRUE), logical(1)))) "High"
  else if (any(vapply(.RISK_MED, function(k) grepl(k, t, fixed = TRUE), logical(1)))) "Medium"
  else "Low"
}

# Parse one Google News RSS document into a data frame.
.parse_rss <- function(doc) {
  items <- xml_find_all(doc, ".//item")
  if (length(items) == 0) return(NULL)
  get1 <- function(node, tag) {
    x <- xml_text(xml_find_first(node, tag))
    if (length(x) == 0 || is.na(x)) "" else x
  }
  do.call(rbind, lapply(items, function(it) {
    title <- get1(it, "title")
    pub   <- get1(it, "pubDate")
    src   <- get1(it, "source")
    link  <- get1(it, "link")
    data.frame(
      Title = title,
      Source = if (nzchar(src)) src else "News",
      Published = pub,
      Link = link,
      stringsAsFactors = FALSE
    )
  }))
}

#' Fetch supply-chain news.
#' @return data.frame(Title, Source, Published, PublishedAt, Link, Risk) or a
#'   curated fallback. Never throws.
fetch_supply_chain_news <- function(queries = NEWS_QUERIES,
                                    max_items = 25, timeout = 6) {
  rows <- list()
  for (q in queries) {
    url <- sprintf("https://news.google.com/rss/search?q=%s&hl=en-US&gl=US&ceid=US:en",
                   utils::URLencode(q, reserved = TRUE))
    df <- tryCatch({
      resp <- httr::GET(url, httr::timeout(timeout),
                        httr::user_agent("Mozilla/5.0 (IMP-supply-monitor)"))
      if (httr::status_code(resp) >= 400) NULL
      else .parse_rss(read_xml(httr::content(resp, as = "raw")))
    }, error = function(e) NULL)
    if (!is.null(df) && nrow(df)) { df$Query <- q; rows[[length(rows) + 1L]] <- df }
  }

  if (length(rows) == 0) return(.fallback_news())

  news <- do.call(rbind, rows)
  news <- news[!duplicated(news$Title), , drop = FALSE]
  news$PublishedAt <- suppressWarnings(as.POSIXct(
    news$Published, format = "%a, %d %b %Y %H:%M:%S", tz = "GMT"))
  news <- news[order(news$PublishedAt, decreasing = TRUE), , drop = FALSE]
  news$Risk <- vapply(news$Title, .tag_risk, character(1))
  head(news, max_items)
}

# Curated offline fallback (clearly representative, not live).
.fallback_news <- function() {
  data.frame(
    Title = c(
      "[sample] Port strike on US West Coast delays container offloading",
      "[sample] Cold-chain failure spoils temperature-sensitive drug shipment",
      "[sample] Regulator flags manufacturing recall at contract fill-finish site",
      "[sample] New export controls tighten cross-border pharmaceutical shipping",
      "[sample] Air-freight capacity crunch raises clinical-supply lead times",
      "[sample] Hurricane disrupts logistics hubs across the Gulf Coast"
    ),
    Source = c("Logistics Wire", "Pharma Daily", "RegWatch",
               "Trade Journal", "Freight Report", "Weather Desk"),
    Published = "", Link = "https://news.google.com/",
    PublishedAt = as.POSIXct(NA),
    Query = "fallback",
    Risk = c("High", "High", "High", "Medium", "Medium", "High"),
    stringsAsFactors = FALSE
  )
}
