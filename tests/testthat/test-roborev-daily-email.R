# test-roborev-daily-email.R — Tests for send_roborev_email.R and publish_roborev_data.sh
#
# Coverage:
#   - send_roborev_email.R dry-run produces body with headline numbers, dashboard link
#   - send_roborev_email.R exits non-zero when no JSON snapshot found
#   - publish_roborev_data.sh DRYRUN=1 skips git operations and exits 0
#   - roborev_daily_cron.sh passes bash -n syntax check
#
# All R tests use a synthetic JSON fixture (no DB access required).
# Bash tests use bash -n + DRYRUN smoke.

library(testthat)
library(jsonlite)

# ── Fixture ────────────────────────────────────────────────────────────────────

make_synthetic_snapshot <- function(date = "2026-05-28") {
  list(
    report_date  = date,
    generated_at = paste0(date, "T08:00:00Z"),
    lineage_source = "heuristic-retry_count+1",
    global_windows = list(
      d7 = list(
        window_days = 7L,
        repo = "__all__",
        n_reviews = 131L,
        freq_table = list(
          list(verdict_label = "issues_found", status = "closed", n = 74L),
          list(verdict_label = "issues_found", status = "open",   n = 50L),
          list(verdict_label = "clean",        status = "closed", n = 55L),
          list(verdict_label = "clean",        status = "open",   n  = 7L)
        ),
        speed = list(
          ttc_p50_hrs    = 96.0,
          ttc_p90_hrs    = 102.5,
          ttc_p99_hrs    = 103.0,
          att_p50        = 1.0,
          att_p90        = 1.0,
          close_rate     = 0.597,
          n_issues_found = 124L,
          n_closed       = 74L,
          n_open         = 50L
        ),
        trends = list(
          ttc_p50    = list(pct_delta = 152.0, abs_delta = 58.0),
          ttc_p90    = list(pct_delta = 10.0,  abs_delta = 9.5),
          att_p50    = list(pct_delta = NA,     abs_delta = 0.0),
          close_rate = list(pct_delta = -5.0,   abs_delta = -0.03)
        )
      )
    ),
    per_repo_7d = list(),
    # outliers_recent_7d: renamed from outliers_14d (llm#793-followup) — ranked
    # by closed_at within a 7-day window instead of created_at within 14 days.
    outliers_recent_7d = list(
      window_days = 7L,
      by_time = list(
        list(review_id = 975L, repo = "knowledge", n_attempts = 1L,
             time_to_close_hrs = 289.9, close_reason = "fixer", created_at = paste0(date, "T00:00:00Z")),
        list(review_id = 800L, repo = "llm", n_attempts = 2L,
             time_to_close_hrs = 120.5, close_reason = "manual", created_at = paste0(date, "T01:00:00Z"))
      ),
      by_attempts = list(
        list(review_id = 4313L, repo = "llmtelemetry", n_attempts = 4L,
             time_to_close_hrs = 48.0, close_reason = "fixer", created_at = paste0(date, "T02:00:00Z"))
      ),
      by_attempts_degenerate = FALSE
    )
  )
}

# ── Helper: run send_roborev_email.R in dry-run against a fixture ──────────────

run_email_dry_run <- function(fixture, extra_env = character(0)) {
  dir <- tempfile("roborev_test_")
  dir.create(dir, recursive = TRUE)
  on.exit(unlink(dir, recursive = TRUE))

  json_path <- file.path(dir, paste0(fixture$report_date, ".json"))
  writeLines(
    jsonlite::toJSON(fixture, auto_unbox = TRUE, pretty = TRUE, na = "null"),
    json_path
  )

  # Primary: installed package path (CI). Fallback: dev-time source tree.
  email_script <- system.file(
    "scripts/send_roborev_email.R",
    package = "llm",
    mustWork = FALSE
  )
  if (!nzchar(email_script) || !file.exists(email_script)) {
    email_script <- normalizePath(
      file.path(dirname(dirname(testthat::test_path())),
                ".claude", "scripts", "send_roborev_email.R"),
      mustWork = FALSE
    )
  }
  expect_true(
    nzchar(email_script) && file.exists(email_script),
    info = "send_roborev_email.R must be present (via system.file or dev-time fallback)"
  )

  env_vars <- c(
    "EMAIL_DRY_RUN=1",
    paste0("ROBOREV_DAILY_DIR=", dir),
    "GMAIL_USERNAME=",
    "GMAIL_APP_PASSWORD=",
    "REPORT_RECIPIENT=",
    extra_env
  )

  # Pre-existing bug fix: `env = c(Sys.getenv(), env_vars)` below used to pass
  # Sys.getenv()'s bare VALUES (no "NAME=" prefix) to system2()'s `env=`
  # argument, which expects "NAME=value" strings — garbling the child process's
  # environment (observed: values containing spaces/tokens got split into
  # bogus positional args, e.g. "sh: claude-code_2-1-211_agent: command not
  # found"). system2() already inherits the calling process's environment by
  # default, and withr::with_envvar() has already set env_vars in THIS
  # process for the duration of the block — so no explicit `env=` override is
  # needed at all.
  result <- withr::with_envvar(
    setNames(
      sub("^[^=]+=", "", env_vars),
      sub("=.*$", "", env_vars)
    ),
    {
      tryCatch(
        system2("Rscript", args = email_script,
                stdout = TRUE, stderr = TRUE),
        error = function(e) as.character(e$message)
      )
    }
  )
  result
}

# ── Tests: send_roborev_email.R ────────────────────────────────────────────────

test_that("dry-run output contains headline numbers", {
  skip_if_not_installed("blastula")
  snap <- make_synthetic_snapshot()
  out <- run_email_dry_run(snap)
  combined <- paste(out, collapse = "\n")

  # Headline numbers present
  expect_true(grepl("74", combined), info = "issues_found_closed=74 not found")
  expect_true(grepl("50", combined), info = "issues_found_open=50 not found")
  expect_true(grepl("59", combined), info = "close_rate ~59.7% not found")
  # TTC p50
  expect_true(grepl("96", combined), info = "TTC p50=96.0h not found")
})

test_that("dry-run output contains dashboard link", {
  skip_if_not_installed("blastula")
  snap <- make_synthetic_snapshot()
  out <- run_email_dry_run(snap,
    extra_env = "ROBOREV_DASHBOARD_URL=https://example.com/roborev")
  combined <- paste(out, collapse = "\n")
  expect_true(grepl("example.com/roborev", combined),
              info = "dashboard URL not found in dry-run output")
})

test_that("dry-run output contains QA markers", {
  skip_if_not_installed("blastula")
  snap <- make_synthetic_snapshot()
  out <- run_email_dry_run(snap)
  combined <- paste(out, collapse = "\n")
  expect_true(grepl("QA:report_date=2026-05-28", combined),
              info = "QA:report_date marker missing")
  expect_true(grepl("QA:issues_found_closed=74", combined),
              info = "QA:issues_found_closed marker missing")
})

test_that("dry-run output is non-empty", {
  skip_if_not_installed("blastula")
  snap <- make_synthetic_snapshot()
  out <- run_email_dry_run(snap)
  combined <- paste(out, collapse = "\n")
  expect_gt(nchar(combined), 500L)
})

test_that("dry-run output contains outlier review IDs", {
  skip_if_not_installed("blastula")
  snap <- make_synthetic_snapshot()
  out <- run_email_dry_run(snap)
  combined <- paste(out, collapse = "\n")
  expect_true(grepl("975", combined), info = "outlier review_id=975 not found")
})

test_that("script exits non-zero when no JSON found in empty dir", {
  skip_if_not_installed("blastula")

  # Primary: installed package path (CI). Fallback: dev-time source tree.
  email_script <- system.file(
    "scripts/send_roborev_email.R",
    package = "llm",
    mustWork = FALSE
  )
  if (!nzchar(email_script) || !file.exists(email_script)) {
    email_script <- normalizePath(
      file.path(dirname(dirname(testthat::test_path())),
                ".claude", "scripts", "send_roborev_email.R"),
      mustWork = FALSE
    )
  }
  expect_true(
    nzchar(email_script) && file.exists(email_script),
    info = "send_roborev_email.R must be present (via system.file or dev-time fallback)"
  )

  empty_dir <- tempfile("roborev_empty_")
  dir.create(empty_dir)
  on.exit(unlink(empty_dir, recursive = TRUE))

  # Use system() to capture exit code
  cmd <- sprintf(
    "EMAIL_DRY_RUN=1 ROBOREV_DAILY_DIR='%s' Rscript '%s' > /dev/null 2>&1; echo $?",
    empty_dir, email_script
  )
  exit_code <- as.integer(trimws(system(cmd, intern = TRUE)))
  expect_true(exit_code != 0L,
    info = sprintf("Expected non-zero exit for empty dir, got %d", exit_code))
})

# ── Tests: publish_roborev_data.sh ────────────────────────────────────────────

test_that("publish_roborev_data.sh passes bash -n syntax check", {
  publish_script <- normalizePath(
    file.path(dirname(dirname(testthat::test_path())),
              "bin", "publish_roborev_data.sh"),
    mustWork = FALSE
  )
  skip_if_not(file.exists(publish_script), "publish_roborev_data.sh not found")

  exit_code <- system2("bash", args = c("-n", publish_script),
                       stdout = FALSE, stderr = FALSE)
  expect_equal(exit_code, 0L, info = "publish_roborev_data.sh has bash syntax errors")
})

test_that("publish_roborev_data.sh DRYRUN=1 exits 0 with expected log lines", {
  publish_script <- normalizePath(
    file.path(dirname(dirname(testthat::test_path())),
              "bin", "publish_roborev_data.sh"),
    mustWork = FALSE
  )
  skip_if_not(file.exists(publish_script), "publish_roborev_data.sh not found")

  dir <- tempfile("roborev_pub_test_")
  dir.create(dir)
  on.exit(unlink(dir, recursive = TRUE))

  # Write a fake snapshot
  fake_json <- file.path(dir, "2026-05-28.json")
  writeLines('{"report_date":"2026-05-28"}', fake_json)

  # NOTE: env = <overrides only>, NOT c(Sys.getenv(), ...) -- system2()
  # renders `env` as `env NAME=VAL ... cmd`, and `env` already inherits the
  # parent environment, so splicing all of Sys.getenv() in produces a vast
  # command line whose quoting mangles the invocation. Same defect fixed in
  # test-kb-digest.R (llm#848) and test-overnight-self-review-email.R (llm#871).
  env_vars <- c(
    "DRYRUN=1",
    paste0("ROBOREV_DAILY_DIR=", dir)
  )
  out <- system2("bash", args = publish_script,
                 stdout = TRUE, stderr = TRUE,
                 env = env_vars)
  combined <- paste(out, collapse = "\n")

  expect_true(grepl("DRYRUN", combined), info = "DRYRUN log line not emitted")
  expect_true(grepl("skip", combined, ignore.case = TRUE),
              info = "Expected 'skip' in DRYRUN output")
})

# ── Tests: roborev_daily_cron.sh ──────────────────────────────────────────────

test_that("roborev_daily_cron.sh passes bash -n syntax check", {
  cron_script <- normalizePath(
    file.path(dirname(dirname(testthat::test_path())),
              "bin", "roborev_daily_cron.sh"),
    mustWork = FALSE
  )
  skip_if_not(file.exists(cron_script), "roborev_daily_cron.sh not found")

  exit_code <- system2("bash", args = c("-n", cron_script),
                       stdout = FALSE, stderr = FALSE)
  expect_equal(exit_code, 0L, info = "roborev_daily_cron.sh has bash syntax errors")
})

test_that("roborev_daily_cron.sh DRYRUN=1 smoke: exits 0", {
  cron_script <- normalizePath(
    file.path(dirname(dirname(testthat::test_path())),
              "bin", "roborev_daily_cron.sh"),
    mustWork = FALSE
  )
  skip_if_not(file.exists(cron_script), "roborev_daily_cron.sh not found")

  # Use timeout to guard against accidental blocking
  cmd <- sprintf(
    "DRYRUN=1 EMAIL_DRY_RUN=1 timeout 30 bash '%s' > /tmp/roborev_cron_test.log 2>&1; echo $?",
    cron_script
  )
  exit_code <- as.integer(trimws(system(cmd, intern = TRUE)))
  # 0 = success, 1 = step failed gracefully, anything else is unexpected
  expect_true(exit_code %in% c(0L, 1L),
    info = sprintf("Unexpected exit code %d from dry-run cron", exit_code))
})

# ── Tests: #529 footer no-regression, #527 details open count, #484 QA marker ──

test_that("dry-run output has no malformed footer CSS (no font-size:# or style='; ')", {
  # #529 regression guard: severity_html must NOT bleed into the footer color slot
  skip_if_not_installed("blastula")
  snap <- make_synthetic_snapshot()
  out <- run_email_dry_run(snap)
  combined <- paste(out, collapse = "\n")

  expect_false(grepl("font-size:#", combined, fixed = TRUE),
    info = "#529 regression: 'font-size:#' found — severity_html is bleeding into footer color slot")
  expect_false(grepl('style="; ', combined, fixed = TRUE),
    info = "#529 regression: 'style=\"; ' found — malformed style attribute in footer")
})

test_that("dry-run output has exactly one <details open> (headline 24h only)", {
  # #527: headline_1d_html uses open=TRUE, all other collapsible blocks use open=FALSE
  skip_if_not_installed("blastula")
  snap <- make_synthetic_snapshot()
  out <- run_email_dry_run(snap)
  combined <- paste(out, collapse = "\n")

  n_details_open <- lengths(regmatches(combined, gregexpr("<details open", combined, fixed = TRUE)))
  expect_equal(n_details_open, 1L,
    info = sprintf("#527: expected exactly 1 '<details open' but found %d", n_details_open))

  n_details_total <- lengths(regmatches(combined, gregexpr("<details", combined, fixed = TRUE)))
  # Pre-existing bug fix: expect_gte() does not accept an `info=` argument in
  # the installed testthat version ("unused argument"), so this assertion was
  # never actually reached. expect_true() with a computed condition supports
  # `info=` and preserves the original intent.
  expect_true(n_details_total >= 5L,
    info = sprintf("#527: expected at least 5 '<details' blocks but found %d", n_details_total))
})

test_that("dry-run output contains QA:zero_action_trap_fired marker", {
  # #484: zero_action_trap_fired must appear in qa_markers regardless of whether trap fired
  skip_if_not_installed("blastula")
  snap <- make_synthetic_snapshot()
  out <- run_email_dry_run(snap)
  combined <- paste(out, collapse = "\n")

  expect_true(grepl("QA:zero_action_trap_fired=", combined),
    info = "#484: QA:zero_action_trap_fired marker missing from dry-run output")
})

# ── Tests: llm#793-followup — severity Unknown column, project links, ────────
#   de-frozen outliers, staleness guardrails

test_that("severity table shows Unknown column and flags a Total mismatch", {
  # Fix 1: the table used to render only High/Medium/Low/Total, silently
  # under-summing Total (compute_severity_by_project() always includes a 4th
  # Unknown bucket in Total). Adding the column must make the display
  # reconcile with Total; a genuinely mismatched row must be flagged (Fix 4.2).
  skip_if_not_installed("blastula")
  snap <- make_synthetic_snapshot()
  snap$severity_by_project_7d <- list(
    list(repo = "llm", High = 2L, Medium = 3L, Low = 1L, Unknown = 4L, Total = 10L),
    list(repo = "llmtelemetry", High = 1L, Medium = 1L, Low = 1L, Unknown = 1L, Total = 99L)
  )
  out <- run_email_dry_run(snap)
  combined <- paste(out, collapse = "\n")

  expect_true(grepl(">Unknown<", combined, fixed = TRUE),
    info = "Severity table must render an Unknown column header")
  expect_true(grepl("&#9888; 99", combined, fixed = TRUE),
    info = "Severity row with Total != High+Medium+Low+Unknown must be flagged with a warning glyph")
})

test_that("degenerate by-attempts outliers table is replaced with a note", {
  # Fix 3b: when every closed review in the window closed on the first
  # attempt, "by attempts" is an identical duplicate of "by time" — omit it.
  skip_if_not_installed("blastula")
  snap <- make_synthetic_snapshot()
  snap$outliers_recent_7d$by_attempts <- list(
    list(review_id = 4313L, repo = "llmtelemetry", n_attempts = 1L,
         time_to_close_hrs = 48.0, close_reason = "fixer", created_at = "2026-05-28T02:00:00Z")
  )
  snap$outliers_recent_7d$by_attempts_degenerate <- TRUE
  out <- run_email_dry_run(snap)
  combined <- paste(out, collapse = "\n")

  expect_true(grepl("No retry data", combined, fixed = TRUE),
    info = "Degenerate by-attempts outliers must render the no-retry-data note")
  expect_false(grepl("Top-5 Outliers by Attempts-to-Close", combined, fixed = TRUE),
    info = "Degenerate by-attempts outliers must NOT render the normal ranked table")
})

test_that("known public repo is hyperlinked; unresolvable slug stays plain text", {
  # Fix 2: every slug used to be hardcoded to
  # https://github.com/JohnGavin/<slug>, which 404s for non-repo slugs (e.g.
  # a local-only planning folder with no GitHub remote).
  skip_if_not_installed("blastula")
  snap <- make_synthetic_snapshot()
  snap$severity_by_project_7d <- list(
    list(repo = "llm", High = 0L, Medium = 0L, Low = 0L, Unknown = 0L, Total = 0L),
    list(repo = "localonlyproj", High = 0L, Medium = 0L, Low = 0L, Unknown = 0L, Total = 0L)
  )
  out <- run_email_dry_run(snap)
  combined <- paste(out, collapse = "\n")

  expect_true(grepl('href="https://github.com/JohnGavin/llm"', combined, fixed = TRUE),
    info = "Known public repo 'llm' must be hyperlinked")
  expect_false(grepl('href="https://github.com/JohnGavin/localonlyproj"', combined, fixed = TRUE),
    info = "Unresolvable slug 'localonlyproj' must NOT be hyperlinked (this was the 404 bug)")
})

# ── Tests: llm#961 regression guard — delta-vs-standing above-threshold banner ─
#
# The defect llm#961 fixed: the above-threshold-open-findings alert used to
# fire on the STANDING backlog total (84% of the whole open backlog on the
# day this was diagnosed), so the red banner rendered every single day
# regardless of whether anything new happened. The fix computes the banner
# off the DAILY DELTA (new_above_threshold_open_n) instead. These tests pin
# that behaviour against a fixture reviews.db (never the live DB, whose
# contents drift hourly) via the ROBOREV_DB env var — the same seam
# query_reviews_db() already reads, wired through run_email_dry_run()'s
# existing extra_env parameter (no script changes needed).

# make_reviews_db_fixture(): builds a genuine sqlite3-readable reviews.db
# fixture (repos/review_jobs/reviews, minimal columns) using DuckDB's sqlite
# extension to ATTACH and write a real .db file on disk — the same mechanism
# already used for reviews.db-shaped fixtures in test-roborev-etl-lifecycle.R
# (reused rather than inventing a second fixture-DB mechanism; the `sqlite3`
# CLI that query_reviews_db() shells out to reads this file directly).
#
#   findings: rows counted by the open-findings query (closed=0, verdict_bool=0)
#     each: list(output=<string>, age_hours=<numeric>)
#   lagged: extra rows for the 2-8 day aged close-rate query only
#     (closed can be either value; verdict_bool is fixed at 1 so these never
#     leak into the open-findings counts above)
#     each: list(age_hours=<numeric>, closed=<0L|1L>)
make_reviews_db_fixture <- function(findings = list(), lagged = list()) {
  skip_if_not_installed("duckdb")
  dir <- tempfile("roborev_db_fixture_")
  dir.create(dir, recursive = TRUE)
  db_path <- file.path(dir, "reviews_fixture.db")

  con <- DBI::dbConnect(duckdb::duckdb(), ":memory:")
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, "LOAD sqlite")
  DBI::dbExecute(con, sprintf("ATTACH '%s' AS fix (TYPE sqlite)", db_path))

  DBI::dbExecute(con, "CREATE TABLE fix.repos (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
  DBI::dbExecute(con, "CREATE TABLE fix.review_jobs (id INTEGER PRIMARY KEY, repo_id INTEGER)")
  DBI::dbExecute(con, "
    CREATE TABLE fix.reviews (
      id INTEGER PRIMARY KEY,
      job_id INTEGER,
      output TEXT DEFAULT '',
      created_at TEXT,
      closed INTEGER DEFAULT 0,
      verdict_bool INTEGER
    )
  ")
  DBI::dbExecute(con, "INSERT INTO fix.repos VALUES (1, 'llm')")

  now <- as.POSIXct(format(Sys.time(), tz = "UTC"), tz = "UTC")
  row_id <- 0L
  insert_row <- function(output, age_hours, closed, verdict_bool) {
    row_id <<- row_id + 1L
    DBI::dbExecute(con, sprintf("INSERT INTO fix.review_jobs VALUES (%d, 1)", row_id))
    ts <- format(now - age_hours * 3600, "%Y-%m-%d %H:%M:%S", tz = "UTC")
    output_escaped <- gsub("'", "''", output, fixed = TRUE)
    DBI::dbExecute(con, sprintf(
      "INSERT INTO fix.reviews (id, job_id, output, created_at, closed, verdict_bool) VALUES (%d, %d, '%s', '%s', %d, %d)",
      row_id, row_id, output_escaped, ts, closed, verdict_bool
    ))
  }
  for (f in findings) insert_row(f$output, f$age_hours, 0L, 0L)
  for (l in lagged)   insert_row("", l$age_hours, l$closed, 1L)

  db_path
}

HIGH_SEV_OUTPUT <- "Review found an issue.\n\n**Severity**: High\n\nDetails: something bad."
NO_SEV_OUTPUT   <- "Review crashed before emitting a severity marker."

test_that("zero delta: standing above-threshold findings exist but none are new -> no banner, marker is 0", {
  # The single most important property of the llm#961 fix: when nothing NEW
  # arrived, the banner must not render at all -- regardless of how large the
  # standing backlog is.
  skip_if_not_installed("blastula")
  db_path <- make_reviews_db_fixture(
    findings = list(
      list(output = HIGH_SEV_OUTPUT, age_hours = 240),  # 10d old -- standing, NOT new
      list(output = HIGH_SEV_OUTPUT, age_hours = 240),
      list(output = HIGH_SEV_OUTPUT, age_hours = 240)
    )
  )
  snap <- make_synthetic_snapshot()
  out <- run_email_dry_run(snap, extra_env = paste0("ROBOREV_DB=", db_path))
  combined <- paste(out, collapse = "\n")

  expect_false(grepl("New Above-Threshold Open Finding", combined, fixed = TRUE),
    info = "llm#961: banner must NOT render when the delta is zero, even with a large standing backlog")
  expect_true(grepl("QA:new_above_threshold_open_n=0", combined, fixed = TRUE),
    info = "llm#961: new_above_threshold_open_n marker must be 0 when nothing new arrived")
})

test_that("non-zero delta: banner fires on the delta count, not the standing total", {
  skip_if_not_installed("blastula")
  standing <- lapply(1:12, function(i) list(output = HIGH_SEV_OUTPUT, age_hours = 240))
  new_ones <- lapply(1:2,  function(i) list(output = HIGH_SEV_OUTPUT, age_hours = 1))
  db_path <- make_reviews_db_fixture(findings = c(standing, new_ones))
  snap <- make_synthetic_snapshot()
  out <- run_email_dry_run(snap, extra_env = paste0("ROBOREV_DB=", db_path))
  combined <- paste(out, collapse = "\n")

  expect_true(grepl("2 New Above-Threshold Open Finding", combined, fixed = TRUE),
    info = "llm#961: banner header must show the delta count (2)")
  expect_false(grepl("14 New Above-Threshold Open Finding", combined, fixed = TRUE),
    info = paste(
      "llm#961: banner header must NOT show the standing total (14) --",
      "a regression to the standing-total banner would pass this test's",
      "old assertion but fail this one"
    ))
  expect_true(grepl("QA:new_above_threshold_open_n=2", combined, fixed = TRUE),
    info = "new_above_threshold_open_n marker must equal the delta (2), not the standing total")
  expect_true(grepl("QA:total_above_threshold_open_n=14", combined, fixed = TRUE),
    info = "total_above_threshold_open_n marker must equal the full standing+new total (12+2=14)")
})

test_that("unparseable findings never inflate the above-threshold buckets", {
  # The two buckets are disjoint: an unparseable-severity finding is a
  # data-quality signal about the parser, not a triage backlog item, and must
  # never be counted as above-threshold in either the new or total marker.
  skip_if_not_installed("blastula")
  db_path <- make_reviews_db_fixture(
    findings = list(
      list(output = NO_SEV_OUTPUT, age_hours = 1),
      list(output = NO_SEV_OUTPUT, age_hours = 1),
      list(output = NO_SEV_OUTPUT, age_hours = 1),
      list(output = NO_SEV_OUTPUT, age_hours = 1)
    )
  )
  snap <- make_synthetic_snapshot()
  out <- run_email_dry_run(snap, extra_env = paste0("ROBOREV_DB=", db_path))
  combined <- paste(out, collapse = "\n")

  expect_true(grepl("QA:new_above_threshold_open_n=0", combined, fixed = TRUE),
    info = "unparseable findings must not count as above-threshold (new)")
  expect_true(grepl("QA:total_above_threshold_open_n=0", combined, fixed = TRUE),
    info = "unparseable findings must not count as above-threshold (total)")
  expect_true(grepl("QA:new_unparseable_open_n=4", combined, fixed = TRUE),
    info = "all 4 unparseable findings must be counted as new_unparseable_open_n")
  expect_true(grepl("QA:total_unparseable_open_n=4", combined, fixed = TRUE),
    info = "all 4 unparseable findings must be counted as total_unparseable_open_n")
  expect_true(grepl("Unparseable severity", combined, fixed = TRUE),
    info = "unparseable block must render (informational, not the red alarm)")
  expect_false(grepl("New Above-Threshold Open Finding", combined, fixed = TRUE),
    info = "unparseable findings must never trigger the above-threshold red banner")
})

test_that("headline close-rate row states its aged window explicitly", {
  # A metric whose label disagrees with its computation is the defect family
  # llm#961 belongs to -- the row must name the window (aged 2-8d) it was
  # actually computed over.
  skip_if_not_installed("blastula")
  db_path <- make_reviews_db_fixture(
    lagged = list(
      list(age_hours = 96, closed = 1L),
      list(age_hours = 96, closed = 1L),
      list(age_hours = 96, closed = 0L),
      list(age_hours = 96, closed = 0L),
      list(age_hours = 96, closed = 0L)
    )
  )
  snap <- make_synthetic_snapshot()
  # headline_1d_rows (where the close-rate row lives) only renders when d1 is
  # present with n_reviews > 0 -- otherwise the empty-state row is shown instead.
  snap$global_windows$d1 <- list(
    window_days = 1L,
    n_reviews = 5L,
    freq_table = list(
      list(verdict_label = "issues_found", status = "closed", n = 1L),
      list(verdict_label = "issues_found", status = "open",   n = 2L),
      list(verdict_label = "clean",        status = "closed", n = 1L),
      list(verdict_label = "clean",        status = "open",   n = 1L)
    )
  )
  out <- run_email_dry_run(snap, extra_env = paste0("ROBOREV_DB=", db_path))
  combined <- paste(out, collapse = "\n")

  expect_true(grepl("close rate (aged 2-8d)", combined, fixed = TRUE),
    info = paste(
      "llm#961: the close-rate row must name its window (aged 2-8d) so the",
      "label can't silently disagree with its computation"
    ))
  expect_true(grepl("40.0%", combined, fixed = TRUE),
    info = "close rate for the fixture cohort (2 closed / 5 total) must be 40.0%")
})

test_that("snapshot older than 24h triggers the staleness banner", {
  # Fix 4.1: find_latest_json() picks the newest-mtime snapshot with no age
  # check; a stale snapshot must be surfaced loudly, not rendered silently.
  skip_if_not_installed("blastula")
  dir <- tempfile("roborev_stale_test_")
  dir.create(dir, recursive = TRUE)
  on.exit(unlink(dir, recursive = TRUE))

  snap <- make_synthetic_snapshot()
  json_path <- file.path(dir, paste0(snap$report_date, ".json"))
  writeLines(
    jsonlite::toJSON(snap, auto_unbox = TRUE, pretty = TRUE, na = "null"),
    json_path
  )
  Sys.setFileTime(json_path, Sys.time() - as.difftime(48, units = "hours"))

  email_script <- system.file("scripts/send_roborev_email.R", package = "llm", mustWork = FALSE)
  if (!nzchar(email_script) || !file.exists(email_script)) {
    email_script <- normalizePath(
      file.path(dirname(dirname(testthat::test_path())),
                ".claude", "scripts", "send_roborev_email.R"),
      mustWork = FALSE
    )
  }
  skip_if_not(file.exists(email_script), "send_roborev_email.R not found")

  env_vars <- c(
    "EMAIL_DRY_RUN=1",
    paste0("ROBOREV_DAILY_DIR=", dir),
    "GMAIL_USERNAME=", "GMAIL_APP_PASSWORD=", "REPORT_RECIPIENT="
  )
  out <- withr::with_envvar(
    setNames(sub("^[^=]+=", "", env_vars), sub("=.*$", "", env_vars)),
    system2("Rscript", args = email_script, stdout = TRUE, stderr = TRUE)
  )
  combined <- paste(out, collapse = "\n")
  expect_true(grepl("STALE SNAPSHOT", combined, fixed = TRUE),
    info = "Snapshot older than 24h must trigger the staleness banner")
})

# ── Tests: llm#972 cause 1 — unbolded "Severity:" marker must also parse ──────
#
# Diagnosed on the live DB: agents emit two shapes for the same marker,
#   "- **Severity**: Medium"   (parses under the old regex)
#   "- Severity: High"         (did NOT parse under the old regex — cause 1)
# Structurally identical apart from the markdown bold markers; not
# agent-specific (gemini and claude-code both produce the plain form).
# `parse_max_severity_ordinal()` (send_roborev_email.R) now makes the `**`
# optional on both sides of "Severity" via `\*{0,2}`. These tests pin: (a)
# the bold form still parses (no regression on the ~58 open reviews that
# already worked), (b) the plain form now parses (the fix, ~21 reviews),
# (c) output with no severity marker at all stays unparseable (cause 2 is a
# SEPARATE, out-of-scope problem — 39 reviews with no findings block at all;
# this test pins the boundary so a later over-broad change cannot silently
# swallow cause 2 too), and (d) prose that merely contains the word
# "severity" (no colon-anchored marker) is not mistaken for a finding.
PLAIN_HIGH_SEV_OUTPUT <- paste(
  "Review Findings:",
  "- Severity: High",
  "- Location: `inst/extdata/codexbar_cost_daily.json`",
  "- Problem: something bad.",
  sep = "\n"
)
PROSE_SEVERITY_NO_MARKER_OUTPUT <- paste(
  "This review discusses the severity of the issue at length, but does not",
  "include a structured severity marker anywhere in its output.",
  "Overall assessment: needs more investigation.",
  sep = "\n"
)

test_that("llm#972: bold '**Severity**: High' still parses as above-threshold (no regression)", {
  skip_if_not_installed("blastula")
  db_path <- make_reviews_db_fixture(findings = list(list(output = HIGH_SEV_OUTPUT, age_hours = 1)))
  snap <- make_synthetic_snapshot()
  out <- run_email_dry_run(snap, extra_env = paste0("ROBOREV_DB=", db_path))
  combined <- paste(out, collapse = "\n")

  expect_true(grepl("QA:total_above_threshold_open_n=1", combined, fixed = TRUE),
    info = "bold '**Severity**: High' must still classify as above-threshold at the medium default")
  expect_true(grepl("QA:total_unparseable_open_n=0", combined, fixed = TRUE),
    info = "bold form must not land in the unparseable bucket")
})

test_that("llm#972 cause 1 fix: plain 'Severity: High' (no bold markers) now parses", {
  skip_if_not_installed("blastula")
  db_path <- make_reviews_db_fixture(findings = list(list(output = PLAIN_HIGH_SEV_OUTPUT, age_hours = 1)))
  snap <- make_synthetic_snapshot()
  out <- run_email_dry_run(snap, extra_env = paste0("ROBOREV_DB=", db_path))
  combined <- paste(out, collapse = "\n")

  expect_true(grepl("QA:total_above_threshold_open_n=1", combined, fixed = TRUE),
    info = paste(
      "llm#972: plain 'Severity: High' (no bold markers) must now classify",
      "as above-threshold instead of unparseable"
    ))
  expect_true(grepl("QA:total_unparseable_open_n=0", combined, fixed = TRUE),
    info = "llm#972: plain-form severity must not land in the unparseable bucket after the fix")
})

test_that("llm#972: output with no severity marker at all stays unparseable (cause 2 boundary)", {
  skip_if_not_installed("blastula")
  db_path <- make_reviews_db_fixture(findings = list(list(output = NO_SEV_OUTPUT, age_hours = 1)))
  snap <- make_synthetic_snapshot()
  out <- run_email_dry_run(snap, extra_env = paste0("ROBOREV_DB=", db_path))
  combined <- paste(out, collapse = "\n")

  expect_true(grepl("QA:total_unparseable_open_n=1", combined, fixed = TRUE),
    info = paste(
      "llm#972: output with no severity marker at all must remain",
      "unparseable -- this is cause 2 territory (no findings block at",
      "all), which is explicitly out of scope for the cause-1 regex fix"
    ))
  expect_true(grepl("QA:total_above_threshold_open_n=0", combined, fixed = TRUE),
    info = "must not be misclassified as above-threshold")
})

test_that("llm#972: prose mentioning the word 'severity' without a marker is not treated as a finding", {
  skip_if_not_installed("blastula")
  db_path <- make_reviews_db_fixture(findings = list(list(output = PROSE_SEVERITY_NO_MARKER_OUTPUT, age_hours = 1)))
  snap <- make_synthetic_snapshot()
  out <- run_email_dry_run(snap, extra_env = paste0("ROBOREV_DB=", db_path))
  combined <- paste(out, collapse = "\n")

  expect_true(grepl("QA:total_unparseable_open_n=1", combined, fixed = TRUE),
    info = paste(
      "prose containing the bare word 'severity' (no colon-anchored",
      "marker) must NOT be treated as a parsed finding -- guards against",
      "the optional-bold regex over-matching beyond the evidence"
    ))
  expect_true(grepl("QA:total_above_threshold_open_n=0", combined, fixed = TRUE),
    info = "prose mention of 'severity' must never be classified above-threshold")
})

# ── Tests: llm#972 cause 2 — unparseable bucket split into not_reviewed / ────
#   passed / unclassified (agent-health vs no-op vs genuine residual)
#
# Diagnosed on the live DB: `verdict_bool` is not a function of the review
# output (identical "SEVERITY_THRESHOLD_MET" bytes appear with verdict_bool=1
# AND verdict_bool=0), so a row in the "unparseable" bucket does not mean
# "needs triage". These tests pin the three-way split added to
# classify_open_findings()/classify_unparseable_finding().

NOT_REVIEWED_EXACT_OUTPUT <- "No review output generated"
NOT_REVIEWED_AGENT_FAILURE_OUTPUT <- paste(
  "I am unable to access the diff file at",
  "`/private/tmp/roborev-snapshot-content.diff` because it is ignored by",
  "configured ignore patterns. Consequently, I cannot perform the requested",
  "code review."
)
PASSED_THRESHOLD_MET_OUTPUT <- "SEVERITY_THRESHOLD_MET"
# Deliberately wraps "issues found" across a line break to prove the
# tolerant-matching requirement -- a naive substring match on raw text fails
# this case.
PASSED_NO_ISSUES_LINEBREAK_OUTPUT <- "No\nissues found"
UNCLASSIFIED_PROSE_OUTPUT <- paste(
  "This review comment matches none of the known agent-failure or",
  "pass-through shapes and should remain visible as a genuine residual."
)

test_that("llm#972 cause 2: exact 'No review output generated' classifies as not_reviewed", {
  skip_if_not_installed("blastula")
  db_path <- make_reviews_db_fixture(findings = list(list(output = NOT_REVIEWED_EXACT_OUTPUT, age_hours = 1)))
  snap <- make_synthetic_snapshot()
  out <- run_email_dry_run(snap, extra_env = paste0("ROBOREV_DB=", db_path))
  combined <- paste(out, collapse = "\n")

  expect_true(grepl("QA:total_not_reviewed_open_n=1", combined, fixed = TRUE),
    info = "'No review output generated' must classify as not_reviewed")
  expect_true(grepl("QA:total_unparseable_open_n=1", combined, fixed = TRUE),
    info = "not_reviewed rows must still count toward the unparseable total")
  expect_true(grepl("QA:total_passed_open_n=0", combined, fixed = TRUE))
  expect_true(grepl("QA:total_unclassified_open_n=0", combined, fixed = TRUE))
})

test_that("llm#972 cause 2: agent-failure prose classifies as not_reviewed", {
  skip_if_not_installed("blastula")
  db_path <- make_reviews_db_fixture(findings = list(list(output = NOT_REVIEWED_AGENT_FAILURE_OUTPUT, age_hours = 1)))
  snap <- make_synthetic_snapshot()
  out <- run_email_dry_run(snap, extra_env = paste0("ROBOREV_DB=", db_path))
  combined <- paste(out, collapse = "\n")

  expect_true(grepl("QA:total_not_reviewed_open_n=1", combined, fixed = TRUE),
    info = "an agent-failure prose sample ('I am unable to access...') must classify as not_reviewed")
})

test_that("llm#972 cause 2: 'SEVERITY_THRESHOLD_MET' alone classifies as passed", {
  skip_if_not_installed("blastula")
  db_path <- make_reviews_db_fixture(findings = list(list(output = PASSED_THRESHOLD_MET_OUTPUT, age_hours = 1)))
  snap <- make_synthetic_snapshot()
  out <- run_email_dry_run(snap, extra_env = paste0("ROBOREV_DB=", db_path))
  combined <- paste(out, collapse = "\n")

  expect_true(grepl("QA:total_passed_open_n=1", combined, fixed = TRUE),
    info = "'SEVERITY_THRESHOLD_MET' alone must classify as passed (inferred, see code comment)")
  expect_true(grepl("QA:total_not_reviewed_open_n=0", combined, fixed = TRUE))
  expect_true(grepl("QA:total_unclassified_open_n=0", combined, fixed = TRUE))
})

test_that("llm#972 cause 2: 'No issues found' wrapped across a line break still classifies as passed (tolerant matching)", {
  skip_if_not_installed("blastula")
  db_path <- make_reviews_db_fixture(findings = list(list(output = PASSED_NO_ISSUES_LINEBREAK_OUTPUT, age_hours = 1)))
  snap <- make_synthetic_snapshot()
  out <- run_email_dry_run(snap, extra_env = paste0("ROBOREV_DB=", db_path))
  combined <- paste(out, collapse = "\n")

  expect_true(grepl("QA:total_passed_open_n=1", combined, fixed = TRUE),
    info = paste(
      "'No\\nissues found' (line break mid-phrase) must still classify as",
      "passed -- a naive literal-substring matcher would miss this and is",
      "exactly the failure mode this test guards against"
    ))
})

test_that("llm#972 cause 2: unrecognised prose classifies as unclassified and is reported, not swallowed", {
  skip_if_not_installed("blastula")
  db_path <- make_reviews_db_fixture(findings = list(list(output = UNCLASSIFIED_PROSE_OUTPUT, age_hours = 1)))
  snap <- make_synthetic_snapshot()
  out <- run_email_dry_run(snap, extra_env = paste0("ROBOREV_DB=", db_path))
  combined <- paste(out, collapse = "\n")

  expect_true(grepl("QA:total_unclassified_open_n=1", combined, fixed = TRUE),
    info = "unrecognised prose must classify as unclassified")
  expect_true(grepl("QA:total_not_reviewed_open_n=0", combined, fixed = TRUE))
  expect_true(grepl("QA:total_passed_open_n=0", combined, fixed = TRUE))
  # Requirement 2: the residual must be VISIBLE, not silently absorbed into
  # the aggregate total -- assert the breakdown text actually renders in the
  # email body, not just in the QA marker.
  expect_true(grepl("unclassified", combined, fixed = TRUE),
    info = "the unclassified count must be reported in the rendered email body, not only the QA marker")
})

test_that("llm#972 cause 2: a real bold-severity finding is still counted as a finding (regression guard)", {
  # A classifier that tidies everything away into not_reviewed/passed/
  # unclassified would be a worse bug than the one being fixed -- this pins
  # that a genuine above-threshold finding is untouched by the new logic.
  skip_if_not_installed("blastula")
  db_path <- make_reviews_db_fixture(findings = list(list(output = HIGH_SEV_OUTPUT, age_hours = 1)))
  snap <- make_synthetic_snapshot()
  out <- run_email_dry_run(snap, extra_env = paste0("ROBOREV_DB=", db_path))
  combined <- paste(out, collapse = "\n")

  expect_true(grepl("QA:total_above_threshold_open_n=1", combined, fixed = TRUE),
    info = "a genuine bold-severity finding must still be classified above-threshold")
  expect_true(grepl("QA:total_unparseable_open_n=0", combined, fixed = TRUE),
    info = "a genuine bold-severity finding must not fall into the unparseable bucket at all")
  expect_true(grepl("QA:total_not_reviewed_open_n=0", combined, fixed = TRUE))
  expect_true(grepl("QA:total_passed_open_n=0", combined, fixed = TRUE))
  expect_true(grepl("QA:total_unclassified_open_n=0", combined, fixed = TRUE))
})

test_that("llm#972 cause 2: mixed population reconciles -- sub-counts sum to the unparseable total", {
  skip_if_not_installed("blastula")
  db_path <- make_reviews_db_fixture(findings = list(
    list(output = NOT_REVIEWED_EXACT_OUTPUT, age_hours = 1),
    list(output = NOT_REVIEWED_AGENT_FAILURE_OUTPUT, age_hours = 1),
    list(output = PASSED_THRESHOLD_MET_OUTPUT, age_hours = 1),
    list(output = PASSED_NO_ISSUES_LINEBREAK_OUTPUT, age_hours = 1),
    list(output = UNCLASSIFIED_PROSE_OUTPUT, age_hours = 1),
    list(output = HIGH_SEV_OUTPUT, age_hours = 1)
  ))
  snap <- make_synthetic_snapshot()
  out <- run_email_dry_run(snap, extra_env = paste0("ROBOREV_DB=", db_path))
  combined <- paste(out, collapse = "\n")

  expect_true(grepl("QA:total_not_reviewed_open_n=2", combined, fixed = TRUE))
  expect_true(grepl("QA:total_passed_open_n=2", combined, fixed = TRUE))
  expect_true(grepl("QA:total_unclassified_open_n=1", combined, fixed = TRUE))
  expect_true(grepl("QA:total_unparseable_open_n=5", combined, fixed = TRUE),
    info = "not_reviewed(2) + passed(2) + unclassified(1) must equal unparseable total(5)")
  expect_true(grepl("QA:total_above_threshold_open_n=1", combined, fixed = TRUE),
    info = "the one real finding must remain above-threshold, untouched by the new split")
})
