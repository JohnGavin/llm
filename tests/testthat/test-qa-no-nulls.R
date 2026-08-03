## Guard the #881 Layer 1 gate: qa_no_nulls was mandated by
## .claude/rules/qa-targets-pipeline.md but never implemented. It must catch
## the #869 failure mode -- an upstream input file disappears, the target
## silently returns NULL, and the committed snapshot masks it -- on BOTH the
## _targets store surface and the committed inst/extdata/vignettes/*.rds
## snapshot surface, since they have different causes and different fixes.

# R/tar_plans/ is a subdirectory of R/, so it is NOT collated into the package
# namespace -- only tar_source() loads it. Source it directly, as
# test-plan-qa-gates.R and test-qa-rds-freshness.R do.
source(file.path(pkgload::pkg_path(), "R", "tar_plans", "plan_qa_gates.R"))

# Build a fake targets store whose tar_meta()/tar_read_raw() report `values`
# for `targets`, alongside an optional snapshot dir holding committed .rds
# files with the given `snapshot_values` (a value of NULL_SENTINEL writes an
# actual NULL to the .rds; NA means "no snapshot file at all").
NULL_SENTINEL <- new.env()

local_fixture <- function(targets, values, snapshot_values = NULL,
                          make_snapshot_dir = TRUE, env = parent.frame()) {
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

  snaps <- NA_character_
  if (make_snapshot_dir) {
    snaps <- withr::local_tempdir(.local_envir = env)
    if (!is.null(snapshot_values)) {
      for (i in seq_along(targets)) {
        sv <- snapshot_values[[i]]
        f <- file.path(snaps, paste0(targets[i], ".rds"))
        if (identical(sv, NULL_SENTINEL)) {
          saveRDS(NULL, f)
        } else if (length(sv) == 1L && is.atomic(sv) && is.na(sv)) {
          next  # no snapshot file for this target
        } else {
          saveRDS(sv, f)
        }
      }
    }
  }

  list(store = store, snaps = snaps)
}

test_that("passes when every built target and snapshot is non-NULL", {
  fx <- local_fixture(
    targets = c("vig_a", "vig_b"),
    values = list(vig_a = data.frame(x = 1), vig_b = list(y = 2)),
    snapshot_values = list(data.frame(x = 1), list(y = 2))
  )

  expect_no_error(
    check_no_nulls(store = fx$store, snapshot_dir = fx$snaps)
  )
})

test_that("aborts and names the target when a built store value is NULL", {
  fx <- local_fixture(
    targets = c("vig_ok", "vig_broken"),
    values = list(vig_ok = data.frame(x = 1), vig_broken = NULL),
    snapshot_values = list(data.frame(x = 1), data.frame(x = 1))
  )

  expect_error(
    check_no_nulls(store = fx$store, snapshot_dir = fx$snaps),
    regexp = "vig_broken"
  )
})

test_that("aborts and names the target when a committed snapshot is NULL", {
  fx <- local_fixture(
    targets = c("vig_ok", "vig_stale_null"),
    values = list(vig_ok = data.frame(x = 1), vig_stale_null = data.frame(x = 1)),
    snapshot_values = list(data.frame(x = 1), NULL_SENTINEL)
  )

  expect_error(
    check_no_nulls(store = fx$store, snapshot_dir = fx$snaps),
    regexp = "vig_stale_null"
  )
})

test_that("skips quietly when there is no targets store", {
  # On a fresh clone with no _targets store the gate must not fail the build.
  expect_null(check_no_nulls(store = tempfile(), snapshot_dir = tempfile()))
})

test_that("skips quietly when there are no built vig_* targets", {
  fx <- local_fixture(
    targets = c("pred_all_raw", "pkgdown_site"),
    values = list(pred_all_raw = data.frame(x = 1), pkgdown_site = "ok")
  )

  expect_null(check_no_nulls(store = fx$store, snapshot_dir = fx$snaps))
})

test_that("ignores non-vig_ targets even when they are NULL", {
  fx <- local_fixture(
    targets = c("vig_a", "pred_all_raw"),
    values = list(vig_a = data.frame(x = 1), pred_all_raw = NULL),
    snapshot_values = list(data.frame(x = 1), NA)
  )

  expect_no_error(check_no_nulls(store = fx$store, snapshot_dir = fx$snaps))
})
