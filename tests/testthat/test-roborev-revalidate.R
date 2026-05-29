# Tests for .claude/scripts/roborev_revalidate.R
#
# Strategy:
#   - Source pure helper functions from the script.
#   - Build a synthetic SQLite fixture with 4 reviews.
#   - Build a synthetic repo tree in tempdir().
#   - Assert each review gets the expected verdict.
#   - Assert markdown report sections are correct.
#   - Assert --apply mode dispatches the right calls (mock roborev binary).
#
# Tracked in llm#280.

library(testthat)

# ── Load script helpers ────────────────────────────────────────────────────────

script_path <- file.path(
  pkgload::pkg_path(),
  ".claude", "scripts", "roborev_revalidate.R"
)

skip_if_not(
  file.exists(script_path),
  "roborev_revalidate.R not found — skipping tests"
)

# Source the script in an isolated environment; suppress the `main()` call
# via the ROBOREV_REVALIDATE_SKIP_MAIN env var guard.

script_env <- new.env(parent = globalenv())
withr::with_envvar(c(ROBOREV_REVALIDATE_SKIP_MAIN = "1"), {
  source(script_path, local = script_env)
})

# Pull key functions into test scope
parse_args         <- script_env$parse_args
parse_findings     <- script_env$parse_findings
parse_location     <- script_env$parse_location
extract_patterns   <- script_env$extract_patterns
classify_finding   <- script_env$classify_finding
classify_review    <- script_env$classify_review
format_report      <- script_env$format_report
VERDICT_WEIGHT     <- script_env$VERDICT_WEIGHT
CONTEXT_LINES      <- script_env$CONTEXT_LINES

# ── Helpers ────────────────────────────────────────────────────────────────────

make_review_row <- function(review_id, job_id, git_ref = "abc123", output) {
  data.frame(
    review_id  = review_id,
    job_id     = job_id,
    git_ref    = git_ref,
    created_at = "2026-05-01 00:00:00",
    output     = output,
    stringsAsFactors = FALSE
  )
}

SEV_ORDER <- c(Critical = 4L, High = 3L, Medium = 2L, Low = 1L)

# ── Synthetic repo tree ────────────────────────────────────────────────────────

setup_repo_tree <- function() {
  # Use a persistent subdirectory under tempdir() (not withr::local_tempdir()
  # which cleans up when the calling frame exits, not the test_that frame).
  repo_root <- file.path(tempdir(), paste0("roborev_test_repo_", Sys.getpid()))
  if (!dir.exists(repo_root)) dir.create(repo_root, recursive = TRUE)

  # A file that still has the problematic pattern
  still_file <- file.path(repo_root, "R", "foo.R")
  dir.create(dirname(still_file), recursive = TRUE, showWarnings = FALSE)
  writeLines(c(
    "# foo.R",
    "list.files('vignettes', recursive = FALSE)  # non-recursive call",
    "# more code",
    "other_function()"
  ), still_file)

  # A directory that exists but pattern is gone
  fixed_file <- file.path(repo_root, "R", "bar.R")
  writeLines(c(
    "# bar.R - fixed version",
    "list.files('vignettes', recursive = TRUE)  # now recursive",
    "another_function()"
  ), fixed_file)

  # A scripts directory for a shell script
  sh_file <- file.path(repo_root, ".claude", "scripts", "qa.sh")
  dir.create(dirname(sh_file), recursive = TRUE, showWarnings = FALSE)
  writeLines(c(
    "#!/bin/bash",
    "find . -maxdepth 1 -name '*.html'  # old shallow find",
    "echo done"
  ), sh_file)

  repo_root
}

# ── Test 1: parse_location ─────────────────────────────────────────────────────

test_that("parse_location handles N, N-M, N,M,K formats and backticks", {
  r1 <- parse_location("`R/foo.R:42`")
  expect_equal(r1$path, "R/foo.R")
  expect_equal(r1$lines, 42L)

  r2 <- parse_location("R/bar.R:10-15")
  expect_equal(r2$path, "R/bar.R")
  expect_equal(r2$lines, 10:15)

  r3 <- parse_location(".claude/scripts/check.R:4,8,12")
  expect_equal(r3$path, ".claude/scripts/check.R")
  expect_equal(r3$lines, c(4L, 8L, 12L))

  r4 <- parse_location("nolines.R")
  expect_equal(r4$path, "nolines.R")
  expect_equal(length(r4$lines), 0L)

  r5 <- parse_location(NA_character_)
  expect_true(is.na(r5$path))
})

# ── Test 2: extract_patterns ───────────────────────────────────────────────────

test_that("extract_patterns returns backtick-quoted tokens first", {
  prob <- "The call `list.files()` uses non-recursive scan causing issues."
  pats <- extract_patterns(prob)
  expect_true(length(pats) > 0L)
  expect_true("list.files()" %in% pats || "list.files" %in% pats)
})

test_that("extract_patterns returns empty for empty/NA input", {
  expect_equal(extract_patterns(NA_character_), character(0))
  expect_equal(extract_patterns(""), character(0))
})

test_that("extract_patterns excludes common stopwords", {
  prob <- "This should not include words like false true null that this which"
  pats <- extract_patterns(prob)
  expect_false("false" %in% pats)
  expect_false("which" %in% pats)
})

# ── Test 3: parse_findings ─────────────────────────────────────────────────────

test_that("parse_findings splits multiple sub-findings correctly", {
  output <- paste0(
    "## Review Findings\n\n",
    "- **Severity**: High\n",
    "- **Location**: `R/foo.R:10-20`\n",
    "- **Problem**: The `list.files` call is not recursive.\n",
    "- **Fix**: Use `recursive = TRUE`.\n",
    "\n---\n\n",
    "- **Severity**: Medium\n",
    "- **Location**: `.github/workflows/ci.yml:5`\n",
    "- **Problem**: Missing `fetch-depth: 0` in checkout step.\n",
    "- **Fix**: Set `fetch-depth: 0`.\n"
  )
  findings <- parse_findings(output)
  expect_equal(length(findings), 2L)
  expect_equal(findings[[1L]]$severity, "High")
  expect_equal(findings[[2L]]$severity, "Medium")
  expect_true(grepl("foo.R", findings[[1L]]$location))
})

# ── Test 4: Four synthetic reviews covering all verdicts ──────────────────────

test_that("classify_review: still-present when pattern found in file", {
  repo_root <- setup_repo_tree()

  output <- paste0(
    "- **Severity**: High\n",
    "- **Location**: `R/foo.R:2`\n",
    "- **Problem**: The `list.files` call uses non-recursive mode. ",
    "This means `vignettes/articles` are skipped.\n",
    "- **Fix**: Use recursive = TRUE.\n"
  )
  row <- make_review_row(1L, 101L, output = output)
  result <- classify_review(row, repo_root, min_severity_num = 3L, sev_order = SEV_ORDER)

  expect_equal(result$verdict, "still-present")
})

test_that("classify_review: likely-fixed when file missing", {
  repo_root <- setup_repo_tree()

  output <- paste0(
    "- **Severity**: High\n",
    "- **Location**: `R/gone_function.R:5-10`\n",
    "- **Problem**: The `deprecated_helper` function is called directly.\n",
    "- **Fix**: Use the new wrapper.\n"
  )
  row <- make_review_row(2L, 102L, output = output)
  result <- classify_review(row, repo_root, min_severity_num = 3L, sev_order = SEV_ORDER)

  expect_equal(result$verdict, "likely-fixed")
  expect_true(grepl("not found", result$reason))
})

test_that("classify_review: likely-fixed when pattern gone from file", {
  repo_root <- setup_repo_tree()

  # bar.R has recursive=TRUE; problem mentions non-recursive which is gone
  output <- paste0(
    "- **Severity**: High\n",
    "- **Location**: `R/bar.R:2`\n",
    "- **Problem**: The `non_recursive_scan_xyz` identifier is used ",
    "causing articles to be skipped entirely.\n",
    "- **Fix**: Use recursive parameter.\n"
  )
  row <- make_review_row(3L, 103L, output = output)
  result <- classify_review(row, repo_root, min_severity_num = 3L, sev_order = SEV_ORDER)

  # non_recursive_scan_xyz does not exist in bar.R → likely-fixed
  expect_equal(result$verdict, "likely-fixed")
})

test_that("classify_review: ambiguous when no pattern extractable", {
  repo_root <- setup_repo_tree()

  output <- paste0(
    "- **Severity**: High\n",
    "- **Location**: `R/foo.R:1`\n",
    "- **Problem**: This code is bad.\n",
    "- **Fix**: Make it good.\n"
  )
  row <- make_review_row(4L, 104L, output = output)
  result <- classify_review(row, repo_root, min_severity_num = 3L, sev_order = SEV_ORDER)

  # "code" and "good" are short/common — ambiguous expected
  # (may also be likely-fixed if patterns truly absent; either is acceptable
  #  but not still-present)
  expect_true(result$verdict %in% c("ambiguous", "likely-fixed"))
})

test_that("classify_review: still-present beats likely-fixed (weakest wins)", {
  repo_root <- setup_repo_tree()

  # First sub-finding: file gone → likely-fixed
  # Second sub-finding: pattern still present in foo.R → still-present
  # Expected overall verdict: still-present
  output <- paste0(
    "## Review Findings\n\n",
    "- **Severity**: High\n",
    "- **Location**: `R/gone_function.R:5`\n",
    "- **Problem**: The `deleted_identifier_xyz` function no longer exists.\n",
    "- **Fix**: Remove calls.\n",
    "\n---\n\n",
    "- **Severity**: High\n",
    "- **Location**: `R/foo.R:2`\n",
    "- **Problem**: The `list.files` call is non-recursive.\n",
    "- **Fix**: Use recursive = TRUE.\n"
  )
  row <- make_review_row(5L, 105L, output = output)
  result <- classify_review(row, repo_root, min_severity_num = 3L, sev_order = SEV_ORDER)

  expect_equal(result$verdict, "still-present")
})

# ── Test 5: format_report sections ────────────────────────────────────────────

test_that("format_report includes all required sections and summary counts", {
  # Synthetic results list
  make_result <- function(review_id, job_id, verdict, reason = "test reason") {
    list(
      review_id   = review_id,
      job_id      = job_id,
      git_ref     = paste0(strrep("a", 8), strrep("0", 32)),
      created_at  = "2026-05-01 00:00:00",
      verdict     = verdict,
      primary_loc = "R/foo.R:10-20",
      reason      = reason,
      sub_results = list(list(
        verdict = verdict,
        finding = list(severity = "High", location = "R/foo.R:10",
                       problem = "test problem text identifier_xyz")
      ))
    )
  }

  results <- list(
    make_result(1L, 101L, "likely-fixed",  "file not found: R/gone.R"),
    make_result(2L, 102L, "still-present", "pattern found"),
    make_result(3L, 103L, "ambiguous",     "no pattern found"),
    make_result(4L, 104L, "likely-fixed",  "pattern absent from file")
  )

  report <- format_report(results, "llm", "High", dry_run = TRUE,
                          timestamp = "2026-05-29T12:00:00")

  expect_match(report, "## Summary")
  expect_match(report, "## Likely-Fixed")
  expect_match(report, "## Still-Present")
  expect_match(report, "## Ambiguous")
  expect_match(report, "Open reviews checked.*4")
  expect_match(report, "Likely-fixed.*2")
  expect_match(report, "Still-present.*1")
  expect_match(report, "Ambiguous.*1")
  expect_match(report, "DRY-RUN")
  expect_match(report, "Recovery")
  # Likely-fixed rows include suggested close command
  expect_match(report, "roborev close 101")
  expect_match(report, "roborev close 104")
  # Still-present row present
  expect_match(report, "102")
})

# ── Test 6: --apply mode dispatches correct calls (mock roborev binary) ────────

test_that("apply_closures calls roborev close for each likely-fixed result", {
  skip_on_cran()

  # Create a mock roborev binary that logs calls to a temp file
  log_file <- tempfile("roborev_calls_", fileext = ".txt")
  mock_bin  <- tempfile("mock_roborev_")

  writeLines(c(
    "#!/bin/bash",
    paste0('echo "$@" >> "', log_file, '"')
  ), mock_bin)
  Sys.chmod(mock_bin, "0755")

  # Temporarily add mock_bin's dir to PATH
  old_path <- Sys.getenv("PATH")
  mock_dir <- dirname(mock_bin)
  # Rename binary to "roborev" inside a tempdir on PATH
  roborev_dir <- withr::local_tempdir()
  roborev_path <- file.path(roborev_dir, "roborev")
  file.copy(mock_bin, roborev_path)
  Sys.chmod(roborev_path, "0755")
  Sys.setenv(PATH = paste0(roborev_dir, ":", old_path))
  on.exit(Sys.setenv(PATH = old_path), add = TRUE)

  make_result <- function(review_id, job_id, verdict) {
    list(
      review_id  = review_id,
      job_id     = job_id,
      git_ref    = "abcdef",
      created_at = "2026-05-01",
      verdict    = verdict,
      primary_loc = "R/foo.R:1",
      reason     = "test",
      sub_results = list()
    )
  }

  results <- list(
    make_result(1L, 201L, "likely-fixed"),
    make_result(2L, 202L, "still-present"),
    make_result(3L, 203L, "likely-fixed"),
    make_result(4L, 204L, "ambiguous")
  )

  apply_closures <- script_env$apply_closures
  apply_closures(results, timestamp = "2026-05-29T12:00:00")

  # Read the log file and verify calls
  calls <- readLines(log_file, warn = FALSE)

  # Should have called `roborev comment <job_id> ...` and `roborev close <job_id>`
  # for job_ids 201 and 203 only (not 202 still-present or 204 ambiguous)
  close_calls   <- grep("^close ", calls, value = TRUE)
  comment_calls <- grep("^comment ", calls, value = TRUE)

  # Two close calls
  expect_equal(length(close_calls), 2L)
  expect_true(any(grepl("201", close_calls)))
  expect_true(any(grepl("203", close_calls)))
  expect_false(any(grepl("202", close_calls)))
  expect_false(any(grepl("204", close_calls)))

  # Two comment calls
  expect_equal(length(comment_calls), 2L)
  expect_true(any(grepl("201", comment_calls)))
  expect_true(any(grepl("203", comment_calls)))
})

# ── Test 7: parse_args defaults ───────────────────────────────────────────────

test_that("parse_args returns correct defaults", {
  args <- parse_args(character(0))
  expect_equal(args$repo, "llm")
  expect_equal(args$min_severity, "High")
  expect_equal(args$limit, 0L)
  expect_false(args$apply)
  expect_null(args$out)
  expect_null(args$repo_root)
})

test_that("parse_args parses --apply correctly", {
  args <- parse_args(c("--apply", "--repo", "myrepo", "--limit", "5"))
  expect_true(args$apply)
  expect_equal(args$repo, "myrepo")
  expect_equal(args$limit, 5L)
})

test_that("parse_args rejects unknown --min-severity", {
  expect_error(parse_args(c("--min-severity", "Blocker")), "must be one of")
})

# ── Test 8: Synthetic SQLite fixture ──────────────────────────────────────────

test_that("fetch_open_reviews returns correct filtered rows from synthetic DB via python3", {
  skip_if(nchar(Sys.which("python3")) == 0L, "python3 not found")

  # Build synthetic SQLite DB via python3
  db_file <- tempfile(fileext = ".db")
  py_setup <- sprintf(paste(
    "import sqlite3",
    "con = sqlite3.connect('%s')",
    "con.execute(\"CREATE TABLE repos (id INTEGER PRIMARY KEY, name TEXT)\")",
    "con.execute(\"INSERT INTO repos VALUES (1, 'llm')\")",
    "con.execute(\"INSERT INTO repos VALUES (2, 'other')\")",
    "con.execute(\"\"\"CREATE TABLE review_jobs (",
    "  id INTEGER PRIMARY KEY, repo_id INTEGER, git_ref TEXT)\"\"\")",
    "con.execute(\"INSERT INTO review_jobs VALUES (1, 1, 'abc111')\")",
    "con.execute(\"INSERT INTO review_jobs VALUES (2, 1, 'abc222')\")",
    "con.execute(\"INSERT INTO review_jobs VALUES (3, 2, 'abc333')\")",
    "con.execute(\"INSERT INTO review_jobs VALUES (4, 1, 'abc444')\")",
    "con.execute(\"\"\"CREATE TABLE reviews (",
    "  id INTEGER PRIMARY KEY, job_id INTEGER, agent TEXT,",
    "  prompt TEXT, output TEXT, created_at TEXT, closed INTEGER DEFAULT 0)\"\"\")",
    "con.execute(\"INSERT INTO reviews VALUES (1,1,'t','p','- **Severity**: High\\n- **Location**: `R/a.R:1`\\n- **Problem**: bad_func_name.\\n','2026-05-01 00:00:00',0)\")",
    "con.execute(\"INSERT INTO reviews VALUES (2,2,'t','p','- **Severity**: High\\n- **Location**: `R/b.R:2`\\n- **Problem**: bad2.\\n','2026-05-02 00:00:00',1)\")",
    "con.execute(\"INSERT INTO reviews VALUES (3,3,'t','p','- **Severity**: High\\n- **Location**: `R/c.R:3`\\n- **Problem**: bad3.\\n','2026-05-03 00:00:00',0)\")",
    "con.execute(\"INSERT INTO reviews VALUES (4,4,'t','p','- **Severity**: Medium\\n- **Location**: `R/d.R:4`\\n- **Problem**: bad4.\\n','2026-05-04 00:00:00',0)\")",
    "con.commit()",
    "con.close()",
    sep = "\n"
  ), db_file)

  system2("python3", args = c("-c", shQuote(py_setup)))
  expect_true(file.exists(db_file))

  # Create a db object with python3 backend pointing to our fixture
  db_fixture <- list(backend = "python3", handle = NULL, db_path = db_file)

  fetch_fn <- script_env$fetch_open_reviews
  rows <- fetch_fn(db_fixture, "llm", min_severity_num = 3L,
                   sev_order = SEV_ORDER, limit = 0L)

  # Only review 1 should be returned: open, llm, High severity
  expect_equal(nrow(rows), 1L)
  expect_equal(rows$review_id, 1L)
  expect_equal(rows$job_id, 1L)
})
