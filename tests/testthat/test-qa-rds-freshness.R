## Guard against the #859/#860 failure mode: pipeline source fixed and merged,
## CI green, but the deployed vignettes keep rendering stale committed
## vig_*.rds snapshots because nothing compared target build time to snapshot
## mtime.

# R/tar_plans/ is a subdirectory of R/, so it is NOT collated into the package
# namespace — only tar_source() loads it. Source it directly, as
# test-plan-qa-gates.R does.
source(file.path(pkgload::pkg_path(), "R", "tar_plans", "plan_qa_gates.R"))

# Build a fake targets store whose tar_meta() reports `built_at` for `targets`,
# alongside a snapshot dir whose .rds files carry `snapshot_at` mtimes.
local_fixture <- function(targets, built_at, snapshot_at, env = parent.frame()) {
  store <- withr::local_tempdir(.local_envir = env)
  snaps <- withr::local_tempdir(.local_envir = env)

  for (i in seq_along(targets)) {
    if (is.na(snapshot_at[i])) next
    f <- file.path(snaps, paste0(targets[i], ".rds"))
    saveRDS(list(x = 1), f)
    Sys.setFileTime(f, snapshot_at[i])
  }

  meta <- data.frame(name = targets, time = built_at, stringsAsFactors = FALSE)
  # .local_envir = env is load-bearing: without it the mock unwinds when this
  # helper returns, the real tar_meta() runs against an empty store, and every
  # test passes for the wrong reason.
  local_mocked_bindings(
    tar_meta = function(...) meta, .package = "targets", .env = env
  )

  list(store = store, snaps = snaps)
}

test_that("passes when every snapshot is newer than its target", {
  now <- Sys.time()
  fx <- local_fixture(
    targets     = c("vig_a", "vig_b"),
    built_at    = c(now - 3600, now - 3600),
    snapshot_at = c(now, now)
  )

  expect_no_error(
    check_rds_freshness(store = fx$store, snapshot_dir = fx$snaps)
  )
})

test_that("aborts when a target is newer than its snapshot (the #860 case)", {
  now <- Sys.time()
  fx <- local_fixture(
    targets     = c("vig_fresh", "vig_stale"),
    built_at    = c(now - 3600, now),
    snapshot_at = c(now, now - 86400)   # vig_stale's snapshot is a day old
  )

  expect_error(
    check_rds_freshness(store = fx$store, snapshot_dir = fx$snaps),
    regexp = "vig_stale"
  )
})

test_that("aborts when a built target has no committed snapshot", {
  now <- Sys.time()
  fx <- local_fixture(
    targets     = c("vig_a", "vig_orphan"),
    built_at    = c(now, now),
    snapshot_at = c(now, NA)            # vig_orphan never exported
  )

  expect_error(
    check_rds_freshness(store = fx$store, snapshot_dir = fx$snaps),
    regexp = "vig_orphan"
  )
})

test_that("tolerance absorbs sub-minute export lag", {
  now <- Sys.time()
  # Snapshot written 5s before the target's recorded build time — an artifact
  # of export ordering, not staleness.
  fx <- local_fixture(
    targets     = "vig_a",
    built_at    = now,
    snapshot_at = now - 5
  )

  expect_no_error(
    check_rds_freshness(store = fx$store, snapshot_dir = fx$snaps, tolerance_sec = 60)
  )
})

test_that("skips quietly when there is no store or no snapshot dir", {
  # On a fresh clone with no _targets store the gate must not fail the build.
  expect_null(check_rds_freshness(store = tempfile(), snapshot_dir = tempfile()))
})

test_that("ignores non-vig_ targets", {
  now <- Sys.time()
  store <- withr::local_tempdir()
  snaps <- withr::local_tempdir()
  meta <- data.frame(
    name = c("pred_all_raw", "pkgdown_site"),
    time = c(now, now),
    stringsAsFactors = FALSE
  )
  local_mocked_bindings(tar_meta = function(...) meta, .package = "targets")
  dir.create(file.path(store, "meta"), recursive = TRUE, showWarnings = FALSE)

  # Neither is a vig_ target, so there is nothing to compare and no abort.
  expect_no_error(check_rds_freshness(store = store, snapshot_dir = snaps))
})
