#!/usr/bin/env Rscript
# =========================================================================== #
# build_methodology_page.R  --  docs/METHODOLOGY.md as a page of the showcase
#
#   Rscript scripts/build_methodology_page.R           # write site/methodology.html
#   Rscript scripts/build_methodology_page.R --check   # exit 1 if the page is stale
#
# The Markdown stays the source. The page takes its styling from the <style>
# block of site/index.html, read at build time, so the two pages carry one set
# of MC² tokens and cannot drift apart; only the reading styles are added here.
# Links to other files in the repository point at them on GitHub.
# =========================================================================== #

suppressPackageStartupMessages(library(commonmark))
root <- normalizePath(file.path(dirname(sub("--file=", "",
          grep("--file=", commandArgs(FALSE), value = TRUE))[1]), ".."))
src  <- file.path(root, "docs/METHODOLOGY.md")
dst  <- file.path(root, "site/methodology.html")
REPO <- "https://github.com/rafaelcarlosabbariao/imp-supply-simulator"

md <- readLines(src, encoding = "UTF-8", warn = FALSE)
h1 <- sub("^#\\s+", "", md[grep("^#\\s", md)[1]])
md <- md[-grep("^#\\s", md)[1]]
body <- markdown_html(paste(md, collapse = "\n"), extensions = TRUE, smart = FALSE)

# Relative links go to the file on GitHub, resolved from docs/.
body <- gsub('href="(?!https?://|#|mailto:)([^"]+)"', 'href="__REL__\\1"', body, perl = TRUE)
rel <- regmatches(body, gregexpr('href="__REL__[^"]+"', body))[[1]]
for (r in unique(rel)) {
  path <- sub('^href="__REL__', "", sub('"$', "", r))
  file <- sub("#.*$", "", path); frag <- if (grepl("#", path)) sub("^[^#]*", "", path) else ""
  full <- normalizePath(file.path(root, "docs", file), mustWork = FALSE)
  repo_path <- sub(paste0("^", root, "/"), "", full)
  body <- gsub(r, sprintf('href="%s/blob/main/%s%s"', REPO, repo_path, frag), body, fixed = TRUE)
}

# Headings get ids, and the h2 and h3 make the contents.
slug <- function(x) {
  x <- tolower(gsub("<[^>]+>", "", x))
  x <- gsub("&[a-z]+;|&#[0-9]+;", "", x)
  x <- gsub("[^a-z0-9]+", "-", x)
  gsub("^-|-$", "", x)
}
toc <- character(0); seen <- character(0)
m <- gregexpr("<h([23])>(.*?)</h\\1>", body, perl = TRUE)
hs <- regmatches(body, m)[[1]]
for (h in hs) {
  lvl  <- sub("^<h([23])>.*$", "\\1", h)
  text <- sub("^<h[23]>(.*)</h[23]>$", "\\1", h)
  id <- slug(text); k <- id; n <- 1
  while (k %in% seen) { n <- n + 1; k <- paste0(id, "-", n) }
  seen <- c(seen, k)
  body <- sub(h, sprintf('<h%s id="%s">%s</h%s>', lvl, k, text, lvl), body, fixed = TRUE)
  toc <- c(toc, sprintf('<a class="l%s" href="#%s">%s</a>', lvl, k, gsub("<[^>]+>", "", text)))
}

# Wide tables scroll inside their own box, never the page.
body <- gsub("<table>", '<div class="tablewrap"><table>', body, fixed = TRUE)
body <- gsub("</table>", "</table></div>", body, fixed = TRUE)

# The showcase's own stylesheet, verbatim.
idx <- paste(readLines(file.path(root, "site/index.html"), encoding = "UTF-8", warn = FALSE), collapse = "\n")
style <- regmatches(idx, regexpr("<style>[\\s\\S]*?</style>", idx, perl = TRUE))
stopifnot(length(style) == 1)

reading_css <- '<style>
  /* Reading styles, added to the showcase sheet above for this page only. */
  header.hero{padding:48px 0 36px}
  header.hero h1{font-size:36px}
  .layout{display:grid;grid-template-columns:220px minmax(0,1fr);gap:48px;padding:40px 0 64px}
  .toc{position:sticky;top:24px;align-self:start;max-height:calc(100vh - 48px);overflow-y:auto;
       font-size:13px;line-height:1.4;border-left:1px solid var(--border);padding-left:14px}
  .toc p{font-size:12px;font-weight:500;letter-spacing:.08em;text-transform:uppercase;color:var(--muted);margin:0 0 10px}
  .toc a{display:block;color:var(--text);padding:4px 0}
  .toc a.l3{padding-left:12px;color:var(--muted)}
  .toc a:hover{color:var(--brand-text);text-decoration:none}
  details.toc-sm{display:none}
  article{max-width:46rem;min-width:0}
  article h2{font-size:24px;margin:48px 0 12px;padding-top:24px;border-top:1px solid var(--border)}
  article h2:first-child{margin-top:0;padding-top:0;border-top:0}
  article h3{font-size:18px;margin:32px 0 8px}
  article h2,article h3{scroll-margin-top:24px}
  article p,article li{font-size:16px}
  article ul,article ol{padding-left:1.4em}
  article li{margin:4px 0}
  article strong{color:var(--ink);font-weight:600}
  article hr{border:0;border-top:1px solid var(--border);margin:32px 0}
  article hr + h2{margin-top:0;padding-top:0;border-top:0}
  article blockquote{margin:16px 0;padding:12px 16px;background:var(--brand-wash);border-left:3px solid var(--brand);
       border-radius:0 var(--r-control) var(--r-control) 0;color:var(--text)}
  article blockquote p{margin:0}
  article pre{background:var(--surface-alt);border:1px solid var(--border);border-radius:var(--r-card);
       padding:14px 16px;overflow-x:auto;font-size:13px;line-height:1.5}
  article pre code{background:none;border:0;padding:0;font-size:13px;overflow-wrap:normal}
  .tablewrap{overflow-x:auto;margin:16px 0;border:1px solid var(--border);border-radius:var(--r-card);box-shadow:var(--shadow-card)}
  article table{border-collapse:collapse;width:100%;font-size:14px}
  article th{text-align:left;font-weight:600;color:var(--ink);background:var(--surface-alt);
       border-bottom:1px solid var(--border);padding:10px 12px;white-space:nowrap}
  article td{border-top:1px solid var(--border);padding:9px 12px;vertical-align:top}
  article tr:first-child td{border-top:0}
  article td code,article th code{white-space:nowrap}
  .source{font-size:13px;color:var(--muted);margin-top:40px;padding-top:16px;border-top:1px solid var(--border)}
  @media(max-width:900px){
    .layout{grid-template-columns:minmax(0,1fr);gap:0;padding-top:24px}
    .toc{display:none}
    details.toc-sm{display:block;margin:0 0 24px;border:1px solid var(--border);border-radius:var(--r-card);padding:10px 14px}
    details.toc-sm summary{cursor:pointer;font-size:14px;font-weight:500;color:var(--ink)}
    details.toc-sm a{display:block;font-size:14px;padding:4px 0;color:var(--text)}
    details.toc-sm a.l3{padding-left:12px;color:var(--muted)}
    header.hero h1{font-size:28px}
  }
</style>'

toc_html <- paste(toc, collapse = "\n      ")
page <- paste0('<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<!-- Generated by scripts/build_methodology_page.R from docs/METHODOLOGY.md. Edit the Markdown, then rebuild. -->
<title>Methodology · MC²</title>
<meta name="description" content="How MC² turns an enrollment plan and a dosing schedule into a demand forecast, and projects inventory forward to catch stockouts."/>
<link rel="canonical" href="https://imp-supply-chain-simulator.netlify.app/methodology.html"/>
<link rel="icon" type="image/svg+xml" href="favicon.svg"/>
<link rel="preconnect" href="https://fonts.googleapis.com"/>
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin/>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&display=swap" rel="stylesheet"/>
', style, '
', reading_css, '
</head>
<body>
<div class="topbar">
  <div class="wrap">
    <a class="lockup" href="index.html" aria-label="MC², Monte-Carlo clinical supply simulator: home">
      <span class="tile" aria-hidden="true">MC²</span>
      <span class="descriptor">Monte-Carlo clinical supply simulator</span>
    </a>
    <nav class="toplinks">
      <a class="toplink" href="index.html">Overview</a>
      <a class="toplink" href="', REPO, '" target="_blank" rel="noopener">GitHub</a>
    </nav>
  </div>
</div>

<header class="hero">
  <div class="wrap">
    <p class="eyebrow brand">Methodology</p>
    <h1>', h1, '</h1>
    <p class="provenance">The technical write-up, rendered from
      <a href="', REPO, '/blob/main/docs/METHODOLOGY.md" target="_blank" rel="noopener"><code>docs/METHODOLOGY.md</code></a>
      in the repository.</p>
  </div>
</header>

<div class="wrap">
  <div class="layout">
    <nav class="toc" aria-label="Contents">
      <p>Contents</p>
      ', toc_html, '
    </nav>
    <article>
    <details class="toc-sm"><summary>Contents</summary>
      ', toc_html, '
    </details>
', body, '
    <p class="source">Source: <a href="', REPO, '/blob/main/docs/METHODOLOGY.md" target="_blank" rel="noopener">docs/METHODOLOGY.md</a>.
      All sample data is synthetic. <a href="index.html">Back to the overview</a>.</p>
    </article>
  </div>
</div>

<footer>
  <div class="wrap">
    <p><a href="index.html">MC² overview</a> · <a href="', REPO, '" rel="noopener">GitHub repository</a></p>
    <p>Built with R · Shiny · plotly · a hand-rolled (s,&nbsp;S) inventory engine</p>
  </div>
</footer>
</body>
</html>
')

if ("--check" %in% commandArgs(trailingOnly = TRUE)) {
  cur <- if (file.exists(dst)) paste(readLines(dst, encoding = "UTF-8", warn = FALSE), collapse = "\n") else ""
  if (!identical(cur, sub("\n$", "", page))) {
    cat("site/methodology.html is stale: run Rscript scripts/build_methodology_page.R\n")
    quit(status = 1L)
  }
  cat("site/methodology.html is current\n")
} else {
  writeLines(sub("\n$", "", page), dst, useBytes = TRUE)
  cat(sprintf("wrote %s: %d sections\n", dst, length(toc)))
}
