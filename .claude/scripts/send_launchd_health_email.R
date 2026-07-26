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

# Split on "---" HR dividers to get section blocks. The report begins with a
# "# Title" block that has its own "---" divider before Section 1, so a plain
# positional split yields 5 elements, not 4 — drop the leading title block and
# keep only the real "## N. ..." sections (llm#300 rendering fix).
sections <- strsplit(report_md, "\n---\n")[[1L]]
sections <- sections[grepl("^\\s*## ", sections)]

s1 <- if (length(sections) >= 1L) sections[1L] else "(no data)"
s2 <- if (length(sections) >= 2L) sections[2L] else "(no data)"
s3 <- if (length(sections) >= 3L) sections[3L] else "(no data)"
s4 <- if (length(sections) >= 4L) sections[4L] else "(no data)"

# ── Convert markdown to HTML ────────────────────────────────────────────────────

#' Convert inline markdown code `foo` to <code>foo</code>
md_inline_code <- function(s) {
  gsub("`([^`]+)`", "<code>\\1</code>", s)
}

#' Convert **bold** to <strong>bold</strong>
md_bold <- function(s) {
  gsub("\\*\\*([^*]+)\\*\\*", "<strong>\\1</strong>", s)
}

md_inline <- function(s) md_bold(md_inline_code(s))

#' Strip the leading "## N. Title" heading line from a section body — the
#' heading is already shown via the collapsible_block() title, so keeping it
#' would duplicate the section title inside the body.
strip_section_heading <- function(s) {
  sub("^\\s*## [^\n]*\n?", "", s)
}

#' Count data rows across one or more contiguous markdown table blocks in a
#' section (each block = header + separator + N data rows; only N counts).
#' Section 1 has three tier tables (### High/Medium/Low), so a naive
#' "total table lines - 2" undercounts/overcounts once there is more than
#' one table.
count_table_data_rows <- function(md_text) {
  lines   <- strsplit(md_text, "\n")[[1L]]
  tbl_idx <- grep("^\\|", lines)
  if (length(tbl_idx) == 0L) return(0L)
  groups <- cumsum(c(1L, diff(tbl_idx) != 1L))
  total <- 0L
  for (g in unique(groups)) total <- total + max(0L, sum(groups == g) - 2L)
  total
}

#' General markdown -> HTML converter: handles "## "/"### " headings,
#' MULTIPLE `|...|` tables per section (opens/closes a <table> around each
#' contiguous run of table lines), and skips `|---|` separator rows. Ported
#' from the corrected md_to_simple_html() in
#' send_roborev_weekly_rollup_email.R (fixed there in #828) — that version
#' only had to open/close <table> once per run of "|" lines; this adds
#' "### " heading support since Section 1 has per-tier subheadings.
md_to_simple_html <- function(md) {
  lines <- strsplit(md, "\n")[[1L]]
  html_parts <- character(length(lines))
  in_table <- FALSE

  for (i in seq_along(lines)) {
    l <- lines[i]

    if (grepl("^### ", l)) {
      if (in_table) { html_parts[i - 1L] <- paste0(html_parts[i - 1L], "</table>"); in_table <- FALSE }
      html_parts[i] <- sprintf(
        '<h4 style="color:%s; margin-top:16px; margin-bottom:4px;">%s</h4>',
        dark_text, md_inline(substr(l, 5L, nchar(l)))
      )
    } else if (grepl("^## ", l)) {
      if (in_table) { html_parts[i - 1L] <- paste0(html_parts[i - 1L], "</table>"); in_table <- FALSE }
      html_parts[i] <- sprintf(
        '<h3 style="color:%s; margin-top:20px; border-bottom:1px solid %s; padding-bottom:4px;">%s</h3>',
        accent_orange, dark_border, md_inline(substr(l, 4L, nchar(l)))
      )
    } else if (grepl("^\\|", l) && grepl("\\|$", l)) {
      table_open <- ""
      if (!in_table) {
        table_open <- sprintf(
          '<table style="border-collapse:collapse; width:100%%; font-size:%s; margin:8px 0;">',
          EMAIL_FONT_BODY
        )
        in_table <- TRUE
      }
      cells <- strsplit(trimws(sub("^\\|", "", sub("\\|$", "", l))), "\\|")[[1L]]
      cells <- trimws(cells)
      # Skip markdown separator rows: every cell looks like ---, :---, ---:, :---:
      if (length(cells) > 0L && all(grepl("^:?-{2,}:?$", cells))) {
        html_parts[i] <- table_open  # preserve <table> if a separator was somehow first
        next
      }
      cell_style <- sprintf('style="padding:5px 8px; border:1px solid %s; color:%s;"',
                             dark_border, dark_text)
      bg <- if ((i %% 2L) == 0L) dark_row_alt else dark_card
      cells_html <- paste0(
        vapply(cells, function(c) sprintf('<td %s>%s</td>', cell_style, md_inline(c)), character(1L)),
        collapse = ""
      )
      html_parts[i] <- paste0(
        table_open,
        sprintf('<tr style="background-color:%s;">%s</tr>', bg, cells_html)
      )
    } else {
      if (in_table) {
        html_parts[i] <- paste0(
          "</table>\n",
          if (nzchar(trimws(l))) {
            sprintf('<p style="color:%s; font-size:%s;">%s</p>', dark_text, EMAIL_FONT_BODY, md_inline(l))
          } else ""
        )
        in_table <- FALSE
      } else if (nzchar(trimws(l))) {
        html_parts[i] <- sprintf('<p style="color:%s; font-size:%s; margin:4px 0;">%s</p>',
                                  dark_text, EMAIL_FONT_BODY, md_inline(l))
      } else {
        html_parts[i] <- ""
      }
    }
  }
  if (in_table) html_parts[length(html_parts)] <- paste0(html_parts[length(html_parts)], "</table>")
  paste(html_parts[nzchar(html_parts)], collapse = "\n")
}

# Section 1 — Inventory (three tier tables)
s1_body   <- strip_section_heading(s1)
s1_n_rows <- count_table_data_rows(s1_body)
s1_tables <- collapsible_block(
  "&#x1F534; Section 1 — Inventory (Priority × Time-of-Day)",
  sprintf("%d job%s", s1_n_rows, if (s1_n_rows == 1L) "" else "s"),
  md_to_simple_html(s1_body)
)

# Section 2 — Per-job run metrics (single table, or placeholder text)
s2_body   <- strip_section_heading(s2)
s2_n_rows <- count_table_data_rows(s2_body)
s2_html <- collapsible_block(
  "&#x1F4CA; Section 2 — Per-Job Run Metrics (7-Day)",
  sprintf("%d job%s", s2_n_rows, if (s2_n_rows == 1L) "" else "s"),
  md_to_simple_html(s2_body)
)

# Section 3 bullets (not collapsible — suggestions are short, always show)
s3_body <- strip_section_heading(s3)
s3_bullets <- strsplit(trimws(s3_body), "\n")[[1L]]
s3_bullets <- s3_bullets[nzchar(s3_bullets)]
s3_html <- paste(sprintf(
  '<li style="color:%s; margin-bottom:6px;">%s</li>',
  dark_text,
  vapply(gsub("^[-*] ", "", s3_bullets), md_inline, character(1L))
), collapse = "\n")

# Section 4 — Cloud crons (single table, or placeholder text)
s4_body   <- strip_section_heading(s4)
s4_n_rows <- count_table_data_rows(s4_body)
s4_html <- collapsible_block(
  "&#x2601; Section 4 — Related Cloud Crons (GitHub Actions)",
  sprintf("%d cron%s", s4_n_rows, if (s4_n_rows == 1L) "" else "s"),
  md_to_simple_html(s4_body)
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
  Ledger: ~/.claude/logs/unified.duckdb (table housekeeping_runs)
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
