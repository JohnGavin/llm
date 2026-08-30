#!/usr/bin/env Rscript
# tests/test_launchd_health_braindumps_staleness.R
#
# testthat tests for the braindumps freshness alarm added to
# .claude/scripts/launchd_health_report.R (llm#937 fix 5).
#
# Origin: llm#937 documented five fixes for a 3-month silent Signal-note
# capture outage. Fixes 1-4 landed already; fix 5 ("freshness alarm") had
# not — signal_braindump_handler.sh records facts into the legacy
# `etl_freshness` table, but nothing ever reads that table to raise an
# alarm, and a check invoked from *inside* the writer's own script would
# only ever run when the writer itself successfully runs — exactly the
# failure mode it exists to catch (`probe-must-not-share-writer-path`,
# `checks-must-distinguish-unknown`).
#
# This test proves the three-state contract using an in-memory duckdb
# connection with a synthetic `braindumps` table — never depends on the
# real ~/.claude/logs/unified.duckdb having any particular content.
#
# Run:
#   nix-shell ~/.claude/nix-gcroots/llm-shell.drv --run \
#     "Rscript tests/test_launchd_health_braindumps_staleness.R"

suppressPackageStartupMessages({
  library(testthat)
})

`%||%` <- function(a, b) if (!is.null(a) && length(a) > 0L) a else b

this_file <- tryCatch(
  normalizePath(sys.frames()[[1L]]$ofile, mustWork = FALSE),
  error = function(e) {
    args <- commandArgs(trailingOnly = FALSE)
    file_flag <- grep("^--file=", args, value = TRUE)
    if (length(file_flag) > 0L) sub("^--file=", "", file_flag[1L]) else "."
  }
)
script_dir <- normalizePath(dirname(this_file), mustWork = FALSE)

report_script <- normalizePath(
  file.path(script_dir, "..", ".claude", "scripts", "launchd_health_report.R"),
  mustWork = FALSE
)
if (!file.exists(report_script)) {
  candidate <- file.path(Sys.getenv("HOME"), "docs_gh", "llm", ".claude",
                          "scripts", "launchd_health_report.R")
  report_script <- candidate[file.exists(candidate)][1L] %||% report_script
}

test_that("launchd_health_report.R exists", {
  # .Rbuildignore excludes .claude/ from the package build, so under
  # covr::package_coverage() / R CMD check this file is genuinely absent —
  # skip (not fail) in that case. skip_if_not() reports the test as SKIPPED,
  # distinct from both PASS and FAIL, so a real regression (script present
  # but broken) still fails loudly while a build-tree exclusion does not.
  testthat::skip_if_not(
    file.exists(report_script),
    sprintf(
      "launchd_health_report.R not found at %s (expected under covr/R CMD check, where .Rbuildignore excludes .claude/)",
      report_script
    )
  )
  expect_true(file.exists(report_script))
})

if (!file.exists(report_script)) {
  message("Skipping execution tests — launchd_health_report.R not found")
  q(status = 0L)
}

has_duckdb_pkg <- requireNamespace("duckdb", quietly = TRUE) &&
  requireNamespace("DBI", quietly = TRUE)

# Source with the source-only guard so main-body side effects (scanning the
# real ~/Library/LaunchAgents, hitting the real ledger, calling gh) never run.
options(launchd_health_source_only = TRUE)
source(report_script)

test_that("braindumps staleness functions are defined after sourcing", {
  expect_true(exists("detect_braindumps_staleness"))
  expect_true(exists("render_braindumps_staleness"))
  expect_true(exists("collect_braindumps_staleness"))
})

if (!has_duckdb_pkg) {
  message("Skipping detect_braindumps_staleness DB tests — duckdb/DBI not available")
  cat("\n--- All tests completed (duckdb unavailable — DB tests skipped) ---\n")
  q(status = 0L)
}

#' Build an in-memory duckdb connection with a synthetic `braindumps` table
#' seeded with the given captured_at timestamps (character, 'YYYY-MM-DD
#' HH:MM:SS' form). Pass character(0) for a table that exists but is empty.
make_test_con <- function(captured_at = character(0)) {
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = ":memory:")
  DBI::dbExecute(con, "CREATE TABLE braindumps (
    id INTEGER, captured_at TIMESTAMP, source VARCHAR, raw_text VARCHAR
  )")
  if (length(captured_at) > 0L) {
    for (i in seq_along(captured_at)) {
      DBI::dbExecute(con, sprintf(
        "INSERT INTO braindumps (id, captured_at, source, raw_text) VALUES (%d, TIMESTAMP '%s', 'signal_notes', 'test')",
        i, captured_at[i]
      ))
    }
  }
  con
}

# ── detect_braindumps_staleness: fresh ──────────────────────────────────────

test_that("a newest row within the threshold is reported as 'fresh'", {
  con <- make_test_con(format(Sys.time() - 3600, "%Y-%m-%d %H:%M:%S", tz = "UTC")) # 1h ago
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  result <- detect_braindumps_staleness(con, threshold_hours = 72)
  expect_equal(nrow(result), 1L)
  expect_equal(result$status, "fresh")
  expect_true(result$hours_since_newest < 72)
  expect_true(is.na(result$detail))
})

# ── detect_braindumps_staleness: stale ──────────────────────────────────────

test_that("a newest row older than the threshold is reported as 'stale'", {
  ninety_days_ago <- format(Sys.time() - 90 * 86400, "%Y-%m-%d %H:%M:%S", tz = "UTC")
  con <- make_test_con(ninety_days_ago)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  result <- detect_braindumps_staleness(con, threshold_hours = 72)
  expect_equal(nrow(result), 1L)
  expect_equal(result$status, "stale")
  expect_true(result$hours_since_newest > 72)
  expect_true(is.na(result$detail))
})

test_that("the newest row (not the oldest) determines the status", {
  now_str <- format(Sys.time() - 3600, "%Y-%m-%d %H:%M:%S", tz = "UTC")  # 1h ago
  old_str <- format(Sys.time() - 90 * 86400, "%Y-%m-%d %H:%M:%S", tz = "UTC")  # 90d ago
  con <- make_test_con(c(old_str, now_str))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  result <- detect_braindumps_staleness(con, threshold_hours = 72)
  expect_equal(result$status, "fresh")
})

# ── detect_braindumps_staleness: indeterminate ──────────────────────────────

test_that("a missing braindumps table is reported as 'indeterminate', never 'stale' or 'fresh'", {
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = ":memory:")
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  # deliberately do NOT create the braindumps table

  result <- detect_braindumps_staleness(con, threshold_hours = 72)
  expect_equal(nrow(result), 1L)
  expect_equal(result$status, "indeterminate")
  expect_true(is.na(result$hours_since_newest))
  expect_false(is.na(result$detail))
  expect_true(nzchar(result$detail))
})

test_that("an existing-but-empty braindumps table is reported as 'indeterminate'", {
  con <- make_test_con(character(0))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  result <- detect_braindumps_staleness(con, threshold_hours = 72)
  expect_equal(result$status, "indeterminate")
  expect_true(is.na(result$hours_since_newest))
})

test_that("a NULL connection is reported as 'indeterminate', never crashes", {
  result <- detect_braindumps_staleness(NULL, threshold_hours = 72)
  expect_equal(nrow(result), 1L)
  expect_equal(result$status, "indeterminate")
})

test_that("a closed/broken connection is reported as 'indeterminate', never errors out of the function", {
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = ":memory:")
  DBI::dbDisconnect(con, shutdown = TRUE)  # now broken

  result <- tryCatch(
    detect_braindumps_staleness(con, threshold_hours = 72),
    error = function(e) NULL
  )
  expect_false(is.null(result))
  expect_equal(result$status, "indeterminate")
})

# ── render_braindumps_staleness: the three states must be textually distinct ─
# (this is the specific regression checks-must-distinguish-unknown exists to
# prevent — an indeterminate check must never render like a quiet "fine")

test_that("render_braindumps_staleness renders 'fresh' distinctly", {
  fresh_row <- data.frame(
    status = "fresh", hours_since_newest = 2.3,
    newest_captured_at = "2026-08-29 10:00 UTC", threshold_hours = 72,
    detail = NA_character_, stringsAsFactors = FALSE
  )
  out <- render_braindumps_staleness(fresh_row)
  expect_true(grepl("fresh", out, ignore.case = TRUE))
  expect_false(grepl("STALE", out))
  expect_false(grepl("INDETERMINATE", out))
})

test_that("render_braindumps_staleness renders 'stale' loudly and distinctly", {
  stale_row <- data.frame(
    status = "stale", hours_since_newest = 2200,
    newest_captured_at = "2026-05-01 10:00 UTC", threshold_hours = 72,
    detail = NA_character_, stringsAsFactors = FALSE
  )
  out <- render_braindumps_staleness(stale_row)
  expect_true(grepl("STALE", out))
  expect_false(grepl("INDETERMINATE", out))
  expect_true(grepl("937", out))
})

test_that("render_braindumps_staleness renders 'indeterminate' loudly and distinctly from fresh/stale", {
  indet_row <- data.frame(
    status = "indeterminate", hours_since_newest = NA_real_,
    newest_captured_at = NA_character_, threshold_hours = 72,
    detail = "'braindumps' table not found in ledger", stringsAsFactors = FALSE
  )
  out <- render_braindumps_staleness(indet_row)
  expect_true(grepl("INDETERMINATE", out))
  expect_false(grepl("STALE", out))
  expect_true(grepl("not found in ledger", out, fixed = TRUE))

  # The three renders must never collide — the whole point of this check.
  fresh_out <- render_braindumps_staleness(data.frame(
    status = "fresh", hours_since_newest = 1, newest_captured_at = "x",
    threshold_hours = 72, detail = NA_character_, stringsAsFactors = FALSE
  ))
  stale_out <- render_braindumps_staleness(data.frame(
    status = "stale", hours_since_newest = 999, newest_captured_at = "x",
    threshold_hours = 72, detail = NA_character_, stringsAsFactors = FALSE
  ))
  expect_false(identical(out, fresh_out))
  expect_false(identical(out, stale_out))
  expect_false(identical(fresh_out, stale_out))
})

test_that("render_braindumps_staleness handles a zero-row/NULL input as indeterminate, not blank", {
  out_null  <- render_braindumps_staleness(NULL)
  out_empty <- render_braindumps_staleness(data.frame(
    status = character(), hours_since_newest = numeric(),
    newest_captured_at = character(), threshold_hours = numeric(),
    detail = character(), stringsAsFactors = FALSE
  ))
  expect_true(grepl("INDETERMINATE", out_null))
  expect_true(grepl("INDETERMINATE", out_empty))
})

# ── collect_braindumps_staleness: production wrapper never errors ──────────

test_that("collect_braindumps_staleness returns 'indeterminate' for a nonexistent ledger path", {
  result <- collect_braindumps_staleness(ledger = "/nonexistent/path/to/ledger.duckdb", threshold_hours = 72)
  expect_equal(nrow(result), 1L)
  expect_equal(result$status, "indeterminate")
})

cat("\n--- All tests completed ---\n")
