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

# ── Signal #479: Fix/revert commits without KB reference (last 24h) ───────────
#
# For commits in the last 24h with fix( / revert( / fix: / revert: subjects,
# count those whose BODY does NOT mention knowledge/, [[, or wiki/.
# Table: commit_sha | subject | author
# QA marker: <!-- QA:kb_signal_479=N -->

compute_fix_no_kb <- function(llm_repo, since_ts) {
  tryCatch({
    # Build the --after= date argument
    ts_to_date <- function(ts) {
      m <- regmatches(ts, regexpr("^[0-9]{4}-[0-9]{2}-[0-9]{2}", ts))
      if (length(m) == 0L || !nzchar(m)) return(ts)
      m
    }
    date_arg <- sprintf("--after=%s", ts_to_date(since_ts))

    # Get all commits since cutoff with SHA + subject + author name, body
    # Format: %H | %s | %an | %b (NULL separator between records)
    raw_lines <- tryCatch(
      suppressWarnings(system2(
        "git",
        c("-C", llm_repo,
          "log", "--format=%H\x01%s\x01%an\x01%b\x01END_BODY",
          date_arg),
        stdout = TRUE, stderr = FALSE
      )),
      error = function(e) character(0L)
    )

    if (length(raw_lines) == 0L) {
      return(list(count = 0L, rows = list()))
    }

    # Parse: collapse into a single string and split on END_BODY
    all_text <- paste(raw_lines, collapse = "\n")
    records  <- strsplit(all_text, "\n.*END_BODY\n?", perl = TRUE)[[1L]]
    records  <- records[nzchar(trimws(records))]

    fix_no_kb <- list()

    for (rec in records) {
      rec_lines <- strsplit(rec, "\n")[[1L]]
      if (length(rec_lines) == 0L) next

      # First line: sha | subject | author | (body follows)
      header_parts <- strsplit(rec_lines[[1L]], "\x01")[[1L]]
      if (length(header_parts) < 3L) next
      sha     <- trimws(header_parts[[1L]])
      subject <- trimws(header_parts[[2L]])
      author  <- trimws(header_parts[[3L]])

      # Only care about fix/revert commits
      is_fix_revert <- grepl(
        "^(fix(|!)|revert(|!))([:(]|$)",
        subject,
        ignore.case = TRUE
      )
      if (!is_fix_revert) next

      # The body: lines after the first header line
      body_text <- paste(
        if (length(rec_lines) > 1L) rec_lines[-1L] else character(0L),
        collapse = "\n"
      )
      # Combine subject + body for KB reference check
      full_text <- paste(subject, body_text, sep = "\n")

      has_kb_ref <- grepl("knowledge/|\\[\\[|wiki/", full_text, perl = TRUE)
      if (!has_kb_ref) {
        fix_no_kb[[length(fix_no_kb) + 1L]] <- list(
          sha     = substr(sha, 1L, 8L),
          subject = if (nchar(subject) > 72L) paste0(substr(subject, 1L, 69L), "...") else subject,
          author  = author
        )
      }
    }

    list(count = length(fix_no_kb), rows = fix_no_kb)
  }, error = function(e) {
    message("compute_fix_no_kb: error — ", conditionMessage(e))
    list(count = 0L, rows = list())
  })
}

signal_479 <- compute_fix_no_kb(
  llm_repo = file.path(Sys.getenv("HOME"), "docs_gh", "llm"),
  since_ts = since_ts
)

signal_479_html <- if (signal_479$count == 0L) {
  collapsible_block(
    title         = "Fix/revert commits without KB reference (last 24h)",
    summary_stats = paste0("0 found — all fix/revert commits reference KB"),
    html_body     = sprintf(
      '<p style="color:%s; font-style:italic;">No fix/revert commits lacking a KB reference in the last 24h.</p>',
      DARK_MUTED
    )
  )
} else {
  rows_html <- paste(vapply(signal_479$rows, function(r) {
    sprintf(
      '<tr>
        <td style="padding:4px 8px; font-family:monospace; color:%s;">%s</td>
        <td style="padding:4px 8px; color:%s;">%s</td>
        <td style="padding:4px 8px; color:%s;">%s</td>
      </tr>',
      ACCENT_BLUE, htmlEscape(r$sha),
      DARK_TEXT,   htmlEscape(r$subject),
      DARK_MUTED,  htmlEscape(r$author)
    )
  }, character(1L)), collapse = "\n")

  table_html <- sprintf(
    '<table style="border-collapse:collapse; width:100%%; font-size:%s;">
      <thead>
        <tr style="color:%s; text-align:left;">
          <th style="padding:4px 8px;">SHA</th>
          <th style="padding:4px 8px;">Subject</th>
          <th style="padding:4px 8px;">Author</th>
        </tr>
      </thead>
      <tbody>%s</tbody>
    </table>',
    EMAIL_FONT_BODY, DARK_MUTED,
    rows_html
  )

  collapsible_block(
    title         = "Fix/revert commits without KB reference (last 24h)",
    summary_stats = sprintf("%d commit%s missing KB ref",
                            signal_479$count,
                            if (signal_479$count == 1L) "" else "s"),
    html_body     = table_html
  )
}

# QA marker for signal #479
signal_479_qa <- sprintf(
  "<!-- QA:kb_signal_479=%d -->", signal_479$count
)

# ── Signal #480: raw/ files awaiting wiki promotion (>14d) ────────────────────
#
# Files under knowledge/raw/ where mtime > 14 days AND no wiki/ file references
# the filename. Table: file | days_old | size.
# QA marker: <!-- QA:kb_signal_480=N -->

compute_stale_raw <- function(knowledge_repo) {
  tryCatch({
    raw_dir  <- file.path(knowledge_repo, "raw")
    wiki_dir <- file.path(knowledge_repo, "wiki")

    if (!dir.exists(raw_dir)) return(list(count = 0L, rows = list()))

    raw_files <- list.files(raw_dir, full.names = TRUE, recursive = FALSE)
    raw_files <- raw_files[!dir.exists(raw_files)]  # files only

    if (length(raw_files) == 0L) return(list(count = 0L, rows = list()))

    # Read all wiki files into a single text blob for reference checking
    wiki_text <- ""
    if (dir.exists(wiki_dir)) {
      wiki_mds <- list.files(wiki_dir, pattern = "\\.md$", full.names = TRUE,
                              recursive = TRUE)
      if (length(wiki_mds) > 0L) {
        wiki_lines <- unlist(lapply(wiki_mds, function(f) {
          tryCatch(readLines(f, warn = FALSE), error = function(e) character(0L))
        }))
        wiki_text <- paste(wiki_lines, collapse = "\n")
      }
    }

    now <- Sys.time()
    stale <- list()

    for (f in raw_files) {
      info <- tryCatch(file.info(f), error = function(e) NULL)
      if (is.null(info) || is.na(info$mtime)) next

      days_old <- as.numeric(difftime(now, info$mtime, units = "days"))
      if (days_old <= 14) next

      # Check if this file's basename is referenced in any wiki file
      fname <- basename(f)
      is_referenced <- grepl(fname, wiki_text, fixed = TRUE)
      if (is_referenced) next

      # Format size
      size_bytes <- info$size
      size_str <- if (size_bytes > 1024 * 1024) {
        sprintf("%.1f MB", size_bytes / (1024 * 1024))
      } else if (size_bytes > 1024) {
        sprintf("%.1f KB", size_bytes / 1024)
      } else {
        sprintf("%d B", size_bytes)
      }

      stale[[length(stale) + 1L]] <- list(
        file     = fname,
        days_old = round(days_old),
        size     = size_str
      )
    }

    list(count = length(stale), rows = stale)
  }, error = function(e) {
    message("compute_stale_raw: error — ", conditionMessage(e))
    list(count = 0L, rows = list())
  })
}

signal_480 <- compute_stale_raw(knowledge_repo)

signal_480_html <- if (signal_480$count == 0L) {
  collapsible_block(
    title         = "raw/ files awaiting wiki promotion (>14d)",
    summary_stats = "0 found — all raw files promoted or referenced",
    html_body     = sprintf(
      '<p style="color:%s; font-style:italic;">No raw files older than 14 days are awaiting wiki promotion.</p>',
      DARK_MUTED
    )
  )
} else {
  rows_html <- paste(vapply(signal_480$rows, function(r) {
    sprintf(
      '<tr>
        <td style="padding:4px 8px; color:%s;">%s</td>
        <td style="padding:4px 8px; text-align:right; color:%s;">%s d</td>
        <td style="padding:4px 8px; text-align:right; color:%s;">%s</td>
      </tr>',
      DARK_TEXT,   htmlEscape(r$file),
      ACCENT_ORANGE, as.character(r$days_old),
      DARK_MUTED,  htmlEscape(r$size)
    )
  }, character(1L)), collapse = "\n")

  table_html <- sprintf(
    '<table style="border-collapse:collapse; width:100%%; font-size:%s;">
      <thead>
        <tr style="color:%s; text-align:left;">
          <th style="padding:4px 8px;">File</th>
          <th style="padding:4px 8px; text-align:right;">Days old</th>
          <th style="padding:4px 8px; text-align:right;">Size</th>
        </tr>
      </thead>
      <tbody>%s</tbody>
    </table>',
    EMAIL_FONT_BODY, DARK_MUTED,
    rows_html
  )

  collapsible_block(
    title         = "raw/ files awaiting wiki promotion (>14d)",
    summary_stats = sprintf("%d file%s stale",
                            signal_480$count,
                            if (signal_480$count == 1L) "" else "s"),
    html_body     = table_html
  )
}

signal_480_qa <- sprintf("<!-- QA:kb_signal_480=%d -->", signal_480$count)

# ── Signal #481: Broken [[topic]] wiki backlinks ───────────────────────────────
#
# Scan knowledge/wiki/*.md for [[topic]] syntax, check if the target file
# exists (try topic.md, topic-page.md, topic.qmd).
# Table: wiki_file:line | broken_target
# QA marker: <!-- QA:kb_signal_481=N -->

compute_broken_backlinks <- function(knowledge_repo) {
  tryCatch({
    wiki_dir <- file.path(knowledge_repo, "wiki")
    if (!dir.exists(wiki_dir)) return(list(count = 0L, rows = list()))

    wiki_files <- list.files(wiki_dir, pattern = "\\.md$", full.names = TRUE,
                              recursive = TRUE)
    if (length(wiki_files) == 0L) return(list(count = 0L, rows = list()))

    broken <- list()

    for (f in wiki_files) {
      lines <- tryCatch(readLines(f, warn = FALSE), error = function(e) character(0L))
      if (length(lines) == 0L) next

      rel_name <- basename(f)

      for (i in seq_along(lines)) {
        line <- lines[[i]]
        # Find all [[topic]] patterns
        m <- gregexpr("\\[\\[([^\\]]+)\\]\\]", line, perl = TRUE)
        if (m[[1L]][[1L]] == -1L) next

        matches <- regmatches(line, m)[[1L]]
        targets <- gsub("^\\[\\[|\\]\\]$", "", matches)

        for (tgt in targets) {
          # Try candidate filenames
          tgt_slug <- gsub(" ", "-", tolower(tgt))
          candidates <- c(
            file.path(wiki_dir, paste0(tgt, ".md")),
            file.path(wiki_dir, paste0(tgt_slug, ".md")),
            file.path(wiki_dir, paste0(tgt, "-page.md")),
            file.path(wiki_dir, paste0(tgt_slug, "-page.md")),
            file.path(wiki_dir, paste0(tgt, ".qmd")),
            file.path(wiki_dir, paste0(tgt_slug, ".qmd"))
          )
          exists_any <- any(file.exists(candidates))
          if (!exists_any) {
            broken[[length(broken) + 1L]] <- list(
              location = sprintf("%s:%d", rel_name, i),
              target   = tgt
            )
          }
        }
      }
    }

    list(count = length(broken), rows = broken)
  }, error = function(e) {
    message("compute_broken_backlinks: error — ", conditionMessage(e))
    list(count = 0L, rows = list())
  })
}

signal_481 <- compute_broken_backlinks(knowledge_repo)

signal_481_html <- if (signal_481$count == 0L) {
  collapsible_block(
    title         = "Broken [[topic]] wiki backlinks",
    summary_stats = "0 found — all backlinks resolve",
    html_body     = sprintf(
      '<p style="color:%s; font-style:italic;">No broken [[topic]] backlinks found in wiki/.</p>',
      DARK_MUTED
    )
  )
} else {
  rows_html <- paste(vapply(signal_481$rows, function(r) {
    sprintf(
      '<tr>
        <td style="padding:4px 8px; font-family:monospace; color:%s;">%s</td>
        <td style="padding:4px 8px; color:%s;">[[%s]]</td>
      </tr>',
      DARK_MUTED, htmlEscape(r$location),
      ACCENT_ORANGE, htmlEscape(r$target)
    )
  }, character(1L)), collapse = "\n")

  table_html <- sprintf(
    '<table style="border-collapse:collapse; width:100%%; font-size:%s;">
      <thead>
        <tr style="color:%s; text-align:left;">
          <th style="padding:4px 8px;">Location (file:line)</th>
          <th style="padding:4px 8px;">Broken target</th>
        </tr>
      </thead>
      <tbody>%s</tbody>
    </table>',
    EMAIL_FONT_BODY, DARK_MUTED,
    rows_html
  )

  collapsible_block(
    title         = "Broken [[topic]] wiki backlinks",
    summary_stats = sprintf("%d broken link%s",
                            signal_481$count,
                            if (signal_481$count == 1L) "" else "s"),
    html_body     = table_html
  )
}

signal_481_qa <- sprintf("<!-- QA:kb_signal_481=%d -->", signal_481$count)

# ── Signal #482: New skills/rules without wiki context (last 7d) ──────────────
#
# Skills under .claude/skills/*/SKILL.md and rules under .claude/rules/*.md
# whose git-add time is within the last 7d, checked against wiki/ references.
# Table: kind | name | created | wiki_referenced (y/n)
# QA marker: <!-- QA:kb_signal_482=N -->

compute_new_no_wiki <- function(knowledge_repo) {
  tryCatch({
    llm_repo <- file.path(Sys.getenv("HOME"), "docs_gh", "llm")
    wiki_dir <- file.path(knowledge_repo, "wiki")

    # Read all wiki content for reference checking
    wiki_text <- ""
    if (dir.exists(wiki_dir)) {
      wiki_mds <- list.files(wiki_dir, pattern = "\\.md$", full.names = TRUE,
                              recursive = TRUE)
      if (length(wiki_mds) > 0L) {
        wiki_lines <- unlist(lapply(wiki_mds, function(f) {
          tryCatch(readLines(f, warn = FALSE), error = function(e) character(0L))
        }))
        wiki_text <- paste(wiki_lines, collapse = "\n")
      }
    }

    cutoff <- Sys.time() - 7L * 86400L  # 7 days ago

    # Get skills: .claude/skills/*/SKILL.md
    skills_dir <- file.path(llm_repo, ".claude", "skills")
    skill_files <- character(0L)
    if (dir.exists(skills_dir)) {
      skill_files <- list.files(skills_dir, pattern = "^SKILL\\.md$",
                                 full.names = TRUE, recursive = TRUE)
    }

    # Get rules: .claude/rules/*.md (non-recursive, excludes _companions/)
    rules_dir <- file.path(llm_repo, ".claude", "rules")
    rule_files <- character(0L)
    if (dir.exists(rules_dir)) {
      rule_files <- list.files(rules_dir, pattern = "\\.md$",
                                full.names = TRUE, recursive = FALSE)
    }

    rows <- list()
    process_file <- function(f, kind) {
      # Get the date this file was first added to git
      rel_path <- sub(paste0(llm_repo, "/?"), "", f)
      date_raw <- tryCatch(
        suppressWarnings(system2(
          "git",
          c("-C", llm_repo,
            "log", "--diff-filter=A", "--format=%aI", "--follow", "--", rel_path),
          stdout = TRUE, stderr = FALSE
        )),
        error = function(e) character(0L)
      )
      if (length(date_raw) == 0L || !nzchar(date_raw[[1L]])) return()

      # Parse ISO 8601 date
      add_time <- tryCatch(
        as.POSIXct(date_raw[[1L]], format = "%Y-%m-%dT%H:%M:%S", tz = "UTC"),
        error   = function(e) NA
      )
      if (is.na(add_time)) return()
      if (add_time < cutoff) return()  # older than 7 days

      # Name: skill dir name or rule filename without extension
      name <- if (kind == "skill") {
        basename(dirname(f))
      } else {
        tools::file_path_sans_ext(basename(f))
      }

      # Check wiki reference: does any wiki page mention this name?
      wiki_ref <- grepl(name, wiki_text, fixed = TRUE)
      wiki_ref_str <- if (wiki_ref) "y" else "n"

      rows[[length(rows) + 1L]] <<- list(
        kind    = kind,
        name    = name,
        created = format(add_time, "%Y-%m-%d"),
        wiki_ref = wiki_ref_str
      )
    }

    for (f in skill_files) process_file(f, "skill")
    for (f in rule_files)  process_file(f, "rule")

    # Count those WITHOUT wiki reference
    no_wiki <- Filter(function(r) r$wiki_ref == "n", rows)
    list(count = length(no_wiki), rows = rows)
  }, error = function(e) {
    message("compute_new_no_wiki: error — ", conditionMessage(e))
    list(count = 0L, rows = list())
  })
}

signal_482 <- compute_new_no_wiki(knowledge_repo)

signal_482_html <- if (length(signal_482$rows) == 0L) {
  collapsible_block(
    title         = "New skills/rules without wiki context (last 7d)",
    summary_stats = "0 new items in last 7d",
    html_body     = sprintf(
      '<p style="color:%s; font-style:italic;">No new skills or rules added in the last 7 days.</p>',
      DARK_MUTED
    )
  )
} else {
  rows_html <- paste(vapply(signal_482$rows, function(r) {
    ref_color <- if (r$wiki_ref == "y") ACCENT_GREEN else ACCENT_ORANGE
    sprintf(
      '<tr>
        <td style="padding:4px 8px; color:%s;">%s</td>
        <td style="padding:4px 8px; color:%s;">%s</td>
        <td style="padding:4px 8px; color:%s;">%s</td>
        <td style="padding:4px 8px; text-align:center; color:%s;">%s</td>
      </tr>',
      DARK_MUTED,  htmlEscape(r$kind),
      DARK_TEXT,   htmlEscape(r$name),
      DARK_MUTED,  htmlEscape(r$created),
      ref_color,   htmlEscape(r$wiki_ref)
    )
  }, character(1L)), collapse = "\n")

  table_html <- sprintf(
    '<table style="border-collapse:collapse; width:100%%; font-size:%s;">
      <thead>
        <tr style="color:%s; text-align:left;">
          <th style="padding:4px 8px;">Kind</th>
          <th style="padding:4px 8px;">Name</th>
          <th style="padding:4px 8px;">Created</th>
          <th style="padding:4px 8px; text-align:center;">Wiki ref</th>
        </tr>
      </thead>
      <tbody>%s</tbody>
    </table>',
    EMAIL_FONT_BODY, DARK_MUTED,
    rows_html
  )

  no_wiki_count <- signal_482$count
  collapsible_block(
    title         = "New skills/rules without wiki context (last 7d)",
    summary_stats = sprintf(
      "%d new item%s — %d without wiki ref",
      length(signal_482$rows),
      if (length(signal_482$rows) == 1L) "" else "s",
      no_wiki_count
    ),
    html_body     = table_html
  )
}

signal_482_qa <- sprintf("<!-- QA:kb_signal_482=%d -->", signal_482$count)

# ── QA markers (tested by test-kb-digest.R) ────────────────────────────────────
qa_markers <- paste0(
  sprintf('<!-- QA:kb_digest_date=%s -->', report_date),
  '<!-- QA:kb_privacy=local_smtp_only -->',
  '<!-- QA:kb_collapsible=true -->',
  signal_479_qa,
  signal_480_qa,
  signal_481_qa,
  signal_482_qa
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
%s
%s
%s
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
  signal_479_html,
  signal_480_html,
  signal_481_html,
  signal_482_html,
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
