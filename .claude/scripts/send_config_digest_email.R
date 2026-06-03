#!/usr/bin/env Rscript
# send_config_digest_email.R — Send daily config-change digest email via Gmail.
#
# Reads the markdown digest produced by config_change_digest.R (or generates it
# on the fly if CONFIG_DIGEST_PATH is not set) and sends an HTML email via blastula.
#
# Required env vars:
#   GMAIL_USERNAME       Gmail address (sender + credential lookup)
#   GMAIL_APP_PASSWORD   Gmail app password
#   REPORT_RECIPIENT     Recipient address (falls back to GMAIL_USERNAME)
#
# Optional env vars:
#   CONFIG_DIGEST_PATH   Pre-computed markdown digest (skips aggregator call)
#   CONFIG_DIGEST_SINCE  ISO8601 --since arg passed to aggregator (default: 24h ago)
#   EMAIL_DRY_RUN        Set to "1" to print body to stdout without sending
#   LLM_REPO_ROOT        Repo root (auto-detected if absent)
#
# Usage:
#   Rscript .claude/scripts/send_config_digest_email.R
#   EMAIL_DRY_RUN=1 Rscript .claude/scripts/send_config_digest_email.R
#
# Called from bin/config_digest_cron.sh (Path b) or standalone.
# Tracked in llm#297.

suppressPackageStartupMessages({
  library(blastula)
})

# ── Shared email styles (font sizes, palette, collapsible_block helper) ───────

`%||%` <- function(a, b) if (!is.null(a) && !is.na(a) && nzchar(as.character(a))) a else b

.scripts_dir <- tryCatch(
  dirname(normalizePath(sys.frame(0L)$ofile, mustWork = FALSE)),
  error = function(e) {
    # Fallback: use commandArgs --file= when run via Rscript
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

dry_run <- identical(Sys.getenv("EMAIL_DRY_RUN"), "1")

config_digest_path  <- Sys.getenv("CONFIG_DIGEST_PATH", "")
config_digest_since <- Sys.getenv(
  "CONFIG_DIGEST_SINCE",
  format(Sys.time() - 86400, "%Y-%m-%dT%H:%M:%S")
)

# ── Locate repo root ──────────────────────────────────────────────────────────

find_repo_root <- function() {
  env_root <- Sys.getenv("LLM_REPO_ROOT", "")
  if (nzchar(env_root) && dir.exists(env_root)) return(env_root)
  # Walk up from script location
  start <- tryCatch(
    dirname(normalizePath(sys.frame(0)$ofile, mustWork = FALSE)),
    error = function(e) getwd()
  )
  path <- start
  for (i in seq_len(12L)) {
    if (file.exists(file.path(path, ".git"))) return(path)
    parent <- dirname(path)
    if (parent == path) break
    path <- parent
  }
  getwd()
}

REPO_ROOT <- find_repo_root()

# ── Generate digest if not pre-computed ───────────────────────────────────────

if (!nzchar(config_digest_path) || !file.exists(config_digest_path)) {
  aggregator <- file.path(REPO_ROOT, ".claude", "scripts", "config_change_digest.R")
  if (!file.exists(aggregator)) {
    message("send_config_digest_email.R: aggregator not found at ", aggregator)
    quit(status = 1L)
  }
  config_digest_path <- file.path(
    tempdir(),
    sprintf("config_digest_%s.md", format(Sys.Date()))
  )
  message(sprintf(
    "send_config_digest_email.R: generating digest (since=%s) ...",
    config_digest_since
  ))
  ret <- system2("Rscript", args = c(
    aggregator,
    "--since", config_digest_since,
    "--out",   config_digest_path
  ), stdout = FALSE, stderr = TRUE)
  if (!file.exists(config_digest_path)) {
    message("send_config_digest_email.R: aggregator did not produce output at ",
            config_digest_path)
    quit(status = 1L)
  }
}

message(sprintf("send_config_digest_email.R: reading digest %s", config_digest_path))
digest_md <- paste(readLines(config_digest_path, warn = FALSE), collapse = "\n")

# ── Extract QA markers from digest ────────────────────────────────────────────

qa_val <- function(key, text) {
  m <- regmatches(text,
    regexpr(sprintf("<!-- QA:%s=([^-]+) -->", key), text, perl = TRUE))
  if (length(m) == 0L || !nzchar(m)) return(NA_character_)
  sub(sprintf("<!-- QA:%s=", key), "", sub(" -->$", "", m))
}

generated_at       <- qa_val("config_digest_generated", digest_md)
since_label        <- qa_val("config_digest_since",     digest_md)
total_files        <- qa_val("config_digest_total_files",   digest_md)
total_added        <- qa_val("config_digest_total_added",   digest_md)
total_deleted      <- qa_val("config_digest_total_deleted", digest_md)
n_themes           <- qa_val("config_digest_n_themes",  digest_md)
n_lessons          <- qa_val("config_digest_n_lessons", digest_md)
themes_breakdown   <- qa_val("config_digest_themes_breakdown",  digest_md)
lessons_breakdown  <- qa_val("config_digest_lessons_breakdown", digest_md)

if (is.na(generated_at)) generated_at <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
if (is.na(since_label))  since_label  <- config_digest_since

report_date <- format(Sys.Date())

# ── Colour palette — aliases to shared constants from email_styles.R ──────────

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

# ── Build email sections from markdown ────────────────────────────────────────

# Strip QA comment lines from rendered prose
clean_md <- gsub("<!-- QA:[^>]+ -->", "", digest_md)

# Convert markdown headings and bullets to basic HTML
md_to_html <- function(txt) {
  lines <- strsplit(txt, "\n", fixed = TRUE)[[1L]]
  out   <- character(length(lines))
  for (i in seq_along(lines)) {
    l <- lines[i]
    if (grepl("^## ", l)) {
      out[i] <- sprintf(
        '<h2 style="color:%s; margin-top:20px; margin-bottom:6px;">%s</h2>',
        accent_orange, htmlify(sub("^## ", "", l))
      )
    } else if (grepl("^### ", l)) {
      out[i] <- sprintf(
        '<h3 style="color:%s; margin-top:14px; margin-bottom:4px;">%s</h3>',
        accent_blue, htmlify(sub("^### ", "", l))
      )
    } else if (grepl("^\\|", l) && grepl("\\|", l)) {
      # Table row — pass through
      out[i] <- render_table_row(l)
    } else if (grepl("^- ", l)) {
      out[i] <- sprintf(
        '<li style="color:%s; margin-bottom:3px;">%s</li>',
        dark_text, inline_code_html(htmlify(sub("^- +", "", l)))
      )
    } else if (grepl("^---$", l)) {
      out[i] <- sprintf('<hr style="border-color:%s; margin:12px 0;">', dark_border)
    } else if (nzchar(trimws(l))) {
      out[i] <- sprintf('<p style="color:%s; margin:4px 0;">%s</p>',
                        dark_text, inline_code_html(htmlify(l)))
    } else {
      out[i] <- ""
    }
  }
  paste(out, collapse = "\n")
}

htmlify <- function(txt) {
  # Minimal HTML escaping
  txt <- gsub("&", "&amp;", txt, fixed = TRUE)
  txt <- gsub("<", "&lt;",  txt, fixed = TRUE)
  txt <- gsub(">", "&gt;",  txt, fixed = TRUE)
  txt
}

inline_code_html <- function(txt) {
  # First: convert markdown links [label](url) to HTML anchors.
  # Must run before htmlify() has escaped the text, because htmlify converts
  # & < > — but [ ] ( ) are safe.  We run inline_code_html AFTER htmlify(),
  # so at this point & < > are already &amp; &lt; &gt;.
  # The link label may itself contain `code` backticks — handle that below.
  txt <- gsub(
    "\\[([^]]+)\\]\\(([^)]+)\\)",
    sprintf('<a href="\\2" style="color:%s;">\\1</a>', accent_blue),
    txt, perl = TRUE
  )
  # Replace `code` spans with styled <code> elements
  gsub("`([^`]+)`",
       sprintf('<code style="background:%s; color:%s; padding:1px 3px; border-radius:3px;">\\1</code>',
               dark_row_alt, accent_green),
       txt, perl = TRUE)
}

# Table state tracking
in_table      <- FALSE
table_header  <- TRUE
table_html    <- character(0)

render_table_row <- function(l) {
  # Skip divider rows like |---|---|
  if (grepl("^\\|[-: |]+\\|$", l)) return("")
  cells <- strsplit(trimws(l), "\\s*\\|\\s*")[[1L]]
  cells <- cells[nzchar(cells)]
  if (length(cells) == 0L) return("")
  if (cells[1L] == "Category" || cells[1L] == "Metric") {
    # Header row
    paste0(
      sprintf('<tr style="background:%s;">', dark_row_alt),
      paste(sprintf(
        '<th style="padding:5px 8px; border:1px solid %s; color:white; text-align:left;">%s</th>',
        dark_border, htmlify(cells)
      ), collapse = ""),
      "</tr>"
    )
  } else {
    paste0(
      sprintf('<tr style="background:%s;">', dark_card),
      paste(sprintf(
        '<td style="padding:4px 8px; border:1px solid %s; color:%s;">%s</td>',
        dark_border, dark_text, inline_code_html(htmlify(cells))
      ), collapse = ""),
      "</tr>"
    )
  }
}

# ── Wrap table rows ────────────────────────────────────────────────────────────

wrap_tables <- function(html_lines) {
  # Group consecutive <tr> elements into <table>
  result    <- character(0)
  in_t      <- FALSE
  buf       <- character(0)

  for (l in strsplit(html_lines, "\n", fixed = TRUE)[[1L]]) {
    if (grepl("^<tr ", l) || grepl("^<th ", l)) {
      if (!in_t) {
        result <- c(result, sprintf(
          '<table style="border-collapse:collapse; width:100%%; font-size:%s; margin:8px 0;">',
          EMAIL_FONT_BODY
        ))
        in_t <- TRUE
      }
      result <- c(result, l)
    } else {
      if (in_t) {
        result <- c(result, "</table>")
        in_t   <- FALSE
      }
      result <- c(result, l)
    }
  }
  if (in_t) result <- c(result, "</table>")
  paste(result, collapse = "\n")
}

# ── Breakdown subtitle helper ──────────────────────────────────────────────────
# Parses "KEY:N,KEY:N,+M" QA breakdown strings into an HTML sub-label.
# e.g. "chore:7,fix:5,feat:3,+2" -> "(chore 7 · fix 5 · feat 3 · +2 others)"

format_breakdown_html <- function(breakdown_str) {
  if (is.na(breakdown_str) || !nzchar(breakdown_str)) return("")
  parts <- strsplit(breakdown_str, ",", fixed = TRUE)[[1L]]
  labels <- character(length(parts))
  for (i in seq_along(parts)) {
    p <- parts[[i]]
    if (grepl("^\\+[0-9]+$", p)) {
      # "+N" tail entry
      labels[i] <- paste0(p, " others")
    } else if (grepl(":", p, fixed = TRUE)) {
      kv <- strsplit(p, ":", fixed = TRUE)[[1L]]
      key <- if (length(kv) >= 1L) kv[[1L]] else ""
      val <- if (length(kv) >= 2L) kv[[2L]] else ""
      labels[i] <- paste(key, val)
    } else {
      labels[i] <- p
    }
  }
  inner <- paste(labels, collapse = " · ")
  sprintf('<br><span style="font-size:%s; color:#aaa;">(%s)</span>', EMAIL_FONT_SUBTITLE, inner)
}

# ── Headline summary table (two-column Metric | Value) ─────────────────────────

# Build value cells with optional breakdown sub-labels (Enhancements 2 & 3)
themes_value_html  <- paste0(
  if (!is.na(n_themes)) n_themes else "—",
  format_breakdown_html(themes_breakdown)
)
lessons_value_html <- paste0(
  if (!is.na(n_lessons)) n_lessons else "—",
  format_breakdown_html(lessons_breakdown)
)

headline_rows <- list(
  c("Files changed",   if (!is.na(total_files))   total_files   else "—"),
  c("Lines added",     if (!is.na(total_added))    paste0("+", total_added) else "—"),
  c("Lines deleted",   if (!is.na(total_deleted))  paste0("-", total_deleted) else "—"),
  list("Themes clustered", themes_value_html),
  list("Lessons found",    lessons_value_html)
)

headline_table_html <- sprintf(
  '<table style="border-collapse:collapse; width:100%%; font-size:%s;">
  <tr style="background-color:%s;">
    <th style="padding:6px 8px; border:1px solid %s; color:white; text-align:left;">Metric</th>
    <th style="padding:6px 8px; border:1px solid %s; color:white; text-align:right;">Value</th>
  </tr>',
  EMAIL_FONT_BODY, dark_row_alt, dark_border, dark_border
)

for (i in seq_along(headline_rows)) {
  bg <- if (i %% 2L == 0L) dark_row_alt else dark_card
  headline_table_html <- paste0(headline_table_html, sprintf(
    '<tr style="background-color:%s;">
      <td style="padding:5px 8px; border:1px solid %s; color:%s;">%s</td>
      <td style="padding:5px 8px; border:1px solid %s; color:%s; text-align:right;">%s</td>
    </tr>',
    bg,
    dark_border, dark_text,   headline_rows[[i]][1L],
    dark_border, accent_green, headline_rows[[i]][2L]
  ))
}
headline_table_html <- paste0(headline_table_html, "</table>")

# Wrap headline table in a collapsible block (#447)
total_files_val  <- if (!is.na(total_files)) total_files else "?"
total_added_val  <- if (!is.na(total_added)) paste0("+", total_added) else "?"
total_deleted_val <- if (!is.na(total_deleted)) paste0("-", total_deleted) else "?"
headline_summary <- sprintf(
  "Files: %s  •  Lines: %s / %s",
  total_files_val, total_added_val, total_deleted_val
)
headline_html <- collapsible_block(
  "At a Glance (last 24h)", headline_summary, headline_table_html
)

# ── Digest body (converted markdown) ──────────────────────────────────────────

digest_html_raw <- md_to_html(clean_md)
digest_html_wrapped <- wrap_tables(digest_html_raw)

# ── Wrap each <table> block in a collapsible <details> block (#447) ───────────
#
# Strategy: scan the wrapped HTML for patterns of:
#   <h2>...</h2> or <h3>...</h3> followed by a <table>...</table>
# and collapse each table under the preceding heading as summary title.
# Tables without a preceding heading get a generic "Details" title.
#
# We use a simple line-based state machine rather than full HTML parsing.

wrap_digest_tables <- function(html) {
  lines   <- strsplit(html, "\n", fixed = TRUE)[[1L]]
  result  <- character(0L)
  pending_title  <- "Details"
  pending_lines  <- character(0L)
  in_table <- FALSE

  for (l in lines) {
    if (grepl("^<h[23] ", l, perl = TRUE)) {
      # Flush any buffered non-table content
      result <- c(result, pending_lines)
      pending_lines <- character(0L)
      # Extract text content for title
      pending_title <- gsub("<[^>]+>", "", l)
      pending_lines <- c(l)
    } else if (grepl("^<table ", l)) {
      in_table   <- TRUE
      table_buf  <- l
    } else if (in_table) {
      table_buf <- paste0(table_buf, "\n", l)
      if (grepl("^</table>", l)) {
        in_table <- FALSE
        # Emit pending heading + collapsible table
        result <- c(result, pending_lines)
        pending_lines <- character(0L)
        result <- c(result, collapsible_block(
          pending_title,
          "Click to expand",
          table_buf
        ))
        pending_title <- "Details"
      }
    } else {
      pending_lines <- c(pending_lines, l)
    }
  }
  # Flush remainder
  result <- c(result, pending_lines)
  paste(result, collapse = "\n")
}

digest_html <- wrap_digest_tables(digest_html_wrapped)

# ── GH commit link ─────────────────────────────────────────────────────────────

gh_commits_url <- sprintf(
  "https://github.com/JohnGavin/llm/commits/main?since=%s",
  URLencode(since_label, reserved = TRUE)
)

commits_link_html <- sprintf(
  '<div style="margin:12px 0;">
  <a href="%s"
     style="display:inline-block; padding:8px 16px; background-color:%s;
            color:#1a1a2e; text-decoration:none; border-radius:4px;
            font-weight:bold; font-size:12px;">
    View Commits on GitHub
  </a>
</div>',
  gh_commits_url, accent_blue
)

# ── QA markers ────────────────────────────────────────────────────────────────

qa_markers <- sprintf(
  '<!-- QA:email_report_date=%s --><!-- QA:email_total_files=%s --><!-- QA:email_n_themes=%s --><!-- QA:email_n_lessons=%s --><!-- QA:config_digest_section=present -->',
  report_date,
  if (!is.na(total_files)) total_files else "0",
  if (!is.na(n_themes))    n_themes    else "0",
  if (!is.na(n_lessons))   n_lessons   else "0"
)

# ── Assemble full body ─────────────────────────────────────────────────────────

email_body <- sprintf(
  '<div style="background-color:%s; color:%s; padding:20px;
               font-family:-apple-system,BlinkMacSystemFont,\'Segoe UI\',sans-serif;
               font-size:%s;">
<h2 style="color:%s; margin-bottom:4px; font-size:%s;">Config-Change Digest — %s</h2>
<p style="color:%s; font-size:%s; margin-top:0;">
  Generated: %s UTC &nbsp;|&nbsp; Window: since %s
</p>
%s
%s
%s
<p style="color:%s; font-size:%s; margin-top:20px;">
  Digest file: %s
</p>
%s
</div>',
  dark_bg, dark_text, EMAIL_FONT_BODY,
  accent_orange, EMAIL_FONT_H2, report_date,
  dark_muted, EMAIL_FONT_SUBTITLE, generated_at, since_label,
  commits_link_html,
  headline_html,
  digest_html,
  dark_muted, EMAIL_FONT_FOOTER, config_digest_path,
  qa_markers
)

# ── Dry-run ────────────────────────────────────────────────────────────────────

if (dry_run) {
  message("send_config_digest_email.R: EMAIL_DRY_RUN=1 — printing body to stdout")
  cat(email_body, "\n")
  message("send_config_digest_email.R: dry-run complete (not sent)")
  quit(status = 0L)
}

# ── Credentials ────────────────────────────────────────────────────────────────

gmail_user <- Sys.getenv("GMAIL_USERNAME", "")
gmail_pass <- Sys.getenv("GMAIL_APP_PASSWORD", "")

if (!nzchar(gmail_user) || !nzchar(gmail_pass)) {
  message("send_config_digest_email.R: GMAIL_USERNAME or GMAIL_APP_PASSWORD not set")
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
    subject     = sprintf("Config-Change Digest — %s", report_date),
    credentials = smtp_creds
  )
  message(sprintf("send_config_digest_email.R: email sent to %s", report_to))
}, error = function(e) {
  message("send_config_digest_email.R: SMTP send failed — ", conditionMessage(e))
  cat("\n--- Email body (SMTP failed) ---\n")
  cat(email_body, "\n")
  quit(status = 1L)
})
