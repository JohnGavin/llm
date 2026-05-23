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
# Other 3 tables are created empty by schema init only.
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

# Install and load SQLite extension
tryCatch({
  dbExecute(read_con, "INSTALL sqlite")
  dbExecute(read_con, "LOAD sqlite")
}, error = function(e) {
  graceful_exit(paste("DuckDB sqlite extension unavailable:", conditionMessage(e)))
})

# Attach the SQLite DB read-only
tryCatch({
  dbExecute(read_con,
            sprintf("ATTACH '%s' AS src (TYPE sqlite, READ_ONLY)", REVIEWS_DB))
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
    rv.created_at
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

cat(sprintf("roborev_metrics_etl.R: read %d jobs, %d reviews from reviews.db\n",
            nrow(jobs_raw), nrow(reviews_raw)))

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

# ── Build roborev_review_lifecycle ─────────────────────────────────────────

build_review_lifecycle <- function(jobs, reviews) {
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

  parse_ts <- function(x) {
    tryCatch(as.POSIXct(x, tz = "UTC", format = "%Y-%m-%d %H:%M:%S"),
             error = function(e) as.POSIXct(NA_real_, origin = "1970-01-01"))
  }

  finished <- parse_ts(merged$finished_at)
  started  <- parse_ts(merged$started_at)
  duration <- as.numeric(difftime(finished, started, units = "secs"))

  verdict <- ifelse(is.na(merged$verdict_bool), NA_character_,
                    ifelse(merged$verdict_bool == 1L, "P", "F"))

  cat("roborev_metrics_etl.R: parsing severity from", nrow(merged), "review outputs...\n")
  severity_max <- vapply(merged$output, parse_max_severity,
                         character(1L), USE.NAMES = FALSE)

  close_reason <- ifelse(!is.na(merged$closed) & merged$closed == 1L,
                         "manual", NA_character_)

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
    closed_at                    = as.POSIXct(NA_real_, origin = "1970-01-01"),
    close_reason                 = close_reason,
    autoclose_threshold_at_close = NA_character_,   # Slice 2
    stringsAsFactors             = FALSE
  )
}

# ── Build tables ───────────────────────────────────────────────────────────

daily_df     <- build_daily_metrics(jobs_raw, reviews_raw)
lifecycle_df <- build_review_lifecycle(jobs_raw, reviews_raw)

cat(sprintf("roborev_metrics_etl.R: built %d daily_metrics rows, %d lifecycle rows\n",
            nrow(daily_df), nrow(lifecycle_df)))

# ── Dry-run: print summary and exit 0 ─────────────────────────────────────

if (mode == "dry-run") {
  cat("\n--- DRY RUN (no writes) ---\n")
  cat(sprintf("  roborev_daily_metrics:    %d rows (since %s)\n",
              nrow(daily_df), format(since, "%Y-%m-%d")))
  cat(sprintf("  roborev_review_lifecycle: %d rows\n", nrow(lifecycle_df)))
  cat("  roborev_agent_performance:  (empty — Slice 2)\n")
  cat("  roborev_threshold_changes:  (empty — Slice 2)\n")
  cat("  roborev_cadence_efficacy:   (empty — Slice 2)\n")
  cat("--- end dry-run ---\n")
  log_msg(sprintf("dry-run: daily=%d lifecycle=%d", nrow(daily_df), nrow(lifecycle_df)))
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

# ── Transaction: populate Slice 1 tables ──────────────────────────────────

tryCatch({
  dbBegin(duck_con)

  upsert_table(duck_con, "roborev_daily_metrics",    daily_df)
  upsert_table(duck_con, "roborev_review_lifecycle", lifecycle_df)

  dbCommit(duck_con)

  log_msg(sprintf(
    "apply: daily=%d lifecycle=%d mode=apply since=%s",
    nrow(daily_df), nrow(lifecycle_df), format(since, "%Y-%m-%d")
  ))
  cat(sprintf(
    "roborev_metrics_etl.R: done — daily=%d lifecycle=%d\n",
    nrow(daily_df), nrow(lifecycle_df)
  ))
}, error = function(e) {
  tryCatch(dbRollback(duck_con), error = function(e2) NULL)
  log_msg("ERROR: transaction failed: ", conditionMessage(e))
  message("roborev_metrics_etl.R ERROR: ", conditionMessage(e))
  quit(status = 1L)
})
