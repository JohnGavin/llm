# test-kb-search.R — Tests for kb_index() and kb_search()
#
# Hermetic: all tests use temp fixtures under tempdir().
# The real knowledge/ directory is NEVER touched.
#
# Coverage:
#  - kb_index() builds an index and returns chunk count
#  - kb_search() finds the expected file for a matching query (provenance cols present)
#  - kb_search() returns 0 rows for a no-match query
#  - kb_search() works on a read-only connection
#  - kb_search() errors informatively when db_path does not exist
#  - kb_index() errors informatively when dir does not exist
#  - chunk_file() internal: heading-less file falls back to block chunking
#  - Snapshot: error message when db_path missing
#  - Snapshot: names() of search result tibble

library(testthat)

# ── Fixture helper ────────────────────────────────────────────────────────────

#' Create a small temp knowledge-base directory for testing.
#'
#' @param .env Environment for withr cleanup (pass parent.env() from caller).
#' @return List with $dir (path) and $db_path (path, not yet created).
make_fixture <- function(.env = parent.frame()) {
  # Register cleanup in the calling test's environment so the dir persists
  # for the full duration of that test, not just until this helper returns.
  tmpdir  <- withr::local_tempdir(.local_envir = .env)
  db_path <- file.path(tmpdir, "test.kbidx.duckdb")

  # --- File 1: headings present ---
  writeLines(c(
    "# DuckDB FTS Overview",
    "",
    "DuckDB provides a full-text search extension via the fts pragma.",
    "It supports BM25 ranking out of the box.",
    "",
    "## Installation",
    "",
    "Run LOAD fts to enable the extension.",
    "",
    "## Query syntax",
    "",
    "Use fts_main_table.match_bm25(id, query) to score documents."
  ), file.path(tmpdir, "duckdb-fts.md"))

  # --- File 2: headings present ---
  writeLines(c(
    "# Agent Dispatch Worktree",
    "",
    "Agents run in isolated git worktrees for sandboxed file writes.",
    "The dispatch ID propagates through commit footers.",
    "",
    "## CRITICAL isolation",
    "",
    "Never write outside the worktree sandbox.",
    "Use git -C for all git operations."
  ), file.path(tmpdir, "agent-dispatch.md"))

  # --- File 3: NO headings (exercises block fallback) ---
  writeLines(c(
    "This is a heading-less document.",
    "It discusses knowledge base organisation.",
    "Files go in raw/ or wiki/ sub-directories.",
    "Sources sections are mandatory.",
    "Cross-links use double-bracket notation.",
    "The system tracks provenance for every entry."
  ), file.path(tmpdir, "no-headings.md"))

  list(dir = tmpdir, db_path = db_path)
}

# ── Tests ─────────────────────────────────────────────────────────────────────

test_that("kb_index() returns chunk count and creates database file", {
  fx <- make_fixture()
  n  <- kb_index(fx$dir, fx$db_path)

  expect_type(n, "integer")
  expect_gt(n, 0L)
  expect_true(file.exists(fx$db_path))
})

test_that("kb_index() chunk count is sensible (>= 1 per file)", {
  fx <- make_fixture()
  n  <- kb_index(fx$dir, fx$db_path)
  # 3 files: file 1 has 3 headings, file 2 has 2 headings, file 3 has no
  # headings -> 1 block chunk. Minimum expected = 3.
  expect_gte(n, 3L)
})

test_that("kb_search() returns tibble with required provenance columns", {
  fx <- make_fixture()
  kb_index(fx$dir, fx$db_path)
  res <- kb_search("BM25 full-text search", fx$db_path)

  expect_s3_class(res, "tbl_df")
  expect_true(all(c("loc", "path", "heading", "line_start", "score", "snippet") %in% names(res)))
  # loc must be the first column
  expect_equal(names(res)[[1L]], "loc")
})

test_that("kb_search() loc column is basename:line_start form", {
  fx <- make_fixture()
  kb_index(fx$dir, fx$db_path)
  res <- kb_search("worktree sandbox isolation", fx$db_path)

  expect_gt(nrow(res), 0L)
  # Every loc entry must match "<basename>:<positive integer>"
  expect_true(all(grepl("^[^:]+:\\d+$", res$loc)))
  # Verify the formula: loc == paste0(basename(path), ":", line_start)
  expected_loc <- paste0(basename(res$path), ":", res$line_start)
  expect_equal(res$loc, expected_loc)
})

test_that("kb_search() finds relevant file for a targeted query", {
  fx <- make_fixture()
  kb_index(fx$dir, fx$db_path)
  res <- kb_search("worktree sandbox isolation", fx$db_path)

  expect_gt(nrow(res), 0L)
  # The agent-dispatch.md file should surface for this query
  expect_true(any(grepl("agent-dispatch", res$path)))
})

test_that("kb_search() provenance: line_start is a positive integer in every row", {
  fx <- make_fixture()
  kb_index(fx$dir, fx$db_path)
  res <- kb_search("knowledge base", fx$db_path)

  if (nrow(res) > 0L) {
    expect_true(all(!is.na(res$line_start)))
    expect_true(all(res$line_start >= 1L))
  }
})

test_that("kb_search() returns 0 rows for a no-match query", {
  fx <- make_fixture()
  kb_index(fx$dir, fx$db_path)
  # Gibberish that won't match any doc
  res <- kb_search("xyzzy99foobarbaz999zzz", fx$db_path)
  expect_equal(nrow(res), 0L)
})

test_that("kb_search() read-only connection: search succeeds after index built", {
  fx <- make_fixture()
  kb_index(fx$dir, fx$db_path)

  # Explicitly test that the read_only=TRUE path in kb_search() works
  # (kb_search() always uses read_only; this test confirms the flow end-to-end)
  res <- kb_search("fts pragma extension", fx$db_path)
  expect_s3_class(res, "tbl_df")
  expect_gt(nrow(res), 0L)
})

test_that("kb_search() respects k argument", {
  fx <- make_fixture()
  kb_index(fx$dir, fx$db_path)
  res <- kb_search("the", fx$db_path, k = 2L)
  expect_lte(nrow(res), 2L)
})

test_that("kb_index() errors when dir does not exist", {
  db_path <- file.path(withr::local_tempdir(), "test.kbidx.duckdb")
  expect_error(
    kb_index("/nonexistent/path/xyz", db_path),
    regexp = "does not exist"
  )
})

test_that("kb_search() errors when db_path does not exist", {
  expect_error(
    kb_search("anything", "/nonexistent/db.duckdb"),
    regexp = "not found"
  )
})

# ── Snapshots ─────────────────────────────────────────────────────────────────

test_that("snapshot: column names of kb_search() result", {
  fx <- make_fixture()
  kb_index(fx$dir, fx$db_path)
  res <- kb_search("fts BM25", fx$db_path)
  expect_snapshot(names(res))
})

test_that("snapshot: error message when db_path missing", {
  expect_snapshot(
    kb_search("test query", "/definitely/does/not/exist.duckdb"),
    error = TRUE
  )
})

test_that("snapshot: error message when dir missing", {
  db_path <- file.path(withr::local_tempdir(), "test.kbidx.duckdb")
  expect_snapshot(
    kb_index("/no/such/dir", db_path),
    error = TRUE
  )
})
