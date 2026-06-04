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

# ── Shared email styles (font sizes, palette, collapsible_block helper) ───────

.scripts_dir_kb <- tryCatch(
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
source(file.path(.scripts_dir_kb, "email_styles.R"))

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

# ── Convert markdown digest to HTML ────────────────────────────────────────────
#
# Simple line-by-line conversion.  We don't pull in a full markdown parser
# to avoid adding a dependency; the digest format is tightly controlled.
#
# Each ## section is wrapped in collapsible_block() (from email_styles.R) so
# readers can expand/collapse sections just like other daily digests.  Any
# content before the first ## line is emitted unwrapped as a preamble.

# Simple HTML escaper (avoids htmltools dependency)
htmlEscape <- function(text) {
  text <- gsub("&", "&amp;", text)
  text <- gsub("<", "&lt;", text)
  text <- gsub(">", "&gt;", text)
  text <- gsub("\"", "&quot;", text)
  text
}

# Convert a vector of lines (excluding the leading ## heading line) to HTML.
lines_to_html <- function(lines) {
  html_lines <- vapply(lines, function(line) {
    if (grepl("^### ", line)) {
      h3_text <- sub("^### ", "", line)
      sprintf('<h3 style="color:%s; margin-top:16px; margin-bottom:6px;">%s</h3>',
              accent_blue, htmlEscape(h3_text))
    } else if (grepl("^\\| ", line)) {
      # Table row — pass through but style it
      sprintf('<div style="font-family:monospace; font-size:%s; color:%s;">%s</div>',
              EMAIL_FONT_BODY, dark_text, htmlEscape(line))
    } else if (grepl("^- ", line)) {
      item_text <- sub("^- ", "", line)
      sprintf('<li style="color:%s; margin:2px 0;">%s</li>',
              dark_text, htmlEscape(item_text))
    } else if (grepl("^---$", line)) {
      sprintf('<hr style="border:1px solid %s; margin:16px 0;">', dark_border)
    } else if (grepl("^_.*_$", line)) {
      em_text <- gsub("^_|_$", "", line)
      sprintf('<p style="color:%s; font-style:italic; font-size:%s;">%s</p>',
              dark_muted, EMAIL_FONT_SUBTITLE, htmlEscape(em_text))
    } else if (!nzchar(trimws(line))) {
      "<br>"
    } else {
      sprintf('<p style="color:%s; margin:4px 0; font-size:%s;">%s</p>',
              dark_text, EMAIL_FONT_BODY, htmlEscape(line))
    }
  }, character(1L))
  paste(html_lines, collapse = "\n")
}

# Derive a one-line summary for a section from its body lines.
section_summary_stats <- function(body_lines) {
  n_list  <- sum(grepl("^- ", body_lines))
  n_table <- sum(grepl("^\\| ", body_lines))
  n_items <- n_list + n_table
  if (n_items > 0L) {
    return(sprintf("%d item%s", n_items, if (n_items == 1L) "" else "s"))
  }
  # Fallback: first non-empty, non-separator line truncated to 60 chars
  first_line <- Filter(function(l) nzchar(trimws(l)) && !grepl("^---$", l), body_lines)
  if (length(first_line) > 0L) {
    raw <- trimws(first_line[[1L]])
    if (nchar(raw) > 60L) raw <- paste0(substr(raw, 1L, 57L), "...")
    return(htmlEscape(raw))
  }
  ""
}

md_to_html_section <- function(md_text) {
  lines <- strsplit(md_text, "\n")[[1L]]

  # Find indices of ## heading lines
  h2_idx <- which(grepl("^## ", lines))

  # Preamble: everything before the first ## heading
  preamble_html <- if (length(h2_idx) == 0L || h2_idx[[1L]] > 1L) {
    preamble_end <- if (length(h2_idx) > 0L) h2_idx[[1L]] - 1L else length(lines)
    lines_to_html(lines[seq_len(preamble_end)])
  } else {
    ""
  }

  # No ## sections at all — fall back to flat conversion
  if (length(h2_idx) == 0L) {
    return(lines_to_html(lines))
  }

  # Build one collapsible_block per ## section
  section_blocks <- vapply(seq_along(h2_idx), function(i) {
    heading_line  <- lines[h2_idx[[i]]]
    section_title <- sub("^## ", "", heading_line)

    body_start <- h2_idx[[i]] + 1L
    body_end   <- if (i < length(h2_idx)) h2_idx[[i + 1L]] - 1L else length(lines)
    body_lines <- if (body_start <= body_end) lines[body_start:body_end] else character(0L)

    stats     <- section_summary_stats(body_lines)
    body_html <- lines_to_html(body_lines)

    collapsible_block(
      title         = htmlEscape(section_title),
      summary_stats = stats,
      html_body     = body_html
    )
  }, character(1L))

  paste(c(preamble_html, section_blocks), collapse = "\n")
}

body_inner <- md_to_html_section(digest_md)

# QA markers (tested by test-kb-digest-email.R)
qa_markers <- sprintf(
  '<!-- QA:kb_digest_date=%s --><!-- QA:kb_privacy=local_smtp_only --><!-- QA:kb_collapsible=true -->',
  report_date
)

email_body <- sprintf(
  '<div style="background-color:%s; color:%s; padding:20px;
               font-family:-apple-system,BlinkMacSystemFont,\'Segoe UI\',sans-serif;
               font-size:%s;">
<h2 style="color:%s; margin-bottom:4px; font-size:%s;">Knowledge Base Digest — %s</h2>
<p style="color:%s; font-size:%s; margin-top:0;">
  Computed locally · No KB content in CI logs · llm#298
</p>
%s
<p style="color:%s; font-size:%s; margin-top:20px;">
  Knowledge repo: (path redacted for privacy) · Sent at %s UTC
</p>
%s
</div>',
  dark_bg, dark_text, EMAIL_FONT_BODY,
  accent_orange, EMAIL_FONT_H2, report_date,
  dark_muted, EMAIL_FONT_SUBTITLE,
  body_inner,
  dark_muted, EMAIL_FONT_FOOTER, format(Sys.time(), "%Y-%m-%dT%H:%M:%S", tz = "UTC"),
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
