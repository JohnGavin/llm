#!/usr/bin/env Rscript
# send_launchd_health_email.R — Send weekly launchd health report via Gmail.
#
# Runs launchd_health_report.R to generate a Markdown report, converts it to
# HTML sections, and sends via blastula (same pattern as send_roborev_email.R).
#
# Required env vars:
#   GMAIL_USERNAME       Gmail sender address
#   GMAIL_APP_PASSWORD   Gmail app password
#   REPORT_RECIPIENT     Recipient (defaults to GMAIL_USERNAME)
#
# Optional env vars:
#   EMAIL_DRY_RUN        Set to "1" to print body to stdout without sending
#   LAUNCHD_LEDGER       Override DuckDB ledger path
#   CLOUD_REPOS          Override cloud repos (comma-separated)
#
# Tracked in llm#300.

suppressPackageStartupMessages({
  library(blastula)
})

# ── Shared email styles (font sizes, palette, collapsible_block helper) ───────

`%||%` <- function(a, b) if (!is.null(a) && !is.na(a) && nzchar(as.character(a))) a else b

.scripts_dir <- tryCatch(
  dirname(normalizePath(sys.frame(0L)$ofile, mustWork = FALSE)),
  error = function(e) {
    args  <- commandArgs(trailingOnly = FALSE)
    idx   <- grep("^--file=", args)
    if (length(idx)) dirname(normalizePath(sub("^--file=", "", args[idx]), mustWork = FALSE))
    else dirname(normalizePath(file.path(Sys.getenv("HOME"), "docs_gh", "llm",
                                         ".claude", "scripts", "email_styles.R"),
                               mustWork = FALSE))
  }
)

source(file.path(.scripts_dir, "email_styles.R"))

# ── Configuration ─────────────────────────────────────────────────────────────

SCRIPTS_DIR <- Sys.getenv(
  "LAUNCHD_SCRIPTS_DIR",
  file.path(Sys.getenv("HOME"), "docs_gh", "llm", ".claude", "scripts")
)

dry_run <- identical(Sys.getenv("EMAIL_DRY_RUN"), "1")

# ── Run aggregator to get report markdown ─────────────────────────────────────

md_tmp <- tempfile(fileext = ".md")
on.exit(unlink(md_tmp), add = TRUE)

aggregator <- file.path(SCRIPTS_DIR, "launchd_health_report.R")
if (!file.exists(aggregator)) {
  stop(sprintf(
    "send_launchd_health_email.R: aggregator not found at %s\n  Set LAUNCHD_SCRIPTS_DIR env var.",
    aggregator
  ))
}

env_extra <- character(0L)
ldger <- Sys.getenv("LAUNCHD_LEDGER", "")
if (nzchar(ldger)) env_extra <- c(env_extra, sprintf("LAUNCHD_LEDGER=%s", ldger))
repos <- Sys.getenv("CLOUD_REPOS", "")
if (nzchar(repos)) env_extra <- c(env_extra, sprintf("CLOUD_REPOS=%s", repos))

env_str <- if (length(env_extra) > 0L) paste(env_extra, collapse = " ") else ""

message("send_launchd_health_email.R: running aggregator")
ret <- system2(
  "Rscript",
  c(aggregator, "--out", md_tmp),
  env = if (nzchar(env_str)) env_extra else character(0L),
  stdout = FALSE,
  stderr = ""
)
if (ret != 0L) {
  stop("send_launchd_health_email.R: aggregator failed with exit code ", ret)
}

if (!file.exists(md_tmp)) {
  stop("send_launchd_health_email.R: aggregator produced no output file")
}

report_md <- paste(readLines(md_tmp, warn = FALSE), collapse = "\n")

# ── Colour aliases (sourced from email_styles.R above) ────────────────────────

dark_bg       <- DARK_BG
dark_card     <- DARK_CARD
dark_row_alt  <- DARK_ROW_ALT
dark_text     <- DARK_TEXT
dark_muted    <- DARK_MUTED
dark_border   <- DARK_BORDER
accent_green  <- ACCENT_GREEN
accent_blue   <- ACCENT_BLUE
accent_orange <- ACCENT_ORANGE
accent_purple <- ACCENT_PURPLE
accent_red    <- "#f08080"   # script-local: not in email_styles.R palette

# ── Parse report sections ──────────────────────────────────────────────────────

# Split on "---" HR dividers to get section blocks
sections <- strsplit(report_md, "\n---\n")[[1L]]

s1 <- if (length(sections) >= 1L) sections[1L] else "(no data)"
s2 <- if (length(sections) >= 2L) sections[2L] else "(no data)"
s3 <- if (length(sections) >= 3L) sections[3L] else "(no data)"
s4 <- if (length(sections) >= 4L) sections[4L] else "(no data)"

# ── Convert markdown tables to simple HTML tables ─────────────────────────────

#' Convert a markdown table block to an HTML table.
md_table_to_html <- function(md_text, header_bg = dark_row_alt, header_color = "#ffffff",
                              row_bg1 = dark_card, row_bg2 = dark_row_alt) {
  lines <- strsplit(md_text, "\n")[[1L]]
  tbl_lines <- lines[grepl("^\\|", lines)]
  if (length(tbl_lines) < 2L) return(paste0("<pre>", md_text, "</pre>"))

  # First line = header; second = separator; rest = data
  header_line <- tbl_lines[1L]
  data_lines  <- if (length(tbl_lines) > 2L) tbl_lines[-(1L:2L)] else character(0L)

  parse_row <- function(line) {
    cells <- strsplit(line, "\\|")[[1L]]
    cells <- trimws(cells[nzchar(trimws(cells))])
    cells
  }

  header_cells <- parse_row(header_line)
  th_html <- paste(sprintf(
    '<th style="padding:6px 8px; border:1px solid %s; color:%s; text-align:left;">%s</th>',
    dark_border, header_color, header_cells
  ), collapse = "")

  rows_html <- character(length(data_lines))
  for (i in seq_along(data_lines)) {
    cells <- parse_row(data_lines[i])
    bg <- if (i %% 2L == 0L) row_bg2 else row_bg1
    td_html <- paste(sprintf(
      '<td style="padding:5px 8px; border:1px solid %s; color:%s;">%s</td>',
      dark_border, dark_text, cells
    ), collapse = "")
    rows_html[i] <- sprintf('<tr style="background-color:%s;">%s</tr>', bg, td_html)
  }

  sprintf(
    '<table style="border-collapse:collapse; width:100%%; font-size:%s;">
  <tr style="background-color:%s;">%s</tr>
  %s
</table>',
    EMAIL_FONT_BODY, header_bg, th_html, paste(rows_html, collapse = "\n  ")
  )
}

#' Convert inline markdown code `foo` to <code>foo</code>
md_inline_code <- function(s) {
  gsub("`([^`]+)`", "<code>\\1</code>", s)
}

#' Convert **bold** to <strong>bold</strong>
md_bold <- function(s) {
  gsub("\\*\\*([^*]+)\\*\\*", "<strong>\\1</strong>", s)
}

md_to_simple_html <- function(s) {
  s <- md_inline_code(s)
  s <- md_bold(s)
  s
}

# Section 1 tables
s1_tables_inner <- md_table_to_html(s1, header_bg = dark_row_alt)
s1_n_rows <- length(grep("^\\|", strsplit(s1, "\n")[[1L]])) - 2L   # minus header + separator
s1_n_rows <- max(0L, s1_n_rows)
s1_tables <- collapsible_block(
  "&#x1F534; Section 1 — Inventory (Priority × Time-of-Day)",
  sprintf("%d job%s", s1_n_rows, if (s1_n_rows == 1L) "" else "s"),
  s1_tables_inner
)

# Section 2 check for placeholder text vs table
has_s2_table <- grepl("^\\|", trimws(s2))
s2_html_inner <- if (has_s2_table) {
  md_table_to_html(s2)
} else {
  sprintf('<p style="color:%s; font-style:italic;">%s</p>',
          dark_muted, md_to_simple_html(gsub("\n", " ", trimws(s2))))
}
s2_n_rows <- if (has_s2_table) max(0L, length(grep("^\\|", strsplit(s2, "\n")[[1L]])) - 2L) else 0L
s2_html <- collapsible_block(
  "&#x1F4CA; Section 2 — Per-Job Run Metrics (7-Day)",
  sprintf("%d job%s", s2_n_rows, if (s2_n_rows == 1L) "" else "s"),
  s2_html_inner
)

# Section 3 bullets (not collapsible — suggestions are short, always show)
s3_bullets <- strsplit(trimws(s3), "\n")[[1L]]
s3_bullets <- s3_bullets[nzchar(s3_bullets)]
s3_html <- paste(sprintf(
  '<li style="color:%s; margin-bottom:6px;">%s</li>',
  dark_text,
  vapply(gsub("^[-*] ", "", s3_bullets), md_to_simple_html, character(1L))
), collapse = "\n")

# Section 4
has_s4_table <- grepl("^\\|", trimws(sub("^[^|]*", "", s4)))
s4_html_inner <- if (has_s4_table) {
  md_table_to_html(s4, header_bg = "#2d1b6e")
} else {
  sprintf('<p style="color:%s; font-style:italic;">%s</p>',
          dark_muted, md_to_simple_html(gsub("\n", " ", trimws(s4))))
}
s4_n_rows <- if (has_s4_table) max(0L, length(grep("^\\|", strsplit(s4, "\n")[[1L]])) - 2L) else 0L
s4_html <- collapsible_block(
  "&#x2601; Section 4 — Related Cloud Crons (GitHub Actions)",
  sprintf("%d cron%s", s4_n_rows, if (s4_n_rows == 1L) "" else "s"),
  s4_html_inner
)

# ── Build full HTML body ───────────────────────────────────────────────────────

report_date  <- format(Sys.Date(), "%Y-%m-%d")
generated_at <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")

# QA markers for tests
qa_markers <- sprintf(
  '<!-- QA:section1=inventory --><!-- QA:section2=run_metrics --><!-- QA:section3=suggestions --><!-- QA:section4=cloud_crons --><!-- QA:report_date=%s -->',
  report_date
)

email_body <- sprintf(
  '<div style="background-color:%s; color:%s; padding:20px;
               font-family:-apple-system,BlinkMacSystemFont,\'Segoe UI\',sans-serif;">
<h2 style="color:%s; margin-bottom:4px;">Weekly Scheduled-Task Health Report — %s</h2>
<p style="color:%s; font-size:%s; margin-top:0;">Generated: %s</p>

%s

%s

<h3 style="color:%s; margin-top:24px; border-bottom:1px solid %s; padding-bottom:4px;">
  &#x26A0; Section 3 — Auto-Generated Improvement Suggestions
</h3>
<ul style="margin:0; padding-left:20px;">
%s
</ul>

%s

<p style="color:%s; font-size:%s; margin-top:24px;">
  Tracked in <a href="https://github.com/JohnGavin/llm/issues/300" style="color:%s;">llm#300</a>.
  Ledger: ~/.claude/logs/launchd_runs.duckdb
</p>
%s
</div>',
  dark_bg, dark_text,
  accent_orange, report_date,
  dark_muted, EMAIL_FONT_SUBTITLE, generated_at,
  s1_tables,
  s2_html,
  accent_red, dark_border,
  s3_html,
  s4_html,
  dark_muted, EMAIL_FONT_FOOTER, accent_blue,
  qa_markers
)

# ── Dry-run mode ───────────────────────────────────────────────────────────────

if (dry_run) {
  message("send_launchd_health_email.R: EMAIL_DRY_RUN=1 — printing body to stdout")
  cat(email_body, "\n")
  message("send_launchd_health_email.R: dry-run complete (not sent)")
  quit(status = 0L)
}

# ── Credentials ────────────────────────────────────────────────────────────────

gmail_user <- Sys.getenv("GMAIL_USERNAME", "")
gmail_pass <- Sys.getenv("GMAIL_APP_PASSWORD", "")

if (!nzchar(gmail_user) || !nzchar(gmail_pass)) {
  message("send_launchd_health_email.R: GMAIL_USERNAME or GMAIL_APP_PASSWORD not set")
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
    subject     = sprintf("Weekly Scheduled-Task Health Report — %s", report_date),
    credentials = smtp_creds
  )
  message(sprintf("send_launchd_health_email.R: email sent to %s", report_to))
}, error = function(e) {
  message("send_launchd_health_email.R: SMTP send failed — ", conditionMessage(e))
  cat("\n--- Email body (SMTP failed) ---\n")
  cat(email_body, "\n")
  quit(status = 1L)
})
