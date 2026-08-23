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
#
# Optional env vars:
#   ROBOREV_DAILY_DIR   Override daily report directory
#   EMAIL_DRY_RUN       Set to "1" to print body to stdout without sending
#   ROBOREV_DASHBOARD_URL        Explicit dashboard link override (wins outright)
#   ROBOREV_DASHBOARD_REPO_URL   GitHub repo fallback (default: llmtelemetry)
#   ROBOREV_DASHBOARD_LOCAL_PATH Locally-rendered dashboard path (default:
#                                 ~/docs_gh/llmtelemetry/_site/index.html)
#   See resolve_dashboard_links()/dashboard_cta_block() in email_styles.R.
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

# ROBOREV_DASHBOARD_URL / _REPO_URL / _LOCAL_PATH: resolved by
# resolve_dashboard_links() / dashboard_cta_block() in email_styles.R (sourced
# above). See that file for the full env-var contract and the 2026-08-22
# llmtelemetry-went-private rationale.

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

# ── Snapshot staleness guardrail ───────────────────────────────────────────────
# find_latest_json() picks the newest-mtime snapshot with no age check. If
# nightly generation has been failing silently for days, "latest" can still be
# stale — surface that loudly instead of quietly rendering old data as fresh.
snapshot_age_hrs <- tryCatch(
  as.numeric(difftime(Sys.time(), file.info(json_path)$mtime, units = "hours")),
  error = function(e) NA_real_
)
SNAPSHOT_STALE_THRESHOLD_HRS <- 24
snapshot_stale_block <- ""
if (!is.na(snapshot_age_hrs) && snapshot_age_hrs > SNAPSHOT_STALE_THRESHOLD_HRS) {
  message(sprintf(
    "send_roborev_email.R: snapshot is %.1fh old (threshold %dh) — flagging as stale",
    snapshot_age_hrs, SNAPSHOT_STALE_THRESHOLD_HRS
  ))
  snapshot_stale_block <- sprintf(
    '<div style="background-color:#5b1a1a; color:#fff5f5; border:2px solid #f08080;
      border-radius:6px; padding:14px 18px; margin:16px 0; font-size:%s;">
      <strong style="font-size:15px;">&#9888; STALE SNAPSHOT</strong><br>
      <span>This report is based on a snapshot generated %.1fh ago (threshold:
      %dh) — nightly generation may have failed or stalled. The data below may
      not reflect recent activity. Check roborev_daily_report.R / the nightly
      cron log.</span>
    </div>',
    EMAIL_FONT_BODY, snapshot_age_hrs, SNAPSHOT_STALE_THRESHOLD_HRS
  )
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

# ── Project slug → GitHub URL resolution ───────────────────────────────────────
# Previously every project slug was hardcoded to
# https://github.com/JohnGavin/<slug> — this 404s for slugs that are not
# public GitHub repos (e.g. "premortem", a local-only planning folder). Only
# render a hyperlink when the slug resolves to a KNOWN public repo.
#
# To extend: add a line to KNOWN_PUBLIC_REPOS below. resolve_repo_url() also
# falls back to asking git for the slug's local remote (when the repo exists
# under ~/docs_gh/<slug>) and uses it ONLY if it resolves to a github.com URL
# — it never fabricates a URL for an unresolvable slug.
KNOWN_PUBLIC_REPOS <- c(
  "llm"          = "https://github.com/JohnGavin/llm",
  "llmtelemetry" = "https://github.com/JohnGavin/llmtelemetry"
)

resolve_repo_url <- function(slug) {
  if (is.null(slug) || !nzchar(slug)) return(NULL)
  if (slug %in% names(KNOWN_PUBLIC_REPOS)) return(unname(KNOWN_PUBLIC_REPOS[[slug]]))
  local_path <- file.path(Sys.getenv("HOME"), "docs_gh", slug)
  if (!dir.exists(file.path(local_path, ".git"))) return(NULL)
  remote_url <- tryCatch(
    suppressWarnings(system2(
      "git", c("-C", local_path, "config", "--get", "remote.origin.url"),
      stdout = TRUE, stderr = FALSE
    )),
    error = function(e) character(0L)
  )
  if (length(remote_url) != 1L || !nzchar(remote_url) || !grepl("github\\.com", remote_url)) {
    return(NULL)
  }
  url <- sub("\\.git$", "", remote_url)
  url <- sub("^git@github\\.com:", "https://github.com/", url)
  url
}

# repo_link_or_text(): renders an <a> only when resolve_repo_url() succeeds,
# otherwise the plain slug — used everywhere a project/repo name is shown.
repo_link_or_text <- function(slug, colour) {
  if (is.null(slug) || !nzchar(slug)) return("")
  url <- resolve_repo_url(slug)
  if (is.null(url)) return(slug)
  sprintf('<a href="%s" style="color:%s;">%s</a>', url, colour, slug)
}

# id_link_for_outlier(): renders an outlier-table finding ID as a link to the
# GitHub commit (or compare view, for range reviews) roborev actually
# reviewed, using review_jobs.git_ref (persisted in the JSON snapshot as
# commit_sha — see roborev_daily_report.R's load_commit_sha()). Falls back to
# a plain-text ID when the repo slug doesn't resolve to a known public GitHub
# URL, or when commit_sha is missing/NA/blank — llm#835 established that
# fabricating a link (there: <repo>/issues/<review_id>, a 404) is worse than
# no link, since review_id is a roborev DB primary key, not a GitHub issue
# number.
id_link_for_outlier <- function(rid, commit_sha, repo, colour) {
  if (is.null(rid) || !nzchar(as.character(rid))) return("")
  if (is.null(commit_sha) || is.na(commit_sha) || !nzchar(commit_sha)) {
    return(as.character(rid))
  }
  repo_url <- resolve_repo_url(repo)
  if (is.null(repo_url)) return(as.character(rid))

  target_url <- if (grepl("\\.\\.", commit_sha)) {
    shas <- strsplit(commit_sha, "\\.\\.")[[1]]
    if (length(shas) != 2L || !nzchar(shas[1]) || !nzchar(shas[2])) {
      return(as.character(rid))
    }
    sprintf("%s/compare/%s...%s", repo_url, shas[1], shas[2])
  } else {
    sprintf("%s/commit/%s", repo_url, commit_sha)
  }
  sprintf('<a href="%s" style="color:%s;">%s</a>', target_url, colour, rid)
}

# ── reviews.db read-only helpers (llm#961) ─────────────────────────────────────
# The daily report runs at 07:00 UTC, 90 minutes BEFORE
# roborev_severity_autoclose (08:30 UTC — see
# bin/launchd-recorders/roborev-severity-autoclose). Any metric computed over
# "the last 24h" therefore shows ~0 closes on almost every run, by
# construction of the schedule, not because anything is broken. #738/#739
# narrowed the old zero-action check to the source-of-truth throughput field,
# but that field is STILL a 24h/right-censored count and fires just as
# reliably. These helpers read ~/.roborev/reviews.db directly (read-only —
# NEVER writes) for two metrics that do not depend on same-day job ordering:
#   1. close rate over a 2-8 day AGED cohort (the closer has had a full
#      schedule cycle to act on these by the time they are 2 days old)
#   2. currently-open findings the autocloser will never touch automatically
#      (severity above its threshold, or unparseable) — the actionable count.

ROBOREV_DB <- Sys.getenv(
  "ROBOREV_DB",
  file.path(Sys.getenv("HOME"), ".roborev", "reviews.db")
)

# query_reviews_db(): read-only query via the sqlite3 CLI (-json mode, so
# embedded newlines/quotes in review `output` text round-trip correctly),
# parsed with jsonlite. Returns NULL on any failure (missing binary, missing
# DB, query error, timeout) — callers must degrade gracefully rather than
# crash the report on a DB hiccup.
query_reviews_db <- function(sql, timeout_sec = 15L) {
  if (!nzchar(ROBOREV_DB) || !file.exists(ROBOREV_DB)) return(NULL)
  out <- tryCatch(
    system2("sqlite3", args = c("-json", shQuote(ROBOREV_DB), shQuote(sql)),
            stdout = TRUE, stderr = TRUE, timeout = timeout_sec),
    error = function(e) NULL
  )
  if (is.null(out)) return(NULL)
  status <- attr(out, "status")
  if (!is.null(status) && !identical(status, 0L)) {
    message("send_roborev_email.R: reviews.db query failed: ", paste(out, collapse = " "))
    return(NULL)
  }
  txt <- paste(out, collapse = "\n")
  if (!nzchar(trimws(txt))) return(list())
  tryCatch(jsonlite::fromJSON(txt, simplifyVector = FALSE), error = function(e) NULL)
}

# ── Lagged close rate (reviews aged 2-8 days) — replaces the 24h close rate ───
LAGGED_WINDOW_MIN_DAYS <- 2L
LAGGED_WINDOW_MAX_DAYS <- 8L
lagged_close_rate <- NA_real_
lagged_cohort_n   <- NA_integer_
lagged_sql <- sprintf(
  "SELECT closed, count(*) AS n FROM reviews WHERE datetime(created_at) >= datetime('now','-%d days') AND datetime(created_at) < datetime('now','-%d days') GROUP BY closed;",
  LAGGED_WINDOW_MAX_DAYS, LAGGED_WINDOW_MIN_DAYS
)
lagged_rows <- query_reviews_db(lagged_sql)
if (!is.null(lagged_rows)) {
  lagged_closed_n <- 0L
  lagged_open_n   <- 0L
  for (row in lagged_rows) {
    n <- as.integer(row[["n"]])
    if (is.na(n)) n <- 0L
    if (isTRUE(row[["closed"]] == 1)) lagged_closed_n <- n
    if (isTRUE(row[["closed"]] == 0)) lagged_open_n   <- n
  }
  lagged_cohort_n <- lagged_closed_n + lagged_open_n
  if (lagged_cohort_n > 0L) lagged_close_rate <- lagged_closed_n / lagged_cohort_n
}

# ── Above-threshold / unparseable open findings — actionable backlog metrics ──
# Mirrors the severity parse + threshold comparison in
# roborev_severity_autoclose.sh (`_parse_max_severity` / `_should_close`) so
# these counts match what the autocloser will (not) act on.
#
# llm#961 follow-up: the original version of this block alerted on the
# STANDING total (measured at 105 of 125 open reviews the day this was
# diagnosed — 84% of the whole backlog). That total barely moves day to day,
# so the banner fired every single day regardless of whether anything new
# happened — exactly the cry-wolf failure #961 exists to remove, just with a
# truer label. It also conflated two different problems under one number: a
# High/Critical finding (a triage backlog for a human) and an unparseable
# severity (a data-quality signal about the `Severity:` / `**Severity**:`
# regex, not something to triage). Both are now split:
#   - above-threshold vs unparseable: disjoint counts, separate wording
#   - total (standing backlog, shown as context only) vs new (created since
#     the previous report — this is what the alarm fires on)
SEVERITY_ORDINAL <- c(critical = 4L, high = 3L, medium = 2L, low = 1L)
AUTOCLOSE_THRESHOLD_STR <- local({
  v <- tolower(Sys.getenv("ROBOREV_SEVERITY_AUTOCLOSE_THRESHOLD", "medium"))
  # "medium" matches the current production invocation — see
  # bin/launchd-recorders/roborev-severity-autoclose ("--threshold" "medium").
  if (v %in% names(SEVERITY_ORDINAL)) v else "medium"
})
AUTOCLOSE_THRESHOLD_ORD <- unname(SEVERITY_ORDINAL[[AUTOCLOSE_THRESHOLD_STR]])

parse_max_severity_ordinal <- function(text) {
  if (is.null(text) || is.na(text) || !nzchar(text)) return(NA_integer_)
  # llm#972 cause 1: some agents emit "- Severity: High" (no bold markers)
  # instead of "- **Severity**: High". The `\\*{0,2}` on both sides of
  # "Severity" makes the markdown bold markers optional so both shapes
  # parse, while still anchoring on "Severity" + colon + one of the four
  # levels — a bare mention of the word "severity" in prose (no colon
  # immediately after) still does not match.
  # Mirrored in roborev_severity_autoclose.sh's `_parse_max_severity()` —
  # keep both patterns in sync; see the comment there.
  m <- gregexpr("(?i)\\*{0,2}Severity\\*{0,2}:\\s*(Critical|High|Medium|Low)", text, perl = TRUE)
  words <- regmatches(text, m)[[1]]
  if (length(words) == 0L) return(NA_integer_)
  words <- tolower(sub(".*:\\s*", "", words))
  max(unname(SEVERITY_ORDINAL[words]), na.rm = TRUE)
}

# llm#972 cause 2: `verdict_bool` is NOT a function of the review output —
# identical bytes ("SEVERITY_THRESHOLD_MET") are recorded with verdict_bool=1
# AND verdict_bool=0 in the live DB, so a row landing in the "unparseable"
# bucket (no `Severity:` marker found) does NOT mean "this review found
# something that needs triage". Three very different situations were being
# reported as one undifferentiated number:
#   - the agent produced nothing usable at all (crash / refusal / env
#     problem) — an AGENT-HEALTH signal, not a code finding
#   - the review ran and explicitly found nothing — not a triage item
#   - genuinely unrecognised text — the real residual that still needs eyes
# classify_unparseable_finding() below splits exactly those three apart for
# any row whose severity could not be parsed. It does NOT touch parseable
# rows (those go through the above-threshold path in
# classify_open_findings() unchanged) — this is purely a finer-grained
# sub-classification of the existing "unparseable" bucket, so
# total_unparseable_open_n / new_unparseable_open_n keep meaning exactly what
# they meant before (== not_reviewed_n + passed_n + unclassified_n, always,
# by construction of the loop below).

# normalize_ws(): the stored `output` text can wrap mid-phrase (observed live:
# "No\n issues found" instead of one line), so a literal substring match on
# raw text silently misses exactly the cases this classifier exists to catch.
# Collapse all whitespace runs (including embedded newlines) to a single
# space before matching.
normalize_ws <- function(text) {
  if (is.null(text) || is.na(text)) return("")
  gsub("\\s+", " ", trimws(text))
}

# NOT_REVIEWED_PATTERNS: the review agent produced nothing usable — an
# AGENT-HEALTH signal (crash / refusal / environment problem), not a code
# finding. Matched against lower-cased, whitespace-normalised text.
NOT_REVIEWED_PATTERNS <- c(
  "no review output generated",
  "unable to access",
  "cannot perform the requested code review"
)

# PASSED_PATTERNS: the review ran and explicitly found nothing — not a
# triage backlog item.
#   "severity_threshold_met" — 96 of 120 identical-byte rows are recorded
#   closed=1 with no findings text at all, vs 14 stuck open with the SAME
#   bytes; treating it as "passed" is INFERRED from that distribution, not
#   documented roborev semantics — the name could plausibly mean the
#   opposite. Do not build anything load-bearing on this inference beyond
#   "not a thing a human needs to triage".
PASSED_PATTERNS <- c(
  "severity_threshold_met",
  "no issues found",
  "no code changes were provided"
)

.pattern_matches <- function(text_norm, patterns) {
  any(vapply(patterns, function(p) grepl(p, text_norm, fixed = TRUE), logical(1L)))
}

# classify_unparseable_finding(): only called for rows whose severity could
# NOT be parsed (parse_max_severity_ordinal() returned NA). Returns one of
# "not_reviewed" | "passed" | "unclassified". "unclassified" is the
# deliberate residual — matches neither known shape — and MUST stay visible
# on its own rather than being folded into either named bucket, so a
# genuinely new failure mode doesn't disappear into a total.
classify_unparseable_finding <- function(text) {
  norm <- tolower(normalize_ws(text))
  if (.pattern_matches(norm, NOT_REVIEWED_PATTERNS)) return("not_reviewed")
  if (.pattern_matches(norm, PASSED_PATTERNS)) return("passed")
  "unclassified"
}

# classify_open_findings(): splits a set of open-findings rows (each with
# `output`/`review_id`/`repo`) into two DISJOINT top-level buckets —
# above-threshold (parseable severity > AUTOCLOSE_THRESHOLD_ORD) and
# unparseable (no `Severity:` marker, bold or plain, found at all). A row
# lands in at most one top-level bucket, so the two counts never
# double-count the same finding. Unparseable rows are further split into
# not_reviewed / passed / unclassified via classify_unparseable_finding()
# (llm#972 cause 2) — those three sub-counts always sum to unparse_n.
classify_open_findings <- function(rows) {
  above_n    <- 0L
  above_rows <- list()
  unparse_n  <- 0L
  not_reviewed_n <- 0L
  passed_n       <- 0L
  unclassified_n <- 0L
  for (r in rows) {
    ord <- parse_max_severity_ordinal(r[["output"]])
    if (is.na(ord)) {
      unparse_n <- unparse_n + 1L
      sub_cls <- classify_unparseable_finding(r[["output"]])
      if (identical(sub_cls, "not_reviewed")) {
        not_reviewed_n <- not_reviewed_n + 1L
      } else if (identical(sub_cls, "passed")) {
        passed_n <- passed_n + 1L
      } else {
        unclassified_n <- unclassified_n + 1L
      }
    } else if (ord > AUTOCLOSE_THRESHOLD_ORD) {
      above_n <- above_n + 1L
      sev_label <- names(SEVERITY_ORDINAL)[SEVERITY_ORDINAL == ord]
      above_rows[[length(above_rows) + 1L]] <- list(
        review_id    = r[["review_id"]],
        repo         = if (is.null(r[["repo"]])) "" else r[["repo"]],
        max_severity = sev_label
      )
    }
  }
  list(
    above_n = above_n, above_rows = above_rows, unparse_n = unparse_n,
    not_reviewed_n = not_reviewed_n, passed_n = passed_n,
    unclassified_n = unclassified_n
  )
}

# NEW_WINDOW_HOURS: the report runs once/day, so "new since the previous
# report" is approximated as "created within the last 24h" — a fixed
# lookback tied directly to the report's own daily cadence (see
# bin/roborev_daily_cron.sh), not an arbitrary magic number. Checked directly
# against the production DB before writing this: reviews.created_at is
# stored space-separated with NO timezone suffix (observed format
# "2026-08-18 15:06:41", not the "T"+offset ISO-8601 form some older rows in
# this codebase were assumed to use) — consistent with sqlite's own
# CURRENT_TIMESTAMP default, which is UTC, matching datetime('now'). sqlite's
# datetime()/'now' modifier pair already handles this format correctly — the
# same pattern is proven in lagged_sql above. Every label below states this
# window explicitly so the reader never has to guess what "new" means or
# assume UTC vs local.
NEW_WINDOW_HOURS <- 24L

open_findings_sql_base <- paste(
  "SELECT rv.id AS review_id, rv.output AS output, rp.name AS repo",
  "FROM reviews rv",
  "JOIN review_jobs rj ON rj.id = rv.job_id",
  "JOIN repos rp ON rp.id = rj.repo_id",
  "WHERE rv.closed = 0 AND rv.verdict_bool = 0"
)
total_open_findings_sql <- paste0(open_findings_sql_base, ";")
new_open_findings_sql <- paste0(
  open_findings_sql_base,
  sprintf(" AND datetime(rv.created_at) >= datetime('now', '-%d hours');", NEW_WINDOW_HOURS)
)

total_above_threshold_open_n <- NA_integer_
total_unparseable_open_n     <- NA_integer_
total_not_reviewed_open_n    <- NA_integer_
total_passed_open_n          <- NA_integer_
total_unclassified_open_n    <- NA_integer_
new_above_threshold_open_n   <- NA_integer_
new_above_threshold_rows     <- list()
new_unparseable_open_n       <- NA_integer_
new_not_reviewed_open_n      <- NA_integer_
new_passed_open_n            <- NA_integer_
new_unclassified_open_n      <- NA_integer_

total_open_findings <- query_reviews_db(total_open_findings_sql)
if (!is.null(total_open_findings)) {
  cls_total <- classify_open_findings(total_open_findings)
  total_above_threshold_open_n <- cls_total$above_n
  total_unparseable_open_n     <- cls_total$unparse_n
  total_not_reviewed_open_n    <- cls_total$not_reviewed_n
  total_passed_open_n          <- cls_total$passed_n
  total_unclassified_open_n    <- cls_total$unclassified_n
} else {
  message("send_roborev_email.R: could not query open findings from reviews.db — ",
          "standing backlog counts unavailable")
}

new_open_findings <- query_reviews_db(new_open_findings_sql)
if (!is.null(new_open_findings)) {
  cls_new <- classify_open_findings(new_open_findings)
  new_above_threshold_open_n <- cls_new$above_n
  new_above_threshold_rows   <- cls_new$above_rows
  new_unparseable_open_n     <- cls_new$unparse_n
  new_not_reviewed_open_n    <- cls_new$not_reviewed_n
  new_passed_open_n          <- cls_new$passed_n
  new_unclassified_open_n    <- cls_new$unclassified_n
} else {
  message("send_roborev_email.R: could not query new open findings from reviews.db — ",
          "delta counts unavailable (rendering nothing rather than a false alert)")
}

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
# 7-day headline aliases (llm#738/#739): the 24h window is right-censored to
# near-empty because median close latency (13-49h) usually exceeds 24h, so
# d1_ttc_p50/d1_att_p50 are structurally "n/a" by design, not a defect. The
# 7d p50s below are shown in the 24h headline block instead, explicitly
# labelled "(7d)" so the window is unambiguous.
d7_ttc_p50 <- d7[["speed"]][["ttc_p50_hrs"]]
d7_att_p50 <- d7[["speed"]][["att_p50"]]

# §3 Trends
tr <- d7[["trends"]]

# §4 Outliers (top-5 of top-10). outliers_recent_7d replaces the old
# outliers_14d key (llm#793-followup) — ranked by closed_at within a 7-day
# window instead of created_at within 14 days, so a single old bulk-close
# event can no longer freeze the leaderboard for up to two weeks.
outliers_block   <- snap[["outliers_recent_7d"]]
outlier_window_days <- (outliers_block[["window_days"]] %||% 7L)
outliers_by_time <- outliers_block[["by_time"]]
if (is.null(outliers_by_time)) outliers_by_time <- list()
n_outliers <- min(5L, length(outliers_by_time))

outliers_by_att <- outliers_block[["by_attempts"]]
if (is.null(outliers_by_att)) outliers_by_att <- list()
n_outliers_att <- min(5L, length(outliers_by_att))
# Fix (llm#793-followup): when every outlier closed in a single attempt, the
# "by attempts" table is a degenerate duplicate of "by time-to-close" (no
# retry data to rank on). Prefer the producer's explicit flag; fall back to
# recomputing it here so this still works against an older snapshot.
outliers_by_attempts_degenerate <- isTRUE(outliers_block[["by_attempts_degenerate"]]) ||
  (length(outliers_by_att) > 0L && all(vapply(
    outliers_by_att, function(r) isTRUE((r[["n_attempts"]] %||% 1L) <= 1L), logical(1L)
  )))

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
# llm#961: d1_ttc_p50/d1_att_p50/d1_close_rate/d1_closed_in_window (the
# right-censored 24h cohort speed metrics and source-of-truth throughput) are
# no longer read here — they fed the retired zero-action trap (see below) and
# are structurally near-zero by schedule, not signal. The 24h "close rate"
# headline row now uses lagged_close_rate (reviews aged 2-8 days) instead.

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

# ── #961: retired zero-action trap ─────────────────────────────────────────────
# The #484/#738/#739 "zero-action trap" fired whenever the 24h source-of-truth
# throughput (d1_closed_in_window) was 0 and attempted a self-healing ETL
# refresh before alerting. That check is retired: given the 07:00/08:30 UTC
# schedule gap documented above, d1_closed_in_window is 0 on almost every run
# regardless of pipeline health, so the trap was alerting on its own scheduling,
# not on a fault (llm#961). The staleness banner below (snapshot age > 24h)
# already covers genuine "nightly generation stalled" failures independently of
# window semantics. The replacement signal is new_above_threshold_open_n,
# computed above directly from reviews.db — and it is itself the DELTA since
# the previous report (last NEW_WINDOW_HOURS), not the standing total,
# because the standing total was found to fire on ~84% of the whole open
# backlog every day (llm#961 follow-up).
above_threshold_fired <- isTRUE(!is.na(new_above_threshold_open_n) && new_above_threshold_open_n > 0L)

# ── Deploy staleness banner (llm#510 attempt #3) ──────────────────────────────
# cron_deploy_pull.sh (sourced by bin/roborev_daily_cron.sh) writes a status
# file every run recording whether the local main checkout was successfully
# brought up to date with origin/main before this email was generated. If the
# pull failed, or main is still behind, the metrics below were computed
# against stale code — surface that prominently instead of silently.
deploy_status_file <- Sys.getenv(
  "DEPLOY_STATUS_FILE",
  file.path(Sys.getenv("HOME"), ".claude", "logs", "cron_deploy_status.json")
)
deploy_stale_block <- ""
if (file.exists(deploy_status_file)) {
  deploy_status <- tryCatch(
    jsonlite::fromJSON(deploy_status_file, simplifyVector = TRUE),
    error = function(e) NULL
  )
  if (!is.null(deploy_status)) {
    .ds_ok     <- isTRUE(deploy_status$ok)
    .ds_behind <- suppressWarnings(as.integer(deploy_status$behind %||% 0L))
    .ds_behind_positive <- isTRUE(!is.na(.ds_behind) && .ds_behind > 0L)
    if (!.ds_ok || .ds_behind_positive) {
      .ds_behind_str <- if (is.na(.ds_behind)) "an unknown number of" else as.character(.ds_behind)
      deploy_stale_block <- sprintf(
        '<div style="background-color:#5b1a1a; color:#fff5f5; border:2px solid #f08080;
          border-radius:6px; padding:14px 18px; margin:16px 0; font-size:%s;">
          <strong style="font-size:15px;">&#9888; DEPLOY STALE</strong><br>
          <span>Local main is %s commit(s) behind origin/main (reason: %s) —
          merged fixes are NOT live. See llm#510.</span>
        </div>',
        EMAIL_FONT_BODY, .ds_behind_str, deploy_status$reason %||% "unknown"
      )
    }
  }
}

# Above-threshold-open-findings block (prepended before dashboard CTA when
# fired — llm#961, replaces the #484 zero-action block). Fires on the DELTA
# — new above-threshold findings since the previous report (last
# NEW_WINDOW_HOURS) — not the standing total, so it stops firing on days
# when nothing new arrived (llm#961 follow-up). The standing total is shown
# as parenthetical context, not as part of the alarm condition.
above_threshold_block <- if (above_threshold_fired) {
  detail_items <- vapply(new_above_threshold_rows, function(x) {
    sprintf("#%s %s (%s)", x$review_id, x$repo, x$max_severity)
  }, character(1L))
  shown    <- utils::head(detail_items, 10L)
  more_n   <- new_above_threshold_open_n - length(shown)
  more_str <- if (more_n > 0L) sprintf(" (+%d more)", more_n) else ""
  total_str <- if (is.na(total_above_threshold_open_n)) "" else
    sprintf(" (%s open in total)", fmt_int(total_above_threshold_open_n))
  sprintf(
    '<div style="background-color:#5b1a1a; color:#fff5f5; border:2px solid #f08080;
      border-radius:6px; padding:14px 18px; margin:16px 0; font-size:%s;">
      <strong style="font-size:15px;">&#9888; %d New Above-Threshold Open Finding(s) (created in the last %dh)%s</strong><br>
      <span>New open findings at or above the autoclose severity threshold
      (%s) since the previous report — roborev will not close them
      automatically, so they need human triage: %s%s</span>
    </div>',
    EMAIL_FONT_BODY, new_above_threshold_open_n, NEW_WINDOW_HOURS, total_str,
    AUTOCLOSE_THRESHOLD_STR, paste(shown, collapse = "; "), more_str
  )
} else ""

# Unparseable-severity block — a DATA-QUALITY signal (no `Severity:` marker,
# bold or plain, was found in the agent's output), not a triage backlog. Kept
# separate from above_threshold_block per llm#961 follow-up requirement 2,
# and rendered with muted/informational styling rather than the red alarm —
# it is not something a human needs to triage the way a High/Critical
# finding is, and giving it its own red banner would just relocate the
# cry-wolf problem rather than remove it. Shown whenever there is a standing
# total to report (context, requirement 3), with the new-since-last-report
# count called out inline.
unparseable_block <- if (isTRUE(!is.na(total_unparseable_open_n) && total_unparseable_open_n > 0L)) {
  new_str <- if (is.na(new_unparseable_open_n)) "n/a" else fmt_int(new_unparseable_open_n)
  # llm#972 cause 2: break the undifferentiated total down into its three
  # sub-populations so each stays visible on its own — see the comment on
  # classify_unparseable_finding() for why this matters (agent-health vs
  # no-op vs genuine residual).
  breakdown_str <- sprintf(
    "Breakdown (standing): not-reviewed (agent-health) %s &nbsp;|&nbsp; passed (no findings) %s &nbsp;|&nbsp; unclassified %s.",
    fmt_int(total_not_reviewed_open_n), fmt_int(total_passed_open_n), fmt_int(total_unclassified_open_n)
  )
  # Requirement 2: if "unclassified" is absorbing most of the bucket, say so
  # explicitly rather than letting it hide inside the total — a genuinely
  # mis-parsed finding disappearing into a named-but-vague bucket is exactly
  # how this issue cluster (llm#972) started.
  unclassified_warn <- if (isTRUE(
    !is.na(total_unclassified_open_n) && !is.na(total_unparseable_open_n) &&
    total_unparseable_open_n > 0L &&
    (total_unclassified_open_n / total_unparseable_open_n) > 0.5
  )) {
    sprintf(
      '<br><strong style="color:#f08080;">&#9888; %s of %s unparseable findings (&gt;50%%) are unclassified — the classifier patterns in send_roborev_email.R may need updating.</strong>',
      fmt_int(total_unclassified_open_n), fmt_int(total_unparseable_open_n)
    )
  } else ""
  sprintf(
    '<div style="background-color:%s; color:%s; border:1px solid %s;
      border-radius:6px; padding:10px 14px; margin:10px 0; font-size:%s;">
      <strong>&#8505; Unparseable severity (data-quality, not triage):</strong>
      %s new in the last %dh, %s open in total.
      The severity parser found no <code>Severity:</code> marker in
      these findings&#39; output — a signal about the parser/agent output
      format, not a backlog to close.<br>
      %s%s
    </div>',
    dark_card, dark_text, accent_purple, EMAIL_FONT_BODY,
    new_str, NEW_WINDOW_HOURS, fmt_int(total_unparseable_open_n),
    breakdown_str, unclassified_warn
  )
} else ""

# Dashboard link CTA (llm#961: above_threshold_block prepended when it fires,
# followed by unparseable_block — llm#961 follow-up, always separate from the
# alarm; llm#510: deploy_stale_block prepended ahead of that when the deploy
# pull failed or main is still behind origin; llm#793-followup:
# snapshot_stale_block prepended first — a stale *snapshot* is a more basic
# problem than a stale *deploy*, so it leads)
dashboard_block <- paste0(
  snapshot_stale_block,
  deploy_stale_block,
  above_threshold_block,
  unparseable_block,
  dashboard_cta_block(accent_blue)
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
    # llm#961: NOT a 24h metric — the 07:00 report runs before the 08:30
    # autocloser, so a 24h close rate is ~0 by schedule, not by defect. Shown
    # as an aged cohort instead, same convention as the 7d rows below.
    c(sprintf("close rate (aged %d-%dd)", LAGGED_WINDOW_MIN_DAYS, LAGGED_WINDOW_MAX_DAYS),
                                       fmt_rate(lagged_close_rate)),
    c("hours to close p50 (7d)",      fmt_num(d7_ttc_p50)),
    c("attempts p50 (7d)",            fmt_att(d7_att_p50)),
    # llm#961 follow-up: standing backlog totals shown as CONTEXT (not an
    # alarm — see above_threshold_block/unparseable_block for the delta-only
    # alert), each split above-threshold vs unparseable and each labelled
    # with its exact window.
    c("open above-threshold (standing backlog)",
                                       fmt_int(total_above_threshold_open_n)),
    c("open unparseable severity (standing backlog)",
                                       fmt_int(total_unparseable_open_n)),
    c(sprintf("new above-threshold (last %dh)", NEW_WINDOW_HOURS),
                                       fmt_int(new_above_threshold_open_n)),
    c(sprintf("new unparseable severity (last %dh)", NEW_WINDOW_HOURS),
                                       fmt_int(new_unparseable_open_n))
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
    commit_sha <- r[["commit_sha"]] %||% NA_character_
    id_link <- id_link_for_outlier(rid, commit_sha, repo, accent_blue)
    repo_link <- repo_link_or_text(repo, accent_blue)
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
    sprintf('<tr><td colspan="5" style="padding:6px; color:%s;">(no data in %dd window)</td></tr>',
            dark_muted, outlier_window_days))
}
outlier_ttc_inner <- paste0(outlier_ttc_inner, "</table>")
outlier_ttc_html  <- collapsible_block(
  sprintf("Top-5 Outliers by Time-to-Close (%dd, by closed_at)", outlier_window_days),
  sprintf("%d outlier(s) — click to expand", n_outliers),
  outlier_ttc_inner
)

# §4 Outliers — top-5 by attempts (llm#449: linkified IDs+Repos, renamed TTC header)
#
# Fix (llm#793-followup): when every closed review in the window closed on its
# first attempt, this table is a degenerate duplicate of the by-time-to-close
# table above (nothing to rank on). Replace it with a one-line note instead of
# rendering an identical copy under a different heading.
if (outliers_by_attempts_degenerate) {
  outlier_att_html <- collapsible_block(
    sprintf("Outliers by Attempts-to-Close (%dd)", outlier_window_days),
    "no retry data",
    sprintf(
      '<p style="color:%s; font-size:%s; margin:0;">No retry data — every review in this window closed in a single attempt.</p>',
      dark_muted, EMAIL_FONT_BODY
    ),
    open = FALSE
  )
} else {
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
      commit_sha <- r[["commit_sha"]] %||% NA_character_
      id_link <- id_link_for_outlier(rid, commit_sha, repo, accent_blue)
      repo_link <- repo_link_or_text(repo, accent_blue)
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
      sprintf('<tr><td colspan="5" style="padding:6px; color:%s;">(no data in %dd window)</td></tr>',
              dark_muted, outlier_window_days))
  }
  outlier_att_inner <- paste0(outlier_att_inner, "</table>")
  outlier_att_html  <- collapsible_block(
    sprintf("Top-5 Outliers by Attempts-to-Close (%dd, by closed_at)", outlier_window_days),
    sprintf("%d outlier(s) — click to expand", n_outliers_att),
    outlier_att_inner
  )
}

# §5 Per-project severity frequency table (llm#449)
severity_rows_data <- snap[["severity_by_project_7d"]]
if (is.null(severity_rows_data)) severity_rows_data <- list()

# Fix (llm#793-followup): the table used to render only High/Medium/Low/Total,
# but compute_severity_by_project() always includes a fourth "Unknown"
# (null-severity) bucket in Total — so the displayed columns silently
# under-summed Total (e.g. observed 103+103+8=214 vs Total=224, the missing
# 10 being Unknown-severity findings). Add the Unknown column so the display
# reconciles with Total, and flag any row where it still doesn't (Fix: §4.2
# self-consistency invariant).
severity_inner <- sprintf(
  '<table style="border-collapse:collapse; width:100%%; font-size:11px;">
  <tr style="background-color:%s;">
    <th style="padding:5px 8px; border:1px solid %s; color:white; text-align:left;">Project</th>
    <th style="padding:5px; border:1px solid %s; color:white; text-align:right;">High</th>
    <th style="padding:5px; border:1px solid %s; color:white; text-align:right;">Medium</th>
    <th style="padding:5px; border:1px solid %s; color:white; text-align:right;">Low</th>
    <th style="padding:5px; border:1px solid %s; color:white; text-align:right;">Unknown</th>
    <th style="padding:5px; border:1px solid %s; color:white; text-align:right;">Total</th>
  </tr>',
  dark_row_alt, dark_border, dark_border, dark_border, dark_border, dark_border, dark_border
)
if (length(severity_rows_data) > 0L) {
  for (i in seq_along(severity_rows_data)) {
    sr <- severity_rows_data[[i]]
    bg <- if (i %% 2 == 0) dark_row_alt else dark_card
    repo_val <- sr[["repo"]] %||% ""
    repo_link <- repo_link_or_text(repo_val, accent_blue)
    sr_high    <- as.integer(sr[["High"]]    %||% 0L)
    sr_medium  <- as.integer(sr[["Medium"]]  %||% 0L)
    sr_low     <- as.integer(sr[["Low"]]     %||% 0L)
    sr_unknown <- as.integer(sr[["Unknown"]] %||% 0L)
    sr_total   <- as.integer(sr[["Total"]]   %||% 0L)
    # §4.2 self-consistency invariant: displayed columns must sum to Total.
    sr_sum_ok <- (sr_high + sr_medium + sr_low + sr_unknown) == sr_total
    total_display <- if (sr_sum_ok) fmt_int(sr_total) else sprintf("&#9888; %s", fmt_int(sr_total))
    severity_inner <- paste0(severity_inner, sprintf(
      '<tr style="background-color:%s;">
        <td style="padding:4px 8px; border:1px solid %s; color:%s;">%s</td>
        <td style="padding:4px 5px; border:1px solid %s; color:%s; text-align:right;">%s</td>
        <td style="padding:4px 5px; border:1px solid %s; color:%s; text-align:right;">%s</td>
        <td style="padding:4px 5px; border:1px solid %s; color:%s; text-align:right;">%s</td>
        <td style="padding:4px 5px; border:1px solid %s; color:%s; text-align:right;">%s</td>
        <td style="padding:4px 5px; border:1px solid %s; color:%s; text-align:right; font-weight:bold;">%s</td>
      </tr>',
      bg,
      dark_border, dark_text, repo_link,
      dark_border, accent_orange, fmt_int(sr_high),
      dark_border, accent_blue, fmt_int(sr_medium),
      dark_border, dark_muted, fmt_int(sr_low),
      dark_border, dark_muted, fmt_int(sr_unknown),
      dark_border, dark_text, total_display
    ))
  }
} else {
  severity_inner <- paste0(severity_inner,
    sprintf('<tr><td colspan="6" style="padding:6px; color:%s;">(no data in 7-day window)</td></tr>', dark_muted))
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

# QA markers (tested by test-roborev-daily-email.R)
# llm#484: added n_reviews and d1_n_reviews markers for diagnostic visibility
# llm#961: zero_action_trap_fired is kept as the marker KEY (test compat) but
# now reflects the above-threshold-open-findings DELTA alert, not the retired
# 24h-close-rate trap.
# llm#961 follow-up: the single above_threshold_open_n marker is replaced by
# four markers — new/total x above-threshold/unparseable — plus the window
# (new_window_hours) the "new" figures were computed over, since the original
# marker conflated a standing-backlog total with a triage delta and merged
# two different problem types (severity vs parse-failure) into one number.
# llm#972 cause 2: the unparseable total is further split into
# not_reviewed/passed/unclassified (new + total, six markers) — these three
# always sum to new_unparseable_open_n / total_unparseable_open_n
# respectively, by construction of classify_open_findings().
qa_markers <- sprintf(
  '<!-- QA:report_date=%s --><!-- QA:issues_found_closed=%d --><!-- QA:close_rate=%s --><!-- QA:dashboard_url=%s --><!-- QA:d1_n_reviews=%d --><!-- QA:d7_n_reviews=%d --><!-- QA:d1_other_n=%d --><!-- QA:zero_action_trap_fired=%s --><!-- QA:new_above_threshold_open_n=%s --><!-- QA:total_above_threshold_open_n=%s --><!-- QA:new_unparseable_open_n=%s --><!-- QA:total_unparseable_open_n=%s --><!-- QA:new_not_reviewed_open_n=%s --><!-- QA:total_not_reviewed_open_n=%s --><!-- QA:new_passed_open_n=%s --><!-- QA:total_passed_open_n=%s --><!-- QA:new_unclassified_open_n=%s --><!-- QA:total_unclassified_open_n=%s --><!-- QA:new_window_hours=%d --><!-- QA:lagged_close_rate_window=%d-%dd -->',
  report_date, issues_found_closed, fmt_rate(close_rate), effective_dashboard_url(),
  d1_n_reviews, d7_n_reviews, d1_other_n, tolower(as.character(above_threshold_fired)),
  if (is.na(new_above_threshold_open_n)) "NA" else as.character(new_above_threshold_open_n),
  if (is.na(total_above_threshold_open_n)) "NA" else as.character(total_above_threshold_open_n),
  if (is.na(new_unparseable_open_n)) "NA" else as.character(new_unparseable_open_n),
  if (is.na(total_unparseable_open_n)) "NA" else as.character(total_unparseable_open_n),
  if (is.na(new_not_reviewed_open_n)) "NA" else as.character(new_not_reviewed_open_n),
  if (is.na(total_not_reviewed_open_n)) "NA" else as.character(total_not_reviewed_open_n),
  if (is.na(new_passed_open_n)) "NA" else as.character(new_passed_open_n),
  if (is.na(total_passed_open_n)) "NA" else as.character(total_passed_open_n),
  if (is.na(new_unclassified_open_n)) "NA" else as.character(new_unclassified_open_n),
  if (is.na(total_unclassified_open_n)) "NA" else as.character(total_unclassified_open_n),
  NEW_WINDOW_HOURS,
  LAGGED_WINDOW_MIN_DAYS, LAGGED_WINDOW_MAX_DAYS
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
