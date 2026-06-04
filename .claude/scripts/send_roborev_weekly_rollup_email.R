#!/usr/bin/env Rscript
# send_roborev_weekly_rollup_email.R — Send weekly roborev rollup digest via Gmail.
#
# Mirrors the pattern of send_roborev_email.R (llm#287 Part A).
#
# 1. Calls roborev_weekly_rollup.R to produce the markdown rollup.
# 2. Converts the markdown to an HTML email body.
# 3. Sends via blastula SMTP.
#
# Required env vars:
#   GMAIL_USERNAME       Gmail address (sender + credential lookup)
#   GMAIL_APP_PASSWORD   Gmail app password
#   REPORT_RECIPIENT     Recipient address (falls back to GMAIL_USERNAME)
#
# Optional env vars:
#   ROBOREV_DAILY_BACKLOG_DIR   override daily backlog dir
#   ROBOREV_DB                  override reviews.db path
#   UNIFIED_DUCKDB              override unified.duckdb path
#   ROBOREV_WEEKLY_DIR          override weekly rollup output dir
#   ROBOREV_DASHBOARD_URL       dashboard link (default provided)
#   EMAIL_DRY_RUN               "1" → print body to stdout, do not send
#
# Usage:
#   Rscript .claude/scripts/send_roborev_weekly_rollup_email.R
#   EMAIL_DRY_RUN=1 Rscript .claude/scripts/send_roborev_weekly_rollup_email.R
#
# Called from bin/roborev_weekly_rollup_cron.sh.
# Tracked in llm#356.

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

# ── Configuration ──────────────────────────────────────────────────────────────

ROBOREV_DASHBOARD_URL <- Sys.getenv(
  "ROBOREV_DASHBOARD_URL",
  "https://johngavin.github.io/llmtelemetry/#roborev"
)

ROBOREV_WEEKLY_DIR <- Sys.getenv(
  "ROBOREV_WEEKLY_DIR",
  file.path(Sys.getenv("HOME"), ".claude", "logs", "roborev_weekly_rollup")
)

dry_run <- identical(Sys.getenv("EMAIL_DRY_RUN"), "1")

# ── Locate or generate the weekly rollup ──────────────────────────────────────

rollup_script <- file.path(
  .scripts_dir,
  "roborev_weekly_rollup.R"
)
# Fallback: resolve from this file's own path
rollup_script_candidates <- c(
  rollup_script,
  file.path(Sys.getenv("HOME"), "docs_gh", "llm", ".claude", "scripts",
            "roborev_weekly_rollup.R")
)
rollup_script <- rollup_script_candidates[file.exists(rollup_script_candidates)][1L]
rollup_script <- rollup_script %||% NA_character_

today_str <- format(Sys.Date(), "%Y-%m-%d")
rollup_path <- file.path(ROBOREV_WEEKLY_DIR, paste0(today_str, ".md"))

# If rollup file doesn't exist yet, generate it first
if (!file.exists(rollup_path)) {
  if (!is.na(rollup_script) && file.exists(rollup_script)) {
    message("send_roborev_weekly_rollup_email.R: generating rollup via ",
            rollup_script)
    ret <- system2(
      "Rscript",
      args = rollup_script,
      stdout = TRUE,
      stderr = TRUE
    )
    if (!is.null(attr(ret, "status")) && attr(ret, "status") != 0L) {
      message("send_roborev_weekly_rollup_email.R: rollup script returned non-zero")
      message(paste(ret, collapse = "\n"))
    }
  } else {
    message("send_roborev_weekly_rollup_email.R: rollup script not found — ",
            "set ROBOREV_WEEKLY_DIR or run roborev_weekly_rollup.R first")
  }
}

# Read the rollup markdown (may still be absent if DB unavailable)
if (file.exists(rollup_path)) {
  rollup_md <- paste(readLines(rollup_path, warn = FALSE), collapse = "\n")
} else {
  rollup_md <- paste0(
    "# roborev Weekly Rollup — ", today_str, "\n\n",
    "_(rollup file not found at ", rollup_path, " — check roborev_weekly_rollup.R)_\n"
  )
}

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

# ── Convert markdown to simple HTML ──────────────────────────────────────────

md_to_simple_html <- function(md) {
  lines <- strsplit(md, "\n")[[1L]]
  html_parts <- character(length(lines))
  in_table <- FALSE

  for (i in seq_along(lines)) {
    l <- lines[i]

    if (grepl("^## ", l)) {
      if (in_table) { html_parts[i - 1L] <- paste0(html_parts[i - 1L], "</table>"); in_table <- FALSE }
      html_parts[i] <- sprintf(
        '<h3 style="color:%s; margin-top:20px; border-bottom:1px solid %s; padding-bottom:4px;">%s</h3>',
        accent_orange, dark_border, substr(l, 4L, nchar(l))
      )
    } else if (grepl("^# ", l)) {
      html_parts[i] <- sprintf(
        '<h2 style="color:%s; margin-bottom:4px;">%s</h2>',
        accent_orange, substr(l, 3L, nchar(l))
      )
    } else if (grepl("^_.*_$", l)) {
      # Italics line (e.g. _Generated: ..._)
      inner <- gsub("^_(.*)_$", "\\1", l)
      html_parts[i] <- sprintf('<p style="color:%s; font-size:%s; margin:2px 0;">%s</p>',
                                dark_muted, EMAIL_FONT_SUBTITLE, inner)
    } else if (grepl("^\\|", l) && grepl("\\|$", l)) {
      # Table row
      if (!in_table) {
        html_parts[i] <- sprintf(
          '<table style="border-collapse:collapse; width:100%%; font-size:%s; margin:8px 0;">\n',
          EMAIL_FONT_BODY
        )
        in_table <- TRUE
      }
      # Skip separator rows (|---|...)
      if (grepl("^\\|[\\s-|]+\\|$", l)) {
        html_parts[i] <- ""
        next
      }
      cells <- strsplit(trimws(sub("^\\|", "", sub("\\|$", "", l))), "\\|")[[1L]]
      cells <- trimws(cells)
      is_header <- i > 1L && !grepl("^\\|[\\s-|]+\\|$", lines[min(i + 1L, length(lines))])
      cell_tag <- "td"
      cell_style <- sprintf('style="padding:5px 8px; border:1px solid %s; color:%s;"',
                             dark_border, dark_text)
      bg <- if ((i %% 2L) == 0L) dark_row_alt else dark_card
      cells_html <- paste0(
        vapply(cells, function(c) {
          sprintf('<%s %s>%s</%s>', cell_tag, cell_style, c, cell_tag)
        }, character(1L)),
        collapse = ""
      )
      html_parts[i] <- sprintf('<tr style="background-color:%s;">%s</tr>', bg, cells_html)
    } else {
      if (in_table) {
        html_parts[i] <- paste0("</table>\n",
                                sprintf('<p style="color:%s; font-size:%s;">%s</p>', dark_text, EMAIL_FONT_BODY, l))
        in_table <- FALSE
      } else if (nzchar(trimws(l))) {
        html_parts[i] <- sprintf('<p style="color:%s; font-size:%s; margin:4px 0;">%s</p>',
                                  dark_text, EMAIL_FONT_BODY, l)
      } else {
        html_parts[i] <- ""
      }
    }
  }
  if (in_table) html_parts[length(html_parts)] <- paste0(html_parts[length(html_parts)], "</table>")
  paste(html_parts, collapse = "\n")
}

body_inner_html <- md_to_simple_html(rollup_md)
rollup_lines <- length(strsplit(rollup_md, "\n")[[1L]])
body_inner <- collapsible_block(
  "&#x1F4CB; Weekly Rollup",
  sprintf("~%d lines", rollup_lines),
  body_inner_html
)

# Dashboard CTA
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

email_body <- sprintf(
  '<div style="background-color:%s; color:%s; padding:20px;
               font-family:-apple-system,BlinkMacSystemFont,\'Segoe UI\',sans-serif;">
%s
%s
<p style="color:%s; font-size:%s; margin-top:20px;">Rollup file: %s</p>
</div>',
  dark_bg, dark_text,
  body_inner,
  dashboard_block,
  dark_muted, EMAIL_FONT_FOOTER, rollup_path
)

# ── Dry-run mode ───────────────────────────────────────────────────────────────

if (dry_run) {
  message("send_roborev_weekly_rollup_email.R: EMAIL_DRY_RUN=1 — printing to stdout")
  cat(email_body, "\n")
  message("send_roborev_weekly_rollup_email.R: dry-run complete (not sent)")
  quit(status = 0L)
}

# ── Credentials ────────────────────────────────────────────────────────────────

gmail_user <- Sys.getenv("GMAIL_USERNAME", "")
gmail_pass <- Sys.getenv("GMAIL_APP_PASSWORD", "")

if (!nzchar(gmail_user) || !nzchar(gmail_pass)) {
  message("send_roborev_weekly_rollup_email.R: GMAIL_USERNAME or GMAIL_APP_PASSWORD not set")
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
  port        = 465L,
  use_ssl     = TRUE
)

tryCatch({
  smtp_send(
    email       = email,
    to          = report_to,
    from        = gmail_user,
    subject     = sprintf("roborev Weekly Rollup — %s", today_str),
    credentials = smtp_creds
  )
  message(sprintf(
    "send_roborev_weekly_rollup_email.R: email sent to %s", report_to
  ))
}, error = function(e) {
  message("send_roborev_weekly_rollup_email.R: SMTP send failed — ",
          conditionMessage(e))
  cat("\n--- Email body (SMTP failed) ---\n")
  cat(email_body, "\n")
  quit(status = 1L)
})
