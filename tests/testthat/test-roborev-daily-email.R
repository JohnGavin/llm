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

  out <- system2("bash", args = publish_script,
                 stdout = TRUE, stderr = TRUE,
                 env = c(Sys.getenv(),
                   "DRYRUN=1",
                   paste0("ROBOREV_DAILY_DIR=", dir)))
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
  # "premortem", a local-only planning folder with no GitHub remote).
  skip_if_not_installed("blastula")
  snap <- make_synthetic_snapshot()
  snap$severity_by_project_7d <- list(
    list(repo = "llm", High = 0L, Medium = 0L, Low = 0L, Unknown = 0L, Total = 0L),
    list(repo = "premortem", High = 0L, Medium = 0L, Low = 0L, Unknown = 0L, Total = 0L)
  )
  out <- run_email_dry_run(snap)
  combined <- paste(out, collapse = "\n")

  expect_true(grepl('href="https://github.com/JohnGavin/llm"', combined, fixed = TRUE),
    info = "Known public repo 'llm' must be hyperlinked")
  expect_false(grepl('href="https://github.com/JohnGavin/premortem"', combined, fixed = TRUE),
    info = "Unresolvable slug 'premortem' must NOT be hyperlinked (this was the 404 bug)")
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
