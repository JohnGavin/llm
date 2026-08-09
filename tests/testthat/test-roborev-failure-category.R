# test-roborev-failure-category.R — classify_failure() from roborev_metrics_etl.R (llm#928)
#
# The ETL is a standalone Rscript, not a package function, so the classifier is
# extracted by parsing the file and evaluating just that one assignment. This
# keeps the test honest: it exercises the code that actually ships, rather than
# a copy that can drift.

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

load_classifier <- function() {
  p <- etl_path()
  skip_if_not(nzchar(p) && file.exists(p), "roborev_metrics_etl.R not found")
  env <- new.env(parent = globalenv())
  exprs <- parse(p)
  found <- FALSE
  for (x in exprs) {
    if (is.call(x) && identical(as.character(x[[1]]), "<-") &&
        identical(as.character(x[[2]]), "classify_failure")) {
      eval(x, env); found <- TRUE
    }
  }
  skip_if_not(found, "classify_failure() not found in roborev_metrics_etl.R")
  env$classify_failure
}

test_that("failed jobs are categorised and non-failed jobs are NA", {
  cf <- load_classifier()

  # Non-failed statuses must never acquire a category, even when an error
  # string is present (a retried job can carry a stale error).
  expect_true(is.na(cf("done",   NA)))
  expect_true(is.na(cf("done",   "agent: something went wrong")))
  expect_true(is.na(cf("queued", NA)))

  # A failed job always gets a category, never NA — that is what makes
  # jobs_failed reconcilable against the source count.
  expect_false(is.na(cf("failed", NA)))
})

test_that("the four categories match real error strings", {
  cf <- load_classifier()

  # Verbatim shapes taken from ~/.roborev/reviews.db (llm#923 / llm#927).
  expect_equal(
    cf("failed", "build prompt: get commit info: git log: chdir /private/tmp/nix-shell-12159-0/RtmpgJFwZN/config_digest_git_fixture_x: no such file or directory"),
    "ephemeral"
  )
  expect_equal(
    cf("failed", "build prompt: get commit info: git log: chdir /private/var/folders/hn/T/tmp.A7TY377RFq: no such file or directory"),
    "ephemeral"
  )
  expect_equal(
    cf("failed", "agent: claude-code failed stream: stream errors: You've hit your monthly spend limit · raise it at claude.ai/settings/usage: exit status 1"),
    "quota"
  )
  expect_equal(
    cf("failed", "agent: gemini failed stream: stream errors: panic: runtime error"),
    "agent"
  )
  expect_equal(cf("failed", "something entirely unrecognised"), "other")
})

test_that("precedence holds — quota beats agent, ephemeral beats both", {
  cf <- load_classifier()

  # The real quota string contains BOTH "agent:" and "stream error", so without
  # ordering it would be filed as an agent failure — which is exactly the
  # misclassification llm#904 reports (quota counted as a crash, dragging
  # claude-code's pass rate to 0.14 on billing state rather than quality).
  expect_equal(
    cf("failed", "agent: claude-code failed stream: stream errors: You've hit your monthly spend limit"),
    "quota"
  )
  # A deleted-tempdir failure is not roborev's failure at all.
  expect_equal(cf("failed", "agent: x failed: chdir /tmp/foo: no such file"), "ephemeral")
})

test_that("vectorised over rows, and handles empty input", {
  cf <- load_classifier()

  expect_equal(
    cf(c("failed", "done", "failed", "failed"),
       c("chdir /tmp/x", NA, "monthly spend limit", "totally unknown")),
    c("ephemeral", NA, "quota", "other")
  )
  expect_length(cf(character(0), character(0)), 0L)
  # A NULL/absent error column degrades to "other", never to an error.
  expect_equal(cf("failed", NA_character_), "other")
})

test_that("snapshot: the category vocabulary is stable", {
  cf <- load_classifier()
  errs <- c(
    "build prompt: get commit info: git log: chdir /private/tmp/x: no such file or directory",
    "agent: claude-code failed stream: stream errors: You've hit your monthly spend limit",
    "agent: gemini failed stream: stream errors: panic: runtime error",
    "fork/exec /opt/homebrew/bin/git: no such file or directory"
  )
  expect_snapshot(print(cf(rep("failed", length(errs)), errs)))
})
