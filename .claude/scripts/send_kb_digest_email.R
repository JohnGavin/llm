#!/usr/bin/env Rscript
# send_kb_digest_email.R — Send daily knowledge-base digest via local SMTP.
#
# PRIVACY: This script NEVER passes KB content through CI or GitHub.
# The digest is computed locally by kb_digest.R and sent directly via
# blastula + SMTP from this machine. CI logs see nothing.
#
# Required env vars:
#   GMAIL_USERNAME       Gmail address (sender + credential lookup)
#   GMAIL_APP_PASSWORD   Gmail app password
#   REPORT_RECIPIENT     Recipient address (falls back to GMAIL_USERNAME)
#
# Optional env vars:
#   KB_DIGEST_FILE       Path to pre-computed digest markdown
#                        (default: auto-generates via kb_digest.R)
#   KB_KNOWLEDGE_REPO    Path to knowledge repo
#   KB_SINCE             ISO timestamp cutoff (default: 24h ago)
#   EMAIL_DRY_RUN        Set to "1" to print body to stdout without sending
#
# Usage:
#   Rscript .claude/scripts/send_kb_digest_email.R
#   EMAIL_DRY_RUN=1 Rscript .claude/scripts/send_kb_digest_email.R
#
# Called from bin/kb_digest_daily_cron.sh.
# Tracked in llm#298.

suppressPackageStartupMessages({
  library(blastula)
})

# ── Configuration ──────────────────────────────────────────────────────────────

dry_run <- identical(Sys.getenv("EMAIL_DRY_RUN"), "1")

knowledge_repo <- Sys.getenv(
  "KB_KNOWLEDGE_REPO",
  file.path(Sys.getenv("HOME"), "docs_gh", "llm", "knowledge")
)

since_ts <- Sys.getenv(
  "KB_SINCE",
  format(Sys.time() - 86400, "%Y-%m-%dT%H:%M:%S", tz = "UTC")
)

report_date <- format(Sys.Date(), "%Y-%m-%d")

# ── Load or generate digest ────────────────────────────────────────────────────

digest_file <- Sys.getenv("KB_DIGEST_FILE", "")

if (nzchar(digest_file) && file.exists(digest_file)) {
  message(sprintf("send_kb_digest_email.R: loading digest from %s", digest_file))
  digest_md <- paste(readLines(digest_file, warn = FALSE), collapse = "\n")
} else {
  # Generate in-process by sourcing kb_digest.R logic inline via Rscript
  # (avoids sourcing complexity while keeping the generated digest in memory)
  tmp_out <- tempfile(fileext = ".md")
  on.exit(unlink(tmp_out), add = TRUE)

  digest_script <- normalizePath(
    file.path(dirname(sys.frame(1L)$ofile %||% ""), "kb_digest.R"),
    mustWork = FALSE
  )
  # Fallback: locate relative to this script
  if (!file.exists(digest_script)) {
    digest_script <- normalizePath(
      file.path(dirname(commandArgs(trailingOnly = FALSE)[[
        grep("--file=", commandArgs(trailingOnly = FALSE))
      ]]),
      "kb_digest.R"),
      mustWork = FALSE
    )
    digest_script <- gsub("--file=", "", digest_script)
  }
  # Final fallback: search standard locations
  if (!file.exists(digest_script)) {
    candidates <- c(
      file.path(Sys.getenv("HOME"), "docs_gh", "llm",
                ".claude", "scripts", "kb_digest.R"),
      ".claude/scripts/kb_digest.R"
    )
    for (cand in candidates) {
      if (file.exists(cand)) { digest_script <- cand; break }
    }
  }

  if (!file.exists(digest_script)) {
    message("send_kb_digest_email.R: kb_digest.R not found — cannot generate digest")
    quit(status = 1L)
  }

  message(sprintf("send_kb_digest_email.R: running %s", digest_script))
  exit_code <- system2(
    "Rscript",
    args = c(
      digest_script,
      "--knowledge-repo", knowledge_repo,
      "--since",          since_ts,
      "--out",            tmp_out
    ),
    stdout = FALSE, stderr = FALSE
  )

  if (exit_code != 0L || !file.exists(tmp_out)) {
    message(sprintf(
      "send_kb_digest_email.R: kb_digest.R failed (exit=%d)", exit_code))
    quit(status = 1L)
  }

  digest_md <- paste(readLines(tmp_out, warn = FALSE), collapse = "\n")
}

`%||%` <- function(a, b) if (!is.null(a) && !is.na(a) && nzchar(as.character(a))) a else b

if (!nzchar(trimws(digest_md))) {
  message("send_kb_digest_email.R: digest is empty — aborting")
  quit(status = 1L)
}

# ── Colour palette (dark-mode safe — mirrors send_roborev_email.R convention) ─

dark_bg     <- "#1a1a2e"
dark_card   <- "#16213e"
dark_row_alt <- "#0f3460"
dark_text   <- "#e8e8e8"
dark_muted  <- "#a0a0a0"
dark_border <- "#2a2a4a"
accent_green  <- "#00d26a"
accent_blue   <- "#4fc3f7"
accent_orange <- "#ff9800"

# ── Convert markdown digest to HTML ────────────────────────────────────────────
#
# Simple line-by-line conversion.  We don't pull in a full markdown parser
# to avoid adding a dependency; the digest format is tightly controlled.

md_to_html_section <- function(md_text) {
  lines <- strsplit(md_text, "\n")[[1L]]
  html_lines <- vapply(lines, function(line) {
    if (grepl("^## ", line)) {
      h2_text <- sub("^## ", "", line)
      sprintf('<h2 style="color:%s; margin-top:24px; margin-bottom:8px;">%s</h2>',
              accent_orange, htmlEscape(h2_text))
    } else if (grepl("^### ", line)) {
      h3_text <- sub("^### ", "", line)
      sprintf('<h3 style="color:%s; margin-top:16px; margin-bottom:6px;">%s</h3>',
              accent_blue, htmlEscape(h3_text))
    } else if (grepl("^\\| ", line)) {
      # Table row — pass through but style it
      sprintf('<div style="font-family:monospace; font-size:11px; color:%s;">%s</div>',
              dark_text, htmlEscape(line))
    } else if (grepl("^- ", line)) {
      item_text <- sub("^- ", "", line)
      sprintf('<li style="color:%s; margin:2px 0;">%s</li>',
              dark_text, htmlEscape(item_text))
    } else if (grepl("^---$", line)) {
      sprintf('<hr style="border:1px solid %s; margin:16px 0;">', dark_border)
    } else if (grepl("^_.*_$", line)) {
      em_text <- gsub("^_|_$", "", line)
      sprintf('<p style="color:%s; font-style:italic; font-size:11px;">%s</p>',
              dark_muted, htmlEscape(em_text))
    } else if (!nzchar(trimws(line))) {
      "<br>"
    } else {
      sprintf('<p style="color:%s; margin:4px 0; font-size:12px;">%s</p>',
              dark_text, htmlEscape(line))
    }
  }, character(1L))
  paste(html_lines, collapse = "\n")
}

# Simple HTML escaper (avoids htmltools dependency)
htmlEscape <- function(text) {
  text <- gsub("&", "&amp;", text)
  text <- gsub("<", "&lt;", text)
  text <- gsub(">", "&gt;", text)
  text <- gsub("\"", "&quot;", text)
  text
}

body_inner <- md_to_html_section(digest_md)

# QA markers (tested by test-kb-digest-email.R)
qa_markers <- sprintf(
  '<!-- QA:kb_digest_date=%s --><!-- QA:kb_privacy=local_smtp_only -->',
  report_date
)

email_body <- sprintf(
  '<div style="background-color:%s; color:%s; padding:20px;
               font-family:-apple-system,BlinkMacSystemFont,\'Segoe UI\',sans-serif;">
<h2 style="color:%s; margin-bottom:4px;">Knowledge Base Digest — %s</h2>
<p style="color:%s; font-size:11px; margin-top:0;">
  Computed locally · No KB content in CI logs · llm#298
</p>
%s
<p style="color:%s; font-size:10px; margin-top:20px;">
  Knowledge repo: (path redacted for privacy) · Sent at %s UTC
</p>
%s
</div>',
  dark_bg, dark_text,
  accent_orange, report_date,
  dark_muted,
  body_inner,
  dark_muted, format(Sys.time(), "%Y-%m-%dT%H:%M:%S", tz = "UTC"),
  qa_markers
)

# ── Dry-run mode ───────────────────────────────────────────────────────────────

if (dry_run) {
  message("send_kb_digest_email.R: EMAIL_DRY_RUN=1 — printing body to stdout")
  cat(email_body, "\n")
  message("send_kb_digest_email.R: dry-run complete (not sent)")
  quit(status = 0L)
}

# ── Credentials ────────────────────────────────────────────────────────────────

gmail_user <- Sys.getenv("GMAIL_USERNAME", "")
gmail_pass <- Sys.getenv("GMAIL_APP_PASSWORD", "")

if (!nzchar(gmail_user) || !nzchar(gmail_pass)) {
  message("send_kb_digest_email.R: GMAIL_USERNAME or GMAIL_APP_PASSWORD not set")
  message("  Set in ~/.claude/env/kb_digest.env or export before running")
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
    subject     = sprintf("Knowledge Base Digest — %s", report_date),
    credentials = smtp_creds
  )
  message(sprintf("send_kb_digest_email.R: email sent to %s", report_to))
}, error = function(e) {
  message("send_kb_digest_email.R: SMTP send failed — ", conditionMessage(e))
  cat("\n--- Email body (SMTP failed) ---\n")
  cat(email_body, "\n")
  quit(status = 1L)
})
