## Guard the #881 Layer 2 gate: qa_no_degenerate_columns closes the concrete
## gap named by #921 -- a numeric column whose values have quietly stopped
## varying can still sum to a plausible-looking total, so `qa_no_nulls`
## (#881 Layer 1, non-NULL check) doesn't catch it. Worked incident: the
## dashboard's `duration_min` column was 99.6% one constant value for 12 days
## and nothing caught it.

# R/tar_plans/ is a subdirectory of R/, so it is NOT collated into the package
# namespace -- only tar_source() loads it. Source it directly, as
# test-qa-no-nulls.R and test-qa-rds-freshness.R do.
#
# locate_tar_plan() (helper-0-locate-tar-plan.R, auto-loaded) resolves via
# system.file() under a real install (inst/tar_plans/ symlink), with a
# dev-tree fallback -- plain pkgload::pkg_path() breaks under
# covr::package_coverage()/R CMD check, where R/tar_plans/*.R is never
# installed as browsable source.
.plan_qa_gates_path <- locate_tar_plan("plan_qa_gates.R")
if (!is.na(.plan_qa_gates_path)) {
  source(.plan_qa_gates_path)
}

# Build a fake targets store whose tar_meta()/tar_read_raw() report `values`
# for `targets` -- same mocking pattern as test-qa-no-nulls.R.
local_fixture <- function(targets, values, env = parent.frame()) {
  store <- withr::local_tempdir(.local_envir = env)
  names(values) <- targets

  meta <- data.frame(
    name = targets,
    time = rep(Sys.time(), length(targets)),
    stringsAsFactors = FALSE
  )

  # .env = env is load-bearing: without it the mock unwinds when this helper
  # returns, the real tar_meta()/tar_read_raw() run against an empty store,
  # and every test passes for the wrong reason (the exact bug that bit #872).
  local_mocked_bindings(
    tar_meta = function(...) meta, .package = "targets", .env = env
  )
  local_mocked_bindings(
    tar_read_raw = function(name, ...) values[[name]],
    .package = "targets", .env = env
  )

  store
}

test_that("passes when a numeric column has healthy variance", {
  store <- local_fixture(
    targets = "vig_session_metrics",
    values = list(vig_session_metrics = data.frame(
      duration_mins = c(5, 12, 8, 21, 3, 17, 9, 14, 6, 25)
    ))
  )

  expect_no_error(check_no_degenerate_columns(store = store))
})

test_that("aborts and names the target/column for a genuinely degenerate column", {
  # Reproduces the #921 incident: 99.6% one constant value -- here, 9/10
  # identical values (90%) is not quite enough at the default 0.95 threshold,
  # so use a clearer 19/20 (95%) case to cross it unambiguously.
  degenerate_values <- c(rep(120, 19), 45)
  store <- local_fixture(
    targets = "vig_session_metrics",
    values = list(vig_session_metrics = data.frame(duration_mins = degenerate_values))
  )

  expect_error(
    check_no_degenerate_columns(store = store),
    regexp = "vig_session_metrics.*duration_mins"
  )
})

test_that("reports INDETERMINATE, not OK or an error, when too few non-NA values exist", {
  store <- local_fixture(
    targets = "vig_session_metrics",
    values = list(vig_session_metrics = data.frame(duration_mins = c(5, NA, NA)))
  )

  expect_no_error(check_no_degenerate_columns(store = store, min_n = 5L))
  expect_message(
    check_no_degenerate_columns(store = store, min_n = 5L),
    regexp = "INDETERMINATE"
  )
})

test_that("reports INDETERMINATE for an all-NA column rather than treating it as healthy", {
  store <- local_fixture(
    targets = "vig_session_metrics",
    values = list(vig_session_metrics = data.frame(duration_mins = c(NA_real_, NA_real_, NA_real_)))
  )

  result <- suppressMessages(check_no_degenerate_columns(store = store, min_n = 1L))
  expect_identical(result$status, "INDETERMINATE")
})

test_that("skips quietly when there is no targets store", {
  expect_null(check_no_degenerate_columns(store = tempfile()))
})

test_that("skips quietly when there are no built vig_* targets", {
  store <- local_fixture(
    targets = "pred_all_raw",
    values = list(pred_all_raw = data.frame(x = 1))
  )

  expect_null(check_no_degenerate_columns(store = store))
})

test_that("ignores non-vig_ targets even when their columns are degenerate", {
  store <- local_fixture(
    targets = c("vig_a", "pred_all_raw"),
    values = list(
      vig_a = data.frame(x = c(1, 2, 3, 4, 5, 6, 7, 8, 9, 10)),
      pred_all_raw = data.frame(y = rep(1, 20))
    )
  )

  result <- check_no_degenerate_columns(store = store)
  expect_false("pred_all_raw" %in% result$target)
})

test_that("skips a NULL vig_* target rather than flagging it INDETERMINATE", {
  store <- local_fixture(
    targets = c("vig_ok", "vig_null"),
    values = list(
      vig_ok = data.frame(x = c(1, 2, 3, 4, 5, 6, 7, 8, 9, 10)),
      vig_null = NULL
    )
  )

  result <- check_no_degenerate_columns(store = store)
  expect_false("vig_null" %in% result$target)
})

test_that("skips a non-data-frame vig_* target (e.g. a plot or status string)", {
  store <- local_fixture(
    targets = c("vig_ok", "vig_plot"),
    values = list(
      vig_ok = data.frame(x = c(1, 2, 3, 4, 5, 6, 7, 8, 9, 10)),
      vig_plot = "ok"
    )
  )

  result <- check_no_degenerate_columns(store = store)
  expect_false("vig_plot" %in% result$target)
})

test_that("ignores non-numeric columns", {
  store <- local_fixture(
    targets = "vig_a",
    values = list(vig_a = data.frame(
      x = c(1, 2, 3, 4, 5, 6, 7, 8, 9, 10),
      label = rep("same", 10),
      stringsAsFactors = FALSE
    ))
  )

  result <- check_no_degenerate_columns(store = store)
  expect_false("label" %in% result$column)
})

test_that("skip_columns excludes a named column from the check even when degenerate", {
  store <- local_fixture(
    targets = "vig_a",
    values = list(vig_a = data.frame(
      x = c(1, 2, 3, 4, 5, 6, 7, 8, 9, 10),
      flag = rep(1, 10)
    ))
  )

  expect_no_error(
    check_no_degenerate_columns(store = store, skip_columns = "flag")
  )
})
