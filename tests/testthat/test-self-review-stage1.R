# test-self-review-stage1.R — Regression tests for self_review_stage1.sql detectors.
#
# Issue: #269 — Stage 1 self-review detectors emit false positives.
#
# Two false-positive patterns fixed:
#   1. stuck_loop — the original query had no status filter, matching
#      status='done' rows (legitimate multi-dispatch sessions).
#      Fixed: filter status='running' AND ended_at IS NULL AND started_at < NOW()-1h.
#   2. high_tool_error_rate — absolute count, not rate-windowed.
#      A single old error produced a 100% rate finding indefinitely.
#      Fixed: both CTEs now bound to logged_at/started_at >= NOW() - 7 DAYS.
#
# Tests use an in-memory DuckDB fixture database populated with synthetic rows.
# Each test asserts:
#   - The fixture row that WOULD have triggered the false positive does NOT trigger.
#   - A genuine positive row DOES trigger.
#
# DuckDB CLI is required. Tests are skipped on CI where it is unavailable.

library(testthat)

# ── Helpers ───────────────────────────────────────────────────────────────────

repo_root <- function() {
  # Walk up from test file location to find the git repo root.
  this_file <- tryCatch(
    normalizePath(sys.frame(0)$ofile, mustWork = FALSE),
    error = function(e) ""
  )
  if (nzchar(this_file) && file.exists(this_file)) {
    candidate <- dirname(dirname(this_file))
    if (file.exists(file.path(candidate, ".git"))) return(candidate)
  }
  tp <- tryCatch(testthat::test_path(), error = function(e) "")
  if (nzchar(tp)) {
    candidate <- normalizePath(file.path(tp, "..", ".."), mustWork = FALSE)
    if (file.exists(file.path(candidate, ".git"))) return(candidate)
  }
  path <- getwd()
  for (i in seq_len(10L)) {
    if (file.exists(file.path(path, ".git"))) return(path)
    parent <- dirname(path)
    if (parent == path) break
    path <- parent
  }
  getwd()
}

sql_file <- function() {
  normalizePath(
    file.path(repo_root(), ".claude", "scripts", "self_review_stage1.sql"),
    mustWork = FALSE
  )
}

duckdb_cmd <- function() {
  # Prefer the nix-shell duckdb for version parity with the pipeline.
  nix_default <- normalizePath(
    file.path(repo_root(), "default.nix"),
    mustWork = FALSE
  )
  if (nzchar(Sys.which("nix-shell")) && file.exists(nix_default)) {
    # Use nix-shell wrapper: pipe SQL via stdin
    list(
      type = "nix",
      nix_default = nix_default
    )
  } else if (nzchar(Sys.which("duckdb"))) {
    list(type = "path")
  } else {
    list(type = "none")
  }
}

# Run setup SQL then the detector SQL against a FRESH in-memory DuckDB.
# Each call gets an independent temp file so CREATE TABLE never conflicts.
# setup_sql is prepended to the detector SQL file contents.
run_sql <- function(setup_sql, detector_sql_file) {
  dc <- duckdb_cmd()
  if (dc$type == "none") return(NULL)

  detector_lines <- readLines(detector_sql_file, warn = FALSE)
  # The detector SQL starts with CREATE TABLE IF NOT EXISTS self_review_findings_stage1.
  # The setup_sql provides the source tables (agent_runs, hook_events, etc.).
  combined_sql <- paste(c(setup_sql, "", detector_lines), collapse = "\n")

  tmp_sql <- tempfile("stage1_test_", fileext = ".sql")
  writeLines(combined_sql, tmp_sql)
  on.exit(unlink(tmp_sql), add = TRUE)

  # Use a FRESH file-based DB each call to avoid "table already exists" errors.
  tmp_db <- tempfile("stage1_test_", fileext = ".duckdb")
  on.exit(unlink(tmp_db), add = TRUE)

  if (dc$type == "nix") {
    cmd <- sprintf(
      "nix-shell '%s' --run \"duckdb -init /dev/null '%s' < '%s' 2>&1\"",
      dc$nix_default, tmp_db, tmp_sql
    )
    out <- system(cmd, intern = TRUE)
  } else {
    # Use shell=TRUE so that < redirection works as expected.
    cmd <- sprintf("duckdb -init /dev/null '%s' < '%s' 2>&1", tmp_db, tmp_sql)
    out <- system(cmd, intern = TRUE)
  }
  out
}

# ── Detector 1: stuck_loop ────────────────────────────────────────────────────

test_that("stuck_loop FALSE POSITIVE: status=done rows do NOT trigger detector (#269)", {
  # Regression: the original query had no status filter. Sessions where the same
  # agent_type was legitimately dispatched ≥3 times with status='done' were
  # flagged as stuck loops. This must no longer trigger.
  skip_if(duckdb_cmd()$type == "none", "duckdb not available")
  skip_if_not(file.exists(sql_file()), "self_review_stage1.sql not found")

  setup_sql <- "
-- Fixture: three fixer runs that completed successfully (status='done').
-- This is a normal multi-dispatch session; NOT a stuck loop.
CREATE TABLE agent_runs (
    id          INTEGER,
    session_id  VARCHAR,
    agent_type  VARCHAR,
    model       VARCHAR,
    started_at  TIMESTAMP,
    ended_at    TIMESTAMP,
    duration_sec DOUBLE,
    prompt_preview VARCHAR,
    status      VARCHAR,
    tool_use_id VARCHAR,
    backfilled  BOOLEAN
);
-- All three are 'done' with ended_at set — completed agents.
INSERT INTO agent_runs VALUES
  (1, 'sess-fp-001', 'fixer', 'sonnet', now() - INTERVAL '2' HOUR, now() - INTERVAL '1' HOUR, 3600.0, 'task A', 'done', 'tool-1', false),
  (2, 'sess-fp-001', 'fixer', 'sonnet', now() - INTERVAL '1' HOUR, now() - INTERVAL '30' MINUTE, 1800.0, 'task B', 'done', 'tool-2', false),
  (3, 'sess-fp-001', 'fixer', 'sonnet', now() - INTERVAL '30' MINUTE, now(),                    1800.0, 'task C', 'done', 'tool-3', false);

-- Other tables required by the SQL file but not used by detector 1:
CREATE TABLE hook_events (id INTEGER, session_id VARCHAR, hook_name VARCHAR, event_type VARCHAR, fired_at TIMESTAMP, duration_ms INTEGER, output_preview VARCHAR);
CREATE TABLE errors (id INTEGER, session_id VARCHAR, source VARCHAR, error_text VARCHAR, context VARCHAR, logged_at TIMESTAMP);
CREATE TABLE sessions (session_id VARCHAR, project VARCHAR, started_at TIMESTAMP, ended_at TIMESTAMP, model VARCHAR);
"
  out <- run_sql(setup_sql, sql_file())
  expect_false(is.null(out), label = "duckdb returned NULL")

  combined <- paste(out, collapse = "\n")
  # stuck_loop must not appear in the findings summary
  expect_false(
    grepl("stuck_loop", combined),
    label = "stuck_loop finding triggered by status='done' rows — false positive not fixed"
  )
})

test_that("stuck_loop TRUE POSITIVE: running agents stuck > 1 hour DO trigger detector", {
  skip_if(duckdb_cmd()$type == "none", "duckdb not available")
  skip_if_not(file.exists(sql_file()), "self_review_stage1.sql not found")

  setup_sql <- "
CREATE TABLE agent_runs (
    id          INTEGER,
    session_id  VARCHAR,
    agent_type  VARCHAR,
    model       VARCHAR,
    started_at  TIMESTAMP,
    ended_at    TIMESTAMP,
    duration_sec DOUBLE,
    prompt_preview VARCHAR,
    status      VARCHAR,
    tool_use_id VARCHAR,
    backfilled  BOOLEAN
);
-- Three 'running' agents with no ended_at, started more than 1 hour ago.
-- This represents genuinely stuck agents.
INSERT INTO agent_runs VALUES
  (1, 'sess-tp-001', 'fixer', 'sonnet', now() - INTERVAL '3' HOUR, NULL, NULL, 'task A', 'running', 'tool-1', false),
  (2, 'sess-tp-001', 'fixer', 'sonnet', now() - INTERVAL '2' HOUR, NULL, NULL, 'task B', 'running', 'tool-2', false),
  (3, 'sess-tp-001', 'fixer', 'sonnet', now() - INTERVAL '90' MINUTE, NULL, NULL, 'task C', 'running', 'tool-3', false);

CREATE TABLE hook_events (id INTEGER, session_id VARCHAR, hook_name VARCHAR, event_type VARCHAR, fired_at TIMESTAMP, duration_ms INTEGER, output_preview VARCHAR);
CREATE TABLE errors (id INTEGER, session_id VARCHAR, source VARCHAR, error_text VARCHAR, context VARCHAR, logged_at TIMESTAMP);
CREATE TABLE sessions (session_id VARCHAR, project VARCHAR, started_at TIMESTAMP, ended_at TIMESTAMP, model VARCHAR);
"
  out <- run_sql(setup_sql, sql_file())
  expect_false(is.null(out), label = "duckdb returned NULL")

  combined <- paste(out, collapse = "\n")
  # stuck_loop MUST appear in the summary
  expect_true(
    grepl("stuck_loop", combined),
    label = "stuck_loop finding NOT triggered by genuinely stuck running agents"
  )
})

test_that("stuck_loop NOT triggered by running agents started < 1 hour ago (in-flight)", {
  # Agents that are still running but started recently are in-flight, not stuck.
  skip_if(duckdb_cmd()$type == "none", "duckdb not available")
  skip_if_not(file.exists(sql_file()), "self_review_stage1.sql not found")

  setup_sql <- "
CREATE TABLE agent_runs (
    id          INTEGER,
    session_id  VARCHAR,
    agent_type  VARCHAR,
    model       VARCHAR,
    started_at  TIMESTAMP,
    ended_at    TIMESTAMP,
    duration_sec DOUBLE,
    prompt_preview VARCHAR,
    status      VARCHAR,
    tool_use_id VARCHAR,
    backfilled  BOOLEAN
);
-- Three 'running' agents started within the last 30 minutes — in-flight.
INSERT INTO agent_runs VALUES
  (1, 'sess-inf-001', 'fixer', 'sonnet', now() - INTERVAL '30' MINUTE, NULL, NULL, 'task A', 'running', 'tool-1', false),
  (2, 'sess-inf-001', 'fixer', 'sonnet', now() - INTERVAL '20' MINUTE, NULL, NULL, 'task B', 'running', 'tool-2', false),
  (3, 'sess-inf-001', 'fixer', 'sonnet', now() - INTERVAL '10' MINUTE, NULL, NULL, 'task C', 'running', 'tool-3', false);

CREATE TABLE hook_events (id INTEGER, session_id VARCHAR, hook_name VARCHAR, event_type VARCHAR, fired_at TIMESTAMP, duration_ms INTEGER, output_preview VARCHAR);
CREATE TABLE errors (id INTEGER, session_id VARCHAR, source VARCHAR, error_text VARCHAR, context VARCHAR, logged_at TIMESTAMP);
CREATE TABLE sessions (session_id VARCHAR, project VARCHAR, started_at TIMESTAMP, ended_at TIMESTAMP, model VARCHAR);
"
  out <- run_sql(setup_sql, sql_file())
  expect_false(is.null(out), label = "duckdb returned NULL")

  combined <- paste(out, collapse = "\n")
  expect_false(
    grepl("stuck_loop", combined),
    label = "stuck_loop triggered by in-flight agents (started < 1h ago)"
  )
})

# ── Detector 3: high_tool_error_rate ─────────────────────────────────────────

test_that("high_tool_error_rate FALSE POSITIVE: old errors outside 7-day window do NOT trigger (#269)", {
  # Regression: a single error logged 6+ weeks ago produced a 100% error rate
  # finding indefinitely because the query had no time window.
  skip_if(duckdb_cmd()$type == "none", "duckdb not available")
  skip_if_not(file.exists(sql_file()), "self_review_stage1.sql not found")

  setup_sql <- "
CREATE TABLE agent_runs (
    id          INTEGER,
    session_id  VARCHAR,
    agent_type  VARCHAR,
    model       VARCHAR,
    started_at  TIMESTAMP,
    ended_at    TIMESTAMP,
    duration_sec DOUBLE,
    prompt_preview VARCHAR,
    status      VARCHAR,
    tool_use_id VARCHAR,
    backfilled  BOOLEAN
);
-- One old agent run (40 days ago) to match the old error row
INSERT INTO agent_runs VALUES
  (1, 'sess-old-001', 'fixer', 'sonnet', now() - INTERVAL '40' DAY, now() - INTERVAL '40' DAY + INTERVAL '1' HOUR, 3600.0, 'old task', 'done', 'tool-old', false);

CREATE TABLE hook_events (id INTEGER, session_id VARCHAR, hook_name VARCHAR, event_type VARCHAR, fired_at TIMESTAMP, duration_ms INTEGER, output_preview VARCHAR);

CREATE TABLE errors (id INTEGER, session_id VARCHAR, source VARCHAR, error_text VARCHAR, context VARCHAR, logged_at TIMESTAMP);
-- One error 40 days old — outside the 7-day window.
-- In the original query this produced 1/1 = 100% error rate finding.
INSERT INTO errors VALUES
  (1, 'sess-old-001', 'signal_notes', 'old error', '{}', now() - INTERVAL '40' DAY);

CREATE TABLE sessions (session_id VARCHAR, project VARCHAR, started_at TIMESTAMP, ended_at TIMESTAMP, model VARCHAR);
"
  out <- run_sql(setup_sql, sql_file())
  expect_false(is.null(out), label = "duckdb returned NULL")

  combined <- paste(out, collapse = "\n")
  expect_false(
    grepl("high_tool_error_rate", combined),
    label = "high_tool_error_rate triggered by error outside 7-day window — false positive not fixed"
  )
})

test_that("high_tool_error_rate TRUE POSITIVE: recent high error rate DOES trigger detector", {
  # A tool with a genuine high error rate in the last 7 days must still fire.
  skip_if(duckdb_cmd()$type == "none", "duckdb not available")
  skip_if_not(file.exists(sql_file()), "self_review_stage1.sql not found")

  setup_sql <- "
CREATE TABLE agent_runs (
    id          INTEGER,
    session_id  VARCHAR,
    agent_type  VARCHAR,
    model       VARCHAR,
    started_at  TIMESTAMP,
    ended_at    TIMESTAMP,
    duration_sec DOUBLE,
    prompt_preview VARCHAR,
    status      VARCHAR,
    tool_use_id VARCHAR,
    backfilled  BOOLEAN
);
-- 2 recent agent calls today
INSERT INTO agent_runs VALUES
  (1, 'sess-rate-001', 'fixer', 'sonnet', now() - INTERVAL '2' HOUR, now() - INTERVAL '1' HOUR, 3600.0, 'task', 'done', 'tool-a', false),
  (2, 'sess-rate-001', 'fixer', 'sonnet', now() - INTERVAL '1' HOUR, now(),                    3600.0, 'task', 'done', 'tool-b', false);

CREATE TABLE hook_events (id INTEGER, session_id VARCHAR, hook_name VARCHAR, event_type VARCHAR, fired_at TIMESTAMP, duration_ms INTEGER, output_preview VARCHAR);

CREATE TABLE errors (id INTEGER, session_id VARCHAR, source VARCHAR, error_text VARCHAR, context VARCHAR, logged_at TIMESTAMP);
-- 2 errors from the same tool today — 2 errors / 2 calls = 100% error rate (> 20% threshold)
INSERT INTO errors VALUES
  (1, 'sess-rate-001', 'bad_tool', 'error 1', '{}', now() - INTERVAL '2' HOUR),
  (2, 'sess-rate-001', 'bad_tool', 'error 2', '{}', now() - INTERVAL '1' HOUR);

CREATE TABLE sessions (session_id VARCHAR, project VARCHAR, started_at TIMESTAMP, ended_at TIMESTAMP, model VARCHAR);
"
  out <- run_sql(setup_sql, sql_file())
  expect_false(is.null(out), label = "duckdb returned NULL")

  combined <- paste(out, collapse = "\n")
  expect_true(
    grepl("high_tool_error_rate", combined),
    label = "high_tool_error_rate NOT triggered by recent high error rate — genuine positive lost"
  )
})

# ── Shell syntax check ────────────────────────────────────────────────────────

test_that("self_review_stage1.sh passes bash -n syntax check", {
  sh <- normalizePath(
    file.path(repo_root(), ".claude", "scripts", "self_review_stage1.sh"),
    mustWork = FALSE
  )
  skip_if_not(file.exists(sh), "self_review_stage1.sh not found")
  exit_code <- system2("bash", args = c("-n", sh), stdout = FALSE, stderr = FALSE)
  expect_equal(exit_code, 0L, info = "self_review_stage1.sh has bash syntax errors")
})

test_that("self_review_stage1.sql exists and is non-empty", {
  f <- sql_file()
  expect_true(file.exists(f), info = "self_review_stage1.sql not found")
  lines <- readLines(f, warn = FALSE)
  expect_gt(length(lines), 10L, label = "SQL file appears empty")
})

test_that("self_review_stage1.sql contains rate-window predicate for errors (#269)", {
  f <- sql_file()
  skip_if_not(file.exists(f), "self_review_stage1.sql not found")
  sql_text <- paste(readLines(f, warn = FALSE), collapse = "\n")
  # The fix must include a time-bounded WHERE clause on the errors table.
  expect_true(
    grepl("INTERVAL.*DAY", sql_text, ignore.case = TRUE),
    info = "No INTERVAL DAY predicate found in SQL — rate-window fix (#269) may be missing"
  )
})

test_that("self_review_stage1.sql stuck_loop detector filters on status='running' (#269)", {
  f <- sql_file()
  skip_if_not(file.exists(f), "self_review_stage1.sql not found")
  sql_text <- paste(readLines(f, warn = FALSE), collapse = "\n")
  # The fix must filter on status = 'running'
  expect_true(
    grepl("status\\s*=\\s*'running'", sql_text, ignore.case = FALSE),
    info = "stuck_loop detector does not filter on status='running' — fix (#269) may be missing"
  )
  # And also require ended_at IS NULL
  expect_true(
    grepl("ended_at\\s+IS\\s+NULL", sql_text, ignore.case = TRUE),
    info = "stuck_loop detector does not check ended_at IS NULL — fix (#269) may be missing"
  )
})
