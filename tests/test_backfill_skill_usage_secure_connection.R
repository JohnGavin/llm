#!/usr/bin/env Rscript
# tests/test_backfill_skill_usage_secure_connection.R
#
# Regression test for the JohnGavin/llm#1156 retrofit of
# .claude/scripts/backfill_skill_usage.R to use connect_duckdb_secure()
# (.claude/scripts/lib/duckdb_secure.R) instead of a raw
# DBI::dbConnect(duckdb::duckdb(), db_path) call.
#
# Note: skill_usage_etl.R (suggested as a first candidate) was NOT
# retrofitted — its STALENESS_VIEW_DDL uses DATEDIFF(), which
# DuckDB auto-loads the `icu` extension for on first use. With
# enable_external_access = false that autoload fails (verified empirically
# during this dispatch), so skill_usage_etl.R was NOT retrofitted; see
# duckdb_secure.R's header comment. backfill_skill_usage.R's DB-write path
# uses only core functions (date_trunc, CAST, current_timestamp, INSERT ...
# SELECT ... WHERE NOT EXISTS) and was verified end-to-end to work under
# the hardened connection, including its NOT EXISTS de-dup logic.
#
# Two things must both be true:
#   1. No behaviour change — the exact "insert only if not already present"
#      de-dup pattern backfill_skill_usage.R uses (NOT EXISTS + date_trunc +
#      IS NOT DISTINCT FROM) still produces correct, idempotent results
#      through the hardened connection.
#   2. The hardening is actually active, not just present in unused code —
#      current_setting('enable_external_access') must report false, and a
#      subsequent attempt to LOAD a DuckDB extension on that same
#      connection must fail (a check that cannot go red is not a check —
#      see verification-before-completion rule). A parallel unhardened
#      connection proves the same LOAD call succeeds absent the hardening,
#      so the assertion is a real check, not a tautology.
#
# Uses a temp DuckDB *file* (not ":memory:") because connect_duckdb_secure()
# is only safe for connections that do not LOAD an extension or ATTACH an
# external database.
#
# Run:
#   nix-shell ~/docs_gh/llm/default.nix --run \
#     "Rscript tests/test_skill_usage_etl_secure_connection.R"

suppressPackageStartupMessages({
  library(testthat)
  library(DBI)
  library(duckdb)
})

this_file <- tryCatch(
  normalizePath(sys.frames()[[1L]]$ofile, mustWork = FALSE),
  error = function(e) {
    args <- commandArgs(trailingOnly = FALSE)
    file_flag <- grep("^--file=", args, value = TRUE)
    if (length(file_flag) > 0L) sub("^--file=", "", file_flag[1L]) else "."
  }
)
script_dir <- normalizePath(dirname(this_file), mustWork = FALSE)

lib_path <- normalizePath(
  file.path(script_dir, "..", ".claude", "scripts", "lib", "duckdb_secure.R"),
  mustWork = FALSE
)
if (!file.exists(lib_path)) {
  candidate <- file.path(Sys.getenv("HOME"), "docs_gh", "llm", ".claude",
                          "scripts", "lib", "duckdb_secure.R")
  if (file.exists(candidate)) lib_path <- candidate
}

backfill_script <- normalizePath(
  file.path(script_dir, "..", ".claude", "scripts", "backfill_skill_usage.R"),
  mustWork = FALSE
)
if (!file.exists(backfill_script)) {
  candidate <- file.path(Sys.getenv("HOME"), "docs_gh", "llm", ".claude",
                          "scripts", "backfill_skill_usage.R")
  if (file.exists(candidate)) backfill_script <- candidate
}

test_that("duckdb_secure.R exists", {
  # .Rbuildignore excludes .claude/ from the package build; skip (not fail)
  # under covr::package_coverage() / R CMD check, where this file is
  # genuinely absent. A real regression (file present but broken) still
  # fails loudly below.
  testthat::skip_if_not(
    file.exists(lib_path),
    sprintf("duckdb_secure.R not found at %s (expected under covr/R CMD check)", lib_path)
  )
  expect_true(file.exists(lib_path))
})

test_that("backfill_skill_usage.R sources connect_duckdb_secure()", {
  testthat::skip_if_not(
    file.exists(backfill_script),
    sprintf("backfill_skill_usage.R not found at %s (expected under covr/R CMD check)",
            backfill_script)
  )
  src <- readLines(backfill_script, warn = FALSE)
  expect_true(any(grepl("duckdb_secure\\.R", src)))
  expect_true(any(grepl("connect_duckdb_secure\\(", src)))
  expect_false(any(grepl("^\\s*con <- dbConnect\\(duckdb\\(\\), db_path\\)", src)))
})

if (!file.exists(lib_path)) {
  cat("duckdb_secure.R not found — skipping remaining tests (see above)\n")
  quit(status = 0L)
}

source(lib_path)

test_that("connect_duckdb_secure() preserves backfill_skill_usage.R's NOT-EXISTS dedup insert", {
  tmp_db <- tempfile(fileext = ".duckdb")
  on.exit(unlink(tmp_db), add = TRUE)

  con <- connect_duckdb_secure(dbdir = tmp_db, read_only = FALSE)
  on.exit(tryCatch(DBI::dbDisconnect(con, shutdown = TRUE), error = function(e) NULL),
          add = TRUE)

  # Same schema as backfill_skill_usage.R's CREATE TABLE.
  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS skill_usage (
      session_id   VARCHAR,
      skill_name   VARCHAR,
      project_path VARCHAR,
      args_hash    VARCHAR,
      ts           TIMESTAMP,
      backfilled   BOOLEAN DEFAULT FALSE
    )")

  staging1 <- data.frame(
    session_id = "s1", skill_name = "adversarial-qa",
    project_path = "/tmp/proj", args_hash = "abc123",
    ts = "2026-09-01 12:00:00", stringsAsFactors = FALSE
  )
  DBI::dbWriteTable(con, "skill_usage_backfill_staging", staging1, overwrite = TRUE)

  n1 <- DBI::dbExecute(con, "
    INSERT INTO skill_usage (session_id, skill_name, project_path, args_hash, ts, backfilled)
    SELECT
      s.session_id, s.skill_name, s.project_path, s.args_hash,
      CAST(s.ts AS TIMESTAMP) AS ts, TRUE
    FROM skill_usage_backfill_staging s
    WHERE NOT EXISTS (
      SELECT 1 FROM skill_usage u
      WHERE u.session_id = s.session_id
        AND u.skill_name = s.skill_name
        AND date_trunc('second', u.ts) = date_trunc('second', CAST(s.ts AS TIMESTAMP))
        AND u.args_hash IS NOT DISTINCT FROM s.args_hash
    )
  ")
  expect_equal(n1, 1L)

  # Re-run the identical insert (idempotency: dedup must skip it this time).
  n2 <- DBI::dbExecute(con, "
    INSERT INTO skill_usage (session_id, skill_name, project_path, args_hash, ts, backfilled)
    SELECT
      s.session_id, s.skill_name, s.project_path, s.args_hash,
      CAST(s.ts AS TIMESTAMP) AS ts, TRUE
    FROM skill_usage_backfill_staging s
    WHERE NOT EXISTS (
      SELECT 1 FROM skill_usage u
      WHERE u.session_id = s.session_id
        AND u.skill_name = s.skill_name
        AND date_trunc('second', u.ts) = date_trunc('second', CAST(s.ts AS TIMESTAMP))
        AND u.args_hash IS NOT DISTINCT FROM s.args_hash
    )
  ")
  expect_equal(n2, 0L)

  final <- dplyr::tbl(con, "skill_usage") |>
    dplyr::summarise(n = dplyr::n()) |>
    dplyr::collect() |>
    dplyr::pull(n)
  expect_equal(final, 1L)
})

test_that("connect_duckdb_secure() actually disables external access (not just present in unused code)", {
  tmp_db <- tempfile(fileext = ".duckdb")
  on.exit(unlink(tmp_db), add = TRUE)

  con <- connect_duckdb_secure(dbdir = tmp_db, read_only = FALSE)
  on.exit(tryCatch(DBI::dbDisconnect(con, shutdown = TRUE), error = function(e) NULL),
          add = TRUE)

  # A scalar SET/current_setting() check, not a table SELECT — there is no
  # table to dplyr::tbl() from here, so dbGetQuery is the correct tool.
  setting <- DBI::dbGetQuery(con, "SELECT current_setting('enable_external_access') AS v")$v[1L]
  expect_identical(tolower(as.character(setting)), "false")

  # Falsification: on an UNHARDENED connection, loading an extension succeeds.
  # This proves the assertion below is a real check, not a tautology.
  plain_con <- DBI::dbConnect(duckdb::duckdb(), ":memory:")
  on.exit(tryCatch(DBI::dbDisconnect(plain_con, shutdown = TRUE), error = function(e) NULL),
          add = TRUE)
  plain_load_ok <- tryCatch({
    DBI::dbExecute(plain_con, "LOAD icu")
    TRUE
  }, error = function(e) FALSE)
  expect_true(plain_load_ok)

  # On the hardened connection, the same LOAD must fail.
  hardened_load_ok <- tryCatch({
    DBI::dbExecute(con, "LOAD icu")
    TRUE
  }, error = function(e) FALSE)
  expect_false(hardened_load_ok)
})
