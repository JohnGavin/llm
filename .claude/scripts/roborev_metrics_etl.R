#!/usr/bin/env Rscript
# roborev_metrics_etl.R — ETL logic for roborev_* tables in unified.duckdb.
#
# Called by roborev_metrics_etl.sh. Do not invoke directly in production —
# the shell wrapper sets PATH, handles logging, and manages flags.
#
# Args (passed from shell via commandArgs):
#   --dry-run   (default) print proposed row counts; no DB writes
#   --apply     write to unified.duckdb
#   --since YYYY-MM-DD  only process records on or after this date
#   --repo <name>       restrict to one repo (default: all)
#
# Dependencies: duckdb (with SQLite extension), dplyr, lubridate, jsonlite
# (all present in the llm nix shell; NO RSQLite needed — DuckDB reads SQLite
# natively via its built-in sqlite extension)
#
# Slice 1 populates:
#   roborev_daily_metrics     — daily per-repo rollup
#   roborev_review_lifecycle  — per-review timeline
# Slice 2 populates:
#   roborev_agent_performance  — daily per-agent rollup (tokens/cost NULL when absent)
#   roborev_threshold_changes  — audit trail reconstructed from counter JSON
#   roborev_cadence_efficacy   — poll vs hook breakdown from poll_merges.log
#
# Schema file: ~/.claude/scripts/roborev_metrics_schema.sql
# Source DB:   ~/.roborev/reviews.db (SQLite, read via DuckDB sqlite ext)
# Target DB:   ~/.claude/logs/unified.duckdb (DuckDB, read-write)
# Log:         ~/.claude/logs/roborev_metrics_etl.log
#
# Tracked in llm#226.

suppressPackageStartupMessages({
  library(DBI)
  library(duckdb)
  library(dplyr)
  library(jsonlite)
})

# ── Argument parsing ──────────────────────────────────────────────────────

args <- commandArgs(trailingOnly = TRUE)

mode  <- "dry-run"   # default
since <- NULL        # NULL = 7 days back
repo  <- NULL        # NULL = all repos

i <- 1L
while (i <= length(args)) {
  switch(args[[i]],
    "--dry-run" = { mode <- "dry-run"; i <- i + 1L },
    "--apply"   = { mode <- "apply";   i <- i + 1L },
    "--since"   = {
      if (i + 1L > length(args)) stop("--since requires a YYYY-MM-DD argument")
      since <- tryCatch(as.Date(args[[i + 1L]]),
                        error = function(e) stop(paste("--since: invalid date:", args[[i + 1L]])))
      if (is.na(since)) stop(paste("--since: invalid date:", args[[i + 1L]]))
      i <- i + 2L
    },
    "--repo"    = {
      if (i + 1L > length(args)) stop("--repo requires an argument")
      repo <- args[[i + 1L]]
      i <- i + 2L
    },
    {
      stop(paste("unknown argument:", args[[i]]))
    }
  )
}

# Default since: 7 days back
if (is.null(since)) {
  since <- Sys.Date() - 7L
}

etl_run_at <- Sys.time()

cat(sprintf("roborev_metrics_etl.R: mode=%s since=%s repo=%s\n",
            mode, format(since, "%Y-%m-%d"), if (is.null(repo)) "(all)" else repo))

# ── Paths ──────────────────────────────────────────────────────────────────

REVIEWS_DB  <- Sys.getenv("ROBOREV_DB",
                           file.path(Sys.getenv("HOME"), ".roborev", "reviews.db"))
UNIFIED_DB  <- Sys.getenv("UNIFIED_DB",
                           file.path(Sys.getenv("HOME"), ".claude", "logs", "unified.duckdb"))
SCHEMA_FILE <- Sys.getenv("SCHEMA_FILE",
                           file.path(Sys.getenv("HOME"), ".claude", "scripts",
                                     "roborev_metrics_schema.sql"))
COUNTER_FILE  <- file.path(Sys.getenv("HOME"), ".claude",
                             ".roborev_autoclose_counters.json")
AUTOCLOSE_LOG <- file.path(Sys.getenv("HOME"), ".claude", "logs",
                             "roborev_severity_autoclose.log")
POLL_LOG      <- file.path(Sys.getenv("HOME"), ".claude", "logs",
                             "roborev_poll_merges.log")
CODEX_FALLBACK_LOG_DIR <- file.path(Sys.getenv("HOME"), ".claude", "logs",
                                     "codex_fallback")

# ── Logging helper ─────────────────────────────────────────────────────────

log_file <- file.path(Sys.getenv("HOME"), ".claude", "logs", "roborev_metrics_etl.log")

log_msg <- function(...) {
  ts  <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  msg <- paste0(ts, " ", paste(..., sep = ""))
  cat(msg, "\n")
  tryCatch(
    cat(msg, "\n", file = log_file, append = TRUE),
    error = function(e) NULL  # log failure must never abort ETL
  )
}

# ── Graceful abort: exit 0 with message ───────────────────────────────────

graceful_exit <- function(reason) {
  log_msg("SKIP: ", reason)
  cat("roborev_metrics_etl.R: skipping — ", reason, "\n", sep = "")
  quit(status = 0L)
}

# ── Read source data via DuckDB SQLite extension ───────────────────────────

if (!file.exists(REVIEWS_DB)) {
  graceful_exit(paste("reviews.db not found at", REVIEWS_DB))
}

# Open a temporary in-memory DuckDB for reading the SQLite source
read_con <- tryCatch(
  dbConnect(duckdb::duckdb(), ":memory:"),
  error = function(e) {
    graceful_exit(paste("cannot open DuckDB in-memory:", conditionMessage(e)))
  }
)
on.exit(tryCatch(dbDisconnect(read_con, shutdown = TRUE), error = function(e) NULL),
        add = TRUE)

# Load SQLite extension.  In DuckDB >= 1.1.0 the sqlite extension is bundled
# and LOAD succeeds without INSTALL.  INSTALL fetches from the network and may
# fail in offline environments (launchd jobs, Nix shells without curl).
# Strategy: try LOAD first; fall back to INSTALL+LOAD only if LOAD fails.
invisible(tryCatch({
  tryCatch({
    invisible(dbExecute(read_con, "LOAD sqlite"))
  }, error = function(e_load) {
    # Bundled LOAD failed — try downloading the extension
    invisible(dbExecute(read_con, "INSTALL sqlite"))
    invisible(dbExecute(read_con, "LOAD sqlite"))
  })
}, error = function(e) {
  graceful_exit(paste("DuckDB sqlite extension unavailable:", conditionMessage(e)))
}))

# Attach the SQLite DB read-only
tryCatch({
  invisible(dbExecute(read_con,
            sprintf("ATTACH '%s' AS src (TYPE sqlite, READ_ONLY)", REVIEWS_DB)))
}, error = function(e) {
  graceful_exit(paste("cannot attach reviews.db:", conditionMessage(e)))
})

# Validate expected columns exist
check_cols <- function(con, db_prefix, table, required) {
  actual <- tryCatch(
    dbGetQuery(con,
               sprintf("SELECT column_name FROM information_schema.columns
                         WHERE table_catalog = '%s' AND table_name = '%s'",
                        db_prefix, table))[[1L]],
    error = function(e) character(0L)
  )
  if (length(actual) == 0L) {
    # Fall back: list columns via a SELECT
    actual <- tryCatch(
      names(dbGetQuery(con, sprintf("SELECT * FROM %s.%s LIMIT 0", db_prefix, table))),
      error = function(e) character(0L)
    )
  }
  missing <- setdiff(required, actual)
  if (length(missing) > 0L) {
    stop(sprintf("Table '%s.%s' missing expected columns: %s",
                 db_prefix, table, paste(missing, collapse = ", ")))
  }
}

tryCatch({
  check_cols(read_con, "src", "review_jobs",
             c("id", "repo_id", "agent", "model", "branch", "status",
               "enqueued_at", "started_at", "finished_at"))
  check_cols(read_con, "src", "reviews",
             c("id", "job_id", "closed", "verdict_bool", "output"))
  check_cols(read_con, "src", "repos",
             c("id", "name"))
  # responses table holds auto-closed marker comments — required for close_reason
  check_cols(read_con, "src", "responses",
             c("id", "job_id", "response"))
}, error = function(e) {
  graceful_exit(paste("Schema validation failed:", conditionMessage(e)))
})

since_str <- format(since, "%Y-%m-%d")

repo_clause <- if (!is.null(repo)) {
  sprintf("AND rp.name = '%s'", gsub("'", "''", repo))
} else {
  ""
}

sql_jobs <- sprintf("
  SELECT
    rj.id          AS job_id,
    rp.name        AS repo,
    rj.agent,
    rj.model,
    rj.branch,
    rj.status,
    rj.enqueued_at,
    rj.started_at,
    rj.finished_at,
    rj.source
  FROM src.review_jobs rj
  JOIN src.repos rp ON rp.id = rj.repo_id
  WHERE date(rj.enqueued_at) >= DATE '%s'
  %s
  ORDER BY rj.id
", since_str, repo_clause)

jobs_raw <- tryCatch(
  dbGetQuery(read_con, sql_jobs),
  error = function(e) {
    log_msg("WARN: could not query review_jobs: ", conditionMessage(e))
    data.frame()
  }
)

sql_reviews <- sprintf("
  SELECT
    rv.id          AS review_id,
    rv.job_id,
    rv.closed,
    rv.verdict_bool,
    rv.output,
    rv.created_at,
    rv.updated_at
  FROM src.reviews rv
  JOIN src.review_jobs rj ON rj.id = rv.job_id
  JOIN src.repos rp ON rp.id = rj.repo_id
  WHERE date(rj.enqueued_at) >= DATE '%s'
  %s
  ORDER BY rv.id
", since_str, repo_clause)

reviews_raw <- tryCatch(
  dbGetQuery(read_con, sql_reviews),
  error = function(e) {
    log_msg("WARN: could not query reviews: ", conditionMessage(e))
    data.frame()
  }
)

# ── Read latest auto-closed marker per job from responses table ───────────
# Only retrieve the most recent auto-closed: marker per job_id (MAX(id) proxy
# for latest).  This is the canonical close reason for a review.
# NOTE: DuckDB sqlite extension reads through WAL automatically; do NOT use
# RSQLite here as it may miss WAL entries.

sql_markers <- "
  SELECT
    rsp.job_id,
    rsp.response AS marker
  FROM src.responses rsp
  WHERE rsp.response LIKE 'auto-closed:%'
  AND rsp.id IN (
    SELECT MAX(id) FROM src.responses
    WHERE response LIKE 'auto-closed:%'
    GROUP BY job_id
  )
"

markers_raw <- tryCatch(
  dbGetQuery(read_con, sql_markers),
  error = function(e) {
    log_msg("WARN: could not query responses (markers): ", conditionMessage(e))
    data.frame(job_id = integer(), marker = character(), stringsAsFactors = FALSE)
  }
)

cat(sprintf("roborev_metrics_etl.R: read %d jobs, %d reviews, %d closure markers from reviews.db\n",
            nrow(jobs_raw), nrow(reviews_raw), nrow(markers_raw)))

# ── Parse autoclose counter JSON ───────────────────────────────────────────

`%||%` <- function(a, b) if (!is.null(a)) a else b

parse_counter_json <- function(path) {
  if (!file.exists(path)) {
    log_msg("INFO: counter file absent: ", path)
    return(list())
  }
  tryCatch({
    raw <- jsonlite::fromJSON(path, simplifyVector = FALSE)
    raw$by_date %||% list()
  }, error = function(e) {
    log_msg("WARN: malformed counter JSON: ", conditionMessage(e))
    list()
  })
}

counter_data <- parse_counter_json(COUNTER_FILE)

# Parse severity autoclose log for per-(date, repo) CLOSE counts
# Log format: 2026-05-21T10:00:00Z CLOSE review_id=42 repo=llm ...
parse_autoclose_log <- function(path) {
  result <- list()
  if (!file.exists(path)) {
    log_msg("INFO: autoclose log absent: ", path)
    return(result)
  }
  tryCatch({
    lines <- readLines(path, warn = FALSE)
    pattern <- "^(\\d{4}-\\d{2}-\\d{2})T[^ ]+ CLOSE review_id=[0-9]+ repo=([^ ]+)"
    for (line in lines) {
      m <- regmatches(line, regexec(pattern, line))[[1L]]
      if (length(m) == 3L) {
        key            <- paste0(m[[2L]], "|", m[[3L]])
        result[[key]]  <- (result[[key]] %||% 0L) + 1L
      }
    }
  }, error = function(e) {
    log_msg("WARN: autoclose log parse error: ", conditionMessage(e))
  })
  result
}

sev_autoclose_counts <- parse_autoclose_log(AUTOCLOSE_LOG)

get_age_autoclose <- function(date_str, repo_name) 0L  # Slice 2

get_sev_autoclose <- function(date_str, repo_name) {
  as.integer(sev_autoclose_counts[[paste0(date_str, "|", repo_name)]] %||% 0L)
}

get_parse_fail <- function(date_str, repo_name) {
  day_data <- counter_data[[date_str]]
  if (is.null(day_data)) return(0L)
  by_repo   <- day_data$by_repo %||% list()
  repo_data <- by_repo[[repo_name]]
  as.integer(repo_data$parse_fail %||% 0L)
}

get_threshold_effective <- function(date_str, repo_name) {
  day_data <- counter_data[[date_str]]
  if (is.null(day_data)) return(NA_character_)
  by_repo   <- day_data$by_repo %||% list()
  repo_data <- by_repo[[repo_name]]
  if (!is.null(repo_data$threshold)) return(repo_data$threshold)
  th_obs <- day_data$threshold_observed %||% list()
  th_obs[[repo_name]] %||% NA_character_
}

# ── Parse severity from review output text ─────────────────────────────────

SEVERITY_PATTERN <- "\\*\\*Severity\\*\\*:[[:space:]]*(Critical|High|Medium|Low)"
SEVERITY_LEVELS  <- c("Low" = 1L, "Medium" = 2L, "High" = 3L, "Critical" = 4L)
SEVERITY_NAMES   <- setNames(names(SEVERITY_LEVELS), as.character(SEVERITY_LEVELS))

parse_max_severity <- function(text) {
  if (is.na(text) || !nzchar(text)) return(NA_character_)
  tryCatch({
    m <- regmatches(text, gregexpr(SEVERITY_PATTERN, text, ignore.case = TRUE))[[1L]]
    if (length(m) == 0L) return(NA_character_)
    words <- sub(SEVERITY_PATTERN, "\\1", m, ignore.case = TRUE)
    ords  <- SEVERITY_LEVELS[words]
    ords  <- ords[!is.na(ords)]
    if (length(ords) == 0L) return(NA_character_)
    SEVERITY_NAMES[[as.character(max(ords))]]
  }, error = function(e) NA_character_)
}

# ── Build roborev_daily_metrics ────────────────────────────────────────────

build_daily_metrics <- function(jobs, reviews) {
  empty_df <- data.frame(
    date                        = as.Date(character()),
    repo                        = character(),
    reviews_created             = integer(),
    reviews_passed              = integer(),
    reviews_failed              = integer(),
    reviews_autoclosed_severity = integer(),
    reviews_autoclosed_age      = integer(),
    parse_fail_count            = integer(),
    threshold_effective         = character(),
    etl_run_at                  = as.POSIXct(character()),
    stringsAsFactors            = FALSE
  )

  if (nrow(jobs) == 0L) {
    cat("roborev_metrics_etl.R: no jobs in window — daily_metrics will be empty\n")
    return(empty_df)
  }

  jobs_dated        <- jobs
  jobs_dated$date_str <- substr(jobs_dated$enqueued_at, 1L, 10L)
  daily_combos      <- unique(jobs_dated[, c("date_str", "repo"), drop = FALSE])

  rv_slim <- if (nrow(reviews) > 0L) {
    reviews[, c("review_id", "job_id", "verdict_bool", "closed"), drop = FALSE]
  } else {
    data.frame(review_id    = integer(),
               job_id       = integer(),
               verdict_bool = integer(),
               closed       = integer(),
               stringsAsFactors = FALSE)
  }

  result_rows <- lapply(seq_len(nrow(daily_combos)), function(k) {
    d   <- daily_combos$date_str[[k]]
    rep <- daily_combos$repo[[k]]

    day_jobs  <- jobs_dated[jobs_dated$date_str == d & jobs_dated$repo == rep, ]
    job_ids   <- day_jobs$job_id
    day_rv    <- rv_slim[rv_slim$job_id %in% job_ids, ]

    data.frame(
      date                        = as.Date(d),
      repo                        = rep,
      reviews_created             = nrow(day_jobs),
      reviews_passed              = sum(day_rv$verdict_bool == 1L, na.rm = TRUE),
      reviews_failed              = sum(day_rv$verdict_bool == 0L, na.rm = TRUE),
      reviews_autoclosed_severity = get_sev_autoclose(d, rep),
      reviews_autoclosed_age      = get_age_autoclose(d, rep),
      parse_fail_count            = get_parse_fail(d, rep),
      threshold_effective         = get_threshold_effective(d, rep),
      etl_run_at                  = etl_run_at,
      stringsAsFactors            = FALSE
    )
  })

  do.call(rbind, result_rows)
}

# ── Derive close_reason from auto-closed marker text ──────────────────────
#
# Priority (applied to the LATEST marker per job):
#   1. "auto-closed: severity<=<band> ..." → "severity-<band>"  (e.g. "severity-medium")
#   2. "auto-closed: clean verdict ..." + verdict_bool=1  → "clean-verdict"
#   3. "auto-closed: clean verdict ..." + verdict_bool=0  → "clean-verdict-pre-fix"
#      (these were closed by the buggy pre-#311 path that called clean-verdict
#       on a non-clean review)
#   4. closed=1, no marker, verdict_bool=1 → "clean-verdict-pre-fix"
#      (pre-autoclose manual closes of clean reviews)
#   5. closed=1, no marker, verdict_bool=0 → "manual"
#      (pre-autoclose manual closes, or closes from before any scripted path)
#   6. closed=0 → NA (open review)
#
# Vocabulary (5 values + NA):
#   "clean-verdict"       — autoclose: review passed, severity markers absent
#   "clean-verdict-pre-fix" — autoclose ran but closed a non-clean review (pre-#311),
#                             OR a clean review closed manually before autoclose existed
#   "severity-<band>"     — autoclose because max severity <= configured threshold
#                           band is the literal word: low/medium/high/critical
#   "manual"              — closed=1, no auto-closed marker, verdict_bool=0
#   NA                    — open (closed=0)

derive_close_reason <- function(marker, verdict_bool, is_closed) {
  # marker: character(1) or NA; verdict_bool: integer(1) or NA; is_closed: logical(1)
  if (!is_closed) return(NA_character_)

  if (!is.na(marker)) {
    if (grepl("^auto-closed: severity<=", marker, perl = TRUE)) {
      # Extract band between "severity<=" and the next space/bracket
      band <- sub("^auto-closed: severity<=(\\w+).*", "\\1", marker, perl = TRUE)
      return(paste0("severity-", tolower(band)))
    }
    if (grepl("^auto-closed: clean verdict", marker, perl = TRUE)) {
      if (!is.na(verdict_bool) && verdict_bool == 1L) {
        return("clean-verdict")
      }
      return("clean-verdict-pre-fix")
    }
    # Unknown marker format — treat as manual
    return("manual")
  }

  # No marker at all
  if (!is.na(verdict_bool) && verdict_bool == 1L) {
    return("clean-verdict-pre-fix")
  }
  "manual"
}

# ── Build roborev_review_lifecycle ─────────────────────────────────────────

build_review_lifecycle <- function(jobs, reviews, markers) {
  empty_df <- data.frame(
    review_id                    = integer(),
    job_id                       = integer(),
    repo                         = character(),
    agent                        = character(),
    model                        = character(),
    branch                       = character(),
    commit_sha                   = character(),
    created_at                   = as.POSIXct(character()),
    started_at                   = as.POSIXct(character()),
    finished_at                  = as.POSIXct(character()),
    duration_s                   = double(),
    verdict                      = character(),
    severity_max                 = character(),
    closed_at                    = as.POSIXct(character()),
    close_reason                 = character(),
    autoclose_threshold_at_close = character(),
    stringsAsFactors             = FALSE
  )

  if (nrow(reviews) == 0L) {
    cat("roborev_metrics_etl.R: no reviews in window — lifecycle will be empty\n")
    return(empty_df)
  }

  jb     <- jobs[, c("job_id", "repo", "agent", "model", "branch",
                      "status", "enqueued_at", "started_at", "finished_at"),
                  drop = FALSE]
  merged <- merge(reviews, jb, by = "job_id", all.x = TRUE)

  # Join the latest closure marker per job (left join — NAs for open/unmarked reviews)
  if (!is.null(markers) && nrow(markers) > 0L) {
    merged <- merge(merged, markers, by = "job_id", all.x = TRUE)
  } else {
    merged$marker <- NA_character_
  }

  parse_ts <- function(x) {
    # Handles these timestamp formats (all observed in reviews.db):
    #   "2026-05-27T18:17:12+01:00"  RFC 3339 with colon offset  → +0100 (after norm)
    #   "2026-05-27T18:17:12+0100"   ISO 8601 compact offset
    #   "2026-05-27T13:02:32Z"       UTC shorthand (Z suffix)    → +0000 (after norm)
    #   "2026-05-27 18:17:12"        plain space-separated (UTC assumed)
    #
    # R's %z expects "+HHMM" (no colon).  Normalise before parsing.
    # IMPORTANT: x is a vector — handle element-by-element fallback.
    tryCatch({
      # 1. Replace RFC 3339 colon-offset "+HH:MM" → "+HHMM"
      x_norm <- sub("([+-][0-9]{2}):([0-9]{2})$", "\\1\\2", x)
      # 2. Replace trailing "Z" with "+0000"
      x_norm <- sub("Z$", "+0000", x_norm)
      # Try ISO 8601 with offset first
      ts <- as.POSIXct(x_norm, tz = "UTC", format = "%Y-%m-%dT%H:%M:%S%z")
      # Element-wise fallback: for any position still NA, try space-separated
      still_na <- which(is.na(ts) & !is.na(x))
      if (length(still_na) > 0L) {
        ts_fb <- as.POSIXct(x_norm[still_na], tz = "UTC", format = "%Y-%m-%d %H:%M:%S")
        ts[still_na] <- ts_fb
      }
      ts
    }, error = function(e) as.POSIXct(NA_real_, origin = "1970-01-01"))
  }

  finished <- parse_ts(merged$finished_at)
  started  <- parse_ts(merged$started_at)
  duration <- as.numeric(difftime(finished, started, units = "secs"))

  verdict <- ifelse(is.na(merged$verdict_bool), NA_character_,
                    ifelse(merged$verdict_bool == 1L, "P", "F"))

  cat("roborev_metrics_etl.R: parsing severity from", nrow(merged), "review outputs...\n")
  severity_max <- vapply(merged$output, parse_max_severity,
                         character(1L), USE.NAMES = FALSE)

  # ── Populate closed_at and close_reason ─────────────────────────────────
  #
  # closed_at: reviews.updated_at when closed=1.  The autoclose scripts always
  # touch updated_at when flipping closed=1, so non-null is the norm.  If
  # updated_at is null or unparseable, fall back to NA (do not fabricate).
  #
  # close_reason: derived by derive_close_reason() from the latest marker.

  is_closed <- !is.na(merged$closed) & merged$closed == 1L

  closed_at_raw <- ifelse(is_closed, merged$updated_at, NA_character_)
  closed_at     <- parse_ts(closed_at_raw)

  close_reason <- mapply(
    derive_close_reason,
    marker      = merged$marker,
    verdict_bool = merged$verdict_bool,
    is_closed   = is_closed,
    SIMPLIFY    = TRUE,
    USE.NAMES   = FALSE
  )

  data.frame(
    review_id                    = as.integer(merged$review_id),
    job_id                       = as.integer(merged$job_id),
    repo                         = as.character(merged$repo),
    agent                        = as.character(merged$agent),
    model                        = as.character(merged$model),
    branch                       = as.character(merged$branch),
    commit_sha                   = NA_character_,   # Slice 2: join via commits table
    created_at                   = parse_ts(merged$created_at),
    started_at                   = started,
    finished_at                  = finished,
    duration_s                   = duration,
    verdict                      = verdict,
    severity_max                 = severity_max,
    closed_at                    = closed_at,
    close_reason                 = close_reason,
    autoclose_threshold_at_close = NA_character_,   # Slice 2
    stringsAsFactors             = FALSE
  )
}

# ── Pricing constants for cost_usd computation ────────────────────────────
#
# Source: Anthropic API pricing as of 2026-05-31, plus codex/gemini estimates.
# Units: USD per 1M tokens.
# Update this table when pricing changes.  A follow-up issue will move this
# to a versioned pricing table in unified.duckdb (#380).
#
# Matching is prefix-based: longest-matching prefix wins.
# Default (unknown model): sonnet-tier pricing.

PRICING_TABLE <- list(
  # Anthropic Claude 4 Opus
  list(prefix = "claude-opus-4",     input = 15.00, output = 75.00),
  # Anthropic Claude 4 Sonnet
  list(prefix = "claude-sonnet-4",   input =  3.00, output = 15.00),
  # Anthropic Claude 4 Haiku
  list(prefix = "claude-haiku-4",    input =  0.80, output =  4.00),
  # Anthropic Claude 3.7 series
  list(prefix = "claude-opus-3-7",   input = 15.00, output = 75.00),
  list(prefix = "claude-sonnet-3-7", input =  3.00, output = 15.00),
  list(prefix = "claude-haiku-3-7",  input =  0.80, output =  4.00),
  # Anthropic Claude 3.5 series
  list(prefix = "claude-opus-3-5",   input = 15.00, output = 75.00),
  list(prefix = "claude-sonnet-3-5", input =  3.00, output = 15.00),
  list(prefix = "claude-haiku-3-5",  input =  0.80, output =  4.00),
  # OpenAI / Codex
  list(prefix = "gpt-5",             input =  0.15, output =  0.60),
  list(prefix = "gpt-4",             input =  2.50, output = 10.00),
  list(prefix = "gpt-3",             input =  0.50, output =  1.50),
  list(prefix = "o1",                input = 15.00, output = 60.00),
  list(prefix = "o3",                input = 10.00, output = 40.00),
  # Google Gemini
  list(prefix = "gemini-2.5",        input =  0.075, output =  0.30),
  list(prefix = "gemini-2",          input =  0.10,  output =  0.40),
  list(prefix = "gemini-1",          input =  0.125, output =  0.375)
)

# Default pricing when no prefix matches (sonnet-tier)
PRICING_DEFAULT_INPUT  <- 3.00
PRICING_DEFAULT_OUTPUT <- 15.00

# Return pricing (input, output) in USD per 1M tokens for a given model id.
# Longest-prefix match wins.
model_pricing <- function(model_id) {
  if (is.na(model_id) || !nzchar(model_id) || model_id == "unknown") {
    return(list(input = PRICING_DEFAULT_INPUT, output = PRICING_DEFAULT_OUTPUT))
  }
  # Sort by prefix length descending so longest prefix wins
  sorted <- PRICING_TABLE[order(vapply(PRICING_TABLE,
                                       function(x) nchar(x$prefix),
                                       integer(1L)),
                                decreasing = TRUE)]
  for (entry in sorted) {
    if (startsWith(tolower(model_id), tolower(entry$prefix))) {
      return(list(input = entry$input, output = entry$output))
    }
  }
  list(input = PRICING_DEFAULT_INPUT, output = PRICING_DEFAULT_OUTPUT)
}

# Compute cost in USD given token counts and model id.
# Tokens are approximate (from byte-count heuristic when CLI doesn't expose them).
compute_cost_usd <- function(prompt_tokens, completion_tokens, model_id) {
  p <- model_pricing(model_id)
  cost_in  <- if (!is.na(prompt_tokens)     && prompt_tokens > 0L)
                (prompt_tokens     / 1e6) * p$input  else 0.0
  cost_out <- if (!is.na(completion_tokens) && completion_tokens > 0L)
                (completion_tokens / 1e6) * p$output else 0.0
  cost_in + cost_out
}

# Bytes-to-tokens approximation: 4 bytes ≈ 1 token (English/code prose).
# Used when the CLI does not expose token counts.  Conservative — actual token
# count may differ.  Documented in plans/380-investigation.md.
BYTES_PER_TOKEN <- 4L

bytes_to_tokens <- function(bytes) {
  if (is.na(bytes) || bytes <= 0L) return(0L)
  as.integer(ceiling(bytes / BYTES_PER_TOKEN))
}

# ── Ingest codex_fallback JSONL into codex_provider_invocations ───────────
#
# Reads all YYYY-MM-DD.jsonl files under CODEX_FALLBACK_LOG_DIR.
# Tracks the last-read high-water mark in UNIFIED_DB via a metadata key so
# incremental runs only process new records.  The tracking is invocation_id
# based: any record whose invocation_id is already in codex_provider_invocations
# is skipped (PRIMARY KEY idempotency is enforced at DB upsert time too).
#
# Returns a data.frame ready for upsert into codex_provider_invocations.
# Returns empty data.frame when no JSONL files exist (graceful).

read_codex_fallback_jsonl <- function(log_dir) {
  empty_df <- data.frame(
    invocation_id        = character(),
    ts                   = as.POSIXct(character()),
    primary_provider     = character(),
    primary_classification = character(),
    fallback_used        = logical(),
    fallback_provider    = character(),
    final_provider       = character(),
    duration_sec         = double(),
    response_bytes       = integer(),
    prompt_bytes         = integer(),
    prompt_tokens        = integer(),
    completion_tokens    = integer(),
    model                = character(),
    cost_usd             = double(),
    stringsAsFactors     = FALSE
  )

  if (!dir.exists(log_dir)) {
    log_msg("INFO: codex_fallback log dir absent: ", log_dir)
    return(empty_df)
  }

  jsonl_files <- list.files(log_dir, pattern = "^\\d{4}-\\d{2}-\\d{2}\\.jsonl$",
                             full.names = TRUE)
  if (length(jsonl_files) == 0L) {
    log_msg("INFO: no codex_fallback JSONL files found in ", log_dir)
    return(empty_df)
  }

  rows <- list()

  for (fpath in jsonl_files) {
    lines <- tryCatch(readLines(fpath, warn = FALSE),
                      error = function(e) {
                        log_msg("WARN: cannot read JSONL file: ", fpath, " — ", conditionMessage(e))
                        character(0L)
                      })

    for (line in lines) {
      line <- trimws(line)
      if (!nzchar(line)) next

      rec <- tryCatch(jsonlite::fromJSON(line, simplifyVector = TRUE),
                      error = function(e) {
                        log_msg("WARN: malformed JSONL record — skipping: ", conditionMessage(e))
                        NULL
                      })
      if (is.null(rec)) next

      # Parse required fields
      inv_id       <- rec$invocation_id %||% NA_character_
      ts_raw       <- rec$ts %||% NA_character_
      final_prov   <- rec$final_provider %||% "codex"
      prim_class   <- rec$primary_classification %||% NA_character_
      fb_used      <- isTRUE(rec$fallback_used)
      fb_provider  <- if (!is.null(rec$fallback_provider) &&
                          !is.na(rec$fallback_provider)) rec$fallback_provider else NA_character_
      dur          <- as.double(rec$duration_sec %||% NA_real_)

      # Byte counts (new fields added in #380; absent in pre-#380 records → 0)
      resp_bytes   <- as.integer(rec$response_bytes %||% 0L)
      prompt_bytes <- as.integer(rec$prompt_bytes   %||% 0L)
      model_id     <- rec$model %||% "unknown"
      if (is.null(model_id) || is.na(model_id)) model_id <- "unknown"

      # Token approximation from byte counts
      prompt_tok  <- bytes_to_tokens(prompt_bytes)
      complet_tok <- bytes_to_tokens(resp_bytes)

      # Cost computation
      cost <- compute_cost_usd(prompt_tok, complet_tok, model_id)

      # Parse timestamp
      ts_val <- tryCatch({
        ts_norm <- sub("Z$", "+0000", ts_raw)
        ts_norm <- sub("([+-][0-9]{2}):([0-9]{2})$", "\\1\\2", ts_norm)
        as.POSIXct(ts_norm, tz = "UTC", format = "%Y-%m-%dT%H:%M:%S%z")
      }, error = function(e) as.POSIXct(NA_real_, origin = "1970-01-01"))

      rows[[length(rows) + 1L]] <- data.frame(
        invocation_id          = as.character(inv_id),
        ts                     = ts_val,
        primary_provider       = "codex",
        primary_classification = as.character(prim_class),
        fallback_used          = fb_used,
        fallback_provider      = as.character(fb_provider),
        final_provider         = as.character(final_prov),
        duration_sec           = dur,
        response_bytes         = resp_bytes,
        prompt_bytes           = prompt_bytes,
        prompt_tokens          = prompt_tok,
        completion_tokens      = complet_tok,
        model                  = as.character(model_id),
        cost_usd               = cost,
        stringsAsFactors       = FALSE
      )
    }
  }

  if (length(rows) == 0L) {
    log_msg("INFO: codex_fallback JSONL read: 0 records")
    return(empty_df)
  }

  result <- do.call(rbind, rows)
  log_msg(sprintf("INFO: codex_fallback JSONL read: %d records from %d files",
                  nrow(result), length(jsonl_files)))
  result
}

# ── Build roborev_agent_performance ───────────────────────────────────────
# Per-day × per-agent × per-model rollup.
# token_usage JSON is sparse/absent in current data → token/cost columns are NULL.
# model column is often NULL → COALESCE to '' (matches schema DEFAULT '').

parse_token_usage <- function(json_text) {
  # Returns list(tokens_in=NA_integer_, tokens_out=NA_integer_)
  # Gracefully handles NULL, empty string, or malformed JSON.
  empty <- list(tokens_in = NA_integer_, tokens_out = NA_integer_)
  if (is.na(json_text) || !nzchar(json_text)) return(empty)
  tryCatch({
    parsed <- jsonlite::fromJSON(json_text, simplifyVector = TRUE)
    # Common key variants: input_tokens/output_tokens, prompt_tokens/completion_tokens
    tok_in  <- parsed$input_tokens %||% parsed$prompt_tokens %||%
               parsed$inputTokens  %||% NA_integer_
    tok_out <- parsed$output_tokens %||% parsed$completion_tokens %||%
               parsed$outputTokens %||% NA_integer_
    list(
      tokens_in  = if (is.null(tok_in)  || is.na(tok_in))  NA_integer_ else as.integer(tok_in),
      tokens_out = if (is.null(tok_out) || is.na(tok_out)) NA_integer_ else as.integer(tok_out)
    )
  }, error = function(e) empty)
}

build_agent_performance <- function(jobs, reviews, invocations = NULL) {
  empty_df <- data.frame(
    date             = as.Date(character()),
    agent            = character(),
    model            = character(),
    n_runs           = integer(),
    pass_count       = integer(),
    fail_count       = integer(),
    error_count      = integer(),
    p50_duration_s   = double(),
    p90_duration_s   = double(),
    total_tokens_in  = integer(),
    total_tokens_out = integer(),
    total_cost_usd   = double(),
    stringsAsFactors = FALSE
  )

  if (nrow(jobs) == 0L) {
    cat("roborev_metrics_etl.R: no jobs in window — agent_performance will be empty\n")
    return(empty_df)
  }

  # Pull token_usage from review_jobs if available; join reviews for verdict
  sql_agent <- sprintf("
    SELECT
      rj.id          AS job_id,
      date(rj.enqueued_at) AS job_date,
      COALESCE(rj.agent, 'unknown') AS agent,
      COALESCE(rj.model, '')        AS model,
      rj.status,
      rj.started_at,
      rj.finished_at,
      rj.token_usage
    FROM src.review_jobs rj
    JOIN src.repos rp ON rp.id = rj.repo_id
    WHERE date(rj.enqueued_at) >= DATE '%s'
    %s
    ORDER BY rj.id
  ", since_str, repo_clause)

  jobs_agent <- tryCatch(
    dbGetQuery(read_con, sql_agent),
    error = function(e) {
      log_msg("WARN: agent_performance query failed: ", conditionMessage(e))
      data.frame()
    }
  )

  if (nrow(jobs_agent) == 0L) return(empty_df)

  # Join verdict from reviews
  rv_verdict <- if (nrow(reviews) > 0L) {
    reviews[, c("job_id", "verdict_bool"), drop = FALSE]
  } else {
    data.frame(job_id = integer(), verdict_bool = integer(), stringsAsFactors = FALSE)
  }
  merged <- merge(jobs_agent, rv_verdict, by = "job_id", all.x = TRUE)

  # Parse duration
  parse_ts_local <- function(x) {
    tryCatch(as.POSIXct(x, tz = "UTC", format = "%Y-%m-%d %H:%M:%S"),
             error = function(e) as.POSIXct(NA_real_, origin = "1970-01-01"))
  }
  finished <- parse_ts_local(merged$finished_at)
  started  <- parse_ts_local(merged$started_at)
  duration <- as.numeric(difftime(finished, started, units = "secs"))
  merged$duration_s <- duration

  # Parse token_usage — defensive, returns NA on any failure
  tok_parsed   <- lapply(merged$token_usage, parse_token_usage)
  merged$tok_in  <- vapply(tok_parsed, `[[`, integer(1L), "tokens_in")
  merged$tok_out <- vapply(tok_parsed, `[[`, integer(1L), "tokens_out")

  # Aggregate by (date, agent, model)
  combos <- unique(merged[, c("job_date", "agent", "model"), drop = FALSE])

  result_rows <- lapply(seq_len(nrow(combos)), function(k) {
    d  <- combos$job_date[[k]]
    ag <- combos$agent[[k]]
    mo <- combos$model[[k]]

    grp <- merged[merged$job_date == d & merged$agent == ag & merged$model == mo, ]

    # Duration quantiles — omit NA
    durs   <- grp$duration_s[!is.na(grp$duration_s)]
    p50_d  <- if (length(durs) > 0L) as.double(quantile(durs, 0.50, names = FALSE)) else NA_real_
    p90_d  <- if (length(durs) > 0L) as.double(quantile(durs, 0.90, names = FALSE)) else NA_real_

    # Token sums — NA if all missing
    tok_in_vals  <- grp$tok_in[!is.na(grp$tok_in)]
    tok_out_vals <- grp$tok_out[!is.na(grp$tok_out)]
    tot_in  <- if (length(tok_in_vals)  > 0L) sum(tok_in_vals)  else NA_integer_
    tot_out <- if (length(tok_out_vals) > 0L) sum(tok_out_vals) else NA_integer_

    # Verdict-level counts (via joined reviews)
    n_pass  <- sum(grp$verdict_bool == 1L, na.rm = TRUE)
    n_fail  <- sum(grp$verdict_bool == 0L, na.rm = TRUE)
    n_error <- sum(grp$status == "failed",  na.rm = TRUE)

    # Cost: sum invocations whose timestamp falls within job started_at..finished_at
    # (± 60s grace). Only computed when invocations data is available.
    grp_cost_usd <- NA_real_
    if (!is.null(invocations) && nrow(invocations) > 0L && nrow(grp) > 0L) {
      grp_started  <- as.POSIXct(grp$started_at,  tz = "UTC",
                                  format = "%Y-%m-%d %H:%M:%S")
      grp_finished <- as.POSIXct(grp$finished_at, tz = "UTC",
                                  format = "%Y-%m-%d %H:%M:%S")
      inv_ts       <- as.POSIXct(invocations$ts, tz = "UTC")
      GRACE_S      <- 60L

      # For each invocation, check if it falls in any of the group's job windows
      inv_matched <- vapply(inv_ts, function(t) {
        any(
          (!is.na(grp_started) & !is.na(grp_finished)) &
          (t >= (grp_started  - GRACE_S)) &
          (t <= (grp_finished + GRACE_S))
        )
      }, logical(1L))

      matched_cost <- invocations$cost_usd[inv_matched]
      matched_cost <- matched_cost[!is.na(matched_cost)]
      grp_cost_usd <- if (length(matched_cost) > 0L) sum(matched_cost) else NA_real_
    }

    data.frame(
      date             = as.Date(d),
      agent            = ag,
      model            = mo,
      n_runs           = nrow(grp),
      pass_count       = n_pass,
      fail_count       = n_fail,
      error_count      = n_error,
      p50_duration_s   = p50_d,
      p90_duration_s   = p90_d,
      total_tokens_in  = tot_in,
      total_tokens_out = tot_out,
      total_cost_usd   = grp_cost_usd,
      stringsAsFactors = FALSE
    )
  })

  do.call(rbind, result_rows)
}

# ── Build roborev_threshold_changes ───────────────────────────────────────
# Reconstructs change events from the counter JSON's by_date history.
# When threshold_observed for a repo changes between two consecutive dates,
# emit one change row. Source = 'counter-json'; actor = hostname.
#
# The counter JSON only keeps one snapshot per date so we can only detect
# inter-day changes. Intra-day changes are not observable from this source.

build_threshold_changes <- function(counter_data, since_date) {
  empty_df <- data.frame(
    changed_at_utc = as.POSIXct(character()),
    repo           = character(),
    old_threshold  = character(),
    new_threshold  = character(),
    source         = character(),
    actor          = character(),
    stringsAsFactors = FALSE
  )

  if (length(counter_data) == 0L) {
    cat("roborev_metrics_etl.R: no counter data — threshold_changes will be empty\n")
    return(empty_df)
  }

  # Sort dates in the counter JSON
  all_dates <- sort(names(counter_data))
  # Filter to dates on or after since_date (keep one day before for context)
  # We include one day before since to detect changes that happened ON since_date
  prior_dates <- all_dates[all_dates < format(since_date, "%Y-%m-%d")]
  window_dates <- c(
    if (length(prior_dates) > 0L) tail(prior_dates, 1L) else character(0L),
    all_dates[all_dates >= format(since_date, "%Y-%m-%d")]
  )

  if (length(window_dates) < 2L) {
    cat("roborev_metrics_etl.R: insufficient date history — threshold_changes may be empty\n")
    # Still return what we can: all observed thresholds as initial records
    if (length(window_dates) == 1L) {
      d <- window_dates[[1L]]
      day_data <- counter_data[[d]] %||% list()
      th_obs   <- day_data$threshold_observed %||% list()
      if (length(th_obs) == 0L) return(empty_df)
      rows <- lapply(names(th_obs), function(repo_name) {
        data.frame(
          changed_at_utc = as.POSIXct(paste0(d, "T00:00:00Z"),
                                       format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
          repo           = repo_name,
          old_threshold  = NA_character_,
          new_threshold  = as.character(th_obs[[repo_name]] %||% NA_character_),
          source         = "counter-json",
          actor          = Sys.info()[["nodename"]],
          stringsAsFactors = FALSE
        )
      })
      return(do.call(rbind, rows))
    }
    return(empty_df)
  }

  # Build per-repo threshold map across dates
  result_rows <- list()
  # Collect all known repos across all dates in window
  all_repos <- unique(unlist(lapply(window_dates, function(d) {
    day_data <- counter_data[[d]] %||% list()
    th_obs   <- day_data$threshold_observed %||% list()
    names(th_obs)
  })))

  # Also add the global '*' sentinel if threshold_observed has a top-level entry
  # (some versions record global threshold differently)

  actor <- tryCatch(Sys.info()[["nodename"]], error = function(e) "unknown")

  for (repo_name in all_repos) {
    prev_th <- NULL  # unknown before first date
    for (idx in seq_along(window_dates)) {
      d <- window_dates[[idx]]
      day_data <- counter_data[[d]] %||% list()
      th_obs   <- day_data$threshold_observed %||% list()
      curr_th  <- th_obs[[repo_name]] %||% NA_character_

      if (is.null(curr_th)) curr_th <- NA_character_

      if (idx == 1L) {
        # First date in window: record as initial state (no change event)
        prev_th <- curr_th
        next
      }

      # Check for change
      prev_known <- !is.null(prev_th) && !is.na(prev_th)
      curr_known <- !is.na(curr_th)

      changed <- if (!prev_known && curr_known) {
        TRUE  # threshold appeared
      } else if (prev_known && curr_known && (prev_th != curr_th)) {
        TRUE  # threshold changed value
      } else {
        FALSE
      }

      if (changed) {
        # Timestamp: midnight UTC of the date where the new value was observed
        ts <- tryCatch(
          as.POSIXct(paste0(d, "T00:00:00Z"),
                     format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
          error = function(e) as.POSIXct(NA_real_, origin = "1970-01-01")
        )
        result_rows[[length(result_rows) + 1L]] <- data.frame(
          changed_at_utc = ts,
          repo           = repo_name,
          old_threshold  = if (!prev_known) NA_character_ else as.character(prev_th),
          new_threshold  = as.character(curr_th),
          source         = "counter-json",
          actor          = actor,
          stringsAsFactors = FALSE
        )
      }
      prev_th <- curr_th
    }
  }

  if (length(result_rows) == 0L) {
    cat("roborev_metrics_etl.R: no threshold changes detected in window\n")
    return(empty_df)
  }

  do.call(rbind, result_rows)
}

# ── Build roborev_cadence_efficacy ─────────────────────────────────────────
# Per-day × per-repo breakdown of poll vs hook activity.
# Log format (roborev_poll_merges.log):
#   YYYY-MM-DD HH:MM:SS [dry] repo: N commit(s) behind, would enqueue: ...
#   YYYY-MM-DD HH:MM:SS applied: repo: N commit(s) enqueued (since ...)
#   YYYY-MM-DD HH:MM:SS summary [applied]: repos=N behind=N enqueued=N skipped=N
#   YYYY-MM-DD HH:MM:SS summary [dry-run]: repos=N behind=N enqueued=N skipped=N
#
# review_jobs.source column is currently always NULL so hook vs poll
# distinction falls back to counting non-null source values.

parse_poll_log <- function(path, since_date) {
  result <- list()  # key = "date|repo" → list(polls_run, polls_noop, polls_enqueued, n_via_poll)

  if (!file.exists(path)) {
    log_msg("INFO: poll log absent: ", path)
    return(result)
  }

  since_str_local <- format(since_date, "%Y-%m-%d")

  tryCatch({
    lines <- readLines(path, warn = FALSE)

    # Pattern 1: "applied:" lines — repo actually got commits enqueued
    # YYYY-MM-DD HH:MM:SS applied: repo: N commit(s) enqueued (since ...)
    pat_applied  <- "^(\\d{4}-\\d{2}-\\d{2}) \\d{2}:\\d{2}:\\d{2} applied: ([^:]+): ([0-9]+) commit"
    # Pattern 2: "[dry]" lines — would-enqueue (in dry-run pass, not a real run)
    # We only count "applied" summary lines as actual poll runs.
    # Pattern 3: summary lines to count total invocations per day
    # YYYY-MM-DD HH:MM:SS summary [applied]: ...
    pat_summary  <- "^(\\d{4}-\\d{2}-\\d{2}) \\d{2}:\\d{2}:\\d{2} summary \\[applied\\]"
    pat_summary_dry <- "^(\\d{4}-\\d{2}-\\d{2}) \\d{2}:\\d{2}:\\d{2} summary \\[dry-run\\]"

    for (line in lines) {
      d <- substr(line, 1L, 10L)
      if (d < since_str_local) next

      # Count summary lines as invocations (one invocation per summary line)
      if (grepl(pat_summary,     line)) {
        key <- paste0(d, "|__INVOCATION__")
        result[[key]] <- (result[[key]] %||% 0L) + 1L
      }
      if (grepl(pat_summary_dry, line)) {
        # dry-run summaries also count as "polls run" for audit purposes
        key <- paste0(d, "|__INVOCATION__")
        result[[key]] <- (result[[key]] %||% 0L) + 1L
      }

      # Count per-repo applied lines
      m <- regmatches(line, regexec(pat_applied, line))[[1L]]
      if (length(m) == 4L) {
        repo_name  <- trimws(m[[3L]])
        n_commits  <- as.integer(m[[4L]])
        key        <- paste0(d, "|", repo_name)
        if (is.null(result[[key]])) {
          result[[key]] <- list(enqueued_runs = 0L, total_commits = 0L)
        }
        result[[key]]$enqueued_runs  <- result[[key]]$enqueued_runs  + 1L
        result[[key]]$total_commits  <- result[[key]]$total_commits  + n_commits
      }
    }
  }, error = function(e) {
    log_msg("WARN: poll log parse error: ", conditionMessage(e))
  })

  result
}

build_cadence_efficacy <- function(jobs, poll_log_data, since_date) {
  empty_df <- data.frame(
    date                     = as.Date(character()),
    repo                     = character(),
    polls_run                = integer(),
    polls_noop               = integer(),
    polls_enqueued           = integer(),
    reviews_created_via_poll = integer(),
    reviews_created_via_hook = integer(),
    stringsAsFactors         = FALSE
  )

  # Build set of (date, repo) combos from jobs + poll_log_data
  job_combos <- if (nrow(jobs) > 0L) {
    jobs_dated <- jobs
    jobs_dated$date_str <- substr(jobs_dated$enqueued_at, 1L, 10L)
    unique(jobs_dated[, c("date_str", "repo"), drop = FALSE])
  } else {
    data.frame(date_str = character(), repo = character(), stringsAsFactors = FALSE)
  }

  # Extract dates/repos from poll log (exclude __INVOCATION__ sentinel)
  poll_repo_keys <- names(poll_log_data)[!grepl("__INVOCATION__", names(poll_log_data))]
  poll_combos <- if (length(poll_repo_keys) > 0L) {
    parts <- strsplit(poll_repo_keys, "\\|")
    data.frame(
      date_str = vapply(parts, `[[`, character(1L), 1L),
      repo     = vapply(parts, `[[`, character(1L), 2L),
      stringsAsFactors = FALSE
    )
  } else {
    data.frame(date_str = character(), repo = character(), stringsAsFactors = FALSE)
  }

  all_combos <- unique(rbind(job_combos, poll_combos))
  if (nrow(all_combos) == 0L) {
    cat("roborev_metrics_etl.R: no data for cadence_efficacy\n")
    return(empty_df)
  }

  result_rows <- lapply(seq_len(nrow(all_combos)), function(k) {
    d        <- all_combos$date_str[[k]]
    rep_name <- all_combos$repo[[k]]

    # Invocations for this date (global, not per-repo)
    inv_key   <- paste0(d, "|__INVOCATION__")
    polls_run <- as.integer(poll_log_data[[inv_key]] %||% 0L)

    # Per-repo enqueued runs
    repo_key   <- paste0(d, "|", rep_name)
    repo_entry <- poll_log_data[[repo_key]]
    enq_runs   <- if (!is.null(repo_entry)) as.integer(repo_entry$enqueued_runs) else 0L

    # polls_noop: invocations where this repo was NOT enqueued
    polls_noop <- max(0L, polls_run - enq_runs)

    # Reviews from this repo on this date
    if (nrow(jobs) > 0L) {
      day_jobs_repo <- jobs[substr(jobs$enqueued_at, 1L, 10L) == d & jobs$repo == rep_name, ]
      n_via_poll <- sum(!is.na(day_jobs_repo$source) & day_jobs_repo$source == "poll",
                        na.rm = TRUE)
      n_via_hook <- sum(!is.na(day_jobs_repo$source) & day_jobs_repo$source == "hook",
                        na.rm = TRUE)
    } else {
      n_via_poll <- 0L
      n_via_hook <- 0L
    }

    data.frame(
      date                     = as.Date(d),
      repo                     = rep_name,
      polls_run                = polls_run,
      polls_noop               = polls_noop,
      polls_enqueued           = enq_runs,
      reviews_created_via_poll = n_via_poll,
      reviews_created_via_hook = n_via_hook,
      stringsAsFactors         = FALSE
    )
  })

  do.call(rbind, result_rows)
}

# ── Build roborev_finding_lineage (#286) ──────────────────────────────────
#
# Heuristic lineage: group review jobs into re-review chains using available
# signals, since parent_job_id is never populated by roborev today (#286).
#
# Signal priority (applied per job, strongest first):
#   1. parent_job_id IS NOT NULL → trust it (forward-compatible)
#   2. patch_id set → group by (repo_id, patch_id)
#   3. commit_id reviewed >1× in same repo+branch → group by (repo_id, branch, commit_id)
#   4. solo → chain of length 1
#
# Returns a data.frame with columns:
#   finding_id, attempt_n, lineage_method, job_id, created_at, verdict_bool,
#   closed, chain_size, is_closing_attempt
#
# "finding_id" = reviews.id (the review row is the canonical finding record;
# jobs without a review row are excluded — they have no finding yet).

build_finding_lineage <- function(read_con, since_date, repo_clause) {
  since_str_local <- format(since_date, "%Y-%m-%d")

  # Pull all job+review pairs in the window (left join — jobs without reviews
  # are excluded: no finding, no lineage row).
  sql_lineage_src <- sprintf("
    SELECT
      rv.id             AS finding_id,
      rj.id             AS job_id,
      rj.repo_id,
      rj.commit_id,
      rj.branch,
      rj.patch_id,
      rj.parent_job_id,
      rj.enqueued_at,
      rv.created_at,
      rv.verdict_bool,
      rv.closed
    FROM src.reviews rv
    JOIN src.review_jobs rj ON rj.id = rv.job_id
    JOIN src.repos rp ON rp.id = rj.repo_id
    WHERE date(rj.enqueued_at) >= DATE '%s'
    %s
    ORDER BY rj.enqueued_at
  ", since_str_local, repo_clause)

  src_df <- tryCatch(
    dbGetQuery(read_con, sql_lineage_src),
    error = function(e) {
      log_msg("WARN: lineage source query failed: ", conditionMessage(e))
      data.frame()
    }
  )

  empty_df <- data.frame(
    finding_id         = integer(),
    attempt_n          = integer(),
    lineage_method     = character(),
    job_id             = integer(),
    created_at         = as.POSIXct(character()),
    verdict_bool       = integer(),
    closed             = integer(),
    chain_size         = integer(),
    is_closing_attempt = logical(),
    stringsAsFactors   = FALSE
  )

  if (nrow(src_df) == 0L) {
    cat("roborev_metrics_etl.R: no reviews in window — finding_lineage will be empty\n")
    return(empty_df)
  }

  # ── Assign each row its group_key and lineage_method ──────────────────────
  # Build lookup: which commit_ids are reviewed more than once within the same
  # repo+branch (the commit_branch signal)?
  multi_commit_key <- function(df) {
    # Group key = paste(repo_id, branch, commit_id)
    keys <- paste(df$repo_id, df$branch, df$commit_id, sep = "|")
    counts <- table(keys)
    names(counts)[counts > 1L]
  }
  multi_keys <- multi_commit_key(src_df)

  group_key   <- character(nrow(src_df))
  lin_method  <- character(nrow(src_df))

  for (i in seq_len(nrow(src_df))) {
    row <- src_df[i, ]
    if (!is.na(row$parent_job_id) && row$parent_job_id > 0L) {
      # Priority 1: explicit parent_job_id (not currently populated by roborev)
      group_key[[i]]  <- paste0("pjid|", row$repo_id, "|", row$parent_job_id)
      lin_method[[i]] <- "parent_job_id"
    } else if (!is.na(row$patch_id) && nzchar(row$patch_id)) {
      # Priority 2: patch_id groups
      group_key[[i]]  <- paste0("patch|", row$repo_id, "|", row$patch_id)
      lin_method[[i]] <- "patch_id"
    } else {
      # Priority 3: commit_branch grouping (only when commit_id appears >1 time)
      ck <- paste(row$repo_id, row$branch, row$commit_id, sep = "|")
      if (!is.na(row$commit_id) && ck %in% multi_keys) {
        group_key[[i]]  <- paste0("cb|", ck)
        lin_method[[i]] <- "commit_branch"
      } else {
        # Priority 4: solo (unique group per finding)
        group_key[[i]]  <- paste0("solo|", row$finding_id)
        lin_method[[i]] <- "solo"
      }
    }
  }

  src_df$group_key  <- group_key
  src_df$lin_method <- lin_method

  # ── Sort chronologically within each group, assign attempt_n ─────────────
  # Sort globally first, then by group so attempt_n reflects enqueue order.
  ord <- order(src_df$group_key, src_df$enqueued_at)
  src_sorted <- src_df[ord, ]

  # Compute within-group rank (attempt_n)
  attempt_n   <- integer(nrow(src_sorted))
  chain_size  <- integer(nrow(src_sorted))
  group_rle   <- rle(src_sorted$group_key)

  pos <- 1L
  for (grp_len in group_rle$lengths) {
    attempt_n[pos:(pos + grp_len - 1L)]  <- seq_len(grp_len)
    chain_size[pos:(pos + grp_len - 1L)] <- grp_len
    pos <- pos + grp_len
  }

  src_sorted$attempt_n  <- attempt_n
  src_sorted$chain_size <- chain_size

  # is_closing_attempt: the LAST row in a chain that has closed=1
  # (a chain may have closed=0 throughout if still open; then no row is TRUE)
  is_closing <- logical(nrow(src_sorted))
  pos <- 1L
  for (grp_len in group_rle$lengths) {
    grp_rows <- pos:(pos + grp_len - 1L)
    # Find the last row in this group that has closed=1
    closed_in_grp <- which(src_sorted$closed[grp_rows] == 1L)
    if (length(closed_in_grp) > 0L) {
      last_closed_pos <- grp_rows[max(closed_in_grp)]
      is_closing[last_closed_pos] <- TRUE
    }
    pos <- pos + grp_len
  }
  src_sorted$is_closing_attempt <- is_closing

  # ── Parse created_at timestamps ───────────────────────────────────────────
  parse_ts_safe <- function(x) {
    tryCatch({
      x_norm <- sub("([+-][0-9]{2}):([0-9]{2})$", "\\1\\2", x)
      x_norm <- sub("Z$", "+0000", x_norm)
      ts <- as.POSIXct(x_norm, tz = "UTC", format = "%Y-%m-%dT%H:%M:%S%z")
      still_na <- which(is.na(ts) & !is.na(x))
      if (length(still_na) > 0L) {
        ts[still_na] <- as.POSIXct(x_norm[still_na], tz = "UTC",
                                    format = "%Y-%m-%d %H:%M:%S")
      }
      ts
    }, error = function(e) as.POSIXct(NA_real_, origin = "1970-01-01"))
  }

  created_at_ts <- parse_ts_safe(src_sorted$created_at)

  data.frame(
    finding_id         = as.integer(src_sorted$finding_id),
    attempt_n          = as.integer(src_sorted$attempt_n),
    lineage_method     = src_sorted$lin_method,
    job_id             = as.integer(src_sorted$job_id),
    created_at         = created_at_ts,
    verdict_bool       = as.integer(src_sorted$verdict_bool),
    closed             = as.integer(coalesce_int(src_sorted$closed, 0L)),
    chain_size         = as.integer(src_sorted$chain_size),
    is_closing_attempt = as.logical(src_sorted$is_closing_attempt),
    stringsAsFactors   = FALSE
  )
}

# Helper: coerce to integer with NA-safe default
coalesce_int <- function(x, default = 0L) {
  x <- as.integer(x)
  x[is.na(x)] <- default
  x
}

# ── Build tables ───────────────────────────────────────────────────────────

daily_df     <- build_daily_metrics(jobs_raw, reviews_raw)
lifecycle_df <- build_review_lifecycle(jobs_raw, reviews_raw, markers_raw)

cat(sprintf("roborev_metrics_etl.R: built %d daily_metrics rows, %d lifecycle rows\n",
            nrow(daily_df), nrow(lifecycle_df)))

# Slice 2 tables
# Read codex/gemini invocation log for cost attribution
invocations_raw <- read_codex_fallback_jsonl(CODEX_FALLBACK_LOG_DIR)
cat(sprintf("roborev_metrics_etl.R: read %d codex_provider_invocations records\n",
            nrow(invocations_raw)))

agent_perf_df <- build_agent_performance(jobs_raw, reviews_raw, invocations_raw)
poll_log_data <- parse_poll_log(POLL_LOG, since)
cadence_df    <- build_cadence_efficacy(jobs_raw, poll_log_data, since)
threshold_df  <- build_threshold_changes(counter_data, since)

cat(sprintf(
  "roborev_metrics_etl.R: built %d agent_performance rows, %d threshold_changes rows, %d cadence_efficacy rows\n",
  nrow(agent_perf_df), nrow(threshold_df), nrow(cadence_df)
))

# Slice 3: heuristic finding lineage (#286)
lineage_df <- build_finding_lineage(read_con, since, repo_clause)

cat(sprintf(
  "roborev_metrics_etl.R: built %d finding_lineage rows (%d chains)\n",
  nrow(lineage_df),
  if (nrow(lineage_df) > 0L) length(unique(
    paste(lineage_df$finding_id[lineage_df$attempt_n == 1L])
  )) else 0L
))

# ── Dry-run: print summary and exit 0 ─────────────────────────────────────

if (mode == "dry-run") {
  cat("\n--- DRY RUN (no writes) ---\n")
  cat(sprintf("  roborev_daily_metrics:        %d rows (since %s)\n",
              nrow(daily_df), format(since, "%Y-%m-%d")))
  cat(sprintf("  roborev_review_lifecycle:     %d rows\n", nrow(lifecycle_df)))
  cat(sprintf("  roborev_agent_performance:    %d rows\n", nrow(agent_perf_df)))
  cat(sprintf("  roborev_threshold_changes:    %d rows\n", nrow(threshold_df)))
  cat(sprintf("  roborev_cadence_efficacy:     %d rows\n", nrow(cadence_df)))
  cat(sprintf("  roborev_finding_lineage:      %d rows\n", nrow(lineage_df)))
  cat(sprintf("  codex_provider_invocations:   %d rows\n", nrow(invocations_raw)))
  cat("--- end dry-run ---\n")
  log_msg(sprintf(
    "dry-run: daily=%d lifecycle=%d agent_perf=%d threshold=%d cadence=%d lineage=%d invocations=%d",
    nrow(daily_df), nrow(lifecycle_df), nrow(agent_perf_df),
    nrow(threshold_df), nrow(cadence_df), nrow(lineage_df), nrow(invocations_raw)
  ))
  quit(status = 0L)
}

# ── Apply: write to unified.duckdb ─────────────────────────────────────────

if (!file.exists(SCHEMA_FILE)) {
  graceful_exit(paste("schema file not found:", SCHEMA_FILE))
}

dir.create(dirname(UNIFIED_DB), recursive = TRUE, showWarnings = FALSE)

duck_con <- tryCatch(
  dbConnect(duckdb::duckdb(), UNIFIED_DB),
  error = function(e) {
    log_msg("ERROR: cannot open unified.duckdb: ", conditionMessage(e))
    quit(status = 1L)
  }
)
on.exit(tryCatch(dbDisconnect(duck_con, shutdown = TRUE), error = function(e) NULL),
        add = TRUE)

# ── Schema init (idempotent) ──────────────────────────────────────────────

schema_sql  <- tryCatch(
  readLines(SCHEMA_FILE, warn = FALSE),
  error = function(e) {
    log_msg("ERROR: cannot read schema file: ", conditionMessage(e))
    quit(status = 1L)
  }
)

schema_text <- paste(schema_sql, collapse = "\n")
schema_text <- gsub("--[^\n]*", "", schema_text)
stmts       <- strsplit(schema_text, ";")[[1L]]
stmts       <- trimws(stmts)
stmts       <- stmts[nzchar(stmts)]

tryCatch({
  for (stmt in stmts) {
    dbExecute(duck_con, stmt)
  }
  cat(sprintf("roborev_metrics_etl.R: schema init complete (%d statements)\n",
              length(stmts)))
}, error = function(e) {
  log_msg("ERROR: schema init failed: ", conditionMessage(e))
  quit(status = 1L)
})

# ── Upsert helper using DuckDB INSERT OR REPLACE ──────────────────────────

upsert_table <- function(con, table_name, df) {
  if (nrow(df) == 0L) {
    cat(sprintf("roborev_metrics_etl.R: %s — 0 rows to upsert, skipping\n", table_name))
    return(invisible(0L))
  }

  # Use a unique temp-table name to avoid collision across calls
  tmp <- paste0("_etl_tmp_", gsub("[^a-zA-Z0-9]", "_", table_name), "_",
                as.integer(proc.time()[["elapsed"]] * 1000) %% 999999L)

  tryCatch({
    dbWriteTable(con, tmp, df, overwrite = TRUE, temporary = TRUE)

    cols <- paste(sprintf('"%s"', names(df)), collapse = ", ")
    sql  <- sprintf(
      'INSERT OR REPLACE INTO "%s" (%s) SELECT %s FROM "%s"',
      table_name, cols, cols, tmp
    )
    n    <- dbExecute(con, sql)

    tryCatch(dbExecute(con, sprintf('DROP TABLE IF EXISTS "%s"', tmp)),
             error = function(e) NULL)

    cat(sprintf("roborev_metrics_etl.R: %s — upserted %d rows\n", table_name, n))
    invisible(n)
  }, error = function(e) {
    tryCatch(dbExecute(con, sprintf('DROP TABLE IF EXISTS "%s"', tmp)),
             error = function(e2) NULL)
    stop(e)
  })
}

# ── Transaction: populate all 5 tables ────────────────────────────────────

tryCatch({
  dbBegin(duck_con)

  upsert_table(duck_con, "roborev_daily_metrics",       daily_df)
  upsert_table(duck_con, "roborev_review_lifecycle",    lifecycle_df)
  upsert_table(duck_con, "roborev_agent_performance",   agent_perf_df)
  upsert_table(duck_con, "roborev_threshold_changes",   threshold_df)
  upsert_table(duck_con, "roborev_cadence_efficacy",    cadence_df)
  upsert_table(duck_con, "roborev_finding_lineage",     lineage_df)
  upsert_table(duck_con, "codex_provider_invocations",  invocations_raw)

  dbCommit(duck_con)

  log_msg(sprintf(
    "apply: daily=%d lifecycle=%d agent_perf=%d threshold=%d cadence=%d lineage=%d invocations=%d mode=apply since=%s",
    nrow(daily_df), nrow(lifecycle_df), nrow(agent_perf_df),
    nrow(threshold_df), nrow(cadence_df), nrow(lineage_df), nrow(invocations_raw),
    format(since, "%Y-%m-%d")
  ))
  cat(sprintf(
    "roborev_metrics_etl.R: done — daily=%d lifecycle=%d agent_perf=%d threshold=%d cadence=%d lineage=%d invocations=%d\n",
    nrow(daily_df), nrow(lifecycle_df), nrow(agent_perf_df),
    nrow(threshold_df), nrow(cadence_df), nrow(lineage_df), nrow(invocations_raw)
  ))
}, error = function(e) {
  tryCatch(dbRollback(duck_con), error = function(e2) NULL)
  log_msg("ERROR: transaction failed: ", conditionMessage(e))
  message("roborev_metrics_etl.R ERROR: ", conditionMessage(e))
  quit(status = 1L)
})
