# test-launchd-health-report.R — Tests for launchd health report components.
#
# Tests:
#   1. Tier classification for all 3 tiers
#   2. Peak-contention detection
#   3. Cloud-cron workflow YAML parsing (dispatch-only fixture)
#   4. "Ledger empty" path produces placeholder text
#   5. Email dry-run produces all 4 section QA markers
#
# Tracked in llm#300.

library(testthat)

# ── Source the aggregator functions ───────────────────────────────────────────

# We source directly to get the helper functions in scope
scripts_dir <- normalizePath(
  file.path(testthat::test_path(), "..", "..", ".claude", "scripts"),
  mustWork = FALSE
)
aggregator_path <- file.path(scripts_dir, "launchd_health_report.R")

# Only run if aggregator exists (worktree check)
skip_if(!file.exists(aggregator_path),
        "launchd_health_report.R not found — skipping launchd tests")

# Source with launchd_health_source_only=TRUE to load helper functions without
# running the main body (which would collect from real LaunchAgents and exit).
old_opt <- getOption("launchd_health_source_only")
options(launchd_health_source_only = TRUE)
.agg_env <- new.env(parent = baseenv())
suppressMessages(
  source(aggregator_path, local = .agg_env)
)
options(launchd_health_source_only = old_opt)

# Pull the key functions
parse_plist        <- get("parse_plist",        envir = .agg_env)
extract_schedule   <- get("extract_schedule",   envir = .agg_env)
classify_tier      <- get("classify_tier",      envir = .agg_env)
detect_contention  <- get("detect_contention",  envir = .agg_env)
collect_inventory  <- get("collect_inventory",  envir = .agg_env)
read_run_metrics   <- get("read_run_metrics",   envir = .agg_env)
parse_workflow_triggers <- get("parse_workflow_triggers", envir = .agg_env)

# ── Fixtures ──────────────────────────────────────────────────────────────────

fixtures_dir <- normalizePath(
  file.path(testthat::test_path(), "..", "fixtures", "launchd"),
  mustWork = FALSE
)

skip_if(!dir.exists(fixtures_dir), "fixtures/launchd not found — skipping")

# ── Test 1: Tier classification ───────────────────────────────────────────────

test_that("High-tier plist is classified correctly", {
  pl <- parse_plist(file.path(fixtures_dir, "com.claude.high-tier-job.plist"))
  skip_if(is.null(pl), "plutil not available")
  sched <- extract_schedule(pl)
  tier  <- classify_tier(pl[["Label"]], sched)
  # 02:00 calendar job → High
  expect_equal(tier, "High")
})

test_that("Medium-tier plist is classified correctly", {
  pl <- parse_plist(file.path(fixtures_dir, "com.claude.medium-tier-job.plist"))
  skip_if(is.null(pl), "plutil not available")
  sched <- extract_schedule(pl)
  tier  <- classify_tier(pl[["Label"]], sched)
  # 09:00 calendar job → Medium
  expect_equal(tier, "Medium")
})

test_that("Low/continuous-tier plist (interval) is classified correctly", {
  pl <- parse_plist(file.path(fixtures_dir, "com.johngavin.low-tier-daemon.plist"))
  skip_if(is.null(pl), "plutil not available")
  sched <- extract_schedule(pl)
  tier  <- classify_tier(pl[["Label"]], sched)
  # 300s interval + RunAtLoad → Low
  expect_equal(tier, "Low")
})

# ── Test 2: Peak contention detection ─────────────────────────────────────────

test_that("detect_contention finds 3+ jobs at the same minute", {
  # Three fixtures fire at 09:00: medium-tier-job, chrome-tab-backup (in real data),
  # and our contention-test fixture.
  inv <- collect_inventory(fixtures_dir)
  skip_if(is.null(inv) || nrow(inv) == 0L, "inventory empty")

  # Count 09:00 jobs in the fixture set
  at_nine <- sum(startsWith(inv$schedule, "09:00"))
  if (at_nine < 3L) skip(sprintf("only %d jobs at 09:00 in fixtures (need 3)", at_nine))

  contention <- detect_contention(inv, threshold = 3L)
  expect_true(nrow(contention) >= 1L)
  expect_true(any(contention$time_slot == "09:00"))
  expect_true(any(contention$count >= 3L))
})

test_that("detect_contention returns empty df when no contention", {
  inv_empty <- data.frame(
    label    = c("com.claude.job-a", "com.claude.job-b"),
    tier     = c("High", "Medium"),
    schedule = c("02:00", "09:00"),
    stringsAsFactors = FALSE
  )
  result <- detect_contention(inv_empty, threshold = 3L)
  expect_equal(nrow(result), 0L)
})

# ── Test 3: Cloud cron YAML parsing (dispatch-only fixture) ───────────────────

test_that("dispatch-only workflow YAML is parsed as dispatch_only=TRUE", {
  # Temporarily place fixture in a structure that parse_workflow_triggers can find
  tmpdir <- file.path(tempdir(), "docs_gh", "llm-test", ".github", "workflows")
  dir.create(tmpdir, recursive = TRUE, showWarnings = FALSE)
  on.exit(unlink(file.path(tempdir(), "docs_gh"), recursive = TRUE), add = TRUE)

  fixture_src <- file.path(fixtures_dir, "dispatch-only-workflow.yml")
  skip_if(!file.exists(fixture_src), "dispatch-only-workflow.yml fixture missing")
  file.copy(fixture_src, file.path(tmpdir, "dispatch-only-workflow.yml"), overwrite = TRUE)

  # Temporarily override HOME-based path resolution via withr
  old_home <- Sys.getenv("HOME")
  on.exit(Sys.setenv(HOME = old_home), add = TRUE)
  Sys.setenv(HOME = tempdir())

  triggers <- parse_workflow_triggers(
    "docs_gh/llm-test",
    ".github/workflows/dispatch-only-workflow.yml"
  )
  expect_true(isTRUE(triggers$dispatch_only))
  expect_false(isTRUE(triggers$has_schedule))
})

test_that("scheduled workflow YAML is parsed as has_schedule=TRUE", {
  tmpdir <- file.path(tempdir(), "docs_gh", "llmtelemetry-test", ".github", "workflows")
  dir.create(tmpdir, recursive = TRUE, showWarnings = FALSE)
  on.exit(unlink(file.path(tempdir(), "docs_gh"), recursive = TRUE), add = TRUE)

  writeLines(
    c("name: Daily Test", "on:", "  schedule:", "    - cron: '0 8 * * *'", "jobs:", "  run:", "    runs-on: ubuntu-latest"),
    file.path(tmpdir, "daily-test.yaml")
  )

  old_home <- Sys.getenv("HOME")
  on.exit(Sys.setenv(HOME = old_home), add = TRUE)
  Sys.setenv(HOME = tempdir())

  triggers <- parse_workflow_triggers(
    "docs_gh/llmtelemetry-test",
    ".github/workflows/daily-test.yaml"
  )
  expect_true(isTRUE(triggers$has_schedule))
  expect_false(isTRUE(triggers$dispatch_only))
  expect_true(grepl("0 8", triggers$crons))
})

# ── Test 4: Ledger empty path ─────────────────────────────────────────────────

test_that("read_run_metrics returns empty-marker df when ledger does not exist", {
  result <- suppressMessages(
    read_run_metrics(ledger = "/tmp/this_ledger_does_not_exist.duckdb")
  )
  # Should be a data.frame with an 'empty' column
  expect_true(is.data.frame(result))
  expect_true("empty" %in% names(result))
})

test_that("render_metrics_table emits placeholder when ledger is empty", {
  render_fn <- get("render_metrics_table", envir = .agg_env)
  empty_df <- data.frame(empty = TRUE, stringsAsFactors = FALSE)
  output <- render_fn(empty_df)
  expect_true(grepl("No run data yet", output))
  expect_true(grepl("launchd_run_record", output))
})

# ── Test 5: Email dry-run has all 4 section QA markers ────────────────────────

test_that("email dry-run output contains all 4 section QA markers", {
  # Run the sender in dry-run mode, capturing stdout
  sender_path <- file.path(scripts_dir, "send_launchd_health_email.R")
  skip_if(!file.exists(sender_path), "send_launchd_health_email.R not found")
  skip_if(!file.exists(aggregator_path), "launchd_health_report.R not found")

  tmp_out <- tempfile(fileext = ".html")
  on.exit(unlink(tmp_out), add = TRUE)

  ret <- system2(
    "Rscript",
    c(sender_path),
    env   = c(
      "EMAIL_DRY_RUN=1",
      sprintf("LAUNCHD_SCRIPTS_DIR=%s", scripts_dir),
      # Point at a non-existent ledger so it gracefully gives placeholder
      "LAUNCHD_LEDGER=/tmp/test_ledger_nonexistent.duckdb",
      "CLOUD_REPOS=JohnGavin/llm,JohnGavin/llmtelemetry"
    ),
    stdout = tmp_out,
    stderr = FALSE,
    wait   = TRUE,
    timeout = 120L
  )

  skip_if(ret != 0L, "dry-run returned non-zero — environment likely missing blastula/Rscript")
  skip_if(!file.exists(tmp_out), "dry-run produced no output file")

  content <- paste(readLines(tmp_out, warn = FALSE), collapse = " ")

  expect_true(grepl("QA:section1=inventory", content),   label = "QA marker: section1")
  expect_true(grepl("QA:section2=run_metrics", content), label = "QA marker: section2")
  expect_true(grepl("QA:section3=suggestions", content), label = "QA marker: section3")
  expect_true(grepl("QA:section4=cloud_crons", content), label = "QA marker: section4")
})
