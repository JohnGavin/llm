#!/usr/bin/env Rscript
# send_roborev_email.R — Send daily roborev resolution report via Gmail.
#
# Reads the latest JSON snapshot from $ROBOREV_DAILY_DIR (default
# ~/.claude/logs/roborev_daily_report/) and sends an HTML email via blastula.
#
# Required env vars:
#   GMAIL_USERNAME       Gmail address (sender + credential lookup)
#   GMAIL_APP_PASSWORD   Gmail app password
#   REPORT_RECIPIENT     Recipient address (falls back to GMAIL_USERNAME)
#   ROBOREV_DASHBOARD_URL  Dashboard link (optional; default provided)
#
# Optional env vars:
#   ROBOREV_DAILY_DIR   Override daily report directory
#   EMAIL_DRY_RUN       Set to "1" to print body to stdout without sending
#
# Usage:
#   Rscript .claude/scripts/send_roborev_email.R
#   EMAIL_DRY_RUN=1 Rscript .claude/scripts/send_roborev_email.R
#
# Called from bin/roborev_daily_cron.sh.
# Tracked in llm#287.

suppressPackageStartupMessages({
  library(blastula)
  library(jsonlite)
})

# ── Shared email styles (font sizes, palette, collapsible_block helper) ───────

.scripts_dir_rr <- tryCatch(
  dirname(normalizePath(sys.frame(0L)$ofile, mustWork = FALSE)),
  error = function(e) {
    args <- commandArgs(trailingOnly = FALSE)
    idx  <- grep("^--file=", args)
    if (length(idx)) dirname(normalizePath(sub("^--file=", "", args[idx]), mustWork = FALSE))
    else dirname(normalizePath(file.path(Sys.getenv("HOME"), "docs_gh", "llm",
                                          ".claude", "scripts", "email_styles.R"),
                               mustWork = FALSE))
  }
)
source(file.path(.scripts_dir_rr, "email_styles.R"))

# ── Configuration ──────────────────────────────────────────────────────────────

ROBOREV_DAILY_DIR <- Sys.getenv(
  "ROBOREV_DAILY_DIR",
  file.path(Sys.getenv("HOME"), ".claude", "logs", "roborev_daily_report")
)

ROBOREV_DASHBOARD_URL <- Sys.getenv(
  "ROBOREV_DASHBOARD_URL",
  "https://johngavin.github.io/llmtelemetry/#roborev"
)

dry_run <- identical(Sys.getenv("EMAIL_DRY_RUN"), "1")

# ── Locate latest JSON snapshot ────────────────────────────────────────────────

find_latest_json <- function(dir) {
  if (!dir.exists(dir)) return(NULL)
  files <- list.files(dir, pattern = "^\\d{4}-\\d{2}-\\d{2}\\.json$",
                      full.names = TRUE)
  if (length(files) == 0L) return(NULL)
  files[which.max(file.info(files)$mtime)]
}

json_path <- find_latest_json(ROBOREV_DAILY_DIR)

if (is.null(json_path)) {
  message(sprintf(
    "send_roborev_email.R: no JSON snapshot found in %s\n",
    "Run .claude/scripts/roborev_daily_report.R --apply first.",
    ROBOREV_DAILY_DIR
  ))
  quit(status = 1L)
}

message(sprintf("send_roborev_email.R: reading snapshot %s", json_path))

snap <- tryCatch(
  jsonlite::fromJSON(json_path, simplifyVector = FALSE),
  error = function(e) {
    message("send_roborev_email.R: failed to parse JSON: ", conditionMessage(e))
    quit(status = 1L)
  }
)

# ── Colour palette — aliases to shared constants from email_styles.R ──────────

dark_bg      <- DARK_BG
dark_card    <- DARK_CARD
dark_row_alt <- DARK_ROW_ALT
dark_text    <- DARK_TEXT
dark_muted   <- DARK_MUTED
dark_border  <- DARK_BORDER
accent_green  <- ACCENT_GREEN
accent_blue   <- ACCENT_BLUE
accent_orange <- ACCENT_ORANGE
accent_purple <- ACCENT_PURPLE

# ── Formatting helpers ─────────────────────────────────────────────────────────

fmt_hrs  <- function(x) if (is.null(x) || is.na(x)) "n/a" else sprintf("%.1fh", as.numeric(x))
fmt_num  <- function(x) if (is.null(x) || is.na(x)) "n/a" else sprintf("%.1f", as.numeric(x))  # bare number (no unit suffix) — llm#449
fmt_att  <- function(x) if (is.null(x) || is.na(x)) "n/a" else sprintf("%.1f", as.numeric(x))
fmt_rate <- function(x) {
  if (is.null(x) || is.na(x)) return("n/a")
  sprintf("%.1f%%", as.numeric(x) * 100)
}
fmt_trend <- function(td) {
  if (is.null(td)) return("n/a")
  pct <- td[["pct_delta"]]
  abs_d <- td[["abs_delta"]]
  if (is.null(pct) || is.na(pct)) {
    if (!is.null(abs_d) && !is.na(abs_d)) return(sprintf("Δ%.2f", abs_d))
    return("n/a")
  }
  dir <- if (pct > 0) "&#9650;" else if (pct < 0) "&#9660;" else "="
  sprintf("%s%.0f%%", dir, abs(pct))
}
fmt_int  <- function(x) if (is.null(x) || is.na(x)) "0" else formatC(as.integer(x), format = "d", big.mark = ",")

# ── Extract window slices ──────────────────────────────────────────────────────

d1 <- snap[["global_windows"]][["d1"]]  # 1-day window — llm#449
d7 <- snap[["global_windows"]][["d7"]]

# §1 Frequency table
freq_rows <- d7[["freq_table"]]
issues_found_closed <- 0L
issues_found_open   <- 0L
clean_closed        <- 0L
clean_open          <- 0L
for (row in freq_rows) {
  v <- row[["verdict_label"]]; s <- row[["status"]]; n <- as.integer(row[["n"]])
  if (identical(v, "issues_found") && identical(s, "closed")) issues_found_closed <- n
  if (identical(v, "issues_found") && identical(s, "open"))   issues_found_open   <- n
  if (identical(v, "clean")        && identical(s, "closed")) clean_closed        <- n
  if (identical(v, "clean")        && identical(s, "open"))   clean_open          <- n
}

# §2 Speed
sp <- d7[["speed"]]
ttc_p50 <- sp[["ttc_p50_hrs"]]
ttc_p90 <- sp[["ttc_p90_hrs"]]
close_rate <- sp[["close_rate"]]
att_p50 <- sp[["att_p50"]]
att_p90 <- sp[["att_p90"]]

# §3 Trends
tr <- d7[["trends"]]

# §4 Outliers (top-5 of top-10)
outliers_by_time <- snap[["outliers_14d"]][["by_time"]]
if (is.null(outliers_by_time)) outliers_by_time <- list()
n_outliers <- min(5L, length(outliers_by_time))

outliers_by_att <- snap[["outliers_14d"]][["by_attempts"]]
if (is.null(outliers_by_att)) outliers_by_att <- list()
n_outliers_att <- min(5L, length(outliers_by_att))

# ── Extract 1-day metrics for headline (llm#449) ──────────────────────────────

d1_freq_rows <- if (!is.null(d1)) d1[["freq_table"]] else list()
d1_found_closed <- 0L; d1_found_open <- 0L; d1_clean_closed <- 0L; d1_clean_open <- 0L
d1_other_n <- 0L  # llm#484: count unmatched verdict/status pairs
for (row in d1_freq_rows) {
  v <- row[["verdict_label"]]; s <- row[["status"]]; n <- as.integer(row[["n"]])
  matched <- FALSE
  if (identical(v, "issues_found") && identical(s, "closed")) { d1_found_closed <- n; matched <- TRUE }
  if (identical(v, "issues_found") && identical(s, "open"))   { d1_found_open   <- n; matched <- TRUE }
  if (identical(v, "clean")        && identical(s, "closed")) { d1_clean_closed <- n; matched <- TRUE }
  if (identical(v, "clean")        && identical(s, "open"))   { d1_clean_open   <- n; matched <- TRUE }
  if (!matched) d1_other_n <- d1_other_n + n
}
d1_sp <- if (!is.null(d1)) d1[["speed"]] else list()
d1_ttc_p50 <- d1_sp[["ttc_p50_hrs"]]; d1_close_rate <- d1_sp[["close_rate"]]
d1_att_p50 <- d1_sp[["att_p50"]]

# ── Build headline summary table (Metric | Value — no bar/pie charts) ─────────

report_date <- snap[["report_date"]] %||% format(Sys.Date())
generated_at <- snap[["generated_at"]] %||% format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
lineage_src  <- snap[["lineage_source"]] %||% "unknown"

`%||%` <- function(a, b) if (!is.null(a) && !is.na(a)) a else b

# ── HTML email body ────────────────────────────────────────────────────────────

# §1 + §2 Headline Metrics (last 24h) — shown FIRST (llm#449, llm#484)
# Derive UTC window bounds from report_date + window_days (no producer changes needed)
d1_window_end_dt   <- tryCatch(
  as.POSIXct(paste0(report_date, "T00:00:00"), tz = "UTC"),
  error = function(e) Sys.time()
)
d1_window_start_dt <- d1_window_end_dt - 86400  # 24h earlier
d1_window_caption  <- sprintf(
  "Headline Metrics (last 24h: %s &#8594; %s UTC)",
  format(d1_window_start_dt, "%Y-%m-%d %H:%M", tz = "UTC"),
  format(d1_window_end_dt,   "%Y-%m-%d %H:%M", tz = "UTC")
)

d1_n_reviews <- if (!is.null(d1)) as.integer(d1[["n_reviews"]] %||% 0L) else 0L

# ── #484: zero-action trap ─────────────────────────────────────────────────────
# When n_reviews > 0 but all action metrics are zero/NA, the JSON is likely stale.
# Attempt an ETL refresh; if it stays zero-action, emit a loud error block.

zero_action_fired <- FALSE

.d1_has_reviews <- isTRUE(!is.null(d1_n_reviews) && d1_n_reviews > 0L)
.d1_no_close    <- isTRUE(is.null(d1_close_rate) || is.na(d1_close_rate) || d1_close_rate == 0)
.d1_no_ttc      <- isTRUE(is.null(d1_ttc_p50) || is.na(d1_ttc_p50))
.d1_no_att      <- isTRUE(is.null(d1_att_p50) || is.na(d1_att_p50))

if (.d1_has_reviews && .d1_no_close && .d1_no_ttc && .d1_no_att) {
  message("send_roborev_email.R: zero-action trap fired — attempting ETL refresh")
  etl_script <- file.path(.scripts_dir_rr, "roborev_metrics_etl.sh")
  if (file.exists(etl_script)) {
    system2("bash", args = c(etl_script, "--apply"),
            stdout = FALSE, stderr = FALSE, timeout = 30L)
    # Re-read latest JSON after ETL refresh
    json_path_new <- find_latest_json(ROBOREV_DAILY_DIR)
    if (!is.null(json_path_new)) {
      snap_new <- tryCatch(
        jsonlite::fromJSON(json_path_new, simplifyVector = FALSE),
        error = function(e) NULL
      )
      if (!is.null(snap_new)) {
        snap <- snap_new
        json_path <- json_path_new
        # Re-extract d1 after refresh; also update n_reviews
        d1 <- snap[["global_windows"]][["d1"]]
        d1_sp_new <- if (!is.null(d1)) d1[["speed"]] else list()
        d1_ttc_p50    <- d1_sp_new[["ttc_p50_hrs"]]
        d1_close_rate <- d1_sp_new[["close_rate"]]
        d1_att_p50    <- d1_sp_new[["att_p50"]]
        d1_n_reviews  <- if (!is.null(d1)) as.integer(d1[["n_reviews"]] %||% 0L) else 0L
      }
    }
  }
  # Re-check: if still zero-action, set flag
  .d1_no_close2 <- isTRUE(is.null(d1_close_rate) || is.na(d1_close_rate) || d1_close_rate == 0)
  .d1_no_ttc2   <- isTRUE(is.null(d1_ttc_p50) || is.na(d1_ttc_p50))
  .d1_no_att2   <- isTRUE(is.null(d1_att_p50) || is.na(d1_att_p50))
  if (.d1_no_close2 && .d1_no_ttc2 && .d1_no_att2) {
    zero_action_fired <- TRUE
    message("send_roborev_email.R: zero-action trap still active after ETL refresh")
  }
}

# Zero-action error block (prepended before dashboard CTA when fired — llm#484)
zero_action_block <- if (zero_action_fired) {
  sprintf(
    '<div style="background-color:#5b1a1a; color:#fff5f5; border:2px solid #f08080;
      border-radius:6px; padding:14px 18px; margin:16px 0; font-size:%s;">
      <strong style="font-size:15px;">&#9888; Zero-Action Data Detected</strong><br>
      <span>%d review(s) were recorded in the 24h window but all action metrics
      (close rate, time-to-close, attempt count) are zero or missing. ETL refresh
      was attempted but the issue persists. Check the roborev daemon and ETL
      pipeline for upstream errors before acting on this report.</span>
    </div>',
    EMAIL_FONT_BODY, d1_n_reviews
  )
} else ""

# Dashboard link CTA (llm#484: zero_action_block prepended when trap fires)
dashboard_block <- paste0(
  zero_action_block,
  sprintf(
    '<div style="margin: 16px 0;">
  <a href="%s"
     style="display:inline-block; padding:10px 20px; background-color:%s;
            color:#1a1a2e; text-decoration:none; border-radius:4px;
            font-weight:bold; font-size:13px;">
    View Full roborev Dashboard
  </a>
</div>',
    ROBOREV_DASHBOARD_URL, accent_blue
  )
)

headline_1d_inner <- sprintf(
  '<table style="border-collapse:collapse; width:100%%; font-size:12px;">
  <tr style="background-color:%s;">
    <th style="padding:6px 8px; border:1px solid %s; color:white; text-align:left;">Metric</th>
    <th style="padding:6px 8px; border:1px solid %s; color:white; text-align:right;">Value</th>
  </tr>',
  dark_row_alt, dark_border, dark_border
)

if (is.null(d1) || d1_n_reviews == 0L) {
  # llm#484: empty-state single-row diagnostic instead of 7 boilerplate zeros
  headline_1d_inner <- paste0(headline_1d_inner, sprintf(
    '<tr style="background-color:%s;">
      <td colspan="2" style="padding:6px 8px; border:1px solid %s; color:%s; font-style:italic;">
        <!-- QA:24h_empty_state -->No reviews logged in this window — see dashboard for full context
      </td>
    </tr>',
    dark_card, dark_border, dark_muted
  ))
} else {
  headline_1d_rows <- list(
    c("24h: reviews in window",       fmt_int(d1_n_reviews)),        # llm#484: n_reviews FIRST
    c("24h: issues found (closed)",   fmt_int(d1_found_closed)),
    c("24h: issues found (open)",     fmt_int(d1_found_open)),
    c("24h: clean (closed)",          fmt_int(d1_clean_closed)),
    c("24h: clean (open)",            fmt_int(d1_clean_open)),
    c("24h: close rate",              fmt_rate(d1_close_rate)),
    c("24h: hours to close p50",      fmt_num(d1_ttc_p50)),
    c("24h: attempts p50",            fmt_att(d1_att_p50))
  )
  # llm#484: append Other verdicts row when there are unmatched entries
  if (d1_other_n > 0L) {
    headline_1d_rows <- c(headline_1d_rows,
      list(c("24h: other verdicts", fmt_int(d1_other_n))))
  }
  for (i in seq_along(headline_1d_rows)) {
    bg <- if (i %% 2 == 0) dark_row_alt else dark_card
    headline_1d_inner <- paste0(headline_1d_inner, sprintf(
      '<tr style="background-color:%s;">
        <td style="padding:5px 8px; border:1px solid %s; color:%s;">%s</td>
        <td style="padding:5px 8px; border:1px solid %s; color:%s; text-align:right;">%s</td>
      </tr>',
      bg,
      dark_border, dark_text, headline_1d_rows[[i]][1],
      dark_border, accent_green, headline_1d_rows[[i]][2]
    ))
  }
}
headline_1d_inner <- paste0(headline_1d_inner, "</table>")
# llm#527: wrap 24h table in collapsible_block(open=TRUE) so it starts expanded
headline_1d_html <- collapsible_block(
  d1_window_caption,
  sprintf("%d review(s) in window", d1_n_reviews),
  headline_1d_inner,
  open = TRUE
)

# §1 + §2 Headline two-column table (7-day)
d7_n_reviews <- if (!is.null(d7)) as.integer(d7[["n_reviews"]] %||% 0L) else 0L
headline_rows <- list(
  c("7d: reviews in window",      fmt_int(d7_n_reviews)),            # llm#484: n_reviews FIRST
  c("7d: issues found (closed)",  fmt_int(issues_found_closed)),
  c("7d: issues found (open)",    fmt_int(issues_found_open)),
  c("7d: clean (closed)",         fmt_int(clean_closed)),
  c("7d: clean (open)",           fmt_int(clean_open)),
  c("7d: close rate",             fmt_rate(close_rate)),
  c("7d: TTC p50",                fmt_hrs(ttc_p50)),
  c("7d: TTC p90",                fmt_hrs(ttc_p90)),
  c("7d: attempts p50",           fmt_att(att_p50)),
  c("7d: attempts p90",           fmt_att(att_p90))
)

headline_table_inner <- sprintf(
  '<table style="border-collapse:collapse; width:100%%; font-size:%s;">
  <tr style="background-color:%s;">
    <th style="padding:6px 8px; border:1px solid %s; color:white; text-align:left;">Metric</th>
    <th style="padding:6px 8px; border:1px solid %s; color:white; text-align:right;">Value</th>
  </tr>',
  EMAIL_FONT_BODY, dark_row_alt, dark_border, dark_border
)
for (i in seq_along(headline_rows)) {
  bg <- if (i %% 2 == 0) dark_row_alt else dark_card
  headline_table_inner <- paste0(headline_table_inner, sprintf(
    '<tr style="background-color:%s;">
      <td style="padding:5px 8px; border:1px solid %s; color:%s;">%s</td>
      <td style="padding:5px 8px; border:1px solid %s; color:%s; text-align:right;">%s</td>
    </tr>',
    bg,
    dark_border, dark_text, headline_rows[[i]][1],
    dark_border, accent_green, headline_rows[[i]][2]
  ))
}
headline_table_inner <- paste0(headline_table_inner, "</table>")
headline_html <- collapsible_block(
  "Headline Metrics (7-day)",
  sprintf("close rate: %s  •  TTC p50: %s", fmt_rate(close_rate), fmt_hrs(ttc_p50)),
  headline_table_inner
)

# §3 Trends two-column table
trends_table_inner <- sprintf(
  '<table style="border-collapse:collapse; width:100%%; font-size:%s;">
  <tr style="background-color:%s;">
    <th style="padding:6px 8px; border:1px solid %s; color:white; text-align:left;">Metric</th>
    <th style="padding:6px 8px; border:1px solid %s; color:white; text-align:right;">Change</th>
  </tr>',
  EMAIL_FONT_BODY, dark_row_alt, dark_border, dark_border
)
trend_rows <- list(
  c("TTC p50",    fmt_trend(tr[["ttc_p50"]])),
  c("TTC p90",    fmt_trend(tr[["ttc_p90"]])),
  c("Att p50",    fmt_trend(tr[["att_p50"]])),
  c("Close rate", fmt_trend(tr[["close_rate"]]))
)
for (i in seq_along(trend_rows)) {
  bg <- if (i %% 2 == 0) dark_row_alt else dark_card
  trends_table_inner <- paste0(trends_table_inner, sprintf(
    '<tr style="background-color:%s;">
      <td style="padding:5px 8px; border:1px solid %s; color:%s;">%s</td>
      <td style="padding:5px 8px; border:1px solid %s; color:%s; text-align:right;">%s</td>
    </tr>',
    bg,
    dark_border, dark_text, trend_rows[[i]][1],
    dark_border, accent_blue, trend_rows[[i]][2]
  ))
}
trends_table_inner <- paste0(trends_table_inner, "</table>")
trends_html <- collapsible_block(
  "Trends (7d vs prior 7d)", "Click to expand", trends_table_inner
)

# §4 Outliers — top-5 by time-to-close (llm#449: linkified IDs+Repos, renamed TTC header)
outlier_ttc_inner <- sprintf(
  '<p style="color:%s; font-size:%s; margin-bottom:6px;">Full detail (top-10) in the JSON snapshot and on the dashboard.</p>
<table style="border-collapse:collapse; width:100%%; font-size:%s;">
  <tr style="background-color:%s;">
    <th style="padding:5px; border:1px solid %s; color:white;">ID</th>
    <th style="padding:5px; border:1px solid %s; color:white;">Repo</th>
    <th style="padding:5px; border:1px solid %s; color:white; text-align:right;">Hours to close (h)</th>
    <th style="padding:5px; border:1px solid %s; color:white; text-align:right;">Attempts</th>
    <th style="padding:5px; border:1px solid %s; color:white;">Reason</th>
  </tr>',
  dark_muted, EMAIL_FONT_SUBTITLE, EMAIL_FONT_BODY,
  dark_row_alt, dark_border, dark_border, dark_border, dark_border, dark_border
)
if (n_outliers > 0L) {
  for (i in seq_len(n_outliers)) {
    r <- outliers_by_time[[i]]
    bg <- if (i %% 2 == 0) dark_row_alt else dark_card
    rid  <- r[["review_id"]] %||% ""
    repo <- r[["repo"]] %||% ""
    id_link   <- if (nzchar(rid) && nzchar(repo))
      sprintf('<a href="https://github.com/JohnGavin/%s/issues/%s" style="color:%s;">%s</a>',
              repo, rid, accent_blue, rid)
    else rid
    repo_link <- if (nzchar(repo))
      sprintf('<a href="https://github.com/JohnGavin/%s" style="color:%s;">%s</a>',
              repo, accent_blue, repo)
    else repo
    outlier_ttc_inner <- paste0(outlier_ttc_inner, sprintf(
      '<tr style="background-color:%s;">
        <td style="padding:4px 5px; border:1px solid %s; color:%s;">%s</td>
        <td style="padding:4px 5px; border:1px solid %s; color:%s;">%s</td>
        <td style="padding:4px 5px; border:1px solid %s; color:%s; text-align:right;">%s</td>
        <td style="padding:4px 5px; border:1px solid %s; color:%s; text-align:right;">%s</td>
        <td style="padding:4px 5px; border:1px solid %s; color:%s;">%s</td>
      </tr>',
      bg,
      dark_border, accent_blue, id_link,
      dark_border, dark_text, repo_link,
      dark_border, accent_orange, fmt_num(r[["time_to_close_hrs"]]),
      dark_border, dark_text, fmt_int(r[["n_attempts"]]),
      dark_border, dark_muted, r[["close_reason"]] %||% ""
    ))
  }
} else {
  outlier_ttc_inner <- paste0(outlier_ttc_inner,
    sprintf('<tr><td colspan="5" style="padding:6px; color:%s;">(no data in 14-day window)</td></tr>', dark_muted))
}
outlier_ttc_inner <- paste0(outlier_ttc_inner, "</table>")
outlier_ttc_html  <- collapsible_block(
  "Top-5 Outliers by Time-to-Close (14d)",
  sprintf("%d outlier(s) — click to expand", n_outliers),
  outlier_ttc_inner
)

# §4 Outliers — top-5 by attempts (llm#449: linkified IDs+Repos, renamed TTC header)
outlier_att_inner <- sprintf(
  '<table style="border-collapse:collapse; width:100%%; font-size:%s;">
  <tr style="background-color:%s;">
    <th style="padding:5px; border:1px solid %s; color:white;">ID</th>
    <th style="padding:5px; border:1px solid %s; color:white;">Repo</th>
    <th style="padding:5px; border:1px solid %s; color:white; text-align:right;">Attempts</th>
    <th style="padding:5px; border:1px solid %s; color:white; text-align:right;">Hours to close (h)</th>
    <th style="padding:5px; border:1px solid %s; color:white;">Reason</th>
  </tr>',
  EMAIL_FONT_BODY, dark_row_alt, dark_border, dark_border, dark_border, dark_border, dark_border
)
if (n_outliers_att > 0L) {
  for (i in seq_len(n_outliers_att)) {
    r <- outliers_by_att[[i]]
    bg <- if (i %% 2 == 0) dark_row_alt else dark_card
    rid  <- r[["review_id"]] %||% ""
    repo <- r[["repo"]] %||% ""
    id_link   <- if (nzchar(rid) && nzchar(repo))
      sprintf('<a href="https://github.com/JohnGavin/%s/issues/%s" style="color:%s;">%s</a>',
              repo, rid, accent_blue, rid)
    else rid
    repo_link <- if (nzchar(repo))
      sprintf('<a href="https://github.com/JohnGavin/%s" style="color:%s;">%s</a>',
              repo, accent_blue, repo)
    else repo
    outlier_att_inner <- paste0(outlier_att_inner, sprintf(
      '<tr style="background-color:%s;">
        <td style="padding:4px 5px; border:1px solid %s; color:%s;">%s</td>
        <td style="padding:4px 5px; border:1px solid %s; color:%s;">%s</td>
        <td style="padding:4px 5px; border:1px solid %s; color:%s; text-align:right;">%s</td>
        <td style="padding:4px 5px; border:1px solid %s; color:%s; text-align:right;">%s</td>
        <td style="padding:4px 5px; border:1px solid %s; color:%s;">%s</td>
      </tr>',
      bg,
      dark_border, accent_blue, id_link,
      dark_border, dark_text, repo_link,
      dark_border, accent_orange, fmt_int(r[["n_attempts"]]),
      dark_border, dark_text, fmt_num(r[["time_to_close_hrs"]]),
      dark_border, dark_muted, r[["close_reason"]] %||% ""
    ))
  }
} else {
  outlier_att_inner <- paste0(outlier_att_inner,
    sprintf('<tr><td colspan="5" style="padding:6px; color:%s;">(no data in 14-day window)</td></tr>', dark_muted))
}
outlier_att_inner <- paste0(outlier_att_inner, "</table>")
outlier_att_html  <- collapsible_block(
  "Top-5 Outliers by Attempts-to-Close (14d)",
  sprintf("%d outlier(s) — click to expand", n_outliers_att),
  outlier_att_inner
)

# §5 Per-project severity frequency table (llm#449)
severity_rows_data <- snap[["severity_by_project_7d"]]
if (is.null(severity_rows_data)) severity_rows_data <- list()

severity_inner <- sprintf(
  '<table style="border-collapse:collapse; width:100%%; font-size:11px;">
  <tr style="background-color:%s;">
    <th style="padding:5px 8px; border:1px solid %s; color:white; text-align:left;">Project</th>
    <th style="padding:5px; border:1px solid %s; color:white; text-align:right;">High</th>
    <th style="padding:5px; border:1px solid %s; color:white; text-align:right;">Medium</th>
    <th style="padding:5px; border:1px solid %s; color:white; text-align:right;">Low</th>
    <th style="padding:5px; border:1px solid %s; color:white; text-align:right;">Total</th>
  </tr>',
  dark_row_alt, dark_border, dark_border, dark_border, dark_border, dark_border
)
if (length(severity_rows_data) > 0L) {
  for (i in seq_along(severity_rows_data)) {
    sr <- severity_rows_data[[i]]
    bg <- if (i %% 2 == 0) dark_row_alt else dark_card
    repo_val <- sr[["repo"]] %||% ""
    repo_link <- if (nzchar(repo_val))
      sprintf('<a href="https://github.com/JohnGavin/%s" style="color:%s;">%s</a>',
              repo_val, accent_blue, repo_val)
    else repo_val
    severity_inner <- paste0(severity_inner, sprintf(
      '<tr style="background-color:%s;">
        <td style="padding:4px 8px; border:1px solid %s; color:%s;">%s</td>
        <td style="padding:4px 5px; border:1px solid %s; color:%s; text-align:right;">%s</td>
        <td style="padding:4px 5px; border:1px solid %s; color:%s; text-align:right;">%s</td>
        <td style="padding:4px 5px; border:1px solid %s; color:%s; text-align:right;">%s</td>
        <td style="padding:4px 5px; border:1px solid %s; color:%s; text-align:right; font-weight:bold;">%s</td>
      </tr>',
      bg,
      dark_border, dark_text, repo_link,
      dark_border, accent_orange, fmt_int(sr[["High"]]),
      dark_border, accent_blue, fmt_int(sr[["Medium"]]),
      dark_border, dark_muted, fmt_int(sr[["Low"]]),
      dark_border, dark_text, fmt_int(sr[["Total"]])
    ))
  }
} else {
  severity_inner <- paste0(severity_inner,
    sprintf('<tr><td colspan="5" style="padding:6px; color:%s;">(no data in 7-day window)</td></tr>', dark_muted))
}
severity_inner <- paste0(severity_inner, "</table>")
# llm#527: wrap severity table in collapsible_block(open=FALSE) — collapsed by default
# llm#534: caption updated to reflect canonical-only filtering
severity_html <- collapsible_block(
  "Severity by Project (7d, canonical only — see #528)",
  sprintf("%d project(s) tracked", length(severity_rows_data)),
  severity_inner,
  open = FALSE
)

# QA markers (tested by test-send-roborev-email.R)
# llm#484: added n_reviews and d1_n_reviews markers for diagnostic visibility
qa_markers <- sprintf(
  '<!-- QA:report_date=%s --><!-- QA:issues_found_closed=%d --><!-- QA:close_rate=%s --><!-- QA:dashboard_url=%s --><!-- QA:d1_n_reviews=%d --><!-- QA:d7_n_reviews=%d --><!-- QA:d1_other_n=%d --><!-- QA:zero_action_trap_fired=%s -->',
  report_date, issues_found_closed, fmt_rate(close_rate), ROBOREV_DASHBOARD_URL,
  d1_n_reviews, d7_n_reviews, d1_other_n, tolower(as.character(zero_action_fired))
)

# Assemble full body
email_body <- sprintf(
  '<div style="background-color:%s; color:%s; padding:20px;
               font-family:-apple-system,BlinkMacSystemFont,\'Segoe UI\',sans-serif;
               font-size:%s;">
<h2 style="color:%s; margin-bottom:4px; font-size:%s;">roborev Daily Report — %s</h2>
<p style="color:%s; font-size:%s; margin-top:0;">
  Generated: %s UTC &nbsp;|&nbsp; Lineage: %s
</p>
%s
%s
%s
%s
%s
%s
%s
<p style="color:%s; font-size:%s; margin-top:20px;">
  JSON snapshot: %s
</p>
%s
</div>',
  dark_bg, dark_text, EMAIL_FONT_BODY,
  accent_orange, EMAIL_FONT_H2, report_date,
  dark_muted, EMAIL_FONT_SUBTITLE, generated_at, lineage_src,
  dashboard_block,
  headline_1d_html,
  headline_html,
  trends_html,
  outlier_ttc_html,
  outlier_att_html,
  severity_html,
  dark_muted, EMAIL_FONT_FOOTER, json_path,
  qa_markers
)

# ── Dry-run mode ───────────────────────────────────────────────────────────────

if (dry_run) {
  message("send_roborev_email.R: EMAIL_DRY_RUN=1 — printing body to stdout")
  cat(email_body, "\n")
  message("send_roborev_email.R: dry-run complete (not sent)")
  quit(status = 0L)
}

# ── Credentials ────────────────────────────────────────────────────────────────

gmail_user <- Sys.getenv("GMAIL_USERNAME", "")
gmail_pass <- Sys.getenv("GMAIL_APP_PASSWORD", "")

if (!nzchar(gmail_user) || !nzchar(gmail_pass)) {
  message("send_roborev_email.R: GMAIL_USERNAME or GMAIL_APP_PASSWORD not set")
  message("  Set in local env file sourced by bin/roborev_daily_cron.sh")
  cat("\n--- Email body (credentials missing, not sent) ---\n")
  cat(email_body, "\n")
  quit(status = 1L)
}

report_to <- Sys.getenv("REPORT_RECIPIENT", "")
if (!nzchar(report_to)) report_to <- gmail_user

# ── Compose and send ───────────────────────────────────────────────────────────

london_time <- format(Sys.time(), tz = "Europe/London", "%Y-%m-%d %H:%M")

email <- compose_email(
  body   = md(email_body),
  footer = md(sprintf(
    "<span style='color:%s;'>Sent: %s (London)</span>",
    dark_muted, london_time
  ))
)

smtp_creds <- creds_envvar(
  user        = gmail_user,
  pass_envvar = "GMAIL_APP_PASSWORD",
  host        = "smtp.gmail.com",
  port        = 465,
  use_ssl     = TRUE
)

tryCatch({
  smtp_send(
    email       = email,
    to          = report_to,
    from        = gmail_user,
    subject     = sprintf("roborev Daily Report — %s", report_date),
    credentials = smtp_creds
  )
  message(sprintf("send_roborev_email.R: email sent to %s", report_to))
}, error = function(e) {
  message("send_roborev_email.R: SMTP send failed — ", conditionMessage(e))
  cat("\n--- Email body (SMTP failed) ---\n")
  cat(email_body, "\n")
  quit(status = 1L)
})
