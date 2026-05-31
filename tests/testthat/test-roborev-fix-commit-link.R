# Tests for find_fix_commit_for_review() and enrich_fix_commit_links().
# Tracks llm#379.
#
# Tests verify:
#   1. Autoclose heuristic (close_reason = "severity-*") → fix_method = autoclose_severity
#   2. Explicit reference heuristic via git log grep → fix_method = commit_reference
#   3. Time-proximity heuristic (commit within 6h before closure) → fix_method = manual
#   4. Fallthrough: closed, no matching commit, not autoclose → fix_method = unknown
#   5. Edge: review with unknown close_reason, no repo path → fix_method = unknown
#   6. Boundary: fix_commit_sha IS NOT NA guard (batch idempotence)
#
# Strategy: source the ETL function block containing find_fix_commit_for_review
# and enrich_fix_commit_links (pure functions with no I/O beyond sys calls).
# git-dependent heuristics (1, 3) are exercised via a temporary git repo fixture.

library(testthat)

# ── Load ETL function block ─────────────────────────────────────────────────
# Source lines covering the new functions.  We source the whole script in a
# sandboxed environment to pick up helpers (coalesce_int, `%||%`, parse_ts, etc.).
#
# Because the script has top-level I/O (arg parsing, DB reads), we fake the
# commandArgs output and redirect the graceful_exit() calls.

etl_script <- file.path(pkgload::pkg_path(),
                         ".claude", "scripts", "roborev_metrics_etl.R")

skip_if_not(file.exists(etl_script), "ETL script not found at expected path")

# Parse-only check (always run, even if duckdb absent)
test_that("ETL script parses without error (syntax check)", {
  expect_silent(parse(etl_script))
})

# ── Minimal fixture helpers ─────────────────────────────────────────────────

# Build a minimal lifecycle_df row matching the build_review_lifecycle schema
make_lifecycle_row <- function(review_id, closed_at, close_reason,
                                fix_commit_sha = NA_character_) {
  data.frame(
    review_id                    = as.integer(review_id),
    job_id                       = as.integer(review_id),
    repo                         = "llm",
    agent                        = "claude-code",
    model                        = NA_character_,
    branch                       = "main",
    commit_sha                   = NA_character_,
    created_at                   = as.POSIXct("2026-05-27 10:00:00", tz = "UTC"),
    started_at                   = as.POSIXct("2026-05-27 10:00:01", tz = "UTC"),
    finished_at                  = as.POSIXct("2026-05-27 10:00:10", tz = "UTC"),
    duration_s                   = 9.0,
    verdict                      = "F",
    severity_max                 = "High",
    closed_at                    = as.POSIXct(closed_at, tz = "UTC"),
    close_reason                 = close_reason,
    autoclose_threshold_at_close = NA_character_,
    fix_commit_sha               = fix_commit_sha,
    fix_commit_at                = as.POSIXct(NA_real_, origin = "1970-01-01"),
    fix_method                   = NA_character_,
    stringsAsFactors             = FALSE
  )
}

# ── Load the functions needed for testing ──────────────────────────────────
#
# We source only the pure-function block to avoid triggering I/O.
# find_fix_commit_for_review and enrich_fix_commit_links are defined after
# coalesce_int (the last helper before the Slice 3 block).

all_lines <- readLines(etl_script)

# Find line numbers for the two target functions.
# Anchor on the unique comment that precedes each function definition.
fn_start_pattern  <- "^# .* find_fix_commit_for_review \\(#379\\)"
enrich_end_pattern <- "^\\}"  # closing brace of enrich_fix_commit_links

fn_start_line  <- grep(fn_start_pattern, all_lines)[[1L]]

# Also need coalesce_int and %||% helpers; source from their first occurrence.
coalesce_line <- grep("^coalesce_int <- function", all_lines)[[1L]]
pipe_line     <- grep("^`%||%` <-", all_lines)[[1L]]
helper_start  <- min(coalesce_line, pipe_line)

# Find end of enrich_fix_commit_links: the first bare "}" after
# "enrich_fix_commit_links <- function" definition.
enrich_fn_line  <- grep("^enrich_fix_commit_links <- function", all_lines)[[1L]]
# The function ends at the first bare "}" that occurs on its own line after
# the function opens, at depth 0. Walk forward to find it.
depth        <- 0L
enrich_end_line <- enrich_fn_line
for (li in enrich_fn_line:length(all_lines)) {
  opens   <- nchar(gsub("[^{]", "", all_lines[[li]]))
  closes  <- nchar(gsub("[^}]", "", all_lines[[li]]))
  depth   <- depth + opens - closes
  if (li > enrich_fn_line && depth == 0L) {
    enrich_end_line <- li
    break
  }
}

fn_block <- all_lines[helper_start:enrich_end_line]

# Evaluate in the test environment
fn_env <- new.env(parent = globalenv())
eval(parse(text = paste(fn_block, collapse = "\n")), envir = fn_env)

find_fix_commit_for_review  <- fn_env$find_fix_commit_for_review
enrich_fix_commit_links      <- fn_env$enrich_fix_commit_links

skip_if(is.null(find_fix_commit_for_review),
        "find_fix_commit_for_review not found in ETL script — line offsets may need updating")

# ── Test 1: autoclose heuristic ────────────────────────────────────────────

test_that("find_fix_commit: autoclose close_reason → autoclose_severity, NULL sha", {
  closed_at <- as.POSIXct("2026-05-27 18:00:00", tz = "UTC")

  for (cr in c("severity-medium", "severity-low", "clean-verdict", "severity-high")) {
    result <- find_fix_commit_for_review(
      review_id    = 42L,
      repo_path    = "/nonexistent/path",
      closed_at    = closed_at,
      close_reason = cr,
      closer_actor = NA_character_
    )
    expect_equal(result$fix_method, "autoclose_severity",
                 info = sprintf("close_reason='%s' should yield autoclose_severity", cr))
    expect_true(is.na(result$fix_commit_sha),
                info = sprintf("fix_commit_sha must be NA for autoclose (close_reason='%s')", cr))
  }
})

# ── Test 2: no repo path → unknown ─────────────────────────────────────────

test_that("find_fix_commit: non-existent repo path → unknown", {
  result <- find_fix_commit_for_review(
    review_id    = 99L,
    repo_path    = "/this/path/does/not/exist",
    closed_at    = as.POSIXct("2026-05-27 18:00:00", tz = "UTC"),
    close_reason = "manual",
    closer_actor = NA_character_
  )
  expect_equal(result$fix_method, "unknown")
  expect_true(is.na(result$fix_commit_sha))
})

# ── Test 3: explicit commit reference via git grep ─────────────────────────

test_that("find_fix_commit: commit with 'roborev #<id>' in message → commit_reference", {
  skip_if_not(nzchar(Sys.which("git")), "git not available")

  tmp_repo <- withr::local_tempdir()

  # Initialise bare git repo with one commit referencing roborev #1234
  system2("git", args = c("-C", tmp_repo, "init", "-q"))
  system2("git", args = c("-C", tmp_repo, "config", "user.email", "test@test.com"))
  system2("git", args = c("-C", tmp_repo, "config", "user.name", "Test"))

  writeLines("hello", file.path(tmp_repo, "file.txt"))
  system2("git", args = c("-C", tmp_repo, "add", "file.txt"))
  system2("git", args = c(
    "-C", tmp_repo,
    "commit", "-m", "fix: address roborev review #1234 finding in R/foo.R",
    "--date", "2026-05-27T17:30:00+00:00",
    "--no-gpg-sign"
  ))

  # Get the commit SHA
  sha_raw <- system2("git", args = c("-C", tmp_repo, "log", "--format=%H", "-1"),
                     stdout = TRUE)
  expected_sha <- trimws(sha_raw[[1L]])

  closed_at <- as.POSIXct("2026-05-27 18:00:00", tz = "UTC")
  result <- find_fix_commit_for_review(
    review_id    = 1234L,
    repo_path    = tmp_repo,
    closed_at    = closed_at,
    close_reason = "manual",
    closer_actor = NA_character_
  )

  expect_equal(result$fix_method, "commit_reference",
               info = "Should detect explicit roborev #1234 reference in commit message")
  expect_equal(result$fix_commit_sha, expected_sha,
               info = "SHA should match the commit that references roborev #1234")
  expect_false(is.na(result$fix_commit_at),
               info = "fix_commit_at must be non-NA when commit is found")
})

# ── Test 4: time-proximity heuristic ───────────────────────────────────────

test_that("find_fix_commit: commit within 6h before closure → manual (time-proximity)", {
  skip_if_not(nzchar(Sys.which("git")), "git not available")

  tmp_repo <- withr::local_tempdir()
  system2("git", args = c("-C", tmp_repo, "init", "-q"))
  system2("git", args = c("-C", tmp_repo, "config", "user.email", "test@test.com"))
  system2("git", args = c("-C", tmp_repo, "config", "user.name", "Test"))

  # A commit 3 hours before closure (within 6h window) WITHOUT a roborev reference
  writeLines("fix", file.path(tmp_repo, "fix.R"))
  system2("git", args = c("-C", tmp_repo, "add", "fix.R"))
  system2("git", args = c(
    "-C", tmp_repo,
    "commit", "-m", "refactor: general cleanup",
    "--date", "2026-05-27T15:00:00+00:00",
    "--no-gpg-sign"
  ))

  sha_raw <- system2("git", args = c("-C", tmp_repo, "log", "--format=%H", "-1"),
                     stdout = TRUE)
  expected_sha <- trimws(sha_raw[[1L]])

  # closed_at = 18:00; commit at 15:00 → 3h gap, within 6h window
  closed_at <- as.POSIXct("2026-05-27 18:00:00", tz = "UTC")
  result <- find_fix_commit_for_review(
    review_id    = 9999L,   # won't match the commit message
    repo_path    = tmp_repo,
    closed_at    = closed_at,
    close_reason = "manual",
    closer_actor = NA_character_
  )

  expect_equal(result$fix_method, "manual",
               info = "Commit within 6h window with no explicit ref → manual")
  expect_equal(result$fix_commit_sha, expected_sha,
               info = "SHA should match the time-proximity commit")
})

# ── Test 5: fallthrough — closed, no commit anywhere near closure ──────────

test_that("find_fix_commit: no commits in window → unknown", {
  skip_if_not(nzchar(Sys.which("git")), "git not available")

  tmp_repo <- withr::local_tempdir()
  system2("git", args = c("-C", tmp_repo, "init", "-q"))
  system2("git", args = c("-C", tmp_repo, "config", "user.email", "test@test.com"))
  system2("git", args = c("-C", tmp_repo, "config", "user.name", "Test"))

  # A commit OUTSIDE the 6-hour window (8 hours before closure)
  writeLines("old", file.path(tmp_repo, "old.R"))
  system2("git", args = c("-C", tmp_repo, "add", "old.R"))
  system2("git", args = c(
    "-C", tmp_repo,
    "commit", "-m", "chore: old unrelated commit",
    "--date", "2026-05-27T10:00:00+00:00",
    "--no-gpg-sign"
  ))

  # closed_at = 18:00; only commit is at 10:00 → 8h gap, outside window
  closed_at <- as.POSIXct("2026-05-27 18:00:00", tz = "UTC")
  result <- find_fix_commit_for_review(
    review_id    = 5555L,
    repo_path    = tmp_repo,
    closed_at    = closed_at,
    close_reason = "manual",
    closer_actor = NA_character_
  )

  expect_equal(result$fix_method, "unknown",
               info = "No commits in window → unknown")
  expect_true(is.na(result$fix_commit_sha),
              info = "fix_commit_sha must be NA when unknown")
})

# ── Test 6: enrich_fix_commit_links batch guard ────────────────────────────

test_that("enrich_fix_commit_links: already-linked rows are not re-processed", {
  skip_if_not_installed("duckdb")

  # Build a minimal SQLite fixture for the repos map lookup
  tmp <- withr::local_tempdir()
  db_path <- file.path(tmp, "reviews_fix.db")

  con <- DBI::dbConnect(duckdb::duckdb(), ":memory:")
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(con, "LOAD sqlite")
  DBI::dbExecute(con, sprintf("ATTACH '%s' AS src (TYPE sqlite)", db_path))
  DBI::dbExecute(con, "CREATE TABLE src.repos (id INTEGER PRIMARY KEY, name TEXT, root_path TEXT)")
  DBI::dbExecute(con, "INSERT INTO src.repos VALUES (1, 'llm', '/nonexistent/llm')")

  # Lifecycle with one row already linked (fix_commit_sha IS NOT NA)
  already_linked <- make_lifecycle_row(
    review_id      = 1L,
    closed_at      = "2026-05-27 18:00:00",
    close_reason   = "manual",
    fix_commit_sha = "abc123def456abc123def456abc123def456abc1"
  )
  already_linked$fix_method <- "commit_reference"

  # Enrich — already-linked row should be untouched
  enriched <- enrich_fix_commit_links(already_linked, con)

  expect_equal(enriched$fix_commit_sha[[1L]],
               "abc123def456abc123def456abc123def456abc1",
               info = "Already-linked sha must not change")
  expect_equal(enriched$fix_method[[1L]], "commit_reference",
               info = "Already-linked method must not change")
})

# ── Test 7: enrich adds fix_commit_sha column if absent ───────────────────

test_that("enrich_fix_commit_links: adds fix_commit_sha column when missing", {
  skip_if_not_installed("duckdb")

  tmp <- withr::local_tempdir()
  db_path <- file.path(tmp, "reviews_fix2.db")

  con <- DBI::dbConnect(duckdb::duckdb(), ":memory:")
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(con, "LOAD sqlite")
  DBI::dbExecute(con, sprintf("ATTACH '%s' AS src (TYPE sqlite)", db_path))
  DBI::dbExecute(con, "CREATE TABLE src.repos (id INTEGER PRIMARY KEY, name TEXT, root_path TEXT)")
  DBI::dbExecute(con, "INSERT INTO src.repos VALUES (1, 'llm', '/nonexistent/path')")

  # Lifecycle without fix-link columns (simulates pre-#379 build)
  row_df <- make_lifecycle_row(1L, "2026-05-27 18:00:00", "manual")
  row_df$fix_commit_sha <- NULL
  row_df$fix_commit_at  <- NULL
  row_df$fix_method     <- NULL

  enriched <- enrich_fix_commit_links(row_df, con)

  expect_true("fix_commit_sha" %in% names(enriched),
              info = "fix_commit_sha column must be added by enrich()")
  expect_true("fix_method"     %in% names(enriched),
              info = "fix_method column must be added by enrich()")
})
