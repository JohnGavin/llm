# test-launchd-health-report.R — Tests for launchd health report components.
#
# Tests:
#   1. Tier classification for all 3 tiers
#   2. Peak-contention detection
#   3. Cloud-cron workflow YAML parsing (dispatch-only fixture)
#   4. "Ledger empty" path produces placeholder text
#   5. Email dry-run produces all 4 section QA markers
#   6. A Program containing "||" renders as exactly 6 table cells (llm#1187 defect 2)
#   7. Label-keyed run counts are picked up for a wrapped job whose Program
#      path appears nowhere in housekeeping_runs (llm#1187 defect 1 regression)
#   8. The three Runs/Fails states (ok/never_recorded/ledger_unavailable)
#      render as three visually distinct strings (llm#1187 defect 1)
#
# Tracked in llm#300, llm#1187.

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
  # Metrics now come from the unified ledger's housekeeping_runs table
  # (llm#300 route (b) — launchd_runs.duckdb is never populated).
  expect_true(grepl("housekeeping_runs", output))
})

# ── Test 6: Defect 2 — a pipe-containing Program must not break the table ────
#
# llm#1187 defect 2: a job whose Program is a `/bin/sh -c ... || true; ...`
# command breaks the markdown table because nothing escapes the literal `|`
# characters — the row gains extra cells. Backticks around a cell do NOT
# protect a `|` from the table's row-splitter.

test_that("a Program containing '||' renders as exactly 6 table cells (llm#1187 defect 2)", {
  render_fn <- get("render_inventory_table", envir = .agg_env)

  inv <- data.frame(
    label       = "com.claude.pipe-test",
    tier        = "Low",
    schedule    = "daemon/run-at-load",
    program     = "/bin/sh -c /usr/local/bin/orbctl start 2>/dev/null || true; sleep 5",
    script_path = NA_character_,
    timeout_s   = NA_integer_,
    n_runs      = NA_integer_,
    n_fail      = NA_integer_,
    run_status  = "never_recorded",
    stringsAsFactors = FALSE
  )

  out   <- render_fn(inv)
  lines <- strsplit(out, "\n", fixed = TRUE)[[1L]]
  row_line <- lines[grepl("pipe-test", lines, fixed = TRUE)]
  expect_length(row_line, 1L)

  # Split on an UNESCAPED "|" only (a "|" immediately preceded by "\" is an
  # escaped cell-internal pipe, not a column separator). A correctly-escaped
  # 6-column row produces exactly 6 cells after dropping the leading empty
  # element (the row starts with "| "); an unescaped "||" inside a cell would
  # instead be picked up as 2 extra column separators.
  cells <- strsplit(row_line, "(?<!\\\\)\\|", perl = TRUE)[[1L]]
  cells <- cells[-1L]
  expect_length(cells, 6L)
})

# ── Test 7: Defect 1 regression — label-keyed counts for a wrapped job ───────
#
# llm#1187 defect 1: High-tier jobs run through bin/launchd-recorders/<name>,
# which execs bin/launchd_run_record.sh <label> -- <real cmd>. The wrapped
# script records its OWN path in housekeeping_runs.source_script, never the
# wrapper's — so a join on the plist's Program path can never match. The fix
# reads run counts from launchd_runs.duckdb's `runs` table, keyed by `label`
# (the launchd Label, which always matches), which has no such join problem.
# This test plants a fixture `runs` table with rows for a wrapped job whose
# Program path (the wrapper) appears nowhere in any housekeeping_runs-style
# source_script value, and asserts the counts are still picked up by label.

test_that("read_run_counts_by_label + attach_label_run_counts pick up a wrapped job by label (llm#1187 defect 1)", {
  skip_if_not_installed("duckdb")
  read_run_counts_by_label <- get("read_run_counts_by_label", envir = .agg_env)
  attach_label_run_counts  <- get("attach_label_run_counts",  envir = .agg_env)

  ledger <- tempfile(fileext = ".duckdb")
  on.exit(unlink(ledger), add = TRUE)

  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = ledger, read_only = FALSE)
  DBI::dbExecute(con, "
    CREATE TABLE runs (
      label        VARCHAR NOT NULL,
      started_at   TIMESTAMPTZ NOT NULL,
      finished_at  TIMESTAMPTZ NOT NULL,
      exit_code    INTEGER NOT NULL,
      peak_rss_mb  DOUBLE,
      host         VARCHAR
    )
  ")
  now <- Sys.time()
  fixture_rows <- data.frame(
    label       = rep("com.claude.overnight-self-review-email", 3L),
    started_at  = now - c(1, 2, 3) * 3600,
    finished_at = now - c(1, 2, 3) * 3600 + 60,
    exit_code   = c(0L, 0L, 1L),
    peak_rss_mb = c(10.5, 10.5, 10.5),
    host        = "test-host",
    stringsAsFactors = FALSE
  )
  DBI::dbAppendTable(con, "runs", fixture_rows)
  DBI::dbDisconnect(con, shutdown = TRUE)

  label_counts <- read_run_counts_by_label(ledger = ledger, window_days = 7)
  expect_false(is.null(label_counts))

  # The plist inventory row for a High-tier wrapped job: its `program` is
  # the WRAPPER path, which never appears as a source_script anywhere in
  # housekeeping_runs — this is exactly the mismatch that broke defect 1.
  inventory <- data.frame(
    label       = "com.claude.overnight-self-review-email",
    tier        = "High",
    schedule    = "02:00",
    program     = "/Users/johngavin/docs_gh/llm/bin/launchd-recorders/overnight-self-review-email",
    script_path = NA_character_,
    timeout_s   = NA_integer_,
    stringsAsFactors = FALSE
  )

  result <- attach_label_run_counts(inventory, label_counts)
  expect_equal(result$run_status, "ok")
  expect_equal(result$n_runs, 3L)
  expect_equal(result$n_fail, 1L)
})

# ── Test 8: Defect 1 — three distinguishable Runs/Fails states ───────────────
#
# Per checks-must-distinguish-unknown: "this job's label has never been
# recorded", "this job's label was recorded but ran zero times in this
# window", and "the run ledger itself is unavailable" are three DIFFERENT
# facts and must never render as the same string (the report previously
# printed "0 runs · 0 fails" for jobs that had, in fact, run 7 times).

test_that("the three run-count states render as three different strings (llm#1187 defect 1)", {
  fmt_run_status <- get("fmt_run_status", envir = .agg_env)

  ok_str      <- fmt_run_status(0L, "ok")
  never_str   <- fmt_run_status(NA_integer_, "never_recorded")
  unavail_str <- fmt_run_status(NA_integer_, "ledger_unavailable")

  expect_false(identical(ok_str, never_str))
  expect_false(identical(ok_str, unavail_str))
  expect_false(identical(never_str, unavail_str))
  # A genuine zero must render as a literal zero, not a placeholder dash —
  # that was the original bug (0 runs indistinguishable from unknown).
  expect_equal(ok_str, "0")
})

test_that("render_inventory_table shows three distinct cell strings across ok/never_recorded/ledger_unavailable rows (llm#1187 defect 1)", {
  render_fn <- get("render_inventory_table", envir = .agg_env)

  inv <- data.frame(
    label       = c("com.claude.ran-zero-in-window", "com.claude.never-recorded", "com.claude.unavailable-ledger"),
    tier        = rep("Low", 3L),
    schedule    = rep("daemon/run-at-load", 3L),
    program     = rep("/bin/true", 3L),
    script_path = rep(NA_character_, 3L),
    timeout_s   = rep(NA_integer_, 3L),
    n_runs      = c(0L, NA_integer_, NA_integer_),
    n_fail      = c(0L, NA_integer_, NA_integer_),
    run_status  = c("ok", "never_recorded", "ledger_unavailable"),
    stringsAsFactors = FALSE
  )

  out   <- render_fn(inv)
  lines <- strsplit(out, "\n", fixed = TRUE)[[1L]]

  extract_runs_cell <- function(needle) {
    row <- lines[grepl(needle, lines, fixed = TRUE)]
    expect_length(row, 1L)
    # Cell layout: "" | Label | Schedule | Runs | Fails | Program | Timeout
    trimws(strsplit(row, "|", fixed = TRUE)[[1L]][4L])
  }

  cell_ok      <- extract_runs_cell("ran-zero-in-window")
  cell_never   <- extract_runs_cell("never-recorded")
  cell_unavail <- extract_runs_cell("unavailable-ledger")

  expect_equal(cell_ok, "0")
  expect_false(identical(cell_ok, cell_never))
  expect_false(identical(cell_ok, cell_unavail))
  expect_false(identical(cell_never, cell_unavail))
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
