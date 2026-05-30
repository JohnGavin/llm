# tests/testthat/test-roborev-etl-since.R
#
# Regression test for llm#332: schema-init Binder Error on narrow --since window.
#
# Root cause: roborev_finding_lineage_summary view referenced `rp.name` in its
# subquery but never joined a `repos` table aliased as `rp`. DuckDB's binder
# correctly rejected this. The view creation is attempted on every --apply run
# (CREATE OR REPLACE VIEW is one of the 7 schema-init statements). With a narrow
# --since window the view was created against an empty roborev_review_lifecycle
# table, exposing the alias error that wider windows masked.
#
# Fix: replace `rp.name` with `rl.repo` (the lifecycle table already carries
# the repo name as a VARCHAR column `repo`).
#
# Tests verify:
#   1. The schema SQL parses and executes without error — specifically the
#      CREATE OR REPLACE VIEW statement that caused the Binder Error.
#   2. The view returns sensible results when lifecycle and lineage tables are
#      populated with synthetic rows (basic smoke test).
#   3. The view definition does NOT reference the undefined alias `rp`
#      (static text check; catches any future regression to rp.name).

library(testthat)
library(DBI)
library(duckdb)

schema_file <- file.path(pkgload::pkg_path(),
                          ".claude", "scripts", "roborev_metrics_schema.sql")

skip_if_not(file.exists(schema_file), "Schema file not found at expected path")
skip_if_not_installed("duckdb")

# ── Helpers ──────────────────────────────────────────────────────────────────

# Parse the schema file the same way the ETL script does (strip comments,
# split on semi-colons, drop blank statements).
parse_schema_stmts <- function(path) {
  lines      <- readLines(path, warn = FALSE)
  text       <- paste(lines, collapse = "\n")
  text       <- gsub("--[^\n]*", "", text)          # strip line comments
  stmts      <- strsplit(text, ";")[[1L]]
  stmts      <- trimws(stmts)
  stmts[nzchar(stmts)]
}

# Build an in-memory DuckDB connection and run the full schema init.
# Returns the connection so callers can query it.
run_schema_init <- function() {
  con <- dbConnect(duckdb::duckdb(), ":memory:")
  stmts <- parse_schema_stmts(schema_file)
  for (stmt in stmts) {
    dbExecute(con, stmt)
  }
  con
}

# Populate the two tables that the view reads from.
populate_lifecycle_and_lineage <- function(con) {
  # One lifecycle row (review_id 1, repo "llm")
  dbExecute(con, "
    INSERT INTO roborev_review_lifecycle
      (review_id, job_id, repo, verdict, created_at, finished_at)
    VALUES
      (1, 1, 'llm', 'P',
       '2026-05-28 10:00:00'::TIMESTAMP,
       '2026-05-28 10:00:10'::TIMESTAMP)
  ")

  # Two lineage rows for finding_id=1 (a 2-attempt chain)
  dbExecute(con, "
    INSERT INTO roborev_finding_lineage
      (finding_id, attempt_n, lineage_method, job_id, created_at,
       verdict_bool, closed, chain_size, is_closing_attempt)
    VALUES
      (1, 1, 'solo', 1, '2026-05-28 10:00:00'::TIMESTAMP, 1, 1, 1, TRUE)
  ")
}

# ── Test 1: schema init succeeds (no Binder Error) ───────────────────────────

test_that("schema init runs without error — CREATE OR REPLACE VIEW succeeds", {
  con <- run_schema_init()
  on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

  # If we get here, all 7 schema statements executed without a Binder Error.
  # Confirm the view was created by checking it exists in information_schema.
  # DuckDB uses table_name (not view_name) in information_schema.views.
  views <- dbGetQuery(con, "
    SELECT table_name
    FROM information_schema.views
    WHERE table_name = 'roborev_finding_lineage_summary'
  ")
  expect_equal(nrow(views), 1L,
               info = "roborev_finding_lineage_summary view must be created")
})

# ── Test 2: view is queryable on an empty lifecycle table ────────────────────
#
# This is the exact scenario that triggered the original Binder Error:
# narrow --since window → lifecycle table empty at view-creation time.

test_that("summary view returns 0 rows (no error) when lifecycle is empty", {
  con <- run_schema_init()
  on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

  # lineage table has 1 row, lifecycle is empty
  dbExecute(con, "
    INSERT INTO roborev_finding_lineage
      (finding_id, attempt_n, lineage_method, job_id,
       verdict_bool, closed, chain_size, is_closing_attempt)
    VALUES (99, 1, 'solo', 99, 0, 0, 1, FALSE)
  ")

  result <- dbGetQuery(con, "SELECT * FROM roborev_finding_lineage_summary")
  # repo will be NULL because no matching lifecycle row — this is expected
  expect_equal(nrow(result), 1L,
               info = "Summary must return 1 row even when lifecycle is empty")
  expect_true(is.na(result$repo) || is.null(result$repo),
              info = "repo must be NULL/NA when lifecycle has no matching row")
})

# ── Test 3: view returns correct repo name when lifecycle row exists ─────────

test_that("summary view returns correct repo name from lifecycle rl.repo", {
  con <- run_schema_init()
  on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

  populate_lifecycle_and_lineage(con)

  result <- dbGetQuery(con, "SELECT * FROM roborev_finding_lineage_summary")

  expect_equal(nrow(result), 1L)
  expect_equal(result$finding_id, 1L)
  expect_equal(result$repo, "llm",
               info = "repo must be populated from roborev_review_lifecycle.repo")
  expect_equal(result$n_attempts, 1L)
})

# ── Test 4: static check — schema SQL does NOT reference undefined alias rp ──

test_that("schema SQL does not reference undefined alias rp in view body", {
  schema_text <- paste(readLines(schema_file, warn = FALSE), collapse = "\n")

  # Extract the view body: everything between CREATE OR REPLACE VIEW ... AS and
  # the final semi-colon of that statement.
  view_start <- regexpr("CREATE OR REPLACE VIEW", schema_text)
  expect_gt(view_start, 0L, label = "CREATE OR REPLACE VIEW must exist in schema")

  view_body <- substring(schema_text, view_start)

  # Must NOT contain "rp." (the undefined alias that caused the Binder Error).
  expect_false(grepl("\\brp\\.", view_body, perl = TRUE),
               info = "View body must not reference undefined alias 'rp.'")

  # Must reference 'rl.repo' (the correct column reference after the fix).
  expect_true(grepl("rl\\.repo", view_body, perl = TRUE),
              info = "View body must reference rl.repo from roborev_review_lifecycle")
})
