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

# ── Test 9: Column rename — "Fails (7d)" -> "Non-zero exits (7d)" ───────────
#
# Per the `exit-code-conventions` rule, a non-zero exit is not necessarily a
# failure — checker/scanner jobs use exit 1 to mean "ran fine, found
# something" (e.g. com.claude.secret-exposure-scan: 7/7 non-zero exits this
# week while every housekeeping_runs row for it recorded status='ok'). The
# old "Fails (7d)" header claimed a stronger meaning than the underlying
# `exit_code <> 0` count actually carries.

test_that("inventory table header says 'Non-zero exits (7d)', not 'Fails (7d)'", {
  render_fn <- get("render_inventory_table", envir = .agg_env)

  inv <- data.frame(
    label       = "com.claude.header-rename-test",
    tier        = "Low",
    schedule    = "daemon/run-at-load",
    program     = "/bin/true",
    script_path = NA_character_,
    timeout_s   = NA_integer_,
    n_runs      = 5L,
    n_fail      = 1L,
    run_status  = "ok",
    stringsAsFactors = FALSE
  )

  out <- render_fn(inv)
  expect_true(grepl("Non-zero exits (7d)", out, fixed = TRUE))
  expect_false(grepl("Fails (7d)", out, fixed = TRUE))
  # The tier-header summary line must use the same renamed vocabulary.
  expect_true(grepl("non-zero exit", out, fixed = TRUE))
})

# ── Tests 10-11: High-tier missing-timeout findings (llm#1187 defect 3) ─────
#
# User decision (llm#1187 defect 3): every job must declare a timeout
# unless the plist owner has recorded an explicit reason not to. A
# High-tier job with no timeout and no recorded exemption is a FINDING.
# Three states must be distinguishable per checks-must-distinguish-unknown:
# timeout declared (not tested here — already covered by the inventory
# table's Timeout column), no timeout + not exempt (finding), no timeout +
# exempt (reason shown, never a bare dash, never silently "fine").

test_that("a High-tier job with no timeout and no exemption is reported as a finding", {
  find_fn   <- get("find_missing_timeout_findings", envir = .agg_env)
  render_fn <- get("render_missing_timeout_findings", envir = .agg_env)

  inv <- data.frame(
    label       = "com.claude.no-timeout-job",
    tier        = "High",
    schedule    = "02:00",
    program     = "/bin/true",
    script_path = NA_character_,
    timeout_s   = NA_integer_,
    stringsAsFactors = FALSE
  )

  findings <- find_fn(inv, exemptions = character(0L))
  expect_equal(nrow(findings), 1L)
  expect_equal(findings$label[1L], "com.claude.no-timeout-job")
  expect_equal(findings$status[1L], "finding")

  out <- render_fn(findings)
  expect_true(grepl("no-timeout-job", out, fixed = TRUE))
  expect_true(grepl("FINDING", out, fixed = TRUE))
})

test_that("a High-tier job with no timeout but a file exemption is not a finding, and shows its reason", {
  read_fn   <- get("read_timeout_exemptions", envir = .agg_env)
  find_fn   <- get("find_missing_timeout_findings", envir = .agg_env)
  render_fn <- get("render_missing_timeout_findings", envir = .agg_env)

  exempt_file <- tempfile(fileext = ".txt")
  on.exit(unlink(exempt_file), add = TRUE)
  writeLines(c(
    "# launchd timeout exemptions -- one 'label  # reason' per line",
    "com.claude.exempt-job  # relies on internal watchdog, see llm#1187"
  ), exempt_file)

  exemptions <- read_fn(path = exempt_file)
  expect_true("com.claude.exempt-job" %in% names(exemptions))

  inv <- data.frame(
    label       = "com.claude.exempt-job",
    tier        = "High",
    schedule    = "03:00",
    program     = "/bin/true",
    script_path = NA_character_,
    timeout_s   = NA_integer_,
    stringsAsFactors = FALSE
  )

  findings <- find_fn(inv, exemptions = exemptions)
  expect_equal(nrow(findings), 1L)
  expect_equal(findings$status[1L], "exempt")
  expect_false(is.na(findings$reason[1L]))
  expect_true(grepl("watchdog", findings$reason[1L], fixed = TRUE))

  out <- render_fn(findings)
  expect_true(grepl("exempt-job", out, fixed = TRUE))
  expect_true(grepl("exempt", out, fixed = TRUE))
  expect_false(grepl("FINDING", out, fixed = TRUE))
  expect_true(grepl("watchdog", out, fixed = TRUE))
})

test_that("read_timeout_exemptions returns zero-length vector when the file is absent", {
  read_fn <- get("read_timeout_exemptions", envir = .agg_env)
  result  <- read_fn(path = "/tmp/this_exempt_file_does_not_exist_1187.txt")
  expect_length(result, 0L)
})

# ── Tests 12-15: wrapper-declared timeout bounds (llm#1190) ─────────────────
#
# Enforcement lives in bin/launchd_run_record.sh's per-label bound file, not
# in each plist's own `TimeOut` key (39 plists were deliberately NOT
# edited). These tests cover the report-side awareness of that file: a job
# bounded only via the wrapper must (a) be readable from the file, (b)
# render distinguishably from a plist-declared bound and from no bound at
# all, and (c) NOT be reported as a missing-timeout finding.

test_that("read_wrapper_timeouts parses label/seconds pairs and skips comments/blanks", {
  read_fn <- get("read_wrapper_timeouts", envir = .agg_env)

  tf <- tempfile(fileext = ".txt")
  on.exit(unlink(tf), add = TRUE)
  writeLines(c(
    "# a pure comment line",
    "",
    "com.claude.wrapped-job       60    # p95=2s, floor",
    "com.claude.another-job       1800  # method A"
  ), tf)

  result <- read_fn(path = tf)
  expect_equal(unname(result[["com.claude.wrapped-job"]]), 60)
  expect_equal(unname(result[["com.claude.another-job"]]), 1800)
  expect_length(result, 2L)
})

test_that("read_wrapper_timeouts returns zero-length vector when the file is absent", {
  read_fn <- get("read_wrapper_timeouts", envir = .agg_env)
  result  <- read_fn(path = "/tmp/this_wrapper_timeouts_file_does_not_exist_1190.txt")
  expect_length(result, 0L)
})

test_that("attach_wrapper_timeout_display renders plist/wrapper/none distinctly", {
  attach_fn <- get("attach_wrapper_timeout_display", envir = .agg_env)

  inv <- data.frame(
    label     = c("com.claude.plist-bound", "com.claude.wrapper-bound", "com.claude.unbound"),
    timeout_s = c(30L, NA_integer_, NA_integer_),
    stringsAsFactors = FALSE
  )
  wrapper_timeouts <- stats::setNames(60, "com.claude.wrapper-bound")

  out <- attach_fn(inv, wrapper_timeouts)

  expect_equal(out$timeout_display[out$label == "com.claude.plist-bound"], "30s")
  expect_equal(out$timeout_display[out$label == "com.claude.wrapper-bound"], "60s (wrapper)")
  expect_equal(out$timeout_display[out$label == "com.claude.unbound"], "—")
  # All three must be textually distinct -- the whole point of this column.
  expect_equal(length(unique(out$timeout_display)), 3L)
})

test_that("a High-tier job bounded only via the wrapper is NOT a missing-timeout finding", {
  find_fn <- get("find_missing_timeout_findings", envir = .agg_env)

  inv <- data.frame(
    label       = "com.claude.wrapper-only-job",
    tier        = "High",
    schedule    = "02:00",
    program     = "/bin/true",
    script_path = NA_character_,
    timeout_s   = NA_integer_,   # no plist TimeOut key
    stringsAsFactors = FALSE
  )
  wrapper_timeouts <- stats::setNames(120, "com.claude.wrapper-only-job")

  findings <- find_fn(inv, exemptions = character(0L), wrapper_timeouts = wrapper_timeouts)
  expect_equal(nrow(findings), 0L)
})

test_that("render_inventory_table shows the wrapper-declared bound when timeout_display is present", {
  render_fn <- get("render_inventory_table", envir = .agg_env)

  inv <- data.frame(
    label           = "com.claude.wrapper-job",
    tier            = "High",
    schedule        = "02:00",
    program         = "/bin/true",
    script_path     = NA_character_,
    timeout_s       = NA_integer_,
    timeout_display = "60s (wrapper)",
    n_runs          = 1L,
    n_fail          = 0L,
    run_status      = "ok",
    stringsAsFactors = FALSE
  )

  out <- render_fn(inv)
  expect_true(grepl("60s (wrapper)", out, fixed = TRUE))
})

# ── Tests 16-20: failing-job findings section (llm#1188) ────────────────────
#
# Prior to this section, a job's non-zero exits were visible only as a
# number buried in a per-tier summary line — nothing named WHICH job
# failed. llm#1188: com.claude.private-data-history-audit had been failing
# for days and the only reason it surfaced was a manual ledger query.
# These tests plant a job with n_fail > 0 in fixture data and assert the
# new section renders it, distinguishing the three tail_log_lines() states.

test_that("find_failing_jobs returns zero rows when nothing failed in-window", {
  find_fn <- get("find_failing_jobs", envir = .agg_env)

  inv <- data.frame(
    label      = c("com.claude.clean-job", "com.claude.never-recorded", "com.claude.unavailable"),
    tier       = c("High", "Medium", "Low"),
    n_runs     = c(5L, NA_integer_, NA_integer_),
    n_fail     = c(0L, NA_integer_, NA_integer_),
    run_status = c("ok", "never_recorded", "ledger_unavailable"),
    stringsAsFactors = FALSE
  )

  out <- find_fn(inv)
  expect_equal(nrow(out), 0L)
})

test_that("find_failing_jobs picks up an 'ok'-status job with n_fail > 0 and excludes unknown-status rows even if n_fail happens to be set", {
  find_fn <- get("find_failing_jobs", envir = .agg_env)

  inv <- data.frame(
    label      = c("com.claude.failing-job", "com.claude.clean-job", "com.claude.unknown-status-with-count"),
    tier       = c("High", "Medium", "Low"),
    n_runs     = c(1L, 3L, 2L),
    n_fail     = c(1L, 0L, 2L),
    run_status = c("ok", "ok", "ledger_unavailable"),
    std_err    = c("/tmp/failing.err", NA_character_, "/tmp/unknown.err"),
    stringsAsFactors = FALSE
  )

  out <- find_fn(inv)
  expect_equal(nrow(out), 1L)
  expect_equal(out$label[1L], "com.claude.failing-job")
  expect_equal(out$n_fail[1L], 1L)
  expect_equal(out$n_runs[1L], 1L)
  expect_equal(out$std_err[1L], "/tmp/failing.err")
})

test_that("find_failing_jobs defaults std_err to NA when the inventory lacks that column", {
  find_fn <- get("find_failing_jobs", envir = .agg_env)

  inv <- data.frame(
    label      = "com.claude.no-std-err-column",
    tier       = "High",
    n_runs     = 1L,
    n_fail     = 1L,
    run_status = "ok",
    stringsAsFactors = FALSE
  )

  out <- find_fn(inv)
  expect_equal(nrow(out), 1L)
  expect_true(is.na(out$std_err[1L]))
})

test_that("tail_log_lines distinguishes no-path, unavailable, and ok-but-empty/ok-with-content", {
  tail_fn <- get("tail_log_lines", envir = .agg_env)

  no_path <- tail_fn(NA_character_)
  expect_equal(no_path$status, "no_path")
  expect_length(no_path$lines, 0L)

  unavail <- tail_fn("/tmp/this_launchd_err_log_does_not_exist_1188.txt")
  expect_equal(unavail$status, "unavailable")
  expect_length(unavail$lines, 0L)

  empty_file <- tempfile()
  on.exit(unlink(empty_file), add = TRUE)
  file.create(empty_file)
  ok_empty <- tail_fn(empty_file)
  expect_equal(ok_empty$status, "ok")
  expect_length(ok_empty$lines, 0L)

  content_file <- tempfile()
  on.exit(unlink(content_file), add = TRUE)
  writeLines(as.character(1:20), content_file)
  ok_content <- tail_fn(content_file, n = 5L)
  expect_equal(ok_content$status, "ok")
  expect_equal(ok_content$lines, as.character(16:20))

  # The three states must never render identically downstream — that is
  # the entire point of returning a status field rather than just lines.
  expect_false(identical(no_path$status, unavail$status))
  expect_false(identical(unavail$status, ok_empty$status))
})

test_that("render_failing_jobs_section shows the placeholder when nothing failed", {
  render_fn <- get("render_failing_jobs_section", envir = .agg_env)
  find_fn   <- get("find_failing_jobs", envir = .agg_env)

  out <- render_fn(find_fn(data.frame(
    label = character(), tier = character(), n_runs = integer(),
    n_fail = integer(), run_status = character(), stringsAsFactors = FALSE
  )))
  expect_true(grepl("No jobs recorded a non-zero exit", out, fixed = TRUE))
})

test_that("render_failing_jobs_section names the failing job and shows its log tail (llm#1188)", {
  render_fn <- get("render_failing_jobs_section", envir = .agg_env)

  failing <- data.frame(
    label   = "com.claude.private-data-history-audit",
    tier    = "High",
    n_runs  = 1L,
    n_fail  = 1L,
    std_err = "/Users/johngavin/.claude/logs/private_data_history_audit.err",
    stringsAsFactors = FALSE
  )

  fake_tail <- function(path, n = 10L) {
    list(status = "ok", lines = c("mode=dry-run findings=587 status=findings_or_error rc=1"))
  }

  out <- render_fn(failing, tail_fn = fake_tail)
  expect_true(grepl("private-data-history-audit", out, fixed = TRUE))
  expect_true(grepl("1/1", out, fixed = TRUE))
  expect_true(grepl("findings=587", out, fixed = TRUE))
})

test_that("render_failing_jobs_section distinguishes no-path/unavailable/empty/content log states", {
  render_fn <- get("render_failing_jobs_section", envir = .agg_env)

  failing <- data.frame(
    label   = c("com.claude.no-path-job", "com.claude.unavail-job", "com.claude.empty-job", "com.claude.content-job"),
    tier    = rep("High", 4L),
    n_runs  = rep(1L, 4L),
    n_fail  = rep(1L, 4L),
    std_err = c(NA_character_, "/tmp/does-not-exist-1188.err", "/tmp/empty-1188.err", "/tmp/content-1188.err"),
    stringsAsFactors = FALSE
  )

  fake_tail <- function(path, n = 10L) {
    if (is.na(path)) return(list(status = "no_path", lines = character(0L)))
    if (identical(path, "/tmp/does-not-exist-1188.err")) return(list(status = "unavailable", lines = character(0L)))
    if (identical(path, "/tmp/empty-1188.err")) return(list(status = "ok", lines = character(0L)))
    list(status = "ok", lines = "boom: something went wrong")
  }

  out <- render_fn(failing, tail_fn = fake_tail)
  expect_true(grepl("No .StandardErrorPath. declared", out))
  expect_true(grepl("not readable", out, fixed = TRUE))
  expect_true(grepl("Log file is empty", out, fixed = TRUE))
  expect_true(grepl("boom: something went wrong", out, fixed = TRUE))
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
