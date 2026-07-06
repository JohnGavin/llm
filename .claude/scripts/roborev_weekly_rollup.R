#!/usr/bin/env Rscript
# roborev_weekly_rollup.R — Weekly cross-project roborev digest.
#
# Reads:
#   1. ~/.claude/logs/roborev_daily_backlog/<date>.md  (last 7 days, from #355 daily aggregator)
#   2. ~/.roborev/reviews.db                           (SQLite; read via DuckDB's sqlite
#                                                        scanner — NOT RSQLite, which is not
#                                                        in the llm nix env, see #736)
#   3. ~/.claude/logs/unified.duckdb roborev_review_lifecycle (close_reason distribution)
#
# Fail-loud policy (#736): an empty rollup is only legitimate when reviews.db itself
# has zero matching rows for the window. If reviews.db has matching rows but the
# rollup would render as all-zero (e.g. a broken JOIN or missing driver), that is
# treated as a bug and the script exits non-zero rather than silently emitting zeros.
#
# Emits:
#   - Markdown rollup → $ROBOREV_WEEKLY_DIR/YYYY-MM-DD.md  (default ~/.claude/logs/roborev_weekly_rollup/)
#   - Prints to stdout
#
# Required env vars (none — all have defaults):
#   ROBOREV_DAILY_BACKLOG_DIR   daily aggregator backlog files (default ~/.claude/logs/roborev_daily_backlog)
#   ROBOREV_DB                  SQLite reviews DB             (default ~/.roborev/reviews.db)
#   UNIFIED_DUCKDB              unified DuckDB                (default ~/.claude/logs/unified.duckdb)
#   ROBOREV_WEEKLY_DIR          output dir                    (default ~/.claude/logs/roborev_weekly_rollup)
#
# Optional env vars:
#   WEEKLY_DRY_RUN              "1" → print to stdout only, no file write
#   EMAIL_DRY_RUN               "1" → same as WEEKLY_DRY_RUN (passed through from wrapper)
#
# Usage:
#   Rscript .claude/scripts/roborev_weekly_rollup.R
#   WEEKLY_DRY_RUN=1 Rscript .claude/scripts/roborev_weekly_rollup.R
#
# Called from bin/roborev_weekly_rollup_cron.sh and by send_roborev_weekly_rollup_email.R.
# Tracked in llm#356.

suppressPackageStartupMessages({
  library(DBI)
})

# ── Canonical-projects filter (#537) ──────────────────────────────────────────
# Source helper from lib/canonical_check.R (provides filter_canonical, canonical_slugs).
# Set INCLUDE_NON_CANONICAL=1 to bypass (e.g. for fixture/test repo debugging).

.scripts_dir_rollup <- tryCatch(
  dirname(normalizePath(sys.frame(0L)$ofile, mustWork = FALSE)),
  error = function(e) {
    args <- commandArgs(trailingOnly = FALSE)
    idx  <- grep("^--file=", args)
    if (length(idx)) dirname(normalizePath(sub("^--file=", "", args[idx]), mustWork = FALSE))
    else dirname(normalizePath(file.path(Sys.getenv("HOME"), "docs_gh", "llm",
                                         ".claude", "scripts", "roborev_weekly_rollup.R"),
                               mustWork = FALSE))
  }
)
source(file.path(.scripts_dir_rollup, "lib", "canonical_check.R"))

# ── Paths ─────────────────────────────────────────────────────────────────────

ROBOREV_DAILY_BACKLOG_DIR <- Sys.getenv(
  "ROBOREV_DAILY_BACKLOG_DIR",
  file.path(Sys.getenv("HOME"), ".claude", "logs", "roborev_daily_backlog")
)

REVIEWS_DB <- Sys.getenv(
  "ROBOREV_DB",
  file.path(Sys.getenv("HOME"), ".roborev", "reviews.db")
)

UNIFIED_DUCKDB <- Sys.getenv(
  "UNIFIED_DUCKDB",
  file.path(Sys.getenv("HOME"), ".claude", "logs", "unified.duckdb")
)

ROBOREV_WEEKLY_DIR <- Sys.getenv(
  "ROBOREV_WEEKLY_DIR",
  file.path(Sys.getenv("HOME"), ".claude", "logs", "roborev_weekly_rollup")
)

dry_run <- identical(Sys.getenv("WEEKLY_DRY_RUN"), "1") ||
  identical(Sys.getenv("EMAIL_DRY_RUN"), "1")

# ── Date range: last 7 full days ──────────────────────────────────────────────

today      <- Sys.Date()
week_start <- today - 7L   # inclusive
week_end   <- today - 1L   # inclusive (yesterday = last full day)

week_start_str <- format(week_start, "%Y-%m-%d")
week_end_str   <- format(week_end, "%Y-%m-%d")

cat(sprintf(
  "roborev_weekly_rollup.R: period=%s to %s dry_run=%s\n",
  week_start_str, week_end_str, dry_run
))

# ── 1. Parse daily backlog files ──────────────────────────────────────────────

parse_daily_backlog_dir <- function(dir, from_date, to_date) {
  if (!dir.exists(dir)) {
    message("roborev_weekly_rollup: daily backlog dir not found: ", dir)
    return(list(files_found = 0L, project_lines = character(0)))
  }

  date_seq <- seq.Date(from_date, to_date, by = "day")
  file_candidates <- file.path(dir, paste0(format(date_seq, "%Y-%m-%d"), ".md"))
  present_files   <- file_candidates[file.exists(file_candidates)]

  if (length(present_files) == 0L) {
    return(list(files_found = 0L, project_lines = character(0)))
  }

  # Collect lines that look like project-level open-count summaries
  all_lines <- unlist(lapply(present_files, function(f) {
    tryCatch(readLines(f, warn = FALSE), error = function(e) character(0))
  }))

  list(files_found = length(present_files), project_lines = all_lines)
}

daily_info <- parse_daily_backlog_dir(
  ROBOREV_DAILY_BACKLOG_DIR, week_start, week_end
)

# ── 2. Query reviews.db for per-project week-over-week trends ────────────────

query_reviews_db <- function(db_path, week_start_str, week_end_str) {
  empty <- data.frame(
    repo_name        = character(0),
    opened_this_week = integer(0),
    closed_this_week = integer(0),
    close_rate       = numeric(0),
    stringsAsFactors = FALSE
  )
  empty_stuck <- data.frame(
    id = integer(0), repo = character(0),
    age_days = integer(0), severity = character(0),
    summary = character(0), stringsAsFactors = FALSE
  )
  if (!file.exists(db_path)) {
    message("roborev_weekly_rollup: reviews.db not found at ", db_path)
    return(list(per_project = empty, global_close_rate = NA_real_,
                global_opened = 0L, global_closed = 0L,
                prev_global_close_rate = NA_real_,
                median_ttc_hrs = NA_real_,
                stuck_findings = empty_stuck,
                evidence_count = 0L))
  }

  # reviews.db is SQLite. RSQLite is NOT in the llm nix env (#736); read it via
  # DuckDB's bundled sqlite scanner instead — the same approach already used for
  # unified.duckdb elsewhere in this script and in roborev_metrics_etl.R.
  #
  # Per #736 fail-loud policy: a connect/attach failure here is a hard error
  # (exit non-zero), NOT a silent empty fallback — an empty rollup must be
  # evidenced, not assumed.
  con <- tryCatch(
    DBI::dbConnect(duckdb::duckdb(), ":memory:"),
    error = function(e) {
      cat(sprintf("ERROR: cannot open DuckDB in-memory connection — %s\n",
                   conditionMessage(e)))
      quit(status = 1L)
    }
  )
  on.exit(tryCatch(DBI::dbDisconnect(con, shutdown = TRUE), error = function(e) NULL),
          add = TRUE)

  attach_ok <- tryCatch({
    tryCatch({
      invisible(DBI::dbExecute(con, "LOAD sqlite"))
    }, error = function(e_load) {
      invisible(DBI::dbExecute(con, "INSTALL sqlite"))
      invisible(DBI::dbExecute(con, "LOAD sqlite"))
    })
    invisible(DBI::dbExecute(
      con, sprintf("ATTACH '%s' AS src (TYPE sqlite, READ_ONLY)", db_path)
    ))
    TRUE
  }, error = function(e) {
    cat(sprintf("ERROR: cannot attach reviews.db via DuckDB — %s\n",
                conditionMessage(e)))
    FALSE
  })
  if (!isTRUE(attach_ok)) {
    quit(status = 1L)
  }

  # Evidence count (#736): counts review_jobs directly, independent of the
  # reviews/review_jobs/repos JOIN below. If this is > 0 but the joined
  # queries render an all-zero rollup, that mismatch is the #736 bug pattern
  # (e.g. a broken JOIN or driver issue) — checked after this function returns.
  evidence_count <- tryCatch(
    as.integer(DBI::dbGetQuery(con, sprintf(
      "SELECT COUNT(*) AS n FROM src.review_jobs
       WHERE status = 'done' AND CAST(finished_at AS DATE) BETWEEN DATE '%s' AND DATE '%s'",
      week_start_str, week_end_str
    ))$n[1L]),
    error = function(e) {
      cat(sprintf("ERROR: evidence-count query failed — %s\n", conditionMessage(e)))
      quit(status = 1L)
    }
  )

  # Per-project opened / closed in current week
  per_proj_sql <- sprintf("
    SELECT
      r.name AS repo_name,
      COUNT(CASE WHEN CAST(rj.finished_at AS DATE) BETWEEN DATE '%s' AND DATE '%s' THEN 1 END) AS opened_this_week,
      COUNT(CASE WHEN rv.closed = 1
                   AND CAST(rv.updated_at AS DATE) BETWEEN DATE '%s' AND DATE '%s' THEN 1 END) AS closed_this_week
    FROM src.reviews rv
    JOIN src.review_jobs rj ON rj.id = rv.job_id
    JOIN src.repos r ON r.id = rj.repo_id
    WHERE rj.status = 'done'
    GROUP BY r.name
    ORDER BY opened_this_week DESC
  ", week_start_str, week_end_str,
     week_start_str, week_end_str)

  per_project <- tryCatch(
    DBI::dbGetQuery(con, per_proj_sql),
    error = function(e) {
      message("roborev_weekly_rollup: per-project query failed — ", conditionMessage(e))
      empty
    }
  )

  # Compute per-project close rate (avoid division by zero)
  if (nrow(per_project) > 0L) {
    per_project$close_rate <- ifelse(
      per_project$opened_this_week > 0L,
      per_project$closed_this_week / per_project$opened_this_week,
      NA_real_
    )
  } else {
    per_project <- empty
  }

  # Global counts for current week
  global_sql <- sprintf("
    SELECT
      COUNT(*) AS opened_this_week,
      COUNT(CASE WHEN rv.closed = 1
                   AND CAST(rv.updated_at AS DATE) BETWEEN DATE '%s' AND DATE '%s' THEN 1 END) AS closed_this_week
    FROM src.reviews rv
    JOIN src.review_jobs rj ON rj.id = rv.job_id
    WHERE rj.status = 'done'
      AND CAST(rj.finished_at AS DATE) BETWEEN DATE '%s' AND DATE '%s'
  ", week_start_str, week_end_str,
     week_start_str, week_end_str)

  global_row <- tryCatch(
    DBI::dbGetQuery(con, global_sql),
    error = function(e) data.frame(opened_this_week = 0L, closed_this_week = 0L)
  )

  global_opened <- as.integer(global_row$opened_this_week[1L])
  global_closed <- as.integer(global_row$closed_this_week[1L])
  global_close_rate <- if (global_opened > 0L) global_closed / global_opened else NA_real_

  # Previous week close rate for delta
  prev_start <- format(week_start - 7L, "%Y-%m-%d")
  prev_end   <- format(week_end   - 7L, "%Y-%m-%d")
  prev_sql <- sprintf("
    SELECT
      COUNT(*) AS opened,
      COUNT(CASE WHEN rv.closed = 1
                   AND CAST(rv.updated_at AS DATE) BETWEEN DATE '%s' AND DATE '%s' THEN 1 END) AS closed
    FROM src.reviews rv
    JOIN src.review_jobs rj ON rj.id = rv.job_id
    WHERE rj.status = 'done'
      AND CAST(rj.finished_at AS DATE) BETWEEN DATE '%s' AND DATE '%s'
  ", prev_start, prev_end, prev_start, prev_end)

  prev_row <- tryCatch(
    DBI::dbGetQuery(con, prev_sql),
    error = function(e) data.frame(opened = 0L, closed = 0L)
  )
  prev_opened <- as.integer(prev_row$opened[1L])
  prev_closed <- as.integer(prev_row$closed[1L])
  prev_global_close_rate <- if (prev_opened > 0L) prev_closed / prev_opened else NA_real_

  # Median time-to-close this week (hours) — best-effort from updated_at vs finished_at
  ttc_sql <- sprintf("
    SELECT
      AVG(
        CAST(EPOCH(CAST(rv.updated_at AS TIMESTAMP)) - EPOCH(CAST(rj.finished_at AS TIMESTAMP)) AS DOUBLE) / 3600.0
      ) AS median_ttc_hrs
    FROM src.reviews rv
    JOIN src.review_jobs rj ON rj.id = rv.job_id
    WHERE rj.status = 'done'
      AND rv.closed = 1
      AND CAST(rv.updated_at AS DATE) BETWEEN DATE '%s' AND DATE '%s'
      AND CAST(rv.updated_at AS TIMESTAMP) >= CAST(rj.finished_at AS TIMESTAMP)
  ", week_start_str, week_end_str)

  ttc_row <- tryCatch(
    DBI::dbGetQuery(con, ttc_sql),
    error = function(e) data.frame(median_ttc_hrs = NA_real_)
  )
  median_ttc_hrs <- as.numeric(ttc_row$median_ttc_hrs[1L])

  # Top stuck findings: open, age > 7 days, order by age desc
  stuck_sql <- "
    SELECT
      rv.id,
      r.name AS repo,
      CAST((EPOCH(CURRENT_TIMESTAMP) - EPOCH(CAST(rj.finished_at AS TIMESTAMP))) / 86400.0 AS INTEGER) AS age_days,
      rv.output
    FROM src.reviews rv
    JOIN src.review_jobs rj ON rj.id = rv.job_id
    JOIN src.repos r ON r.id = rj.repo_id
    WHERE rj.status = 'done'
      AND rv.closed = 0
      AND (EPOCH(CURRENT_TIMESTAMP) - EPOCH(CAST(rj.finished_at AS TIMESTAMP))) / 86400.0 > 7
    ORDER BY age_days DESC
    LIMIT 10
  "

  stuck_raw <- tryCatch(
    DBI::dbGetQuery(con, stuck_sql),
    error = function(e) data.frame(id = integer(0), repo = character(0),
                                   age_days = integer(0), output = character(0))
  )

  # Extract one-line summary and severity from output text
  extract_sev <- function(txt) {
    txt <- txt %||% ""
    for (sev in c("Critical", "High", "Medium", "Low")) {
      if (grepl(paste0("Severity.*", sev), txt, ignore.case = TRUE)) return(tolower(sev))
    }
    "unknown"
  }
  extract_summary <- function(txt) {
    if (is.null(txt) || is.na(txt) || !nzchar(txt)) return("")
    lines <- trimws(strsplit(txt, "\n")[[1]])
    lines <- lines[nzchar(lines)]
    lines <- lines[!startsWith(lines, "#")]
    lines <- lines[!startsWith(lines, "---")]
    if (length(lines) == 0L) return("")
    substr(lines[1L], 1L, 80L)
  }

  if (nrow(stuck_raw) > 0L) {
    stuck_findings <- data.frame(
      id       = stuck_raw$id,
      repo     = stuck_raw$repo,
      age_days = stuck_raw$age_days,
      severity = vapply(stuck_raw$output, extract_sev, character(1L)),
      summary  = vapply(stuck_raw$output, extract_summary, character(1L)),
      stringsAsFactors = FALSE
    )
  } else {
    stuck_findings <- data.frame(
      id = integer(0), repo = character(0), age_days = integer(0),
      severity = character(0), summary = character(0),
      stringsAsFactors = FALSE
    )
  }

  list(
    per_project          = per_project,
    global_close_rate    = global_close_rate,
    global_opened        = global_opened,
    global_closed        = global_closed,
    prev_global_close_rate = prev_global_close_rate,
    median_ttc_hrs       = median_ttc_hrs,
    stuck_findings       = stuck_findings,
    evidence_count       = evidence_count
  )
}

# Null-coalescing helper
# Treats NULL, length-0, NA, AND empty string as missing.
# Empty-string handling matters because Sys.getenv() returns "" not NA.
# See llm#559.
`%||%` <- function(a, b) {
  if (is.null(a) || length(a) == 0L) return(b)
  if (is.na(a[[1L]])) return(b)
  if (is.character(a) && !nzchar(a[[1L]])) return(b)
  a
}

# reviews.db is read via DuckDB's sqlite scanner (#736) — NOT RSQLite, which is
# not in the llm nix env. duckdb is a firm dependency of this script already
# (used below for unified.duckdb), so its absence is a hard error, not a
# graceful skip: a silently-skipped DB read is exactly the failure mode #736
# reported (all-zero rollup with no indication anything went wrong).
if (!requireNamespace("duckdb", quietly = TRUE)) {
  cat("ERROR: duckdb package not available — cannot read reviews.db (#736)\n")
  quit(status = 1L)
}
db_data <- query_reviews_db(REVIEWS_DB, week_start_str, week_end_str)

# ── Fail-loud guard (#736 Part B) ─────────────────────────────────────────────
# evidence_count is queried directly against review_jobs, independent of the
# reviews/review_jobs/repos JOIN used for global_opened/global_closed. If
# evidence_count is > 0 but the joined queries render an all-zero rollup, that
# is a bug (e.g. a broken JOIN or schema drift) — not a legitimately empty
# week — and must fail loudly rather than emit a misleading all-zero report.
# A genuinely empty week (evidence_count == 0) is allowed through unchanged.
if (db_data$evidence_count > 0L &&
    db_data$global_opened == 0L && db_data$global_closed == 0L) {
  cat(sprintf(
    "ERROR: rollup empty but reviews.db has %d done job(s) in window %s..%s — treating as BUG (#736)\n",
    db_data$evidence_count, week_start_str, week_end_str
  ))
  quit(status = 1L)
}

# ── 2b. Apply canonical-projects filter to per_project and stuck_findings ────
# Both data frames come from reviews.db (SQLite); canonical_projects lives in
# unified.duckdb.  We cannot JOIN across DBs, so we fetch slugs from duckdb
# first and filter in R.
#
# Opt-out: INCLUDE_NON_CANONICAL=1 skips filtering (useful for debugging).
# CANONICAL_PROJECTS_INCLUDE_FIXTURES=1 is also honoured (set inside filter_canonical).

if (!identical(Sys.getenv("INCLUDE_NON_CANONICAL"), "1") &&
    requireNamespace("duckdb", quietly = TRUE) &&
    file.exists(UNIFIED_DUCKDB)) {

  duck_con_filter <- tryCatch(
    DBI::dbConnect(duckdb::duckdb(), UNIFIED_DUCKDB, read_only = TRUE),
    error = function(e) {
      message("roborev_weekly_rollup: cannot open unified.duckdb for canonical filter — ",
              conditionMessage(e))
      NULL
    }
  )

  if (!is.null(duck_con_filter)) {
    on.exit(DBI::dbDisconnect(duck_con_filter, shutdown = FALSE), add = TRUE)

    # Filter per_project (has repo_name, not repo — rename before/after)
    pp <- db_data$per_project
    n_pp_before <- nrow(pp)
    if (n_pp_before > 0L) {
      names(pp)[names(pp) == "repo_name"] <- "repo"
      pp <- filter_canonical(pp, duck_con_filter,
                             producer = "roborev_weekly_rollup/per_project")
      names(pp)[names(pp) == "repo"] <- "repo_name"
    }
    n_pp_after <- nrow(pp)
    if (n_pp_before != n_pp_after) {
      message(sprintf(
        "roborev_weekly_rollup: per_project: %d → %d rows after canonical filter",
        n_pp_before, n_pp_after
      ))
    }
    db_data$per_project <- pp

    # Filter stuck_findings (already has repo column)
    sf <- db_data$stuck_findings
    n_sf_before <- nrow(sf)
    sf <- filter_canonical(sf, duck_con_filter,
                           producer = "roborev_weekly_rollup/stuck_findings")
    n_sf_after <- nrow(sf)
    if (n_sf_before != n_sf_after) {
      message(sprintf(
        "roborev_weekly_rollup: stuck_findings: %d → %d rows after canonical filter",
        n_sf_before, n_sf_after
      ))
    }
    db_data$stuck_findings <- sf
  }
} else if (identical(Sys.getenv("INCLUDE_NON_CANONICAL"), "1")) {
  message("roborev_weekly_rollup: INCLUDE_NON_CANONICAL=1 — canonical filter bypassed")
}

# ── 3. Query unified.duckdb for close_reason distribution ────────────────────

query_close_reasons <- function(duckdb_path, week_start_str, week_end_str) {
  empty <- data.frame(close_reason = character(0), n = integer(0),
                      stringsAsFactors = FALSE)

  if (!file.exists(duckdb_path)) {
    message("roborev_weekly_rollup: unified.duckdb not found at ", duckdb_path)
    return(empty)
  }

  has_duckdb <- requireNamespace("duckdb", quietly = TRUE)
  if (!has_duckdb) {
    message("roborev_weekly_rollup: duckdb package not available — skipping close_reason query")
    return(empty)
  }

  con <- tryCatch(
    DBI::dbConnect(duckdb::duckdb(), duckdb_path, read_only = TRUE),
    error = function(e) {
      message("roborev_weekly_rollup: cannot open unified.duckdb — ", conditionMessage(e))
      NULL
    }
  )
  if (is.null(con)) return(empty)
  on.exit({
    DBI::dbDisconnect(con, shutdown = FALSE)
  }, add = TRUE)

  # Check if the relevant table/column exists
  tables <- tryCatch(
    DBI::dbListTables(con),
    error = function(e) character(0)
  )

  if (!"roborev_review_lifecycle" %in% tables) {
    message("roborev_weekly_rollup: roborev_review_lifecycle not in unified.duckdb")
    return(empty)
  }

  # Use closed_at IS NOT NULL as the closed indicator (per #316 schema).
  # Fall back to closed = 1 for older schema versions.
  columns <- tryCatch(
    DBI::dbListFields(con, "roborev_review_lifecycle"),
    error = function(e) character(0)
  )
  closed_clause <- if ("closed_at" %in% columns) {
    sprintf("closed_at IS NOT NULL AND CAST(closed_at AS DATE) BETWEEN DATE '%s' AND DATE '%s'",
            week_start_str, week_end_str)
  } else {
    sprintf("closed = 1 AND CAST(updated_at AS DATE) BETWEEN DATE '%s' AND DATE '%s'",
            week_start_str, week_end_str)
  }

  sql <- sprintf("
    SELECT
      COALESCE(close_reason, 'unknown') AS close_reason,
      COUNT(*) AS n
    FROM roborev_review_lifecycle
    WHERE %s
    GROUP BY close_reason
    ORDER BY n DESC
  ", closed_clause)

  tryCatch(
    DBI::dbGetQuery(con, sql),
    error = function(e) {
      message("roborev_weekly_rollup: close_reason query failed — ", conditionMessage(e))
      empty
    }
  )
}

close_reasons <- query_close_reasons(UNIFIED_DUCKDB, week_start_str, week_end_str)

# ── 4. Build markdown rollup ──────────────────────────────────────────────────

fmt_rate <- function(x) {
  if (is.null(x) || length(x) == 0L || is.na(x)) return("n/a")
  sprintf("%.1f%%", as.numeric(x) * 100)
}

fmt_hrs <- function(x) {
  if (is.null(x) || length(x) == 0L || is.na(x)) return("n/a")
  h <- as.numeric(x)
  if (h < 1) sprintf("%.0f min", h * 60) else sprintf("%.1f h", h)
}

fmt_delta <- function(current, previous) {
  if (is.na(current) || is.na(previous)) return("")
  delta <- current - previous
  sign  <- if (delta >= 0) "+" else ""
  sprintf(" (%s%.1f pp)", sign, delta * 100)
}

rate_delta_str <- fmt_delta(
  db_data$global_close_rate %||% NA_real_,
  db_data$prev_global_close_rate %||% NA_real_
)

# §1 Global summary
section_global <- sprintf(
  "## Global Summary\n\nPeriod: %s to %s\n\n| Metric | Value |\n|--------|-------|\n| Opened this week | %d |\n| Closed this week | %d |\n| Close rate | %s%s |\n| Median time-to-close | %s |\n| Daily backlog files found | %d / 7 |\n",
  week_start_str, week_end_str,
  db_data$global_opened,
  db_data$global_closed,
  fmt_rate(db_data$global_close_rate), rate_delta_str,
  fmt_hrs(db_data$median_ttc_hrs),
  daily_info$files_found
)

# §2 Per-project table
if (nrow(db_data$per_project) > 0L) {
  proj_rows <- paste0(
    vapply(seq_len(nrow(db_data$per_project)), function(i) {
      row <- db_data$per_project[i, ]
      sprintf("| %s | %d | %d | %s |",
              row$repo_name,
              row$opened_this_week,
              row$closed_this_week,
              fmt_rate(row$close_rate))
    }, character(1L)),
    collapse = "\n"
  )
  section_projects <- paste0(
    "## Per-Project Backlog\n\n",
    "| Project | Opened | Closed | Close Rate |\n",
    "|---------|--------|--------|------------|\n",
    proj_rows, "\n"
  )
} else {
  section_projects <- "## Per-Project Backlog\n\n_(no data — reviews.db unavailable or empty)_\n"
}

# §3 Close-reason distribution
if (nrow(close_reasons) > 0L) {
  total_closed <- sum(close_reasons$n)
  cr_rows <- paste0(
    vapply(seq_len(nrow(close_reasons)), function(i) {
      row <- close_reasons[i, ]
      pct <- if (total_closed > 0L) row$n / total_closed else 0
      sprintf("| %s | %d | %.1f%% |",
              row$close_reason, row$n, pct * 100)
    }, character(1L)),
    collapse = "\n"
  )
  section_reasons <- paste0(
    "## Close-Reason Distribution\n\n",
    "| Reason | Count | % |\n",
    "|--------|-------|---|\n",
    cr_rows, "\n"
  )
} else {
  section_reasons <- "## Close-Reason Distribution\n\n_(no data — unified.duckdb unavailable or table missing)_\n"
}

# §4 Top stuck findings
if (nrow(db_data$stuck_findings) > 0L) {
  n_show <- min(10L, nrow(db_data$stuck_findings))
  stuck_rows <- paste0(
    vapply(seq_len(n_show), function(i) {
      row <- db_data$stuck_findings[i, ]
      summary_esc <- gsub("|", "\\|", row$summary, fixed = TRUE)
      sprintf("| %d | %s | %d days | %s | %s |",
              row$id, row$repo, row$age_days, row$severity, summary_esc)
    }, character(1L)),
    collapse = "\n"
  )
  section_stuck <- paste0(
    "## Top Stuck Findings (open > 7 days)\n\n",
    "| ID | Project | Age | Severity | Summary |\n",
    "|----|---------|-----|----------|---------|\n",
    stuck_rows, "\n"
  )
} else {
  section_stuck <- "## Top Stuck Findings (open > 7 days)\n\n_(none — all findings closed or too recent)_\n"
}

# Assemble full rollup
rollup_md <- paste(
  sprintf("# roborev Weekly Rollup — %s", format(today, "%Y-%m-%d")),
  sprintf("_Generated: %s UTC_", format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")),
  "",
  section_global,
  section_projects,
  section_reasons,
  section_stuck,
  sep = "\n"
)

# ── 5. Write output ───────────────────────────────────────────────────────────

if (dry_run) {
  message("roborev_weekly_rollup.R: WEEKLY_DRY_RUN=1 — printing to stdout only")
  cat(rollup_md, "\n")
  message("roborev_weekly_rollup.R: dry-run complete (no file written)")
  quit(status = 0L)
}

dir.create(ROBOREV_WEEKLY_DIR, showWarnings = FALSE, recursive = TRUE)
out_path <- file.path(ROBOREV_WEEKLY_DIR, paste0(format(today, "%Y-%m-%d"), ".md"))

writeLines(rollup_md, out_path)
message(sprintf("roborev_weekly_rollup.R: wrote %s", out_path))
cat(rollup_md, "\n")
