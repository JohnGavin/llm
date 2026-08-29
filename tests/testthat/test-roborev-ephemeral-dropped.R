# test-roborev-ephemeral-dropped.R — is_ephemeral_repo_path() and
# is_job_dropped() from roborev_metrics_etl.R (llm#928 items 3-4).
#
# Same strategy as test-roborev-failure-category.R: the ETL is a standalone
# Rscript, not a package function, so each helper is extracted by parsing the
# file and evaluating just that one assignment. This exercises the code that
# actually ships, rather than a copy that can drift.

library(testthat)

etl_path <- function() {
  # tests/testthat/ -> repo root
  candidates <- c(
    file.path(testthat::test_path("..", ".."), ".claude", "scripts", "roborev_metrics_etl.R"),
    file.path(getwd(), ".claude", "scripts", "roborev_metrics_etl.R")
  )
  for (p in candidates) if (file.exists(p)) return(normalizePath(p))
  ""
}

# Loads `name` PLUS any of its top-level dependency constants (e.g.
# is_ephemeral_repo_path() reads the module-level EPHEMERAL_ROOT_PATTERN, not
# just its own arguments) into one shared env, and returns the `name` binding.
load_assignment <- function(name, also = character(0)) {
  p <- etl_path()
  skip_if_not(nzchar(p) && file.exists(p), "roborev_metrics_etl.R not found")
  env <- new.env(parent = globalenv())
  exprs <- parse(p)
  wanted <- c(name, also)
  found  <- setNames(rep(FALSE, length(wanted)), wanted)
  for (x in exprs) {
    if (is.call(x) && identical(as.character(x[[1]]), "<-") &&
        as.character(x[[2]]) %in% wanted) {
      eval(x, env)
      found[[as.character(x[[2]])]] <- TRUE
    }
  }
  skip_if_not(all(found), paste0(
    paste(names(found)[!found], collapse = ", "),
    " not found in roborev_metrics_etl.R"))
  env[[name]]
}

# ── is_ephemeral_repo_path() ────────────────────────────────────────────────

test_that("is_ephemeral_repo_path: temp-rooted paths are flagged TRUE", {
  fn <- load_assignment("is_ephemeral_repo_path", also = "EPHEMERAL_ROOT_PATTERN")

  expect_true(fn("/private/tmp/nix-shell-12159-0/RtmpgJFwZN/some_fixture"))
  expect_true(fn("/tmp/roborev_pmhook_test_XXXXXX"))
  expect_true(fn("/private/var/folders/hn/T/tmp.A7TY377RFq"))
  expect_true(fn("/var/folders/hn/xyz/T/some_worktree"))
})

test_that("is_ephemeral_repo_path: real repo paths are flagged FALSE", {
  fn <- load_assignment("is_ephemeral_repo_path", also = "EPHEMERAL_ROOT_PATTERN")

  expect_false(fn("/Users/johngavin/docs_gh/llm"))
  expect_false(fn("/Users/johngavin/docs_gh/worktrees/llm/feat/some-branch"))
  expect_false(fn("/home/ci/repo"))
})

test_that("is_ephemeral_repo_path: anchored at start — mid-path '/tmp/' does not match", {
  fn <- load_assignment("is_ephemeral_repo_path", also = "EPHEMERAL_ROOT_PATTERN")

  # A real repo whose path merely CONTAINS "/tmp/" below its root must not be
  # misclassified — root_path IS the path, unlike classify_failure()'s
  # unanchored match against free-text error strings.
  expect_false(fn("/Users/johngavin/docs_gh/tmp/not_actually_ephemeral"))
})

test_that("is_ephemeral_repo_path: NA and vectorised input handled", {
  fn <- load_assignment("is_ephemeral_repo_path", also = "EPHEMERAL_ROOT_PATTERN")

  expect_false(fn(NA_character_))
  expect_equal(
    fn(c("/tmp/x", "/Users/johngavin/docs_gh/llm", NA_character_, "/private/tmp/y")),
    c(TRUE, FALSE, FALSE, TRUE)
  )
  expect_equal(fn(character(0)), logical(0))
})

# ── is_job_dropped() ─────────────────────────────────────────────────────────

test_that("is_job_dropped: stale, no review, not failed -> dropped", {
  fn <- load_assignment("is_job_dropped")

  # An enqueued-but-never-completed job (still 'running', no review, and past
  # the staleness window) must be counted.
  expect_true(fn("running", FALSE, TRUE))
  expect_true(fn("queued", FALSE, TRUE))
})

test_that("is_job_dropped: a completed job (has a review) is never dropped", {
  fn <- load_assignment("is_job_dropped")

  expect_false(fn("done", TRUE, TRUE))
  expect_false(fn("running", TRUE, TRUE))  # review exists even if status lags
})

test_that("is_job_dropped: a failed job is not double-counted as dropped", {
  fn <- load_assignment("is_job_dropped")

  # status='failed' is already captured by jobs_failed_*; counting it again
  # here would double-count the same job under two metrics.
  expect_false(fn("failed", FALSE, TRUE))
})

test_that("is_job_dropped: not yet stale -> never dropped, even with no review", {
  fn <- load_assignment("is_job_dropped")

  # A job enqueued minutes ago that is still 'running' is legitimately in
  # flight, not dropped.
  expect_false(fn("running", FALSE, FALSE))
  expect_false(fn("queued", FALSE, FALSE))
})

test_that("is_job_dropped: vectorised over rows, and handles empty input", {
  fn <- load_assignment("is_job_dropped")

  expect_equal(
    fn(
      status      = c("running", "done",  "failed", "queued", "running"),
      has_review  = c(FALSE,     TRUE,    FALSE,    FALSE,    FALSE),
      is_stale    = c(TRUE,      TRUE,    TRUE,     TRUE,     FALSE)
    ),
    c(TRUE, FALSE, FALSE, TRUE, FALSE)
  )
  expect_length(fn(character(0), logical(0), logical(0)), 0L)
})

test_that("is_job_dropped: NA status is treated as not-failed (dropped if stale+no review)", {
  fn <- load_assignment("is_job_dropped")

  expect_true(fn(NA_character_, FALSE, TRUE))
})
