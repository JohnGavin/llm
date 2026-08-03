## Guard vig_snapshot_action() (R/vig_snapshot.R), the decision helper behind
## data-raw/export_vignette_snapshots.R's write/skip/refuse logic. #879
## relaxed the original guard to let a brand-new target's first NULL build
## get written as its snapshot; that shipped a real defect (a NULL
## vig_codexbar_project_cost_plot.rds rendered a blank chart, #877). The
## qa_no_nulls gate (#881) now treats ANY NULL vig_* value as a P0 failure,
## so this helper must NEVER return an action that results in a NULL
## snapshot being written -- these tests pin that contract down.

test_that("returns 'write' when obj is non-NULL, regardless of snapshot state", {
  tmp <- withr::local_tempdir()
  rds <- file.path(tmp, "vig_a.rds")

  # No snapshot file at all yet.
  expect_identical(vig_snapshot_action(data.frame(x = 1), rds), "write")

  # Existing non-NULL snapshot -- still "write", caller overwrites with the
  # fresh non-NULL value.
  saveRDS(data.frame(x = 0), rds)
  expect_identical(vig_snapshot_action(list(y = 2), rds), "write")

  # Existing NULL snapshot -- still "write", a real value supersedes it.
  saveRDS(NULL, rds)
  expect_identical(vig_snapshot_action("real value", rds), "write")
})

test_that("returns 'skip' when obj is NULL but the snapshot holds real data", {
  tmp <- withr::local_tempdir()
  rds <- file.path(tmp, "vig_b.rds")
  saveRDS(data.frame(x = 1), rds)

  expect_identical(vig_snapshot_action(NULL, rds), "skip")
})

test_that("returns 'refuse' when obj is NULL and no snapshot file exists", {
  tmp <- withr::local_tempdir()
  rds <- file.path(tmp, "vig_c.rds")  # never created

  expect_identical(vig_snapshot_action(NULL, rds), "refuse")
})

test_that("returns 'refuse' when obj is NULL and the existing snapshot is itself NULL", {
  tmp <- withr::local_tempdir()
  rds <- file.path(tmp, "vig_d.rds")
  saveRDS(NULL, rds)

  expect_identical(vig_snapshot_action(NULL, rds), "refuse")
})

test_that("never returns an action that writes NULL over nothing or over NULL", {
  # Property check across the two NULL-obj branches: 'refuse' is the only
  # possible outcome when there is no non-NULL value anywhere to protect.
  tmp <- withr::local_tempdir()

  no_snapshot <- file.path(tmp, "vig_e.rds")
  expect_identical(vig_snapshot_action(NULL, no_snapshot), "refuse")

  null_snapshot <- file.path(tmp, "vig_f.rds")
  saveRDS(NULL, null_snapshot)
  expect_identical(vig_snapshot_action(NULL, null_snapshot), "refuse")
})
