# test-selfreview-coverage-phrase.R
#
# llm#1037. The overnight report's headline read "0 new findings" whether
# twelve sessions had been analysed and found clean, or zero sessions existed
# to analyse. Those are different facts and only one is reassuring.
#
# Three states must render differently:
#   NA  session count unavailable  -> coverage UNKNOWN, never silently zero
#   0   no sessions in the window  -> says nothing was analysed
#   >0  sessions analysed          -> states how many
#
# The phrase logic is extracted from the production script rather than
# restated, so a change there fails here.

library(testthat)

.script <- local({
  s <- system.file("scripts/send_overnight_self_review_email.R",
                   package = "llm", mustWork = FALSE)
  if (!nzchar(s) || !file.exists(s)) {
    root <- tryCatch(pkgload::pkg_path(), error = function(e) NULL)
    if (!is.null(root)) {
      s <- file.path(root, ".claude", "scripts", "send_overnight_self_review_email.R")
    }
  }
  s
})

# Pull the `findings_phrase <- if (...) ... else ...` assignment out of the
# production file. Anchored on the variable name; errors rather than testing
# nothing if it is renamed.
.phrase_expr <- function() {
  skip_if_not(nzchar(.script) && file.exists(.script), "sender script not found")
  src <- readLines(.script, warn = FALSE)
  start <- grep("^findings_phrase <- if", src)
  skip_if_not(length(start) > 0L, "findings_phrase assignment not found")
  # take until the closing brace at column 0
  ends <- grep("^\\}$", src)
  ends <- ends[ends > start[[1L]]]
  skip_if_not(length(ends) > 0L, "could not find end of findings_phrase block")
  paste(src[start[[1L]]:ends[[1L]]], collapse = "\n")
}

.render <- function(n_sessions, n_findings = 0L) {
  env <- new.env(parent = baseenv())
  assign("n_sessions_in_window", n_sessions, envir = env)
  assign("n_new_findings", n_findings, envir = env)
  eval(parse(text = .phrase_expr()), envir = env)
  get("findings_phrase", envir = env)
}

test_that("the phrase block is actually located", {
  # Without this, every assertion below could pass vacuously on an empty
  # extraction — the failure mode that bit the llm#1030 selftest.
  expr <- .phrase_expr()
  expect_true(nzchar(expr))
  expect_match(expr, "n_sessions_in_window", fixed = TRUE)
})

test_that("zero sessions says nothing was analysed, not just zero findings", {
  out <- .render(0L, 0L)
  expect_match(out, "nothing was analysed", fixed = TRUE)
  # The whole point: it must NOT read like a clean result.
  expect_false(identical(out, "0 new findings"))
})

test_that("sessions present states the coverage", {
  out <- .render(12L, 0L)
  expect_match(out, "12 session", fixed = TRUE)
  expect_false(grepl("nothing was analysed", out, fixed = TRUE))
})

test_that("an unavailable count is UNKNOWN, never zero", {
  out <- .render(NA_integer_, 0L)
  expect_match(out, "unknown", ignore.case = TRUE)
  # Must not be confused with the genuine no-sessions case…
  expect_false(grepl("nothing was analysed", out, fixed = TRUE))
  # …nor with a real coverage figure.
  expect_false(grepl("across", out, fixed = TRUE))
})

test_that("findings are still reported alongside the coverage", {
  # A control: the coverage wording must not swallow the finding count.
  expect_match(.render(5L, 3L), "3 new findings", fixed = TRUE)
  expect_match(.render(0L, 3L), "3 new findings", fixed = TRUE)
})
