# test-roborev-repo-stats.R — roborev_repo_stats() from
# inst/shiny/dashboard/app.R (roborev#9342).
#
# roborev_repo_stats() had NO test coverage at all (High-severity finding).
# Same "parse + eval just this assignment" strategy as
# test-roborev-ephemeral-dropped.R: the Shiny app is not a package function
# and sourcing the whole file would execute UI/server code as a side effect.
#
# The function was also refactored (Medium-severity part of the same finding)
# away from shelling out to `system2("sqlite3", ...)` to an in-memory DuckDB
# connection that ATTACHes the SQLite reviews.db read-only and queries it via
# dplyr verbs (mirroring .claude/scripts/roborev_daily_report.R). These tests
# build a fixture SQLite file (via the sqlite3 CLI — test-only use; the
# function under test no longer shells out to it) shaped like the real
# ~/.roborev/reviews.db `repos` / `review_jobs` tables.

library(testthat)

app_path <- function() {
  candidates <- c(
    file.path(testthat::test_path("..", ".."), "inst", "shiny", "dashboard", "app.R"),
    file.path(getwd(), "inst", "shiny", "dashboard", "app.R")
  )
  for (p in candidates) if (file.exists(p)) return(normalizePath(p))
  ""
}

load_roborev_repo_stats <- function() {
  p <- app_path()
  skip_if_not(nzchar(p) && file.exists(p), "app.R not found")
  env <- new.env(parent = globalenv())
  exprs <- parse(p)
  found <- FALSE
  for (x in exprs) {
    if (is.call(x) && identical(as.character(x[[1]]), "<-") &&
        identical(as.character(x[[2]]), "roborev_repo_stats")) {
      eval(x, env)
      found <- TRUE
    }
  }
  skip_if_not(found, "roborev_repo_stats not found in app.R")
  env[["roborev_repo_stats"]]
}

# Build a fixture SQLite DB with `repos` and `review_jobs` tables via the
# sqlite3 CLI. All dates are computed relative to Sys.Date() in R (not
# sqlite's own date('now', ...)) so the fixture's expected counts are exact
# and independent of when the test runs.
make_fixture_db <- function(env = parent.frame()) {
  skip_if_not(nzchar(Sys.which("sqlite3")), "sqlite3 CLI not available")
  db <- withr::local_tempfile(fileext = ".sqlite", .local_envir = env)

  today  <- Sys.Date()
  cutoff <- today - 7
  d_boundary_in  <- format(cutoff,       "%Y-%m-%d")  # == cutoff: >= includes it
  d_boundary_out <- format(cutoff - 1L,  "%Y-%m-%d")  # one day before cutoff: excluded
  d_recent       <- format(today - 1L,   "%Y-%m-%d")
  d_old          <- format(today - 30L,  "%Y-%m-%d")

  sql <- sprintf("
    CREATE TABLE repos (id INTEGER PRIMARY KEY, root_path TEXT, created_at TEXT);
    CREATE TABLE review_jobs (id INTEGER PRIMARY KEY, repo_id INTEGER, enqueued_at TEXT);

    INSERT INTO repos (id, root_path, created_at) VALUES
      (1, '/home/ci/docs_gh/proj_a', '%s'),
      (2, '/home/ci/docs_gh/proj_b', '%s'),
      (3, '/tmp/agent-worktree-1', '%s'),
      (4, '/private/var/folders/hn/xyz/T/tmp.abc', '%s'),
      (5, '/home/ci/docs_gh/proj_c', '%s');

    INSERT INTO review_jobs (id, repo_id, enqueued_at) VALUES
      (1, 1, '%s'),
      (2, 2, '%s'),
      (3, 2, '%s'),
      (4, 5, '%s'),
      (5, 1, '%s');
  ", d_old, d_recent, d_boundary_in, d_boundary_out, d_recent,
     d_old, d_recent, d_old, d_boundary_in, d_boundary_out)

  status <- system2("sqlite3", c(shQuote(db), shQuote(sql)))
  skip_if_not(identical(status, 0L), "failed to build fixture sqlite db")
  db
}

# ── missing DB ───────────────────────────────────────────────────────────────

test_that("roborev_repo_stats: missing DB returns all-NA result", {
  fn <- load_roborev_repo_stats()

  withr::local_envvar(ROBOREV_DB = file.path(tempdir(), "does-not-exist.sqlite"))
  result <- fn()

  expect_type(result, "list")
  expect_named(result, c("total", "new_7d", "active_7d", "ephemeral"))
  expect_true(all(vapply(result, is.na, logical(1))))
})

# ── successful execution against a fixture DB ───────────────────────────────

test_that("roborev_repo_stats: counts match a known fixture", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dplyr")
  skip_if_not_installed("stringr")
  fn <- load_roborev_repo_stats()
  db <- make_fixture_db()

  withr::local_envvar(ROBOREV_DB = db)
  result <- fn()

  # total: all 5 repos
  expect_identical(result$total, 5L)
  # new_7d: created_at >= cutoff -> proj_b (recent), agent-worktree-1
  # (on the boundary, inclusive), proj_c (recent) = 3; proj_a (old) and
  # tmp.abc (one day before cutoff) excluded
  expect_identical(result$new_7d, 3L)
  # active_7d: distinct repo_id with enqueued_at >= cutoff -> repo 2
  # (recent job) and repo 5 (on the boundary, inclusive) = 2; repo 1's two
  # jobs are both before cutoff (old / one day before), so repo 1 does not
  # count even though it has jobs
  expect_identical(result$active_7d, 2L)
  # ephemeral: /tmp/... and /private/var/folders/... paths = 2
  expect_identical(result$ephemeral, 2L)
})

test_that("roborev_repo_stats: zero ephemeral repos -> 0, not NA", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dplyr")
  skip_if_not_installed("stringr")
  skip_if_not(nzchar(Sys.which("sqlite3")), "sqlite3 CLI not available")
  fn <- load_roborev_repo_stats()

  db <- withr::local_tempfile(fileext = ".sqlite")
  sql <- "
    CREATE TABLE repos (id INTEGER PRIMARY KEY, root_path TEXT, created_at TEXT);
    CREATE TABLE review_jobs (id INTEGER PRIMARY KEY, repo_id INTEGER, enqueued_at TEXT);
    INSERT INTO repos (id, root_path, created_at) VALUES
      (1, '/home/ci/docs_gh/proj_a', date('now'));
  "
  system2("sqlite3", c(shQuote(db), shQuote(sql)))

  withr::local_envvar(ROBOREV_DB = db)
  result <- fn()

  expect_identical(result$total, 1L)
  expect_identical(result$ephemeral, 0L)
  expect_identical(result$active_7d, 0L)
})

test_that("roborev_repo_stats: empty tables (no repos at all) -> zeros, not NA", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("dplyr")
  skip_if_not_installed("stringr")
  skip_if_not(nzchar(Sys.which("sqlite3")), "sqlite3 CLI not available")
  fn <- load_roborev_repo_stats()

  db <- withr::local_tempfile(fileext = ".sqlite")
  sql <- "
    CREATE TABLE repos (id INTEGER PRIMARY KEY, root_path TEXT, created_at TEXT);
    CREATE TABLE review_jobs (id INTEGER PRIMARY KEY, repo_id INTEGER, enqueued_at TEXT);
  "
  system2("sqlite3", c(shQuote(db), shQuote(sql)))

  withr::local_envvar(ROBOREV_DB = db)
  result <- fn()

  expect_identical(result$total, 0L)
  expect_identical(result$new_7d, 0L)
  expect_identical(result$active_7d, 0L)
  expect_identical(result$ephemeral, 0L)
})
