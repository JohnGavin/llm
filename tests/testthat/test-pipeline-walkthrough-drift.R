# tests/testthat/test-pipeline-walkthrough-drift.R
#
# Tests for check_pipeline_walkthrough_drift() / abort_on_pipeline_walkthrough_drift()
# (R/pipeline_walkthrough_drift.R), which validates the hand-typed `plan`
# column in vig_cr_pipeline_walkthrough (plan_vignette_closeread.R target 6)
# against a real irishbuoys/R/tar_plans checkout. llm#793 item 1.

test_that("check_pipeline_walkthrough_drift reports INDETERMINATE when the directory is absent", {
  missing_dir <- file.path(tempdir(), "definitely-does-not-exist-irishbuoys-plans")

  result <- check_pipeline_walkthrough_drift(
    documented_plans = c("plan_a", "plan_b"),
    irishbuoys_plans_dir = missing_dir
  )

  expect_equal(result$status, "INDETERMINATE")
  expect_equal(result$checked_dir, missing_dir)
  expect_true(is.character(result$reason) && nzchar(result$reason))  # a real reason string, not NA
  expect_equal(result$missing_from_doc, character(0L))
  expect_equal(result$stale_in_doc, character(0L))
})

test_that("check_pipeline_walkthrough_drift reports MATCHED when the file list agrees", {
  fixture_dir <- withr::local_tempdir()
  file.create(file.path(fixture_dir, c("plan_a.R", "plan_b.R", "plan_c.R")))

  result <- check_pipeline_walkthrough_drift(
    documented_plans = c("plan_a", "plan_b", "plan_c"),
    irishbuoys_plans_dir = fixture_dir
  )

  expect_equal(result$status, "MATCHED")
  expect_true(is.na(result$reason))
  expect_equal(result$missing_from_doc, character(0L))
  expect_equal(result$stale_in_doc, character(0L))
})

test_that("check_pipeline_walkthrough_drift reports DRIFTED on a mismatched file list", {
  fixture_dir <- withr::local_tempdir()
  # Real files: plan_a, plan_b, plan_new (plan_new is undocumented)
  # Documented: plan_a, plan_b, plan_removed (plan_removed no longer exists)
  file.create(file.path(fixture_dir, c("plan_a.R", "plan_b.R", "plan_new.R")))

  result <- check_pipeline_walkthrough_drift(
    documented_plans = c("plan_a", "plan_b", "plan_removed"),
    irishbuoys_plans_dir = fixture_dir
  )

  expect_equal(result$status, "DRIFTED")
  expect_true(is.na(result$reason))
  expect_equal(result$missing_from_doc, "plan_new")
  expect_equal(result$stale_in_doc, "plan_removed")
})

test_that("check_pipeline_walkthrough_drift ignores non-.R files in the directory", {
  fixture_dir <- withr::local_tempdir()
  file.create(file.path(fixture_dir, c("plan_a.R", "README.md", "notes.txt")))

  result <- check_pipeline_walkthrough_drift(
    documented_plans = c("plan_a"),
    irishbuoys_plans_dir = fixture_dir
  )

  expect_equal(result$status, "MATCHED")
})

test_that("check_pipeline_walkthrough_drift validates its inputs", {
  fixture_dir <- withr::local_tempdir()
  expect_error(
    check_pipeline_walkthrough_drift(character(0L), fixture_dir),
    class = "simpleError"
  )
  expect_error(
    check_pipeline_walkthrough_drift(c("plan_a"), 123),
    class = "simpleError"
  )
})

# ── abort_on_pipeline_walkthrough_drift() ─────────────────────────────────

test_that("abort_on_pipeline_walkthrough_drift is silent and passthrough on MATCHED", {
  matched <- list(
    status = "MATCHED", checked_dir = "/some/dir", reason = NA_character_,
    missing_from_doc = character(0L), stale_in_doc = character(0L)
  )
  expect_no_message(result <- abort_on_pipeline_walkthrough_drift(matched))
  expect_identical(result, matched)
})

test_that("abort_on_pipeline_walkthrough_drift informs (does not abort) on INDETERMINATE", {
  indeterminate <- list(
    status = "INDETERMINATE", checked_dir = "/missing/dir",
    reason = "irishbuoys checkout not found — comparison not performed",
    missing_from_doc = character(0L), stale_in_doc = character(0L)
  )
  expect_message(
    result <- abort_on_pipeline_walkthrough_drift(indeterminate),
    "INDETERMINATE"
  )
  expect_identical(result, indeterminate)
})

test_that("abort_on_pipeline_walkthrough_drift aborts loudly on DRIFTED", {
  drifted <- list(
    status = "DRIFTED", checked_dir = "/some/dir", reason = NA_character_,
    missing_from_doc = "plan_new", stale_in_doc = "plan_removed"
  )
  expect_error(
    abort_on_pipeline_walkthrough_drift(drifted),
    "drifted"
  )
})

test_that("end-to-end: a real drift is caught and reported, and INDETERMINATE never masquerades as MATCHED", {
  # Falsification check for llm#793 item 1's core requirement: a mismatched
  # file list must produce a DRIFTED verdict (checked above), and a missing
  # directory must NEVER produce MATCHED.
  fixture_dir <- withr::local_tempdir()
  file.create(file.path(fixture_dir, "plan_only_here.R"))

  drifted_result <- check_pipeline_walkthrough_drift(
    documented_plans = "plan_only_in_docs",
    irishbuoys_plans_dir = fixture_dir
  )
  expect_error(abort_on_pipeline_walkthrough_drift(drifted_result))

  missing_dir_result <- check_pipeline_walkthrough_drift(
    documented_plans = "plan_only_in_docs",
    irishbuoys_plans_dir = file.path(tempdir(), "still-does-not-exist")
  )
  expect_false(identical(missing_dir_result$status, "MATCHED"))
  expect_equal(missing_dir_result$status, "INDETERMINATE")
})
