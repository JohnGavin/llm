#!/usr/bin/env Rscript
# send_stage1_findings_email.R — Send daily Stage 1 self-review findings digest via Gmail.
#
# Reads self_review_findings_stage1 from unified.duckdb (last 24h).
# If 0 rows: logs and exits 0 (no email sent — no noise on quiet days).
# If >=1 rows: renders an HTML body grouped by finding_type x severity, sends via blastula.
#
# Required env vars:
#   GMAIL_USERNAME       Gmail address (sender + credential lookup)
#   GMAIL_APP_PASSWORD   Gmail app password
#   REPORT_RECIPIENT     Recipient address (falls back to GMAIL_USERNAME)
#
# Optional env vars:
#   UNIFIED_DUCKDB   Path to unified.duckdb (default ~/.claude/logs/unified.duckdb)
#   EMAIL_DRY_RUN    Set to "1" to print body to stdout without sending
#
# Usage:
#   Rscript .claude/scripts/send_stage1_findings_email.R
#   EMAIL_DRY_RUN=1 Rscript .claude/scripts/send_stage1_findings_email.R
#
# Called from bin/stage1_findings_daily_cron.sh.
# Tracked in llm#436.

suppressPackageStartupMessages({
  library(blastula)
  library(DBI)
  library(duckdb)
  library(jsonlite)
})

# ── Shared email styles (font sizes, palette, collapsible_block helper) ───────

`%||%` <- function(a, b) {
  # Treats NULL, length-0, NA, AND empty string as missing.
  # Empty-string handling matters because Sys.getenv() returns "" not NA.
  # See llm#559.
  if (is.null(a) || length(a) == 0L) return(b)
  if (is.na(a[[1L]])) return(b)
  if (is.character(a) && !nzchar(a[[1L]])) return(b)
  a
}

.scripts_dir_s1 <- tryCatch(
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
source(file.path(.scripts_dir_s1, "email_styles.R"))

# ── Configuration ──────────────────────────────────────────────────────────────

UNIFIED_DUCKDB <- Sys.getenv(
  "UNIFIED_DUCKDB",
  file.path(Sys.getenv("HOME"), ".claude", "logs", "unified.duckdb")
)

dry_run <- identical(Sys.getenv("EMAIL_DRY_RUN"), "1")
report_date <- format(Sys.Date())

# ── Connect to DuckDB (read-only) ─────────────────────────────────────────────

if (!file.exists(UNIFIED_DUCKDB)) {
  message(sprintf("send_stage1_findings_email.R: unified.duckdb not found at %s", UNIFIED_DUCKDB))
  quit(status = 1L)
}

con <- DBI::dbConnect(duckdb::duckdb(), UNIFIED_DUCKDB, read_only = TRUE)
on.exit(DBI::dbDisconnect(con), add = TRUE)

# ── Query last 24h of findings ─────────────────────────────────────────────────

findings <- tryCatch(
  DBI::dbGetQuery(con, "
    SELECT
      finding_id,
      finding_type,
      session_id,
      severity,
      evidence,
      detected_at
    FROM self_review_findings_stage1
    WHERE detected_at >= (CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::TIMESTAMP - INTERVAL '24 hours'
    ORDER BY severity, finding_type, detected_at DESC
  "),
  error = function(e) {
    message("send_stage1_findings_email.R: query failed — ", conditionMessage(e))
    quit(status = 1L)
  }
)

n_findings <- nrow(findings)
message(sprintf(
  "send_stage1_findings_email.R: %d findings in last 24h (date=%s)",
  n_findings, report_date
))

# ── Exit silently when no findings (no noise on quiet days) ───────────────────

if (n_findings == 0L) {
  message("send_stage1_findings_email.R: 0 findings — skipping email (quiet day)")
  quit(status = 0L)
}

# ── Colour palette (dark-mode safe, matches send_roborev_email.R) ─────────────
# Note: DARK_BG, DARK_CARD, DARK_ROW_ALT, DARK_TEXT, DARK_MUTED, DARK_BORDER,
#       ACCENT_GREEN, ACCENT_BLUE, ACCENT_ORANGE, ACCENT_PURPLE now from email_styles.R
# Local aliases for backward-compat with the helper functions below:

dark_bg       <- DARK_BG
dark_card     <- DARK_CARD
dark_row_alt  <- DARK_ROW_ALT
dark_text     <- DARK_TEXT
dark_muted    <- DARK_MUTED
dark_border   <- DARK_BORDER
accent_green  <- ACCENT_GREEN
accent_blue   <- ACCENT_BLUE
accent_orange <- ACCENT_ORANGE
accent_red    <- "#f08080"
accent_purple <- ACCENT_PURPLE

severity_colour <- function(sev) {
  switch(
    tolower(sev %||% "unknown"),
    critical = accent_red,
    major    = accent_orange,
    minor    = accent_blue,
    info     = accent_green,
    accent_blue
  )
}

# ── Truncate evidence JSON to ~200 chars ──────────────────────────────────────

truncate_evidence <- function(ev, max_chars = 200L) {
  if (is.null(ev) || is.na(ev) || !nzchar(ev)) return("(no evidence)")
  # Pretty-print the JSON key=value pairs as a compact string
  parsed <- tryCatch(jsonlite::fromJSON(ev, simplifyVector = TRUE), error = function(e) NULL)
  if (!is.null(parsed) && is.list(parsed)) {
    flat <- paste(names(parsed), unlist(parsed), sep = "=", collapse = " | ")
  } else {
    flat <- ev
  }
  if (nchar(flat) > max_chars) {
    flat <- paste0(substr(flat, 1L, max_chars), "...")
  }
  # HTML-escape special characters
  flat <- gsub("&", "&amp;", flat, fixed = TRUE)
  flat <- gsub("<", "&lt;",  flat, fixed = TRUE)
  flat <- gsub(">", "&gt;",  flat, fixed = TRUE)
  flat
}

# ── Group findings by finding_type then severity ───────────────────────────────

build_group_table <- function(group_df) {
  type_val <- group_df$finding_type[1]
  sev_val  <- group_df$severity[1]
  sev_col  <- severity_colour(sev_val)
  n_rows   <- nrow(group_df)

  header <- sprintf(
    '<h4 style="color:%s; margin:16px 0 6px 0;">
       %s &nbsp;<span style="color:%s; font-size:%s;">[%s]</span>
       &nbsp;<span style="color:%s; font-size:%s;">(%d finding%s)</span>
     </h4>',
    sev_col,
    htmltools_escape(type_val),
    sev_col, EMAIL_FONT_SUBTITLE, htmltools_escape(sev_val),
    dark_muted, EMAIL_FONT_SUBTITLE, n_rows, if (n_rows == 1L) "" else "s"
  )

  table_open <- sprintf(
    '<table style="border-collapse:collapse; width:100%%; font-size:%s; margin-bottom:10px;">
       <tr style="background-color:%s;">
         <th style="padding:5px 8px; border:1px solid %s; color:white; text-align:left;">Finding ID</th>
         <th style="padding:5px 8px; border:1px solid %s; color:white; text-align:left;">Session</th>
         <th style="padding:5px 8px; border:1px solid %s; color:white; text-align:left;">Evidence</th>
         <th style="padding:5px 8px; border:1px solid %s; color:white; text-align:left;">Detected</th>
       </tr>',
    EMAIL_FONT_BODY,
    dark_row_alt,
    dark_border, dark_border, dark_border, dark_border
  )

  rows_html <- ""
  for (i in seq_len(n_rows)) {
    bg  <- if (i %% 2L == 0L) dark_row_alt else dark_card
    row <- group_df[i, ]
    session_short <- if (is.na(row$session_id) || !nzchar(row$session_id %||% "")) {
      "(unknown)"
    } else {
      substr(row$session_id, 1L, 12L)
    }
    detected_str <- format(as.POSIXct(row$detected_at), "%Y-%m-%d %H:%M", tz = "UTC")
    rows_html <- paste0(rows_html, sprintf(
      '<tr style="background-color:%s;">
         <td style="padding:4px 6px; border:1px solid %s; color:%s; font-size:%s;">%s</td>
         <td style="padding:4px 6px; border:1px solid %s; color:%s; font-size:%s;">%s</td>
         <td style="padding:4px 6px; border:1px solid %s; color:%s;">%s</td>
         <td style="padding:4px 6px; border:1px solid %s; color:%s; white-space:nowrap;">%s</td>
       </tr>',
      bg,
      dark_border, accent_blue, EMAIL_FONT_FOOTER, htmltools_escape(row$finding_id %||% ""),
      dark_border, dark_muted,  EMAIL_FONT_FOOTER, session_short,
      dark_border, dark_text,   truncate_evidence(row$evidence),
      dark_border, dark_muted,  detected_str
    ))
  }

  table_html <- paste0(table_open, rows_html, "</table>")
  collapsible_block(
    title         = paste0(htmltools_escape(type_val),
                           " [", htmltools_escape(sev_val), "]"),
    summary_stats = paste0(n_rows, " finding", if (n_rows == 1L) "" else "s"),
    html_body     = paste0(header, table_html)
  )
}

# Minimal HTML escaping (htmltools not always available in nix env)
htmltools_escape <- function(x) {
  x <- as.character(x %||% "")
  x <- gsub("&", "&amp;", x, fixed = TRUE)
  x <- gsub("<", "&lt;",  x, fixed = TRUE)
  x <- gsub(">", "&gt;",  x, fixed = TRUE)
  x <- gsub('"', "&quot;", x, fixed = TRUE)
  x
}

# Build sections grouped by (finding_type, severity)
group_keys <- unique(findings[, c("finding_type", "severity"), drop = FALSE])
# Sort: severity order critical > major > minor > info
sev_order <- c(critical = 1L, major = 2L, minor = 3L, info = 4L)
group_keys$sev_ord <- sev_order[tolower(group_keys$severity)]
group_keys$sev_ord[is.na(group_keys$sev_ord)] <- 5L
group_keys <- group_keys[order(group_keys$sev_ord, group_keys$finding_type), ]

groups_html <- ""
for (i in seq_len(nrow(group_keys))) {
  mask <- findings$finding_type == group_keys$finding_type[i] &
          findings$severity      == group_keys$severity[i]
  groups_html <- paste0(groups_html, build_group_table(findings[mask, ]))
}

# ── Build email body ───────────────────────────────────────────────────────────

subject_line <- sprintf(
  "Stage 1 Self-Review Findings — %s (%d finding%s)",
  report_date, n_findings, if (n_findings == 1L) "" else "s"
)

qa_markers <- sprintf(
  "<!-- QA:report_date=%s --><!-- QA:n_findings=%d -->",
  report_date, n_findings
)

email_body <- sprintf(
  '<div style="background-color:%s; color:%s; padding:20px;
               font-family:-apple-system,BlinkMacSystemFont,\'Segoe UI\',sans-serif;">
<h2 style="color:%s; margin-bottom:4px;">Stage 1 Self-Review Findings &mdash; %s</h2>
<p style="color:%s; font-size:%s; margin-top:0; margin-bottom:16px;">
  %d finding%s in the last 24 hours &nbsp;|&nbsp; Generated: %s UTC
</p>
%s
<p style="color:%s; font-size:%s; margin-top:20px;">
  Source: %s &nbsp;|&nbsp; Table: self_review_findings_stage1
</p>
%s
</div>',
  dark_bg, dark_text,
  accent_orange, report_date,
  dark_muted, EMAIL_FONT_SUBTITLE,
  n_findings, if (n_findings == 1L) "" else "s",
  format(Sys.time(), "%Y-%m-%d %H:%M", tz = "UTC"),
  groups_html,
  dark_muted, EMAIL_FONT_FOOTER, UNIFIED_DUCKDB,
  qa_markers
)

# ── Dry-run mode ───────────────────────────────────────────────────────────────

if (dry_run) {
  message("send_stage1_findings_email.R: EMAIL_DRY_RUN=1 — printing body to stdout")
  cat(email_body, "\n")
  message(sprintf(
    "send_stage1_findings_email.R: dry-run complete (would send: %s)",
    subject_line
  ))
  quit(status = 0L)
}

# ── Credentials ────────────────────────────────────────────────────────────────

gmail_user <- Sys.getenv("GMAIL_USERNAME", "")
gmail_pass <- Sys.getenv("GMAIL_APP_PASSWORD", "")

if (!nzchar(gmail_user) || !nzchar(gmail_pass)) {
  message("send_stage1_findings_email.R: GMAIL_USERNAME or GMAIL_APP_PASSWORD not set")
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
    subject     = subject_line,
    credentials = smtp_creds
  )
  message(sprintf("send_stage1_findings_email.R: email sent to %s", report_to))
}, error = function(e) {
  message("send_stage1_findings_email.R: SMTP send failed — ", conditionMessage(e))
  cat("\n--- Email body (SMTP failed) ---\n")
  cat(email_body, "\n")
  quit(status = 1L)
})
