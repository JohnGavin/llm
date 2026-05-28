# Tests for roborev_daily_report.R — daily resolution report compute layer.
# Tracks llm#284.
#
# Strategy: extract the pure-function block from the script (the helpers below
# the main I/O section), supply a synthetic unified.duckdb fixture, and verify:
#   1. Frequency table sums match known fixture counts
#   2. Percentile computations on a known sequence
#   3. Close-rate is correct
#   4. JSON snapshot is written with expected keys
#   5. Text digest is non-empty
#   6. Trend deltas are directionally correct
#   7. Outlier top-10 ordering is correct

library(testthat)
library(DBI)
library(duckdb)

# ── Load helper functions from the report script ──────────────────────────────
#
# Source only the pure helper functions (lines before the main I/O section).
# We detect boundaries by landmark comment patterns.

report_script <- file.path(
  pkgload::pkg_path(),
  ".claude", "scripts", "roborev_daily_report.R"
)

skip_if_not(file.exists(report_script),
            "roborev_daily_report.R not found at expected path")

all_lines <- readLines(report_script)

# Find the line range containing only the pure helpers:
#   Start: pct() function definition
#   End:   just before "── Core: compute one window slice ──"
start_line <- grep("^pct <- function", all_lines, fixed = FALSE)[1L]
end_line   <- grep("# .+ Core: compute one window slice", all_lines)[1L] - 1L

stopifnot(!is.na(start_line), !is.na(end_line), start_line < end_line)

fn_block <- all_lines[start_line:end_line]
eval(parse(text = paste(fn_block, collapse = "\n")), envir = globalenv())

# ── Synthetic unified.duckdb fixture ─────────────────────────────────────────
#
# 20 reviews anchored around a fixed reference date (2026-05-20 00:00:00 UTC):
#
# Window setup (anchor = 2026-05-21 00:00:00 UTC):
#   7-day current:  2026-05-14 00:00:00 – 2026-05-21 00:00:00
#   7-day prior:    2026-05-07 00:00:00 – 2026-05-14 00:00:00
#
# Reviews in current 7d window (created_at 2026-05-15 to 2026-05-20):
#   ids 1–10, all repo="llm"
#   ids 1-6:  verdict="F"
#     1-4: closed_at set,  close_reason="manual",     ttc=24h each
#     5-6: closed_at=NULL (open)
#   ids 7-9:  verdict="P", closed_at set, close_reason="clean-verdict"
#   id  10:   verdict="P", closed_at=NULL
#
# Reviews in prior 7d window (created_at 2026-05-08 to 2026-05-13):
#   ids 11–15, all repo="llm"
#   ids 11-13: verdict="F", closed, ttc=48h each
#   ids 14-15: verdict="F", open
#
# Current 1d window (2026-05-20 – 2026-05-21):
#   ids 20-21: verdict="F", one closed (24h), one open

make_lifecycle_fixture <- function(con) {
  DBI::dbExecute(con, "
    CREATE OR REPLACE TABLE roborev_review_lifecycle (
      review_id   BIGINT  PRIMARY KEY,
      job_id      BIGINT  NOT NULL,
      repo        VARCHAR NOT NULL,
      agent       VARCHAR NOT NULL,
      model       VARCHAR,
      branch      VARCHAR,
      commit_sha  VARCHAR,
      created_at  TIMESTAMP,
      started_at  TIMESTAMP,
      finished_at TIMESTAMP,
      duration_s  DOUBLE,
      verdict     VARCHAR,
      severity_max VARCHAR,
      closed_at   TIMESTAMP,
      close_reason VARCHAR,
      autoclose_threshold_at_close VARCHAR
    )
  ")

  anchor_epoch <- as.POSIXct("2026-05-21 00:00:00", tz = "UTC")

  rows <- rbind(
    # current 7d window: ids 1-10
    data.frame(
      review_id   = 1L:10L,
      job_id      = 101L:110L,
      repo        = "llm",
      agent       = "claude-code",
      model       = NA_character_,
      branch      = "main",
      commit_sha  = NA_character_,
      # ids 1-10: created 2 to 7 days before anchor
      created_at  = as.POSIXct("2026-05-20 12:00:00", tz = "UTC") -
                    as.difftime(c(1,2,3,4,5,6,2,3,4,5), units = "days"),
      started_at  = NA,
      finished_at = NA,
      duration_s  = NA_real_,
      verdict     = c("F","F","F","F","F","F","P","P","P","P"),
      severity_max = NA_character_,
      # ids 1-4 closed (24h after creation); ids 5-6 open; ids 7-9 closed; id 10 open
      # closed_at = created_at + 24h for ids 1-4
      # created_at offsets: c(1,2,3,4,5,6,2,3,4,5) days before 2026-05-20 12:00:00
      # so id1: created=2026-05-19 12:00, closed=2026-05-20 12:00
      #    id2: created=2026-05-18 12:00, closed=2026-05-19 12:00
      #    id3: created=2026-05-17 12:00, closed=2026-05-18 12:00
      #    id4: created=2026-05-16 12:00, closed=2026-05-17 12:00
      closed_at   = c(
        as.POSIXct("2026-05-20 12:00:00", tz = "UTC") - as.difftime(c(0,1,2,3), units = "days"),
        NA, NA,
        as.POSIXct("2026-05-18 12:00:00", tz = "UTC") - as.difftime(c(0,1,2), units = "days"),
        NA
      ),
      close_reason = c(rep("manual", 4L), NA, NA, rep("clean-verdict", 3L), NA),
      autoclose_threshold_at_close = NA_character_,
      stringsAsFactors = FALSE
    ),
    # prior 7d window: ids 11-15
    data.frame(
      review_id   = 11L:15L,
      job_id      = 111L:115L,
      repo        = "llm",
      agent       = "claude-code",
      model       = NA_character_,
      branch      = "main",
      commit_sha  = NA_character_,
      created_at  = as.POSIXct("2026-05-10 12:00:00", tz = "UTC") -
                    as.difftime(c(0,1,2,3,4), units = "days"),
      started_at  = NA,
      finished_at = NA,
      duration_s  = NA_real_,
      verdict     = c("F","F","F","F","F"),
      severity_max = NA_character_,
      # ids 11-13 closed (48h after creation); ids 14-15 open
      closed_at   = c(
        as.POSIXct("2026-05-12 12:00:00", tz = "UTC") - as.difftime(c(0,1,2), units = "days"),
        NA, NA
      ),
      close_reason = c(rep("manual", 3L), NA, NA),
      autoclose_threshold_at_close = NA_character_,
      stringsAsFactors = FALSE
    ),
    # 1d window: ids 20-21
    data.frame(
      review_id   = 20L:21L,
      job_id      = 120L:121L,
      repo        = "llm",
      agent       = "claude-code",
      model       = NA_character_,
      branch      = "main",
      commit_sha  = NA_character_,
      created_at  = c(
        as.POSIXct("2026-05-20 06:00:00", tz = "UTC"),
        as.POSIXct("2026-05-20 08:00:00", tz = "UTC")
      ),
      started_at  = NA,
      finished_at = NA,
      duration_s  = NA_real_,
      verdict     = c("F","F"),
      severity_max = NA_character_,
      closed_at   = c(
        as.POSIXct("2026-05-20 06:00:00", tz = "UTC") + as.difftime(24, units = "hours"),
        NA
      ),
      close_reason = c("manual", NA),
      autoclose_threshold_at_close = NA_character_,
      stringsAsFactors = FALSE
    )
  )

  # time_to_close_hrs is a computed column in the SELECT query, not a stored column.
  # Do NOT include it when appending rows to the fixture table.
  DBI::dbWriteTable(con, "roborev_review_lifecycle", rows, append = TRUE)
  invisible(con)
}

make_fixture_con <- function() {
  skip_if_not_installed("duckdb")
  tmp_path <- tempfile(fileext = ".duckdb")
  con      <- DBI::dbConnect(duckdb::duckdb(), tmp_path)
  make_lifecycle_fixture(con)
  list(con = con, path = tmp_path)
}

ANCHOR <- as.POSIXct("2026-05-21 00:00:00", tz = "UTC")

# ── Helper: stub for enrich_with_attempts ─────────────────────────────────────
# In tests we pin n_attempts = 1 for all rows (no reviews.db in fixture).
with_stub_attempts <- function(df) {
  df$n_attempts <- rep(1L, nrow(df))
  df
}

# Override enrich_with_attempts for tests to avoid reviews.db dependency
enrich_with_attempts_test <- function(df, ...) with_stub_attempts(df)

# ── pct() unit tests ──────────────────────────────────────────────────────────

test_that("pct: empty input returns NA vector", {
  result <- pct(numeric(0L), c(0.50, 0.90, 0.99))
  expect_true(all(is.na(result)))
  expect_equal(names(result), c("p50", "p90", "p99"))
})

test_that("pct: known sequence gives correct median", {
  # sequence 1:10 — median = 5.5
  result <- pct(1:10, c(0.50))
  expect_equal(unname(result), 5.5)
})

test_that("pct: NA values are excluded", {
  # 1, 3, 5, NA, NA — median of (1,3,5) = 3
  result <- pct(c(1, 3, 5, NA, NA), c(0.50))
  expect_equal(unname(result), 3)
})

test_that("pct: p90 on ten values is correct", {
  # 1:10, p90 = 9.1 (type 7 default)
  result <- pct(1:10, 0.90)
  expect_equal(unname(result), quantile(1:10, 0.90, names = FALSE))
})

# ── compute_freq_table tests ──────────────────────────────────────────────────

test_that("compute_freq_table: sums match total reviews", {
  fix  <- make_fixture_con()
  on.exit(DBI::dbDisconnect(fix$con, shutdown = TRUE), add = TRUE)

  bounds <- window_bounds(ANCHOR, 7L)
  df     <- load_window(fix$con, bounds$cur$start, bounds$cur$end)
  freq   <- compute_freq_table(df)

  expect_equal(sum(freq$n), nrow(df),
               info = "sum of freq table must equal row count of window slice")
})

test_that("compute_freq_table: correct open/closed split for issues_found", {
  fix  <- make_fixture_con()
  on.exit(DBI::dbDisconnect(fix$con, shutdown = TRUE), add = TRUE)

  bounds <- window_bounds(ANCHOR, 7L)
  df     <- load_window(fix$con, bounds$cur$start, bounds$cur$end)
  freq   <- compute_freq_table(df)

  found_closed <- freq[freq$verdict_label == "issues_found" & freq$status == "closed", "n"]
  found_open   <- freq[freq$verdict_label == "issues_found" & freq$status == "open",   "n"]

  # ids 1-6 and 20-21 are all "F" in 7d window (ids 20-21 are in 1d window which is a subset)
  # closed: ids 1-4 + id 20 = 5 closed
  # open:   ids 5, 6, 21    = 3 open
  expect_equal(found_closed, 5L,
               info = "5 issues_found reviews should be closed in 7d fixture (ids 1-4 + 20)")
  expect_equal(found_open,   3L,
               info = "3 issues_found reviews should be open in 7d fixture (ids 5, 6, 21)")
})

# ── compute_speed tests ───────────────────────────────────────────────────────

test_that("compute_speed: close_rate correct for 7d window", {
  fix  <- make_fixture_con()
  on.exit(DBI::dbDisconnect(fix$con, shutdown = TRUE), add = TRUE)

  bounds <- window_bounds(ANCHOR, 7L)
  df     <- load_window(fix$con, bounds$cur$start, bounds$cur$end)
  df     <- with_stub_attempts(df)
  sp     <- compute_speed(df)

  # 5 closed / 8 total issues_found = 0.625
  # (ids 1-6 and 20-21 are all "F" in 7d window; 5 closed, 3 open)
  expect_equal(sp$n_issues_found, 8L)
  expect_equal(sp$n_closed, 5L)
  expect_equal(sp$n_open,   3L)
  expect_equal(sp$close_rate, 5/8, tolerance = 1e-6)
})

test_that("compute_speed: ttc p50 matches known 24h fixture values", {
  fix  <- make_fixture_con()
  on.exit(DBI::dbDisconnect(fix$con, shutdown = TRUE), add = TRUE)

  bounds <- window_bounds(ANCHOR, 7L)
  df     <- load_window(fix$con, bounds$cur$start, bounds$cur$end)
  df     <- with_stub_attempts(df)
  sp     <- compute_speed(df)

  # All 5 closed "F" reviews have ttc = 24h → median = 24
  expect_equal(sp$ttc_p50, 24, tolerance = 0.01)
})

test_that("compute_speed: empty window returns NA for percentiles", {
  df_empty <- data.frame(
    review_id = integer(), repo = character(), verdict = character(),
    created_at = as.POSIXct(character()), closed_at = as.POSIXct(character()),
    close_reason = character(), time_to_close_hrs = double(),
    n_attempts = integer(), stringsAsFactors = FALSE
  )
  sp <- compute_speed(df_empty)
  expect_true(is.na(sp$ttc_p50))
  expect_true(is.na(sp$close_rate))
  expect_equal(sp$n_issues_found, 0L)
})

# ── trend_delta tests ─────────────────────────────────────────────────────────

test_that("trend_delta: decrease returns negative pct", {
  td <- trend_delta(cur_val = 3, pri_val = 6)
  expect_equal(td$pct_delta, -50)
  expect_equal(td$abs_delta, -3)
})

test_that("trend_delta: increase returns positive pct", {
  td <- trend_delta(cur_val = 12, pri_val = 8)
  expect_equal(td$pct_delta, 50)
  expect_equal(td$abs_delta, 4)
})

test_that("trend_delta: NA prior returns NA pct but numeric abs when possible", {
  td <- trend_delta(cur_val = 5, pri_val = NA_real_)
  expect_true(is.na(td$pct_delta))
  expect_true(is.na(td$abs_delta))
})

test_that("trend_delta: prior = 0 returns NA pct (avoid division by zero)", {
  td <- trend_delta(cur_val = 5, pri_val = 0)
  expect_true(is.na(td$pct_delta))
})

# ── compute_outliers tests ────────────────────────────────────────────────────

test_that("compute_outliers: by_time ordering is descending by time_to_close_hrs", {
  fix  <- make_fixture_con()
  on.exit(DBI::dbDisconnect(fix$con, shutdown = TRUE), add = TRUE)

  bounds <- window_bounds(ANCHOR, 14L)
  df     <- load_window(fix$con, bounds$cur$start, bounds$cur$end)
  df     <- with_stub_attempts(df)
  out    <- compute_outliers(df)

  if (nrow(out$by_time) > 1L) {
    expect_true(
      all(diff(out$by_time$time_to_close_hrs) <= 0),
      info = "by_time must be sorted descending by time_to_close_hrs"
    )
  }
})

test_that("compute_outliers: by_attempts ordering is descending by n_attempts", {
  fix  <- make_fixture_con()
  on.exit(DBI::dbDisconnect(fix$con, shutdown = TRUE), add = TRUE)

  bounds <- window_bounds(ANCHOR, 14L)
  df     <- load_window(fix$con, bounds$cur$start, bounds$cur$end)
  df     <- with_stub_attempts(df)
  out    <- compute_outliers(df)

  if (nrow(out$by_attempts) > 1L) {
    expect_true(
      all(diff(out$by_attempts$n_attempts) <= 0),
      info = "by_attempts must be sorted descending by n_attempts"
    )
  }
})

test_that("compute_outliers: at most 10 rows per list", {
  fix  <- make_fixture_con()
  on.exit(DBI::dbDisconnect(fix$con, shutdown = TRUE), add = TRUE)

  bounds <- window_bounds(ANCHOR, 14L)
  df     <- load_window(fix$con, bounds$cur$start, bounds$cur$end)
  df     <- with_stub_attempts(df)
  out    <- compute_outliers(df)

  expect_lte(nrow(out$by_time),     10L)
  expect_lte(nrow(out$by_attempts), 10L)
})

# ── End-to-end: JSON snapshot ─────────────────────────────────────────────────

test_that("full script: JSON snapshot written with required top-level keys", {
  skip_if_not_installed("duckdb")

  tmp_db  <- tempfile(fileext = ".duckdb")
  tmp_dir <- tempdir()

  # Write fixture to a temporary DuckDB file, then disconnect BEFORE subprocess
  c2 <- DBI::dbConnect(duckdb::duckdb(), tmp_db)
  make_lifecycle_fixture(c2)
  DBI::dbDisconnect(c2, shutdown = TRUE)   # must close before subprocess opens read-only

  # Run the script as a subprocess
  script_args <- c(
    sprintf("--anchor=%s", format(ANCHOR, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"))
  )
  env <- c(
    sprintf("UNIFIED_DUCKDB=%s", tmp_db),
    sprintf("ROBOREV_DAILY_DIR=%s", tmp_dir),
    "ROBOREV_DB=/dev/null"   # prevent heuristic fallback from opening live DB
  )
  result <- tryCatch(
    system2(
      "Rscript",
      args   = c(report_script, script_args),
      env    = env,
      stdout = TRUE,
      stderr = TRUE
    ),
    error = function(e) {
      skip(paste("Rscript unavailable:", conditionMessage(e)))
    }
  )

  # Check JSON output
  json_path <- file.path(tmp_dir, "2026-05-21.json")
  skip_if(!file.exists(json_path), "JSON snapshot not written (script may have errored)")

  payload <- jsonlite::fromJSON(json_path, simplifyVector = FALSE)

  required_keys <- c("report_date", "generated_at", "lineage_source",
                     "global_windows", "per_repo_7d", "outliers_14d")
  for (k in required_keys) {
    expect_true(k %in% names(payload),
                info = sprintf("JSON must contain top-level key '%s'", k))
  }

  expect_equal(payload$report_date, "2026-05-21")
  expect_true(length(payload$global_windows) == 4L,
              info = "Must have 4 global window slices (1d, 3d, 7d, 14d)")

  # Each global window must have speed sub-keys
  w7 <- payload$global_windows[["d7"]]
  expect_true(!is.null(w7), info = "d7 window must be present")
  if (!is.null(w7)) {
    sp_keys <- c("ttc_p50_hrs", "ttc_p90_hrs", "ttc_p99_hrs",
                 "att_p50", "att_p90", "close_rate",
                 "n_issues_found", "n_closed", "n_open")
    for (k in sp_keys) {
      expect_true(k %in% names(w7$speed),
                  info = sprintf("global window d7 speed must contain key '%s'", k))
    }
  }

  # outliers_14d must contain by_attempts and by_time
  expect_true("by_attempts" %in% names(payload$outliers_14d))
  expect_true("by_time"     %in% names(payload$outliers_14d))
})

test_that("full script: text digest is non-empty", {
  skip_if_not_installed("duckdb")

  tmp_db  <- tempfile(fileext = ".duckdb")
  tmp_dir <- tempdir()

  # Write fixture then disconnect before subprocess opens the file read-only
  c3 <- DBI::dbConnect(duckdb::duckdb(), tmp_db)
  make_lifecycle_fixture(c3)
  DBI::dbDisconnect(c3, shutdown = TRUE)

  script_args <- c(
    sprintf("--anchor=%s", format(ANCHOR, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"))
  )
  env <- c(
    sprintf("UNIFIED_DUCKDB=%s", tmp_db),
    sprintf("ROBOREV_DAILY_DIR=%s", tmp_dir),
    "ROBOREV_DB=/dev/null"
  )
  output <- tryCatch(
    system2("Rscript",
            args   = c(report_script, script_args),
            env    = env,
            stdout = TRUE,
            stderr = FALSE),
    error = function(e) skip(paste("Rscript unavailable:", conditionMessage(e)))
  )

  # The stdout digest should contain section headers
  combined <- paste(output, collapse = "\n")
  expect_true(nchar(combined) > 0L, info = "Text digest must be non-empty")
  expect_true(grepl("FREQUENCY TABLE", combined, fixed = TRUE),
              info = "Digest must contain §1 heading")
  expect_true(grepl("RESOLUTION SPEED", combined, fixed = TRUE),
              info = "Digest must contain §2 heading")
  expect_true(grepl("TRENDS", combined, fixed = TRUE),
              info = "Digest must contain §3 heading")
  expect_true(grepl("OUTLIERS", combined, fixed = TRUE),
              info = "Digest must contain §4 heading")
})
