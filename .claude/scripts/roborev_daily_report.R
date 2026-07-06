#!/usr/bin/env Rscript
# roborev_daily_report.R — Daily resolution-speed report for roborev findings.
#
# Computes structured metrics over rolling 1d / 3d / 7d / 14d windows:
#   §1  Frequency table:   review_type × verdict, open vs closed counts
#   §2  Resolution speed:  time_to_close (median/p90/p99), attempts_to_close
#                          (median/p90), close_rate
#   §3  Trends:            each metric vs prior equivalent window (% + absolute)
#   §4  Outliers (14d):    top-10 by attempts_to_close + top-10 by time_to_close_hrs
#   §5  Severity by project (7d):  per-repo counts of High/Medium/Low/Unknown findings
#                                  (llm#449)
#
# Writes:
#   - JSON snapshot → $ROBOREV_DAILY_DIR/YYYY-MM-DD.json  (default ~/.claude/logs/roborev_daily_report/)
#   - Text digest   → stdout (suitable for email body)
#
# Data source:
#   unified.duckdb (path from $UNIFIED_DUCKDB, default ~/.claude/logs/unified.duckdb)
#   Must contain roborev_review_lifecycle table (populated by roborev_metrics_etl.R / llm#226 / #316).
#
# If table roborev_finding_lineage_summary exists (from llm#286), uses its
# n_attempts and time_to_close_hrs columns.  Otherwise falls back to a thin
# heuristic:  attempts = retry_count + 1  (read from reviews.db via lifecycle
# job_id if available, else default 1).
#
# DO NOT write to ~/.roborev/reviews.db.
#
# Tracked in llm#284.

suppressPackageStartupMessages({
  library(DBI)
  library(duckdb)
  library(jsonlite)
})

# ── Paths ─────────────────────────────────────────────────────────────────────

UNIFIED_DUCKDB <- Sys.getenv(
  "UNIFIED_DUCKDB",
  file.path(Sys.getenv("HOME"), ".claude", "logs", "unified.duckdb")
)

ROBOREV_DAILY_DIR <- Sys.getenv(
  "ROBOREV_DAILY_DIR",
  file.path(Sys.getenv("HOME"), ".claude", "logs", "roborev_daily_report")
)

REVIEWS_DB <- Sys.getenv(
  "ROBOREV_DB",
  file.path(Sys.getenv("HOME"), ".roborev", "reviews.db")
)

# ── Argument parsing ──────────────────────────────────────────────────────────

args <- commandArgs(trailingOnly = TRUE)
dry_run <- "--dry-run" %in% args
anchor_arg <- args[startsWith(args, "--anchor=")]
anchor_date <- if (length(anchor_arg) > 0L) {
  tryCatch(
    as.POSIXct(sub("--anchor=", "", anchor_arg[1L]), tz = "UTC"),
    error = function(e) {
      message("--anchor= requires ISO timestamp, e.g. --anchor=2026-05-28T00:00:00Z")
      quit(status = 1L)
    }
  )
} else {
  as.POSIXct(Sys.time(), tz = "UTC")
}

cat(sprintf(
  "roborev_daily_report.R: anchor=%s dry_run=%s\n",
  format(anchor_date, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"), dry_run
))

# ── Graceful exit ─────────────────────────────────────────────────────────────

graceful_exit <- function(reason) {
  message("roborev_daily_report.R: skipping — ", reason)
  quit(status = 0L)
}

# ── Open unified.duckdb (read-only) ───────────────────────────────────────────

if (!file.exists(UNIFIED_DUCKDB)) {
  graceful_exit(paste("unified.duckdb not found at", UNIFIED_DUCKDB))
}

con <- tryCatch(
  dbConnect(duckdb::duckdb(), UNIFIED_DUCKDB, read_only = TRUE),
  error = function(e) {
    graceful_exit(paste("cannot open unified.duckdb:", conditionMessage(e)))
  }
)
on.exit(tryCatch(dbDisconnect(con, shutdown = TRUE), error = function(e) NULL),
        add = TRUE)

# Validate required table
if (!"roborev_review_lifecycle" %in% dbListTables(con)) {
  graceful_exit("roborev_review_lifecycle table not found in unified.duckdb")
}

has_lineage_table <- "roborev_finding_lineage_summary" %in% dbListTables(con)
cat(sprintf("roborev_daily_report.R: lineage table present=%s\n", has_lineage_table))

# ── Quantile helper (robust: median / p90 / p99) ──────────────────────────────

pct <- function(x, probs, na.rm = TRUE) {
  x <- x[!is.na(x)]
  if (length(x) == 0L) return(setNames(rep(NA_real_, length(probs)), paste0("p", probs * 100)))
  setNames(as.numeric(quantile(x, probs = probs)), paste0("p", probs * 100))
}

# ── Window bounds helper ───────────────────────────────────────────────────────
#
# Returns a named list of (start, end) TIMESTAMP strings for the current window
# and the prior equivalent window.
# All comparisons against created_at::TIMESTAMP in the lifecycle table.

window_bounds <- function(anchor, days) {
  # Current window: [anchor - days, anchor)
  cur_end   <- anchor
  cur_start <- anchor - as.difftime(days, units = "days")
  # Prior window: [anchor - 2*days, anchor - days)
  pri_end   <- cur_start
  pri_start <- anchor - as.difftime(2 * days, units = "days")
  list(
    cur  = list(start = cur_start, end = cur_end),
    pri  = list(start = pri_start, end = pri_end)
  )
}

fmt_ts <- function(ts) format(ts, "%Y-%m-%d %H:%M:%S", tz = "UTC")

# ── Load lifecycle slice for a window ─────────────────────────────────────────

load_window <- function(con, start_ts, end_ts) {
  sql <- sprintf(
    "SELECT
       review_id, repo,
       verdict,
       created_at::TIMESTAMP       AS created_at,
       closed_at,
       close_reason,
       ROUND(EPOCH_MS(closed_at - created_at::TIMESTAMP) / 3600000.0, 4)
         AS time_to_close_hrs
     FROM roborev_review_lifecycle
     WHERE created_at::TIMESTAMP >= TIMESTAMP '%s'
       AND created_at::TIMESTAMP <  TIMESTAMP '%s'",
    fmt_ts(start_ts), fmt_ts(end_ts)
  )
  tryCatch(
    dbGetQuery(con, sql),
    error = function(e) {
      message("roborev_daily_report.R: window query error: ", conditionMessage(e))
      data.frame(
        review_id = integer(), repo = character(),
        verdict = character(), created_at = as.POSIXct(character()),
        closed_at = as.POSIXct(character()), close_reason = character(),
        time_to_close_hrs = double(),
        stringsAsFactors = FALSE
      )
    }
  )
}

# ── Closed-in-window counts (throughput) ──────────────────────────────────────
#
# llm#738: the created_at-cohort close_rate computed by compute_speed() is
# right-censored — a review CREATED in the last 24h typically has NOT closed
# yet (median time-to-close is 13-49h across d3/d7/d14), so a d1 "close rate"
# over the created-cohort is ~0 by construction even when closure activity is
# healthy. These helpers count closes independent of when the review was
# created, to give an honest throughput signal for the window.

# Lifecycle-table version: counts roborev_review_lifecycle rows whose
# closed_at falls in [start, end). Cheap (reuses the already-open `con`), but
# can lag behind reality by up to one ETL cadence, because
# roborev_metrics_etl.R runs on a schedule, not on every close — see
# load_raw_closed_count() below, which avoids this lag.
load_lifecycle_closed_count <- function(con, start_ts, end_ts) {
  sql <- sprintf(
    "SELECT COUNT(*)::INTEGER AS n
     FROM roborev_review_lifecycle
     WHERE closed_at IS NOT NULL
       AND closed_at::TIMESTAMP >= TIMESTAMP '%s'
       AND closed_at::TIMESTAMP <  TIMESTAMP '%s'",
    fmt_ts(start_ts), fmt_ts(end_ts)
  )
  tryCatch(
    as.integer(dbGetQuery(con, sql)$n[1L]),
    error = function(e) {
      message("roborev_daily_report.R: lifecycle closed-count query error: ", conditionMessage(e))
      NA_integer_
    }
  )
}

# Raw-source version: counts reviews.db `reviews` rows with closed=1 whose
# updated_at falls in [start, end). This is the authoritative source (it is
# what actually flips the moment roborev closes a review) and does NOT suffer
# the ETL-cadence lag that roborev_review_lifecycle.closed_at can have
# (llm#738 residual — confirmed empirically: on 2026-07-06 the lifecycle table
# showed 0 closes in the trailing 24h while reviews.db showed 171).
# updated_at is stored as an ISO-8601 string with a local UTC offset (e.g.
# "+01:00"); TRY_CAST straight to TIMESTAMP silently DISCARDS that offset
# (verified — do not "simplify" this to TIMESTAMP), so we cast via TIMESTAMPTZ
# first (which honours the offset) and then drop to a naive UTC TIMESTAMP for
# comparison against start_ts/end_ts (already UTC).
load_raw_closed_count <- function(start_ts, end_ts) {
  if (!file.exists(REVIEWS_DB)) return(NA_integer_)
  tryCatch({
    tmp_con <- dbConnect(duckdb::duckdb(), ":memory:")
    on.exit(
      tryCatch(dbDisconnect(tmp_con, shutdown = TRUE), error = function(e) NULL),
      add = TRUE
    )
    invisible(tryCatch(
      dbExecute(tmp_con, "LOAD sqlite"),
      error = function(e) {
        invisible(tryCatch(dbExecute(tmp_con, "INSTALL sqlite"), error = function(e2) NULL))
        invisible(dbExecute(tmp_con, "LOAD sqlite"))
      }
    ))
    dbExecute(tmp_con,
      sprintf("ATTACH '%s' AS rdb (TYPE sqlite, READ_ONLY)", REVIEWS_DB)
    )
    sql <- sprintf(
      "SELECT COUNT(*)::INTEGER AS n
       FROM rdb.reviews
       WHERE closed = 1
         AND updated_at IS NOT NULL
         AND TRY_CAST(updated_at AS TIMESTAMPTZ)::TIMESTAMP >= TIMESTAMP '%s'
         AND TRY_CAST(updated_at AS TIMESTAMPTZ)::TIMESTAMP <  TIMESTAMP '%s'",
      fmt_ts(start_ts), fmt_ts(end_ts)
    )
    as.integer(dbGetQuery(tmp_con, sql)$n[1L])
  }, error = function(e) {
    message("roborev_daily_report.R: raw closed-count query error: ", conditionMessage(e))
    NA_integer_
  })
}

# ── Attempts heuristic from reviews.db ────────────────────────────────────────
#
# When roborev_finding_lineage_summary is absent, we use retry_count from
# review_jobs as a thin proxy:  attempts_to_close = retry_count + 1.
# This is intentionally conservative — it under-counts re-reviews that were
# enqueued as fresh jobs rather than retries.
#
# Returns a data.frame(review_id, n_attempts) or NULL on any failure.

load_attempts_heuristic <- function(lifecycle_df) {
  if (nrow(lifecycle_df) == 0L || !file.exists(REVIEWS_DB)) {
    return(NULL)
  }
  review_ids <- lifecycle_df$review_id[!is.na(lifecycle_df$review_id)]
  if (length(review_ids) == 0L) return(NULL)

  tryCatch({
    # Use DuckDB sqlite extension to read reviews.db (handles WAL automatically)
    tmp_con <- dbConnect(duckdb::duckdb(), ":memory:")
    on.exit(
      tryCatch(dbDisconnect(tmp_con, shutdown = TRUE), error = function(e) NULL),
      add = TRUE
    )
    invisible(tryCatch(
      dbExecute(tmp_con, "LOAD sqlite"),
      error = function(e) {
        invisible(tryCatch(dbExecute(tmp_con, "INSTALL sqlite"), error = function(e2) NULL))
        invisible(dbExecute(tmp_con, "LOAD sqlite"))
      }
    ))
    dbExecute(tmp_con,
      sprintf("ATTACH '%s' AS rdb (TYPE sqlite, READ_ONLY)", REVIEWS_DB)
    )

    id_list <- paste(review_ids, collapse = ", ")
    sql <- sprintf("
      SELECT
        rv.id AS review_id,
        COALESCE(rj.retry_count, 0) + 1 AS n_attempts
      FROM rdb.reviews rv
      LEFT JOIN rdb.review_jobs rj ON rj.id = rv.job_id
      WHERE rv.id IN (%s)
    ", id_list)
    df <- dbGetQuery(tmp_con, sql)
    if (nrow(df) == 0L) return(NULL)
    df
  }, error = function(e) {
    message("roborev_daily_report.R: heuristic attempts query error: ", conditionMessage(e))
    NULL
  })
}

# ── Join attempts to lifecycle slice ──────────────────────────────────────────

enrich_with_attempts <- function(con, lifecycle_df, has_lineage) {
  if (nrow(lifecycle_df) == 0L) {
    lifecycle_df$n_attempts <- integer(0L)
    return(lifecycle_df)
  }

  if (has_lineage) {
    # Use authoritative table from #286
    ids <- paste(lifecycle_df$review_id, collapse = ", ")
    sql <- sprintf("
      SELECT review_id, n_attempts
      FROM roborev_finding_lineage_summary
      WHERE review_id IN (%s)
    ", ids)
    att_df <- tryCatch(
      dbGetQuery(con, sql),
      error = function(e) data.frame(review_id = integer(), n_attempts = integer())
    )
  } else {
    att_df <- load_attempts_heuristic(lifecycle_df)
    if (is.null(att_df)) {
      att_df <- data.frame(review_id = integer(), n_attempts = integer())
    }
  }

  # Left-join: reviews without attempts get n_attempts = 1 (minimum possible)
  result <- merge(lifecycle_df, att_df, by = "review_id", all.x = TRUE)
  result$n_attempts[is.na(result$n_attempts)] <- 1L
  result
}

# ── §1 Frequency table ────────────────────────────────────────────────────────
#
# verdict: "F" (issues_found) / "P" (clean) — use chr() trick to avoid DuckDB
# identifier parsing.  We receive as raw column values here.
#
# Returns: data.frame(verdict_label, status, n)
# where status = "open" | "closed"

compute_freq_table <- function(df) {
  if (nrow(df) == 0L) {
    return(data.frame(
      verdict_label = character(), status = character(), n = integer(),
      stringsAsFactors = FALSE
    ))
  }
  df$verdict_label <- ifelse(
    is.na(df$verdict), "unknown",
    ifelse(df$verdict == "F", "issues_found", "clean")
  )
  df$status <- ifelse(!is.na(df$closed_at), "closed", "open")

  tbl <- aggregate(review_id ~ verdict_label + status, data = df, FUN = length)
  names(tbl)[names(tbl) == "review_id"] <- "n"
  tbl <- tbl[order(tbl$verdict_label, tbl$status), ]
  rownames(tbl) <- NULL
  tbl
}

# ── §2 Resolution speed ───────────────────────────────────────────────────────
#
# Operates on the subset: verdict == "F" (issues_found), where closed_at IS NOT NULL.
# Returns a list of scalars:
#   ttc_p50, ttc_p90, ttc_p99          (hours; robust per #robust-statistics)
#   att_p50, att_p90                    (counts)
#   close_rate                          (0..1)
#   n_issues_found, n_closed, n_open

compute_speed <- function(df) {
  empty <- list(
    ttc_p50 = NA_real_, ttc_p90 = NA_real_, ttc_p99 = NA_real_,
    att_p50 = NA_real_, att_p90 = NA_real_,
    close_rate = NA_real_,
    n_issues_found = 0L, n_closed = 0L, n_open = 0L
  )

  found <- df[!is.na(df$verdict) & df$verdict == "F", ]
  if (nrow(found) == 0L) return(empty)

  closed <- found[!is.na(found$closed_at), ]
  n_closed <- nrow(closed)
  n_open   <- nrow(found) - n_closed

  close_rate <- if ((n_closed + n_open) > 0L) {
    n_closed / (n_closed + n_open)
  } else NA_real_

  ttc_qs <- pct(closed$time_to_close_hrs, c(0.50, 0.90, 0.99))
  att_qs <- pct(closed$n_attempts, c(0.50, 0.90))

  list(
    ttc_p50        = unname(ttc_qs["p50"]),
    ttc_p90        = unname(ttc_qs["p90"]),
    ttc_p99        = unname(ttc_qs["p99"]),
    att_p50        = unname(att_qs["p50"]),
    att_p90        = unname(att_qs["p90"]),
    close_rate     = close_rate,
    n_issues_found = nrow(found),
    n_closed       = n_closed,
    n_open         = n_open
  )
}

# ── §3 Trend delta helper ─────────────────────────────────────────────────────
#
# Returns list(pct_delta, abs_delta) or list(pct_delta = NA, abs_delta = NA)
# when either value is NA.

trend_delta <- function(cur_val, pri_val) {
  if (is.na(cur_val) || is.na(pri_val) || pri_val == 0) {
    list(pct_delta = NA_real_, abs_delta = if (!is.na(cur_val) && !is.na(pri_val)) cur_val - pri_val else NA_real_)
  } else {
    list(
      pct_delta = (cur_val - pri_val) / abs(pri_val) * 100,
      abs_delta = cur_val - pri_val
    )
  }
}

# ── §5 Per-project severity frequency (7-day window) ─────────────────────────
#
# Returns a list of records {repo, High, Medium, Low, Unknown, Total}
# sorted descending by Total.  Uses severity_max column from lifecycle table.

compute_severity_by_project <- function(con, anchor, days,
                                       filtered = TRUE) {
  # Honour env-var escape hatch: INCLUDE_NON_CANONICAL=1 forces unfiltered.
  if (nzchar(Sys.getenv("INCLUDE_NON_CANONICAL"))) filtered <- FALSE

  bounds <- window_bounds(anchor, days)

  if (filtered) {
    # Join against canonical_projects + canonical_project_aliases so fixture
    # repos, test repos, and one-off repos are excluded.  Aliases (e.g.
    # "coMMpass") are resolved to the canonical slug before pivoting.
    # See issue #534 and the canonical_projects table seeded by PR #540.
    sql <- sprintf(
      "WITH valid_slugs AS (
         SELECT slug FROM canonical_projects WHERE is_active = TRUE
       ),
       alias_map AS (
         SELECT alias, slug FROM canonical_project_aliases
       )
       SELECT
         COALESCE(a.slug, s.repo) AS repo,
         COALESCE(s.severity_max, 'Unknown') AS severity,
         COUNT(*)::INTEGER AS n
       FROM roborev_review_lifecycle s
       LEFT JOIN alias_map a ON s.repo = a.alias
       WHERE s.verdict = 'F'
         AND s.created_at::TIMESTAMP >= TIMESTAMP '%s'
         AND s.created_at::TIMESTAMP <  TIMESTAMP '%s'
         AND (s.repo IN (SELECT slug FROM valid_slugs)
              OR s.repo IN (SELECT alias FROM alias_map))
       GROUP BY COALESCE(a.slug, s.repo), s.severity_max
       ORDER BY repo",
      fmt_ts(bounds$cur$start), fmt_ts(bounds$cur$end)
    )
  } else {
    sql <- sprintf(
      "SELECT
         repo,
         COALESCE(severity_max, 'Unknown') AS severity,
         COUNT(*)::INTEGER AS n
       FROM roborev_review_lifecycle
       WHERE verdict = 'F'
         AND created_at::TIMESTAMP >= TIMESTAMP '%s'
         AND created_at::TIMESTAMP <  TIMESTAMP '%s'
       GROUP BY repo, severity_max
       ORDER BY repo",
      fmt_ts(bounds$cur$start), fmt_ts(bounds$cur$end)
    )
  }

  raw <- tryCatch(
    dbGetQuery(con, sql),
    error = function(e) {
      message("roborev_daily_report.R: severity_by_project query error: ",
              conditionMessage(e))
      data.frame(repo = character(), severity = character(), n = integer(),
                 stringsAsFactors = FALSE)
    }
  )
  if (nrow(raw) == 0L) return(list())

  sev_levels <- c("High", "Medium", "Low", "Unknown")
  repos <- unique(raw$repo)
  pivot <- lapply(repos, function(r) {
    sub_df <- raw[raw$repo == r, ]
    counts <- setNames(
      vapply(sev_levels, function(s) {
        idx <- sub_df$severity == s
        if (any(idx)) as.integer(sub_df$n[idx][1L]) else 0L
      }, integer(1L)),
      sev_levels
    )
    list(
      repo    = r,
      High    = counts[["High"]],
      Medium  = counts[["Medium"]],
      Low     = counts[["Low"]],
      Unknown = counts[["Unknown"]],
      Total   = sum(counts)
    )
  })
  # Sort desc by Total
  totals <- vapply(pivot, function(x) x[["Total"]], integer(1L))
  pivot[order(-totals)]
}

# ── §4 Outliers (14-day window) ───────────────────────────────────────────────
#
# Returns list(by_attempts, by_time) — each a data.frame of top-10 closed
# issues_found reviews for the relevant metric.

compute_outliers <- function(df) {
  found_closed <- df[
    !is.na(df$verdict) & df$verdict == "F" & !is.na(df$closed_at),
  ]

  format_outlier_row <- function(row) {
    list(
      review_id         = as.integer(row$review_id),
      repo              = as.character(row$repo),
      n_attempts        = if (!is.null(row$n_attempts)) as.integer(row$n_attempts) else NA_integer_,
      time_to_close_hrs = if (!is.null(row$time_to_close_hrs)) round(as.numeric(row$time_to_close_hrs), 2) else NA_real_,
      close_reason      = as.character(row$close_reason),
      created_at        = format(row$created_at, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
    )
  }

  if (nrow(found_closed) == 0L) {
    empty_df <- data.frame(
      review_id = integer(), repo = character(),
      n_attempts = integer(), time_to_close_hrs = double(),
      close_reason = character(), created_at = character(),
      stringsAsFactors = FALSE
    )
    return(list(by_attempts = empty_df, by_time = empty_df))
  }

  # Top-10 by attempts
  by_att <- found_closed[order(-found_closed$n_attempts, -found_closed$time_to_close_hrs), ]
  by_att <- head(by_att, 10L)
  by_att_out <- data.frame(
    review_id         = as.integer(by_att$review_id),
    repo              = as.character(by_att$repo),
    n_attempts        = as.integer(by_att$n_attempts),
    time_to_close_hrs = round(as.numeric(by_att$time_to_close_hrs), 2),
    close_reason      = as.character(by_att$close_reason),
    created_at        = format(by_att$created_at, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    stringsAsFactors  = FALSE
  )

  # Top-10 by time-to-close
  by_ttc <- found_closed[order(-found_closed$time_to_close_hrs, -found_closed$n_attempts), ]
  by_ttc <- head(by_ttc, 10L)
  by_ttc_out <- data.frame(
    review_id         = as.integer(by_ttc$review_id),
    repo              = as.character(by_ttc$repo),
    n_attempts        = as.integer(by_ttc$n_attempts),
    time_to_close_hrs = round(as.numeric(by_ttc$time_to_close_hrs), 2),
    close_reason      = as.character(by_ttc$close_reason),
    created_at        = format(by_ttc$created_at, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    stringsAsFactors  = FALSE
  )

  list(by_attempts = by_att_out, by_time = by_ttc_out)
}

# ── Core: compute one window slice ────────────────────────────────────────────
#
# Returns a list with all structured outputs for a single (days, repo) slice.

compute_window_slice <- function(con, anchor, days, repo_filter = NULL, has_lineage = FALSE) {
  bounds <- window_bounds(anchor, days)

  cur_df <- load_window(con, bounds$cur$start, bounds$cur$end)
  pri_df <- load_window(con, bounds$pri$start, bounds$pri$end)

  if (!is.null(repo_filter)) {
    cur_df <- cur_df[cur_df$repo == repo_filter, ]
    pri_df <- pri_df[pri_df$repo == repo_filter, ]
  }

  cur_df <- enrich_with_attempts(con, cur_df, has_lineage)
  pri_df <- enrich_with_attempts(con, pri_df, has_lineage)

  cur_freq  <- compute_freq_table(cur_df)
  cur_speed <- compute_speed(cur_df)
  pri_speed <- compute_speed(pri_df)

  trends <- list(
    ttc_p50    = trend_delta(cur_speed$ttc_p50,    pri_speed$ttc_p50),
    ttc_p90    = trend_delta(cur_speed$ttc_p90,    pri_speed$ttc_p90),
    att_p50    = trend_delta(cur_speed$att_p50,    pri_speed$att_p50),
    close_rate = trend_delta(cur_speed$close_rate, pri_speed$close_rate)
  )

  # ── Throughput (llm#738) ────────────────────────────────────────────────────
  # n_opened_in_window: verdict='F' reviews CREATED in this window — identical
  #   to compute_speed()'s n_issues_found; re-exposed here under an honest name
  #   because it is the natural denominator for a throughput ratio.
  # n_closed_in_window: ALL reviews (any verdict) that CLOSED in this window,
  #   counted by closed_at/updated_at — independent of when they were created,
  #   so a fresh d1 window is NOT structurally forced to zero. Global (repo_filter
  #   is NULL) slices prefer the authoritative reviews.db source (no ETL lag);
  #   per-repo slices use the lifecycle table only (repo attribution for the
  #   reviews.db path is not implemented — see PR notes for llm#738).
  n_opened_in_window <- cur_speed$n_issues_found

  n_closed_lifecycle <- load_lifecycle_closed_count(con, bounds$cur$start, bounds$cur$end)
  n_closed_raw <- if (is.null(repo_filter)) {
    load_raw_closed_count(bounds$cur$start, bounds$cur$end)
  } else {
    NA_integer_
  }

  n_closed_in_window <- if (!is.na(n_closed_raw)) {
    n_closed_raw
  } else if (!is.na(n_closed_lifecycle)) {
    n_closed_lifecycle
  } else {
    NA_integer_
  }
  n_closed_in_window_source <- if (!is.na(n_closed_raw)) {
    "reviews_db_updated_at"
  } else if (!is.na(n_closed_lifecycle)) {
    "lifecycle_closed_at"
  } else {
    "unavailable"
  }

  close_throughput_rate <- if (!is.na(n_closed_in_window) && !is.na(n_opened_in_window) &&
                               n_opened_in_window > 0L) {
    n_closed_in_window / n_opened_in_window
  } else {
    NA_real_
  }

  throughput <- list(
    n_opened_in_window        = n_opened_in_window,
    n_closed_in_window        = n_closed_in_window,
    n_closed_in_window_source = n_closed_in_window_source,
    close_throughput_rate     = close_throughput_rate
  )

  list(
    window_days  = days,
    repo         = if (is.null(repo_filter)) "__all__" else repo_filter,
    n_reviews    = nrow(cur_df),
    freq_table   = cur_freq,
    speed        = cur_speed,
    trends       = trends,
    prior_speed  = pri_speed,
    throughput   = throughput
  )
}

# ── Build full report structure ────────────────────────────────────────────────
#
# Runs §1–§3 for each (window, repo_slice) combination.
# §4 (outliers) is computed for the 14d global window only.

WINDOWS <- c(1L, 3L, 7L, 14L)

cat("roborev_daily_report.R: computing global window slices...\n")

window_slices_global <- lapply(WINDOWS, function(w) {
  compute_window_slice(con, anchor_date, w, repo_filter = NULL, has_lineage = has_lineage_table)
})
names(window_slices_global) <- paste0("d", WINDOWS)

# Per-repo slices for the 7-day window (most useful for project-level drill-down)
repos_present <- tryCatch(
  dbGetQuery(con, "SELECT DISTINCT repo FROM roborev_review_lifecycle ORDER BY repo")$repo,
  error = function(e) character(0L)
)

cat(sprintf("roborev_daily_report.R: per-repo 7d slices for %d repos...\n",
            length(repos_present)))

window_slices_by_repo <- lapply(repos_present, function(r) {
  compute_window_slice(con, anchor_date, 7L, repo_filter = r, has_lineage = has_lineage_table)
})
names(window_slices_by_repo) <- repos_present

# §4 Outliers: 14d global
cat("roborev_daily_report.R: computing 14d outliers...\n")
bounds_14d <- window_bounds(anchor_date, 14L)
df_14d_global <- load_window(con, bounds_14d$cur$start, bounds_14d$cur$end)
df_14d_global <- enrich_with_attempts(con, df_14d_global, has_lineage_table)
outliers_14d  <- compute_outliers(df_14d_global)

# §5 Severity by project: 7d global (filtered to canonical_projects)
cat("roborev_daily_report.R: computing 7d per-project severity table...\n")
severity_by_project_7d     <- compute_severity_by_project(con, anchor_date, 7L, filtered = TRUE)
severity_by_project_7d_all <- compute_severity_by_project(con, anchor_date, 7L, filtered = FALSE)

# ── Assemble JSON output ───────────────────────────────────────────────────────

report_date   <- format(anchor_date, "%Y-%m-%d", tz = "UTC")
report_ts     <- format(anchor_date, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")

# Serialise freq_table as a list of records (JSON-array compatible)
serialise_freq <- function(df) {
  if (nrow(df) == 0L) return(list())
  lapply(seq_len(nrow(df)), function(i) {
    list(verdict_label = df$verdict_label[i],
         status        = df$status[i],
         n             = df$n[i])
  })
}

serialise_slice <- function(sl) {
  list(
    window_days    = sl$window_days,
    repo           = sl$repo,
    n_reviews      = sl$n_reviews,
    freq_table     = serialise_freq(sl$freq_table),
    speed = list(
      ttc_p50_hrs    = sl$speed$ttc_p50,
      ttc_p90_hrs    = sl$speed$ttc_p90,
      ttc_p99_hrs    = sl$speed$ttc_p99,
      att_p50        = sl$speed$att_p50,
      att_p90        = sl$speed$att_p90,
      # close_rate: KEPT for back-compat with send_roborev_email.R's existing
      # d1_close_rate reader (llm#738 — that file is outside this PR's write
      # scope; renaming this key here without also updating the email script
      # would silently break the email's zero-action guard). This is the
      # created_at-cohort rate — i.e. "of the reviews CREATED in this window,
      # what fraction have closed SO FAR" — which is right-censored for short
      # windows (see cohort_close_rate_created_window below for the honest name).
      close_rate     = sl$speed$close_rate,
      # cohort_close_rate_created_window: identical value to close_rate above,
      # under an honest name that can't be mistaken for closure throughput.
      # It is a valid cohort/maturation metric (llm#738 item 2) — just not the
      # metric a reader means by "how many closed in the last 24h". See
      # throughput.close_throughput_rate below for that question.
      cohort_close_rate_created_window = sl$speed$close_rate,
      n_issues_found = sl$speed$n_issues_found,
      n_closed       = sl$speed$n_closed,
      n_open         = sl$speed$n_open
    ),
    # throughput (llm#738): closed_at/updated_at-window metrics, NOT censored
    # by created_at. n_closed_in_window counts ALL verdicts; n_opened_in_window
    # is verdict='F' only (same cohort as speed$n_issues_found) — so
    # close_throughput_rate is a rough backlog-clearance signal (can exceed
    # 100% when more get closed than were newly opened), not a strict
    # verdict-matched conversion rate.
    throughput = list(
      n_opened_in_window        = sl$throughput$n_opened_in_window,
      n_closed_in_window        = sl$throughput$n_closed_in_window,
      n_closed_in_window_source = sl$throughput$n_closed_in_window_source,
      close_throughput_rate     = sl$throughput$close_throughput_rate
    ),
    trends = list(
      ttc_p50    = sl$trends$ttc_p50,
      ttc_p90    = sl$trends$ttc_p90,
      att_p50    = sl$trends$att_p50,
      close_rate = sl$trends$close_rate
    )
  )
}

json_payload <- list(
  report_date   = report_date,
  generated_at  = report_ts,
  lineage_source = if (has_lineage_table) "roborev_finding_lineage_summary" else "heuristic-retry_count+1",
  global_windows = lapply(window_slices_global, serialise_slice),
  per_repo_7d    = lapply(window_slices_by_repo, serialise_slice),
  outliers_14d   = list(
    by_attempts = outliers_14d$by_attempts,
    by_time     = outliers_14d$by_time
  ),
  severity_by_project_7d     = severity_by_project_7d,      # §5: filtered (llm#534)
  severity_by_project_7d_all = severity_by_project_7d_all   # §5: unfiltered (debug/legacy)
)

# ── Write JSON snapshot ───────────────────────────────────────────────────────

out_path <- file.path(ROBOREV_DAILY_DIR, paste0(report_date, ".json"))

if (!dry_run) {
  dir.create(ROBOREV_DAILY_DIR, recursive = TRUE, showWarnings = FALSE)
  tryCatch({
    writeLines(
      jsonlite::toJSON(json_payload, auto_unbox = TRUE, pretty = TRUE, na = "null"),
      out_path
    )
    cat(sprintf("roborev_daily_report.R: JSON snapshot written → %s\n", out_path))
  }, error = function(e) {
    message("roborev_daily_report.R: failed to write JSON: ", conditionMessage(e))
  })
} else {
  cat(sprintf("roborev_daily_report.R: dry-run — would write → %s\n", out_path))
}

# ── Text digest (stdout) ──────────────────────────────────────────────────────
#
# Suitable for email body (#287).  Compact tables + section headings.
# All values are dynamic (computed above, never hardcoded).

fmt_pct  <- function(x) if (is.na(x)) "n/a" else sprintf("%.0f%%", x)
fmt_hrs  <- function(x) if (is.na(x)) "n/a" else sprintf("%.1fh", x)
fmt_att  <- function(x) if (is.na(x)) "n/a" else sprintf("%.1f", x)
fmt_rate <- function(x) if (is.na(x)) "n/a" else sprintf("%.1f%%", x * 100)
fmt_int0 <- function(x) if (is.na(x)) "n/a" else sprintf("%d", as.integer(x))
fmt_trend <- function(td) {
  if (is.na(td$pct_delta) && is.na(td$abs_delta)) return("n/a")
  if (is.na(td$pct_delta)) return(sprintf("Δ%.2f", td$abs_delta))
  dir <- if (td$pct_delta > 0) "▲" else if (td$pct_delta < 0) "▼" else "="
  sprintf("%s%.0f%%", dir, abs(td$pct_delta))
}

digest_lines <- character(0L)
catd <- function(...) { digest_lines <<- c(digest_lines, paste0(...)) }

catd("=======================================================")
catd(sprintf("roborev Daily Report — %s", report_date))
catd(sprintf("Generated: %s UTC", report_ts))
catd(sprintf("Lineage source: %s", json_payload$lineage_source))
catd("=======================================================")
catd("")

# §1 Frequency table — 7d global
catd("§1 FREQUENCY TABLE (7-day, all repos)")
catd("-------------------------------------------------------")
sl7 <- window_slices_global[["d7"]]
if (nrow(sl7$freq_table) > 0L) {
  catd(sprintf("  %-18s  %-8s  %6s", "verdict", "status", "count"))
  catd(sprintf("  %-18s  %-8s  %6s", "------", "------", "-----"))
  for (i in seq_len(nrow(sl7$freq_table))) {
    r <- sl7$freq_table[i, ]
    catd(sprintf("  %-18s  %-8s  %6d", r$verdict_label, r$status, r$n))
  }
} else {
  catd("  (no data)")
}
catd("")

# §2 Resolution speed — all 4 windows
catd("§2 RESOLUTION SPEED (issues-found reviews that were closed)")
catd("-------------------------------------------------------")
catd(sprintf("  %-6s  %10s  %10s  %10s  %8s  %8s  %8s",
             "Window", "TTC-p50", "TTC-p90", "TTC-p99", "Att-p50", "Att-p90", "CloseRate"))
catd(sprintf("  %-6s  %10s  %10s  %10s  %8s  %8s  %8s",
             "------", "-------", "-------", "-------", "-------", "-------", "---------"))
for (w in names(window_slices_global)) {
  sl <- window_slices_global[[w]]
  sp <- sl$speed
  catd(sprintf("  %-6s  %10s  %10s  %10s  %8s  %8s  %8s",
               paste0(sl$window_days, "d"),
               fmt_hrs(sp$ttc_p50), fmt_hrs(sp$ttc_p90), fmt_hrs(sp$ttc_p99),
               fmt_att(sp$att_p50), fmt_att(sp$att_p90),
               fmt_rate(sp$close_rate)))
}
catd("")

# §2b Throughput — closed_at/updated_at-window, NOT censored by created_at
# (llm#738). Fixes the structural d1 zero: a review created 24h ago typically
# hasn't closed yet (median TTC 13-49h per §2 above), so close_rate ~0 for d1
# is expected censoring, not a broken pipeline. n_closed_in_window instead
# counts closes BY closed_at/updated_at, independent of when the review was
# created.
catd("§2b THROUGHPUT (closed_at/updated_at-window; not censored by created_at)")
catd("-------------------------------------------------------")
catd(sprintf("  %-6s  %8s  %8s  %10s  %s",
             "Window", "Opened", "Closed", "Thruput%", "Source"))
catd(sprintf("  %-6s  %8s  %8s  %10s  %s",
             "------", "------", "------", "--------", "------"))
for (w in names(window_slices_global)) {
  sl <- window_slices_global[[w]]
  th <- sl$throughput
  catd(sprintf("  %-6s  %8s  %8s  %10s  %s",
               paste0(sl$window_days, "d"),
               fmt_int0(th$n_opened_in_window),
               fmt_int0(th$n_closed_in_window),
               fmt_rate(th$close_throughput_rate),
               th$n_closed_in_window_source))
}
catd("")

# §3 Trends — 7d vs prior 7d
catd("§3 TRENDS (7-day vs prior 7-day, global)")
catd("-------------------------------------------------------")
tr7 <- window_slices_global[["d7"]]$trends
catd(sprintf("  TTC p50:    %s   (cur=%s)",
             fmt_trend(tr7$ttc_p50),    fmt_hrs(window_slices_global[["d7"]]$speed$ttc_p50)))
catd(sprintf("  TTC p90:    %s   (cur=%s)",
             fmt_trend(tr7$ttc_p90),    fmt_hrs(window_slices_global[["d7"]]$speed$ttc_p90)))
catd(sprintf("  Att p50:    %s   (cur=%s)",
             fmt_trend(tr7$att_p50),    fmt_att(window_slices_global[["d7"]]$speed$att_p50)))
catd(sprintf("  Close rate: %s   (cur=%s)",
             fmt_trend(tr7$close_rate), fmt_rate(window_slices_global[["d7"]]$speed$close_rate)))
catd("")

# §4 Outliers — top-5 of each (truncated for email; full data in JSON)
catd("§4 OUTLIERS — Top-5 by time-to-close (14-day window)")
catd("-------------------------------------------------------")
by_ttc <- outliers_14d$by_time
if (nrow(by_ttc) > 0L) {
  n_show <- min(5L, nrow(by_ttc))
  catd(sprintf("  %-8s  %-20s  %10s  %8s  %s",
               "review_id", "repo", "TTC(hrs)", "attempts", "close_reason"))
  catd(sprintf("  %-8s  %-20s  %10s  %8s  %s",
               "---------", "----", "--------", "--------", "------------"))
  for (i in seq_len(n_show)) {
    r <- by_ttc[i, ]
    catd(sprintf("  %-8d  %-20s  %10.1f  %8d  %s",
                 r$review_id, r$repo, r$time_to_close_hrs, r$n_attempts, r$close_reason))
  }
} else {
  catd("  (no closed issues-found reviews in 14-day window)")
}
catd("")

catd("§4 OUTLIERS — Top-5 by attempts-to-close (14-day window)")
catd("-------------------------------------------------------")
by_att <- outliers_14d$by_attempts
if (nrow(by_att) > 0L) {
  n_show <- min(5L, nrow(by_att))
  catd(sprintf("  %-8s  %-20s  %8s  %10s  %s",
               "review_id", "repo", "attempts", "TTC(hrs)", "close_reason"))
  catd(sprintf("  %-8s  %-20s  %8s  %10s  %s",
               "---------", "----", "--------", "--------", "------------"))
  for (i in seq_len(n_show)) {
    r <- by_att[i, ]
    catd(sprintf("  %-8d  %-20s  %8d  %10.1f  %s",
                 r$review_id, r$repo, r$n_attempts, r$time_to_close_hrs, r$close_reason))
  }
} else {
  catd("  (no closed issues-found reviews in 14-day window)")
}
catd("")
catd("=======================================================")
catd("Full data: JSON snapshot at")
catd(out_path)
catd("=======================================================")

cat(paste(digest_lines, collapse = "\n"), "\n")

cat(sprintf(
  "roborev_daily_report.R: done — %d global slices, %d repo slices computed\n",
  length(window_slices_global), length(window_slices_by_repo)
))
