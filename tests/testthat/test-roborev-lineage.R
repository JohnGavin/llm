# tests/testthat/test-roborev-lineage.R
#
# Regression tests for roborev_finding_lineage ETL.
# Tracks llm#286.
#
# Tests verify:
#   1. Each lineage_method is assigned correctly on synthetic data.
#   2. chain_size is consistent within a chain (all rows share the same value).
#   3. Summary counts (n_attempts) match raw row counts per finding chain.
#   4. Idempotence: re-running build_finding_lineage produces identical rows.
#
# Strategy: source only the two pure-function blocks from the ETL script
# (build_finding_lineage + coalesce_int, lines ~1032-1215).
# These blocks have no I/O side effects and depend only on:
#   - a DBI connection pointing at an in-memory SQLite fixture
#   - the log_msg helper (stubbed below)
#   - since_date / repo_clause (plain strings)

library(testthat)
library(DBI)
library(duckdb)

# ── Source the lineage function block ─────────────────────────────────────
#
# Two separate eval blocks:
#   Block 1: lines 100-108  — log_msg helper (required by build_finding_lineage)
#   Block 2: lines 1032-end — build_finding_lineage + coalesce_int
#
# We source log_msg from the script rather than stubbing it, so the dependency
# is explicit and the stub doesn't drift if the signature changes.

.log_msg_start  <- 100L   # log_msg <- function(...)
.log_msg_end    <- 108L   # closing } of log_msg
.etl_fn_start   <- 1032L  # "# ── Build roborev_finding_lineage"
.etl_fn_end     <- 1215L  # closing } of coalesce_int

etl_script <- file.path(pkgload::pkg_path(),
                         ".claude", "scripts", "roborev_metrics_etl.R")

skip_if_not(file.exists(etl_script), "ETL script not found at expected path")

all_lines <- readLines(etl_script)

# log_file is referenced inside log_msg — provide a tempfile so it doesn't
# try to write to ~/.claude/logs/ during tests.
log_file <- tempfile(fileext = ".log")

eval(parse(text = paste(all_lines[.log_msg_start:.log_msg_end], collapse = "\n")),
     envir = globalenv())
eval(parse(text = paste(all_lines[.etl_fn_start:.etl_fn_end],  collapse = "\n")),
     envir = globalenv())

# ── Fixture builder ───────────────────────────────────────────────────────
#
# 5-review synthetic SQLite database covering all 4 lineage methods:
#
#   job  rv  repo_id  commit_id  branch  patch_id              parent_job_id
#   1    1   1        10         main    patch-AAA             NULL    → patch_id
#   2    2   1        10         main    patch-AAA             NULL    → patch_id (chain w/ rv1)
#   3    3   1        11         main    NULL                  NULL    → commit_branch
#   4    4   1        11         main    NULL                  NULL    → commit_branch (chain w/ rv3)
#   5    5   1        12         main    NULL                  NULL    → solo
#
# Plus a 6th entry exercising parent_job_id (not NULL):
#   job  rv  repo_id  commit_id  branch  patch_id  parent_job_id
#   6    6   2        20         main    NULL       6            → parent_job_id
#   (parent_job_id self-references for simplicity; the code doesn't validate)

make_lineage_fixture <- function(dir) {
  skip_if_not_installed("duckdb")
  db_path <- file.path(dir, "lineage_fixture.db")

  # Use DuckDB to create the SQLite file via the sqlite extension
  con <- DBI::dbConnect(duckdb::duckdb(), ":memory:")
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(con, "LOAD sqlite")
  DBI::dbExecute(con, sprintf("ATTACH '%s' AS fix (TYPE sqlite)", db_path))

  DBI::dbExecute(con, "CREATE TABLE fix.repos (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
  DBI::dbExecute(con, "INSERT INTO fix.repos VALUES (1, 'llm'), (2, 'mycare')")

  DBI::dbExecute(con, "
    CREATE TABLE fix.review_jobs (
      id INTEGER PRIMARY KEY,
      repo_id INTEGER NOT NULL,
      commit_id INTEGER,
      branch TEXT DEFAULT 'main',
      patch_id TEXT,
      parent_job_id INTEGER,
      enqueued_at TEXT NOT NULL
    )
  ")

  jobs <- data.frame(
    id            = 1:6,
    repo_id       = c(1L, 1L, 1L, 1L, 1L, 2L),
    commit_id     = c(10L, 10L, 11L, 11L, 12L, 20L),
    branch        = c("main", "main", "main", "main", "main", "main"),
    patch_id      = c("patch-AAA", "patch-AAA", NA, NA, NA, NA),
    parent_job_id = c(NA, NA, NA, NA, NA, 6L),
    enqueued_at   = c(
      "2026-05-01 10:00:00",
      "2026-05-01 10:05:00",
      "2026-05-01 11:00:00",
      "2026-05-01 11:05:00",
      "2026-05-01 12:00:00",
      "2026-05-01 13:00:00"
    ),
    stringsAsFactors = FALSE
  )

  for (i in seq_len(nrow(jobs))) {
    row <- jobs[i, ]
    pid_sql <- if (is.na(row$patch_id)) "NULL" else sprintf("'%s'", row$patch_id)
    pjid_sql <- if (is.na(row$parent_job_id)) "NULL" else as.character(row$parent_job_id)
    DBI::dbExecute(con, sprintf(
      "INSERT INTO fix.review_jobs
       (id, repo_id, commit_id, branch, patch_id, parent_job_id, enqueued_at)
       VALUES (%d, %d, %d, '%s', %s, %s, '%s')",
      row$id, row$repo_id, row$commit_id, row$branch,
      pid_sql, pjid_sql, row$enqueued_at
    ))
  }

  DBI::dbExecute(con, "
    CREATE TABLE fix.reviews (
      id INTEGER PRIMARY KEY,
      job_id INTEGER NOT NULL,
      closed INTEGER DEFAULT 0,
      verdict_bool INTEGER,
      created_at TEXT DEFAULT '2026-05-01 10:00:00',
      output TEXT DEFAULT ''
    )
  ")

  reviews <- data.frame(
    id           = 1:6,
    job_id       = 1:6,
    closed       = c(0L, 1L, 0L, 1L, 0L, 1L),
    verdict_bool = c(0L, 1L, 0L, 0L, 0L, 1L),
    created_at   = c(
      "2026-05-01 10:01:00",
      "2026-05-01 10:06:00",
      "2026-05-01 11:01:00",
      "2026-05-01 11:06:00",
      "2026-05-01 12:01:00",
      "2026-05-01 13:01:00"
    ),
    stringsAsFactors = FALSE
  )

  for (i in seq_len(nrow(reviews))) {
    row <- reviews[i, ]
    DBI::dbExecute(con, sprintf(
      "INSERT INTO fix.reviews (id, job_id, closed, verdict_bool, created_at)
       VALUES (%d, %d, %d, %d, '%s')",
      row$id, row$job_id, row$closed, row$verdict_bool, row$created_at
    ))
  }

  db_path
}

# Open a DBI connection to the fixture's SQLite file via DuckDB's sqlite ext
open_fixture_con <- function(db_path) {
  con <- DBI::dbConnect(duckdb::duckdb(), ":memory:")
  DBI::dbExecute(con, "LOAD sqlite")
  DBI::dbExecute(con, sprintf("ATTACH '%s' AS src (TYPE sqlite, READ_ONLY)", db_path))
  con
}

# ── Tests ─────────────────────────────────────────────────────────────────

test_that("lineage_method assigned correctly for all 4 cases", {
  skip_if_not_installed("duckdb")

  tmp    <- withr::local_tempdir()
  db     <- make_lineage_fixture(tmp)
  con    <- open_fixture_con(db)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  since  <- as.Date("2026-05-01")
  result <- build_finding_lineage(con, since, "")

  expect_equal(nrow(result), 6L)

  get_method <- function(rv_id) result$lineage_method[result$finding_id == rv_id]

  # rv1 + rv2: same patch_id → patch_id
  expect_equal(get_method(1L), "patch_id",      info = "rv1 patch_id method")
  expect_equal(get_method(2L), "patch_id",      info = "rv2 patch_id method")

  # rv3 + rv4: same repo+branch+commit_id, no patch_id → commit_branch
  expect_equal(get_method(3L), "commit_branch", info = "rv3 commit_branch method")
  expect_equal(get_method(4L), "commit_branch", info = "rv4 commit_branch method")

  # rv5: unique commit_id, no patch_id, no parent_job_id → solo
  expect_equal(get_method(5L), "solo",          info = "rv5 solo method")

  # rv6: parent_job_id set → parent_job_id (priority 1)
  expect_equal(get_method(6L), "parent_job_id", info = "rv6 parent_job_id method")
})

test_that("chain_size is consistent within each chain", {
  skip_if_not_installed("duckdb")

  tmp    <- withr::local_tempdir()
  db     <- make_lineage_fixture(tmp)
  con    <- open_fixture_con(db)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  since  <- as.Date("2026-05-01")
  result <- build_finding_lineage(con, since, "")

  # patch_id chain: rv1 + rv2 → chain_size = 2
  cs_patch <- result$chain_size[result$lineage_method == "patch_id"]
  expect_true(all(cs_patch == 2L),
              info = "All patch_id chain rows must have chain_size=2")

  # commit_branch chain: rv3 + rv4 → chain_size = 2
  cs_cb <- result$chain_size[result$lineage_method == "commit_branch"]
  expect_true(all(cs_cb == 2L),
              info = "All commit_branch chain rows must have chain_size=2")

  # solo chain: rv5 → chain_size = 1
  cs_solo <- result$chain_size[result$lineage_method == "solo"]
  expect_true(all(cs_solo == 1L),
              info = "Solo chain must have chain_size=1")

  # parent_job_id chain: rv6 → chain_size = 1 (only one row in the group)
  cs_pjid <- result$chain_size[result$lineage_method == "parent_job_id"]
  expect_true(all(cs_pjid == 1L),
              info = "parent_job_id singleton chain must have chain_size=1")
})

test_that("summary counts match raw row counts per chain", {
  skip_if_not_installed("duckdb")

  tmp    <- withr::local_tempdir()
  db     <- make_lineage_fixture(tmp)
  con    <- open_fixture_con(db)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  since  <- as.Date("2026-05-01")
  result <- build_finding_lineage(con, since, "")

  # chain_size should equal the number of rows with the same group
  # (for each row, chain_size == count of rows sharing the same group).
  # Verify by cross-checking: for patch_id chains, two distinct finding_ids
  # → each chain has 2 rows and chain_size=2.
  patch_rows  <- result[result$lineage_method == "patch_id", ]
  expect_equal(nrow(patch_rows), 2L,
               info = "Exactly 2 rows in patch_id chain")
  expect_equal(unique(patch_rows$chain_size), 2L,
               info = "chain_size=2 for both patch_id rows")

  cb_rows <- result[result$lineage_method == "commit_branch", ]
  expect_equal(nrow(cb_rows), 2L,
               info = "Exactly 2 rows in commit_branch chain")
  expect_equal(unique(cb_rows$chain_size), 2L,
               info = "chain_size=2 for both commit_branch rows")
})

test_that("is_closing_attempt marks last closed row in each chain", {
  skip_if_not_installed("duckdb")

  tmp    <- withr::local_tempdir()
  db     <- make_lineage_fixture(tmp)
  con    <- open_fixture_con(db)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  since  <- as.Date("2026-05-01")
  result <- build_finding_lineage(con, since, "")

  # rv2 is the closing attempt of the patch_id chain (rv1=open, rv2=closed)
  r2 <- result[result$finding_id == 2L, ]
  expect_true(r2$is_closing_attempt,
              info = "rv2 (last closed in patch_id chain) must be is_closing_attempt=TRUE")

  r1 <- result[result$finding_id == 1L, ]
  expect_false(r1$is_closing_attempt,
               info = "rv1 (open, first in chain) must be is_closing_attempt=FALSE")

  # rv5: solo, still open → no closing attempt in chain
  r5 <- result[result$finding_id == 5L, ]
  expect_false(r5$is_closing_attempt,
               info = "rv5 (solo, open) must be is_closing_attempt=FALSE")
})

test_that("idempotence: two runs produce identical rows", {
  skip_if_not_installed("duckdb")

  tmp    <- withr::local_tempdir()
  db     <- make_lineage_fixture(tmp)
  con    <- open_fixture_con(db)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  since  <- as.Date("2026-05-01")

  res1 <- build_finding_lineage(con, since, "")
  res2 <- build_finding_lineage(con, since, "")

  expect_equal(nrow(res1), nrow(res2))
  expect_equal(res1$lineage_method, res2$lineage_method)
  expect_equal(res1$attempt_n,      res2$attempt_n)
  expect_equal(res1$chain_size,     res2$chain_size)
  expect_equal(res1$is_closing_attempt, res2$is_closing_attempt)
})
