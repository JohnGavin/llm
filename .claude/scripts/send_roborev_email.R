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

# ── Colour palette (dark-mode safe, matches llmtelemetry convention) ──────────

dark_bg     <- "#1a1a2e"
dark_card   <- "#16213e"
dark_row_alt <- "#0f3460"
dark_text   <- "#e8e8e8"
dark_muted  <- "#a0a0a0"
dark_border <- "#2a2a4a"
accent_green  <- "#00d26a"
accent_blue   <- "#4fc3f7"
accent_orange <- "#ff9800"
accent_purple <- "#bb86fc"

# ── Formatting helpers ─────────────────────────────────────────────────────────

fmt_hrs  <- function(x) if (is.null(x) || is.na(x)) "n/a" else sprintf("%.1fh", as.numeric(x))
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

# ── Extract 7-day window slice ─────────────────────────────────────────────────

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

# ── Build headline summary table (Metric | Value — no bar/pie charts) ─────────

report_date <- snap[["report_date"]] %||% format(Sys.Date())
generated_at <- snap[["generated_at"]] %||% format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
lineage_src  <- snap[["lineage_source"]] %||% "unknown"

`%||%` <- function(a, b) if (!is.null(a) && !is.na(a)) a else b

# ── HTML email body ────────────────────────────────────────────────────────────

# Dashboard link CTA
dashboard_block <- sprintf(
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

# §1 + §2 Headline two-column table
headline_rows <- list(
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

headline_html <- sprintf(
  '<h3 style="color:%s; margin-top:20px;">Headline Metrics (7-day)</h3>
<table style="border-collapse:collapse; width:100%%; font-size:12px;">
  <tr style="background-color:%s;">
    <th style="padding:6px 8px; border:1px solid %s; color:white; text-align:left;">Metric</th>
    <th style="padding:6px 8px; border:1px solid %s; color:white; text-align:right;">Value</th>
  </tr>',
  accent_orange, dark_row_alt, dark_border, dark_border
)
for (i in seq_along(headline_rows)) {
  bg <- if (i %% 2 == 0) dark_row_alt else dark_card
  headline_html <- paste0(headline_html, sprintf(
    '<tr style="background-color:%s;">
      <td style="padding:5px 8px; border:1px solid %s; color:%s;">%s</td>
      <td style="padding:5px 8px; border:1px solid %s; color:%s; text-align:right;">%s</td>
    </tr>',
    bg,
    dark_border, dark_text, headline_rows[[i]][1],
    dark_border, accent_green, headline_rows[[i]][2]
  ))
}
headline_html <- paste0(headline_html, "</table>")

# §3 Trends two-column table
trends_html <- sprintf(
  '<h3 style="color:%s; margin-top:20px;">Trends (7d vs prior 7d)</h3>
<table style="border-collapse:collapse; width:100%%; font-size:12px;">
  <tr style="background-color:%s;">
    <th style="padding:6px 8px; border:1px solid %s; color:white; text-align:left;">Metric</th>
    <th style="padding:6px 8px; border:1px solid %s; color:white; text-align:right;">Change</th>
  </tr>',
  accent_purple, dark_row_alt, dark_border, dark_border
)
trend_rows <- list(
  c("TTC p50",    fmt_trend(tr[["ttc_p50"]])),
  c("TTC p90",    fmt_trend(tr[["ttc_p90"]])),
  c("Att p50",    fmt_trend(tr[["att_p50"]])),
  c("Close rate", fmt_trend(tr[["close_rate"]]))
)
for (i in seq_along(trend_rows)) {
  bg <- if (i %% 2 == 0) dark_row_alt else dark_card
  trends_html <- paste0(trends_html, sprintf(
    '<tr style="background-color:%s;">
      <td style="padding:5px 8px; border:1px solid %s; color:%s;">%s</td>
      <td style="padding:5px 8px; border:1px solid %s; color:%s; text-align:right;">%s</td>
    </tr>',
    bg,
    dark_border, dark_text, trend_rows[[i]][1],
    dark_border, accent_blue, trend_rows[[i]][2]
  ))
}
trends_html <- paste0(trends_html, "</table>")

# §4 Outliers — top-5 by time-to-close
outlier_ttc_html <- sprintf(
  '<h3 style="color:%s; margin-top:20px;">Top-5 Outliers by Time-to-Close (14d)</h3>
<p style="color:%s; font-size:11px; margin-bottom:6px;">Full detail (top-10) in the JSON snapshot and on the dashboard.</p>
<table style="border-collapse:collapse; width:100%%; font-size:11px;">
  <tr style="background-color:%s;">
    <th style="padding:5px; border:1px solid %s; color:white;">ID</th>
    <th style="padding:5px; border:1px solid %s; color:white;">Repo</th>
    <th style="padding:5px; border:1px solid %s; color:white; text-align:right;">TTC</th>
    <th style="padding:5px; border:1px solid %s; color:white; text-align:right;">Attempts</th>
    <th style="padding:5px; border:1px solid %s; color:white;">Reason</th>
  </tr>',
  accent_orange, dark_muted,
  dark_row_alt, dark_border, dark_border, dark_border, dark_border, dark_border
)
if (n_outliers > 0L) {
  for (i in seq_len(n_outliers)) {
    r <- outliers_by_time[[i]]
    bg <- if (i %% 2 == 0) dark_row_alt else dark_card
    outlier_ttc_html <- paste0(outlier_ttc_html, sprintf(
      '<tr style="background-color:%s;">
        <td style="padding:4px 5px; border:1px solid %s; color:%s;">%s</td>
        <td style="padding:4px 5px; border:1px solid %s; color:%s;">%s</td>
        <td style="padding:4px 5px; border:1px solid %s; color:%s; text-align:right;">%s</td>
        <td style="padding:4px 5px; border:1px solid %s; color:%s; text-align:right;">%s</td>
        <td style="padding:4px 5px; border:1px solid %s; color:%s;">%s</td>
      </tr>',
      bg,
      dark_border, accent_blue, r[["review_id"]] %||% "",
      dark_border, dark_text, r[["repo"]] %||% "",
      dark_border, accent_orange, fmt_hrs(r[["time_to_close_hrs"]]),
      dark_border, dark_text, fmt_int(r[["n_attempts"]]),
      dark_border, dark_muted, r[["close_reason"]] %||% ""
    ))
  }
} else {
  outlier_ttc_html <- paste0(outlier_ttc_html,
    sprintf('<tr><td colspan="5" style="padding:6px; color:%s;">(no data in 14-day window)</td></tr>', dark_muted))
}
outlier_ttc_html <- paste0(outlier_ttc_html, "</table>")

# §4 Outliers — top-5 by attempts
outlier_att_html <- sprintf(
  '<h3 style="color:%s; margin-top:20px;">Top-5 Outliers by Attempts-to-Close (14d)</h3>
<table style="border-collapse:collapse; width:100%%; font-size:11px;">
  <tr style="background-color:%s;">
    <th style="padding:5px; border:1px solid %s; color:white;">ID</th>
    <th style="padding:5px; border:1px solid %s; color:white;">Repo</th>
    <th style="padding:5px; border:1px solid %s; color:white; text-align:right;">Attempts</th>
    <th style="padding:5px; border:1px solid %s; color:white; text-align:right;">TTC</th>
    <th style="padding:5px; border:1px solid %s; color:white;">Reason</th>
  </tr>',
  accent_purple, dark_row_alt, dark_border, dark_border, dark_border, dark_border, dark_border
)
if (n_outliers_att > 0L) {
  for (i in seq_len(n_outliers_att)) {
    r <- outliers_by_att[[i]]
    bg <- if (i %% 2 == 0) dark_row_alt else dark_card
    outlier_att_html <- paste0(outlier_att_html, sprintf(
      '<tr style="background-color:%s;">
        <td style="padding:4px 5px; border:1px solid %s; color:%s;">%s</td>
        <td style="padding:4px 5px; border:1px solid %s; color:%s;">%s</td>
        <td style="padding:4px 5px; border:1px solid %s; color:%s; text-align:right;">%s</td>
        <td style="padding:4px 5px; border:1px solid %s; color:%s; text-align:right;">%s</td>
        <td style="padding:4px 5px; border:1px solid %s; color:%s;">%s</td>
      </tr>',
      bg,
      dark_border, accent_blue, r[["review_id"]] %||% "",
      dark_border, dark_text, r[["repo"]] %||% "",
      dark_border, accent_orange, fmt_int(r[["n_attempts"]]),
      dark_border, dark_text, fmt_hrs(r[["time_to_close_hrs"]]),
      dark_border, dark_muted, r[["close_reason"]] %||% ""
    ))
  }
} else {
  outlier_att_html <- paste0(outlier_att_html,
    sprintf('<tr><td colspan="5" style="padding:6px; color:%s;">(no data in 14-day window)</td></tr>', dark_muted))
}
outlier_att_html <- paste0(outlier_att_html, "</table>")

# QA markers (tested by test-send-roborev-email.R)
qa_markers <- sprintf(
  '<!-- QA:report_date=%s --><!-- QA:issues_found_closed=%d --><!-- QA:close_rate=%s --><!-- QA:dashboard_url=%s -->',
  report_date, issues_found_closed, fmt_rate(close_rate), ROBOREV_DASHBOARD_URL
)

# Assemble full body
email_body <- sprintf(
  '<div style="background-color:%s; color:%s; padding:20px;
               font-family:-apple-system,BlinkMacSystemFont,\'Segoe UI\',sans-serif;">
<h2 style="color:%s; margin-bottom:4px;">roborev Daily Report — %s</h2>
<p style="color:%s; font-size:11px; margin-top:0;">
  Generated: %s UTC &nbsp;|&nbsp; Lineage: %s
</p>
%s
%s
%s
%s
%s
<p style="color:%s; font-size:10px; margin-top:20px;">
  JSON snapshot: %s
</p>
%s
</div>',
  dark_bg, dark_text,
  accent_orange, report_date,
  dark_muted, generated_at, lineage_src,
  dashboard_block,
  headline_html,
  trends_html,
  outlier_ttc_html,
  outlier_att_html,
  dark_muted, json_path,
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
