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
        list(review_id = 975L, job_id = 12975L, repo = "knowledge", n_attempts = 1L,
             time_to_close_hrs = 289.9, close_reason = "fixer", created_at = paste0(date, "T00:00:00Z")),
        list(review_id = 800L, job_id = 12800L, repo = "llm", n_attempts = 2L,
             time_to_close_hrs = 120.5, close_reason = "manual", created_at = paste0(date, "T01:00:00Z"))
      ),
      by_attempts = list(
        list(review_id = 4313L, job_id = 14313L, repo = "llmtelemetry", n_attempts = 4L,
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
    # Hermetic defaults for the llm#984/#1044/#1123 health inputs: a test must
    # never read the live ~/.roborev config/acks or write the live state dir.
    paste0("ROBOREV_CONFIG_TOML=", file.path(dir, "no_such_config.toml")),
    paste0("ROBOREV_ACKS_JSONL=", file.path(dir, "no_such_acks.jsonl")),
    paste0("ROBOREV_HEALTH_STATE_DIR=", file.path(dir, "health_state")),
    # llm#816: the eval's stored-run lookup must never touch the live DB.
    paste0("UNIFIED_DB_PATH=", file.path(dir, "no_such_unified.duckdb")),
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
  expect_true(grepl("12975", combined), info = "outlier job_id=12975 not found")
})

test_that("outlier tables print the JOB id (CLI id space), never reviews.id", {
  # roborev's CLI (show/close/comment) takes review_jobs.id. reviews.id is a
  # different id space (review 9409 == job 12500); printing it makes
  # `roborev close <id>` close an unrelated job.
  skip_if_not_installed("blastula")
  snap <- make_synthetic_snapshot()
  out <- run_email_dry_run(snap)
  combined <- paste(out, collapse = "\n")
  expect_true(grepl(">12975<", combined, fixed = TRUE),
    info = "outlier cell must show job_id 12975")
  expect_false(grepl(">975<", combined, fixed = TRUE),
    info = "outlier cell must NOT show reviews.id 975")
  expect_false(grepl(">4313<", combined, fixed = TRUE),
    info = "by-attempts outlier cell must NOT show reviews.id 4313")
  expect_true(grepl(">14313<", combined, fixed = TRUE),
    info = "by-attempts outlier cell must show job_id 14313")
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
#   findings[[i]]$duration_min / $status: optional (llm#984 item 2) -- the
#     job's started_at..finished_at span and review_jobs.status; default is a
#     'done' job of 1 minute so pre-existing callers are unaffected.
#   repo_root: repos.root_path of the single fixture repo (where a per-repo
#     .roborev.toml override is looked up).
make_reviews_db_fixture <- function(findings = list(), lagged = list(), job_offset = 0L,
                                    repo_root = "") {
  skip_if_not_installed("duckdb")
  dir <- tempfile("roborev_db_fixture_")
  dir.create(dir, recursive = TRUE)
  db_path <- file.path(dir, "reviews_fixture.db")

  con <- DBI::dbConnect(duckdb::duckdb(), ":memory:")
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  # sqlite is bundled in recent DuckDB builds and LOAD succeeds without
  # INSTALL; INSTALL fetches from the network and can fail/be unavailable
  # in offline or restricted environments (e.g. covr::package_coverage()
  # CI runners). Mirrors the established try-LOAD-then-INSTALL+LOAD
  # fallback already used in .claude/scripts/roborev_metrics_etl.R and
  # friends for this exact extension.
  tryCatch(
    DBI::dbExecute(con, "LOAD sqlite"),
    error = function(e_load) {
      DBI::dbExecute(con, "INSTALL sqlite")
      DBI::dbExecute(con, "LOAD sqlite")
    }
  )
  DBI::dbExecute(con, sprintf("ATTACH '%s' AS fix (TYPE sqlite)", db_path))

  DBI::dbExecute(con, "CREATE TABLE fix.repos (id INTEGER PRIMARY KEY, name TEXT NOT NULL, root_path TEXT)")
  # agent/model: added for the llm#1044 per-agent review-health block — a
  # default of 'codex'/NULL mirrors the live schema's
  # review_jobs.agent NOT NULL DEFAULT 'codex' (model has no default there
  # either) so every EXISTING caller of this fixture (which never passes
  # agent/model) keeps constructing the same rows it always did.
  DBI::dbExecute(con, "CREATE TABLE fix.review_jobs (id INTEGER PRIMARY KEY, repo_id INTEGER, agent TEXT DEFAULT 'codex', model TEXT, status TEXT DEFAULT 'done', started_at TEXT, finished_at TEXT)")
  DBI::dbExecute(con, "
    CREATE TABLE fix.reviews (
      id INTEGER PRIMARY KEY,
      job_id INTEGER,
      output TEXT DEFAULT '',
      structured_output TEXT DEFAULT NULL,
      created_at TEXT,
      closed INTEGER DEFAULT 0,
      verdict_bool INTEGER
    )
  ")
  DBI::dbExecute(con, sprintf("INSERT INTO fix.repos (id, name, root_path) VALUES (1, 'llm', '%s')", repo_root))

  now <- as.POSIXct(format(Sys.time(), tz = "UTC"), tz = "UTC")
  row_id <- 0L
  # `structured_output`: PR #1269 round 3 -- optional, defaults to NA (no
  # existing caller passes it, so every pre-existing fixture row keeps
  # constructing exactly what it always did with output-only rows).
  insert_row <- function(output, age_hours, closed, verdict_bool,
                          agent = "codex", model = NA_character_,
                          structured_output = NA_character_,
                          duration_min = 1, status = "done") {
    row_id <<- row_id + 1L
    model_sql <- if (is.na(model)) "NULL" else sprintf("'%s'", gsub("'", "''", model, fixed = TRUE))
    DBI::dbExecute(con, sprintf(
      "INSERT INTO fix.review_jobs (id, repo_id, agent, model, status, started_at, finished_at) VALUES (%d, 1, '%s', %s, '%s', '%s', '%s')",
      row_id + job_offset, gsub("'", "''", agent, fixed = TRUE), model_sql, status,
      format(now - age_hours * 3600 - duration_min * 60, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
      format(now - age_hours * 3600, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
    ))
    ts <- format(now - age_hours * 3600, "%Y-%m-%d %H:%M:%S", tz = "UTC")
    output_escaped <- gsub("'", "''", output, fixed = TRUE)
    structured_sql <- if (is.na(structured_output)) {
      "NULL"
    } else {
      sprintf("'%s'", gsub("'", "''", structured_output, fixed = TRUE))
    }
    DBI::dbExecute(con, sprintf(
      "INSERT INTO fix.reviews (id, job_id, output, structured_output, created_at, closed, verdict_bool) VALUES (%d, %d, '%s', %s, '%s', %d, %d)",
      row_id, row_id + job_offset, output_escaped, structured_sql, ts, closed, verdict_bool
    ))
  }
  for (f in findings) {
    insert_row(f$output, f$age_hours, 0L, 0L,
               agent = if (is.null(f$agent)) "codex" else f$agent,
               model = if (is.null(f$model)) NA_character_ else f$model,
               structured_output = if (is.null(f$structured_output)) NA_character_ else f$structured_output,
               duration_min = if (is.null(f$duration_min)) 1 else f$duration_min,
               status = if (is.null(f$status)) "done" else f$status)
  }
  for (l in lagged)   insert_row("", l$age_hours, l$closed, 1L)

  db_path
}

HIGH_SEV_OUTPUT <- "Review found an issue.\n\n**Severity**: High\n\nDetails: something bad."
NO_SEV_OUTPUT   <- "Review crashed before emitting a severity marker."

# PR #1269 round 3 (llm#1265 follow-up, review ids 10523/10524): a v2
# structured_output row whose real max severity is MEDIUM, but whose
# finding's OWN problem/fix prose quotes "Severity: High"/"**Severity**:
# Critical" as an illustrative example of a DIFFERENT bug it describes --
# the exact live shape found in ~/.roborev/reviews.db. Default threshold
# is "medium" (AUTOCLOSE_THRESHOLD_STR default), so a Medium finding is
# NOT above-threshold (`ord > AUTOCLOSE_THRESHOLD_ORD` requires strictly
# greater); the old regex-over-rendered-text bug would have read High or
# Critical here and misclassified it as above-threshold.
V2_MEDIUM_QUOTED_HIGH_STRUCTURED <- paste0(
  '{"schema_version":2,"summary":"one medium finding, prose quotes a higher ',
  'severity as an example","verdict":"fail","findings":[{"severity":"medium",',
  '"location":"R/quux.R:5","problem":"Add a fixture where output holds a real ',
  'Severity: High review.","fix":"Emit **Severity**: Critical only when ',
  'genuinely critical."}]}'
)

test_that("PR #1269 round 3: structured Medium finding is NOT inflated to above-threshold by quoted prose", {
  skip_if_not_installed("blastula")
  skip_if_not_installed("duckdb")
  db_path <- make_reviews_db_fixture(
    findings = list(list(output = "", age_hours = 1,
                          structured_output = V2_MEDIUM_QUOTED_HIGH_STRUCTURED))
  )
  snap <- make_synthetic_snapshot()
  out <- run_email_dry_run(snap, extra_env = paste0("ROBOREV_DB=", db_path))
  combined <- paste(out, collapse = "\n")
  expect_true(grepl("QA:total_above_threshold_open_n=0", combined, fixed = TRUE),
    info = paste(
      "A true-Medium finding must NOT count as above-threshold (default",
      "threshold is medium, requires STRICTLY greater). The old",
      "regex-over-rendered-text bug read High/Critical from the finding's",
      "own problem/fix prose (which quotes those words as an example) and",
      "would have counted it here."
    ))
  expect_true(grepl("QA:total_unparseable_open_n=0", combined, fixed = TRUE),
    info = "a genuinely parseable Medium severity must not land in the unparseable bucket either")
})

# ── PR #1269 round 4 (review 10535): non-scalar crash guard + legacy.markdown
# priority ordering ─────────────────────────────────────────────────────────

test_that("PR #1269 round 4: array-valued severity/location/problem does not crash the daily email", {
  # Finding 1: a JSON-array severity/location/problem field used to make
  # as.character()+nzchar()/`||` crash in .structured_findings_normalized()
  # and .render_structured_findings_as_markdown() -- aborting
  # classify_open_findings() for EVERY open finding, not just this one row.
  bad_structured <- paste0(
    '{"schema_version":2,"summary":"x","verdict":"fail","findings":[',
    '{"severity":["high","low"],"location":["a.R:1","b.R:2"],"problem":["p1","p2"]}',
    ']}'
  )
  db_path <- make_reviews_db_fixture(
    findings = list(
      list(output = "", age_hours = 1, structured_output = bad_structured),
      list(output = HIGH_SEV_OUTPUT, age_hours = 1)
    )
  )
  snap <- make_synthetic_snapshot()
  out <- run_email_dry_run(snap, extra_env = paste0("ROBOREV_DB=", db_path))
  combined <- paste(out, collapse = "\n")
  # If the crash this test guards against reappears, the script aborts
  # before ever printing the QA marker line, so these two assertions alone
  # (with the full output in `info=`) are enough to reveal it -- no separate
  # exit-code plumbing needed.
  #
  # The malformed row has no usable severity to read -> unclassified. The
  # OTHER (well-formed High) row must still be counted normally, proving the
  # malformed row did not abort the whole classification loop.
  expect_true(grepl("QA:total_unclassified_open_n=1", combined, fixed = TRUE), info = combined)
  expect_true(grepl("QA:total_above_threshold_open_n=1", combined, fixed = TRUE), info = combined)
})

test_that("PR #1269 round 4: line-wrapped SEVERITY_THRESHOLD_MET token is still classified 'passed'", {
  # review_id 10411 in the live backlog: a schema_version 0 row whose
  # legacy.markdown text has a hard line-wrap splitting the
  # SEVERITY_THRESHOLD_MET token across two lines. normalize_ws() collapses
  # the embedded newline to a space rather than removing it, so the tight
  # "severity_threshold_met" literal never matched -- landing this genuinely
  # passed review in "unclassified" instead.
  wrapped_structured <- paste0(
    '{"legacy":{"markdown":"Summary: refactor x.\\nSEVERITY_THRESHOLD_\\nMET",',
    '"recorded_verdict":false},"schema_version":0,"summary":"","findings":[]}'
  )
  db_path <- make_reviews_db_fixture(
    findings = list(list(output = "", age_hours = 1, structured_output = wrapped_structured))
  )
  snap <- make_synthetic_snapshot()
  out <- run_email_dry_run(snap, extra_env = paste0("ROBOREV_DB=", db_path))
  combined <- paste(out, collapse = "\n")
  expect_true(grepl("QA:total_unclassified_open_n=0", combined, fixed = TRUE), info = combined)
  expect_true(grepl("QA:total_passed_open_n=1", combined, fixed = TRUE), info = combined)
})

test_that("PR #1269 round 4: JSON-direct severity wins over a stale legacy.markdown block on a schema 2 row", {
  # Finding 4: a schema_version 2 row that ALSO carries a legacy.markdown
  # block quoting a higher severity than the real (JSON-direct) Medium
  # finding must NOT be scored from that legacy.markdown text.
  structured <- paste0(
    '{"schema_version":2,"summary":"x","verdict":"fail",',
    '"legacy":{"markdown":"- **Severity**: Critical\\n\\n## Summary\\n\\nstale text"},',
    '"findings":[{"severity":"medium","location":"a.R:1","problem":"real problem"}]}'
  )
  db_path <- make_reviews_db_fixture(
    findings = list(list(output = "", age_hours = 1, structured_output = structured))
  )
  snap <- make_synthetic_snapshot()
  out <- run_email_dry_run(snap, extra_env = paste0("ROBOREV_DB=", db_path))
  combined <- paste(out, collapse = "\n")
  expect_true(grepl("QA:total_above_threshold_open_n=0", combined, fixed = TRUE),
    info = paste("a real Medium finding must not be inflated to Critical by a stale",
                  "legacy.markdown block on the same schema 2 row:", combined))
})

test_that("above-threshold banner prints the JOB id, not reviews.id", {
  skip_if_not_installed("blastula")
  db_path <- make_reviews_db_fixture(
    findings = list(list(output = HIGH_SEV_OUTPUT, age_hours = 1)),
    job_offset = 5000L
  )
  snap <- make_synthetic_snapshot()
  out <- run_email_dry_run(snap, extra_env = paste0("ROBOREV_DB=", db_path))
  combined <- paste(out, collapse = "\n")
  # SEVERITY_ORDINAL names are lower-case, so the banner prints "(high)".
  expect_true(grepl("Job 5001 llm (high)", combined, fixed = TRUE),
    info = "banner must show job id 5001 (reviews.id is 1)")
  expect_false(grepl("#1 llm", combined, fixed = TRUE),
    info = "banner must NOT show reviews.id as #1")
})

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
  # llm#1035: the block heading changed from "Unparseable severity
  # (data-quality, not triage)" because that framing was wrong for the
  # not-reviewed sub-population. Assert the block RENDERS, not the old words.
  expect_true(grepl("Findings with no parsed severity", combined, fixed = TRUE),
    info = "unparseable block must render (informational, not the red alarm)")
  # The blanket reassurance must be gone: it used to cover reviews that
  # never ran, telling the reader they needed no attention.
  expect_false(grepl("not a backlog to close", combined, fixed = TRUE),
    info = "llm#1035: blanket 'not a backlog to close' must not reappear")
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

# ── llm#1035: did-not-run reviews must not be framed as a formatting nit ──────
#
# llm#983 added the not_reviewed/passed/unclassified split but left the block's
# framing intact, so the reader was told in bold that the whole bucket was
# "data-quality, not triage" and "not a backlog to close" — while 16 of those
# rows were reviews that never ran.
#
# The fixtures below are taken from the LIVE backlog, not invented. The
# pre-existing NOT_REVIEWED_AGENT_FAILURE_OUTPUT fixture happens to contain
# BOTH "unable to access" AND "cannot perform the requested code review", so it
# passed against the old pattern list by construction — it sat nowhere near the
# boundary. These three phrasings are the ones the agent actually emits and the
# old list missed, sending 10 never-ran reviews into "unclassified".
NOT_REVIEWED_LIVE_UNABLE_TO_READ <- paste(
  "I am unable to read the diff file",
  "`/Users/x/repo/.roborev/roborev-snapshot-1/roborev-snapshot-content.diff`",
  "because it is ignored by configured ignore patterns."
)
NOT_REVIEWED_LIVE_UNABLE_TO_PERFORM <- paste(
  "I am unable to perform the code review because the diff file at",
  "`/Users/x/repo/.roborev/roborev-snapshot-2/roborev-snapshot-content.diff`",
  "is not readable."
)
NOT_REVIEWED_LIVE_COULD_NOT_BE_READ <- paste(
  "Summary: Cannot review code changes as the diff file could not be read.",
  "Review Findings: none available."
)

test_that("llm#1035: live did-not-run phrasings classify as not_reviewed", {
  skip_if_not_installed("blastula")
  for (nm in c("NOT_REVIEWED_LIVE_UNABLE_TO_READ",
               "NOT_REVIEWED_LIVE_UNABLE_TO_PERFORM",
               "NOT_REVIEWED_LIVE_COULD_NOT_BE_READ")) {
    db_path <- make_reviews_db_fixture(
      findings = list(list(output = get(nm), age_hours = 1)))
    snap <- make_synthetic_snapshot()
    combined <- paste(
      run_email_dry_run(snap, extra_env = paste0("ROBOREV_DB=", db_path)),
      collapse = "\n")
    expect_true(grepl("QA:total_not_reviewed_open_n=1", combined, fixed = TRUE),
      info = paste0(nm, " must classify as not_reviewed, not unclassified"))
    expect_true(grepl("QA:total_unclassified_open_n=0", combined, fixed = TRUE),
      info = paste0(nm, " must NOT land in the residual bucket"))
  }
})

test_that("llm#1035: a did-not-run review is framed as an alert, not a nit", {
  skip_if_not_installed("blastula")
  db_path <- make_reviews_db_fixture(
    findings = list(list(output = NOT_REVIEWED_LIVE_UNABLE_TO_READ, age_hours = 1)))
  snap <- make_synthetic_snapshot()
  combined <- paste(
    run_email_dry_run(snap, extra_env = paste0("ROBOREV_DB=", db_path)),
    collapse = "\n")

  expect_true(grepl("Reviews that did not run", combined, fixed = TRUE),
    info = "the did-not-run population must get its own heading")
  expect_false(grepl("not a backlog to close", combined, fixed = TRUE),
    info = "the blanket reassurance must never cover a review that never ran")
})

test_that("llm#1035: 'passed' rows are excluded from the data-quality denominator", {
  # The >50%-unclassified guard exists to say "the classifier patterns need
  # updating". On the live DB it was silent at 26.2% because `passed` (43 of
  # 80 rows) padded its denominator; on the not-passed denominator the same
  # data reads 56.8%. This fixture reproduces that shape in miniature:
  #   1 not_reviewed + 4 unclassified + 10 passed
  #   old denominator: 4/15 = 27%  -> silent
  #   new denominator: 4/5  = 80%  -> fires (5 = DQ_MIN_DENOM, at threshold)
  skip_if_not_installed("blastula")
  findings <- c(
    list(list(output = NOT_REVIEWED_EXACT_OUTPUT, age_hours = 1)),
    replicate(4, list(output = UNCLASSIFIED_PROSE_OUTPUT, age_hours = 1), simplify = FALSE),
    replicate(10, list(output = PASSED_THRESHOLD_MET_OUTPUT, age_hours = 1), simplify = FALSE)
  )
  db_path <- make_reviews_db_fixture(findings = findings)
  snap <- make_synthetic_snapshot()
  combined <- paste(
    run_email_dry_run(snap, extra_env = paste0("ROBOREV_DB=", db_path)),
    collapse = "\n")

  # Sub-counts must still sum to the unchanged total (other tests rely on it).
  expect_true(grepl("QA:total_unparseable_open_n=15", combined, fixed = TRUE))
  expect_true(grepl("QA:total_not_reviewed_open_n=1", combined, fixed = TRUE))
  expect_true(grepl("QA:total_passed_open_n=10", combined, fixed = TRUE))
  expect_true(grepl("QA:total_unclassified_open_n=4", combined, fixed = TRUE))

  # The guard must fire on the not-passed denominator.
  expect_true(grepl("may need updating", combined, fixed = TRUE),
    info = "4 of 5 non-passed findings unclassified (>50%) must trigger the guard")
  # And `passed` must be labelled correct rather than counted as a problem.
  expect_true(grepl("Clean reviews with no severity marker:", combined, fixed = TRUE),
    info = "passed rows must be shown as context, explicitly labelled correct")
})

test_that("llm#1035: the guard stays silent when unclassified is genuinely low", {
  # Control for the test above: same machinery, honest minority. Without this,
  # a guard that fired unconditionally would pass the previous test.
  skip_if_not_installed("blastula")
  findings <- c(
    replicate(9, list(output = NOT_REVIEWED_EXACT_OUTPUT, age_hours = 1), simplify = FALSE),
    list(list(output = UNCLASSIFIED_PROSE_OUTPUT, age_hours = 1))
  )
  db_path <- make_reviews_db_fixture(findings = findings)
  snap <- make_synthetic_snapshot()
  combined <- paste(
    run_email_dry_run(snap, extra_env = paste0("ROBOREV_DB=", db_path)),
    collapse = "\n")

  expect_true(grepl("QA:total_unclassified_open_n=1", combined, fixed = TRUE))
  expect_false(grepl("may need updating", combined, fixed = TRUE),
    info = "1 of 10 non-passed unclassified (10%) must NOT trigger the guard")
})

# ── Tests: minimum-denominator guard (2026-09-20) ──
# The daily report said "1 of 1 findings ... (>50%) are unclassified" — a
# small-N artefact. Below DQ_MIN_DENOM (5) the warning is suppressed, but a
# "too few findings" note must print instead of nothing (indeterminate is not
# healthy). Real live row: id 10014 (genuine review, no Severity marker).
UNCLASSIFIED_LIVE_10014_OUTPUT <- paste(
  "**Summary**: Refactors activity lists to a single constant and dynamically",
  "generates vignette sentence literals. **Review Findings**: * **Testing gaps**",
  "* **Problem**: a required vignette RDS has not been generated/committed.",
  "* **Fix**: Generate and commit the missing RDS file. * No other issues found."
)

test_that("live id 10014 phrasing (real finding, no marker) stays unclassified", {
  # Control: a genuine finding must NOT be forced into passed/not_reviewed.
  # "No other issues found" must not match the "no issues found" pattern.
  skip_if_not_installed("blastula")
  db_path <- make_reviews_db_fixture(
    findings = list(list(output = UNCLASSIFIED_LIVE_10014_OUTPUT, age_hours = 1)))
  combined <- paste(
    run_email_dry_run(make_synthetic_snapshot(),
                      extra_env = paste0("ROBOREV_DB=", db_path)),
    collapse = "\n")
  expect_true(grepl("QA:total_unclassified_open_n=1", combined, fixed = TRUE))
  expect_true(grepl("QA:total_passed_open_n=0", combined, fixed = TRUE))
  expect_true(grepl("QA:total_not_reviewed_open_n=0", combined, fixed = TRUE))
})

run_dq_case <- function(n_unclass, n_notrev) {
  findings <- c(
    replicate(n_unclass, list(output = UNCLASSIFIED_PROSE_OUTPUT, age_hours = 1), simplify = FALSE),
    replicate(n_notrev, list(output = NOT_REVIEWED_EXACT_OUTPUT, age_hours = 1), simplify = FALSE)
  )
  db_path <- make_reviews_db_fixture(findings = findings)
  paste(run_email_dry_run(make_synthetic_snapshot(),
                          extra_env = paste0("ROBOREV_DB=", db_path)),
        collapse = "\n")
}

test_that("dq guard: denominator below minimum -> no warning, 'too few' note shown", {
  skip_if_not_installed("blastula")
  combined <- run_dq_case(n_unclass = 1, n_notrev = 0)  # 1 of 1 = 100%
  expect_false(grepl("may need updating", combined, fixed = TRUE))
  expect_true(grepl("Too few findings", combined, fixed = TRUE))
  expect_true(grepl("Unclassified severity (data-quality)", combined, fixed = TRUE),
    info = "the plain count line must still print")
})

test_that("dq guard: at minimum denominator with >50% -> warning fires", {
  skip_if_not_installed("blastula")
  combined <- run_dq_case(n_unclass = 3, n_notrev = 2)  # 3 of 5 = 60%
  expect_true(grepl("may need updating", combined, fixed = TRUE))
  expect_false(grepl("Too few findings", combined, fixed = TRUE))
})

test_that("dq guard: at minimum denominator with <=50% -> nothing", {
  skip_if_not_installed("blastula")
  combined <- run_dq_case(n_unclass = 2, n_notrev = 3)  # 2 of 5 = 40%
  expect_false(grepl("may need updating", combined, fixed = TRUE))
  expect_false(grepl("Too few findings", combined, fixed = TRUE))
})

# ── Tests: llm#1035 follow-up (2026-09-02) — re-measured the live backlog ──
#
# A week after the four NOT_REVIEWED_PATTERNS above landed, 3 of the 5
# still-unclassified open rows were re-checked against the PRODUCTION
# classifier (not a SQL approximation -- `classify_unparseable_finding()`
# run directly against the raw `reviews.db` text) and turned out to be two
# more phrasings of "the review never ran" and one more phrasing of "empty
# diff, nothing to review". The other 2 of the 5 (a real Medium finding with
# no `Severity:` marker) are genuinely unclassified and must stay that way --
# see the control test at the end of this section.
#
# Fixtures below are lifted from the live backlog (ids 9932/9966/9987 in
# ~/.roborev/reviews.db), paths redacted to match the existing fixture
# convention (`/Users/x/repo/...`) rather than the real local path.
NOT_REVIEWED_LIVE_INACCESSIBLE_IGNORE_OUTPUT <- paste(
  "Summary: Unable to perform code review.",
  "Review Findings: Review could not be performed as the diff file at",
  "`/private/tmp/pr120-mergecheck2/.roborev/roborev-snapshot-1/roborev-snapshot-content.diff`",
  "is inaccessible due to configured ignore patterns."
)
NOT_REVIEWED_LIVE_UNABLE_TO_PROCEED_OUTPUT <- paste(
  "I am unable to proceed with the review as the diff file",
  "`/Users/x/repo/.roborev/roborev-snapshot-2/roborev-snapshot-content.diff`",
  "is ignored by the configured patterns, and the `read_file` tool does not",
  "provide an option to bypass these patterns. Without access to the diff",
  "content, I cannot perform the code review."
)
PASSED_LIVE_EMPTY_DIFF_OUTPUT <- "No review found for empty diff."
# Control: a real Medium finding with no `Severity:` marker (live ids
# 9861/10014). Must stay unclassified -- proves the two new
# NOT_REVIEWED_PATTERNS below do not swallow genuine findings.
UNCLASSIFIED_REAL_FINDING_NO_MARKER_OUTPUT <- paste(
  "Summary: Adds new quality gates for provisional constants and manual",
  "marker staleness checks.",
  "Review Findings:",
  "- Medium, `.claude/rules/provisional-constants.md`, Line Count: The file",
  "exceeds the 150-line limit for rule files (190 lines). Consider",
  "splitting or condensing documentation."
)

test_that("llm#1035 follow-up: live 'inaccessible due to ... ignore patterns' phrasing classifies as not_reviewed", {
  skip_if_not_installed("blastula")
  db_path <- make_reviews_db_fixture(
    findings = list(list(output = NOT_REVIEWED_LIVE_INACCESSIBLE_IGNORE_OUTPUT, age_hours = 1)))
  snap <- make_synthetic_snapshot()
  combined <- paste(
    run_email_dry_run(snap, extra_env = paste0("ROBOREV_DB=", db_path)),
    collapse = "\n")
  expect_true(grepl("QA:total_not_reviewed_open_n=1", combined, fixed = TRUE),
    info = "'inaccessible due to configured ignore patterns' must classify as not_reviewed")
  expect_true(grepl("QA:total_unclassified_open_n=0", combined, fixed = TRUE),
    info = "must NOT land in the residual bucket")
})

test_that("llm#1035 follow-up: live 'unable to proceed with the review' phrasing classifies as not_reviewed", {
  skip_if_not_installed("blastula")
  db_path <- make_reviews_db_fixture(
    findings = list(list(output = NOT_REVIEWED_LIVE_UNABLE_TO_PROCEED_OUTPUT, age_hours = 1)))
  snap <- make_synthetic_snapshot()
  combined <- paste(
    run_email_dry_run(snap, extra_env = paste0("ROBOREV_DB=", db_path)),
    collapse = "\n")
  expect_true(grepl("QA:total_not_reviewed_open_n=1", combined, fixed = TRUE),
    info = "'unable to proceed with the review' must classify as not_reviewed")
  expect_true(grepl("QA:total_unclassified_open_n=0", combined, fixed = TRUE),
    info = "must NOT land in the residual bucket")
})

test_that("llm#1035 follow-up: live 'no review found for empty diff' phrasing classifies as passed", {
  skip_if_not_installed("blastula")
  db_path <- make_reviews_db_fixture(
    findings = list(list(output = PASSED_LIVE_EMPTY_DIFF_OUTPUT, age_hours = 1)))
  snap <- make_synthetic_snapshot()
  combined <- paste(
    run_email_dry_run(snap, extra_env = paste0("ROBOREV_DB=", db_path)),
    collapse = "\n")
  expect_true(grepl("QA:total_passed_open_n=1", combined, fixed = TRUE),
    info = "'no review found for empty diff' must classify as passed, not unclassified")
  expect_true(grepl("QA:total_unclassified_open_n=0", combined, fixed = TRUE),
    info = "must NOT land in the residual bucket")
})

test_that("llm#1035 follow-up: a real finding with no Severity marker still stays unclassified (regression guard)", {
  # Companion to the three tests above. Without this, a classifier broadened
  # to catch the new not-reviewed/passed phrasings could plausibly also
  # start swallowing genuine findings -- this fixture is real content (a
  # live Medium-severity finding) that must NOT be reclassified away.
  skip_if_not_installed("blastula")
  db_path <- make_reviews_db_fixture(
    findings = list(list(output = UNCLASSIFIED_REAL_FINDING_NO_MARKER_OUTPUT, age_hours = 1)))
  snap <- make_synthetic_snapshot()
  combined <- paste(
    run_email_dry_run(snap, extra_env = paste0("ROBOREV_DB=", db_path)),
    collapse = "\n")
  expect_true(grepl("QA:total_unclassified_open_n=1", combined, fixed = TRUE),
    info = "a real finding with no Severity marker must remain unclassified")
  expect_true(grepl("QA:total_not_reviewed_open_n=0", combined, fixed = TRUE))
  expect_true(grepl("QA:total_passed_open_n=0", combined, fixed = TRUE))
})

# ── Tests: llm#1127 — a fabricated "Severity: High" marker must not
# override a tooling-failure signature ──
#
# Live evidence (~/.roborev/reviews.db, `gemini` agent, `micromort` repo,
# 2026-08-31, ids 9962/9963/9968): the review agent's OWN `read_file` tool
# was blocked by its ignore-pattern config from reading the diff snapshot
# at `.roborev/roborev-snapshot-*/roborev-snapshot-content.diff`, and it
# wrote up that tooling failure as a "Severity: High" finding ABOUT the
# code, rather than reporting an error. Before this fix,
# classify_open_findings() only ran classify_unparseable_finding() when NO
# `Severity:` marker was found at all — a fabricated marker skipped that
# check entirely and routed straight into the above-threshold triage
# backlog. Fixtures below are the exact live text of ids 9962/9963, paths
# redacted to the existing fixture convention.
FABRICATED_HIGH_BLOCKED_IGNORE_OUTPUT <- paste(
  "Summary: Unable to retrieve diff content for review.",
  "Review Findings:",
  "- **Severity**: High",
  "- **Location**: N/A",
  "- **Problem**: The diff file, expected at",
  "`/Users/x/repo/.roborev/roborev-snapshot-1456588781/roborev-snapshot-content.diff`,",
  "could not be accessed. Initial attempts to read it were blocked by",
  "ignore patterns, and a subsequent `glob` command, even when attempting",
  "to bypass Gemini ignore patterns, indicated a file was ignored without",
  "finding the target file. This prevents the code review from proceeding.",
  "- **Fix**: Ensure the diff content is accessible, either by adjusting",
  "ignore patterns or providing the diff content through an alternative,",
  "accessible method."
)
FABRICATED_HIGH_BLOCKED_CONFIGURED_IGNORE_OUTPUT <- paste(
  "Summary: Unable to retrieve diff content for review.",
  "Review Findings:",
  "- **Severity**: High",
  "- **Location**: N/A",
  "- **Problem**: The diff file, located at",
  "`/Users/x/repo/.roborev/roborev-snapshot-3126204784/roborev-snapshot-content.diff`,",
  "could not be accessed using the `read_file` tool because it is blocked",
  "by configured ignore patterns. The `read_file` tool does not provide an",
  "option to bypass these ignore patterns, preventing the code review from",
  "proceeding.",
  "- **Fix**: A mechanism to bypass ignore patterns for the `read_file`",
  "tool is required, or the diff content must be made accessible in a",
  "different manner that is not subject to ignore patterns for review by",
  "the agent."
)

test_that("llm#1127: a fabricated Severity:High wrapping a 'blocked by ignore patterns' tooling failure is not_reviewed, not above-threshold", {
  skip_if_not_installed("blastula")
  db_path <- make_reviews_db_fixture(
    findings = list(list(output = FABRICATED_HIGH_BLOCKED_IGNORE_OUTPUT, age_hours = 1)))
  snap <- make_synthetic_snapshot()
  combined <- paste(
    run_email_dry_run(snap, extra_env = paste0("ROBOREV_DB=", db_path)),
    collapse = "\n")
  expect_true(grepl("QA:total_not_reviewed_open_n=1", combined, fixed = TRUE),
    info = "a Severity:High wrapper around a 'blocked by ignore patterns' failure must classify as not_reviewed")
  expect_true(grepl("QA:total_above_threshold_open_n=0", combined, fixed = TRUE),
    info = "the fabricated High marker must NOT reach the human-triage backlog")
  expect_true(grepl("QA:total_unclassified_open_n=0", combined, fixed = TRUE))
})

test_that("llm#1127: a fabricated Severity:High wrapping a 'blocked by configured ignore patterns' tooling failure is not_reviewed, not above-threshold", {
  skip_if_not_installed("blastula")
  db_path <- make_reviews_db_fixture(
    findings = list(list(output = FABRICATED_HIGH_BLOCKED_CONFIGURED_IGNORE_OUTPUT, age_hours = 1)))
  snap <- make_synthetic_snapshot()
  combined <- paste(
    run_email_dry_run(snap, extra_env = paste0("ROBOREV_DB=", db_path)),
    collapse = "\n")
  expect_true(grepl("QA:total_not_reviewed_open_n=1", combined, fixed = TRUE),
    info = "a Severity:High wrapper around a 'blocked by configured ignore patterns' failure must classify as not_reviewed")
  expect_true(grepl("QA:total_above_threshold_open_n=0", combined, fixed = TRUE),
    info = "the fabricated High marker must NOT reach the human-triage backlog")
  expect_true(grepl("QA:total_unclassified_open_n=0", combined, fixed = TRUE))
})

test_that("llm#1127: a genuine Severity:High finding (no tooling-failure signature) still lands above-threshold (regression guard)", {
  # Companion to the two tests above. Without this, a classifier that runs
  # classify_unparseable_finding() on every row could plausibly also start
  # swallowing real High-severity findings into not_reviewed/passed. This
  # fixture (HIGH_SEV_OUTPUT, already used elsewhere in this file) is a
  # normal finding with no tooling-failure phrasing and MUST still reach
  # the human-triage backlog.
  skip_if_not_installed("blastula")
  db_path <- make_reviews_db_fixture(
    findings = list(list(output = HIGH_SEV_OUTPUT, age_hours = 1)))
  snap <- make_synthetic_snapshot()
  combined <- paste(
    run_email_dry_run(snap, extra_env = paste0("ROBOREV_DB=", db_path)),
    collapse = "\n")
  expect_true(grepl("QA:total_above_threshold_open_n=1", combined, fixed = TRUE),
    info = "a real High-severity finding with no tooling-failure signature must still count as above-threshold")
  expect_true(grepl("QA:total_not_reviewed_open_n=0", combined, fixed = TRUE))
  expect_true(grepl("QA:total_unclassified_open_n=0", combined, fixed = TRUE))
})

# ── Tests: llm#1044 item 3 — per-agent not-reviewed rate ────────────────────
#
# llm#1044 found gemini silently failed to read its diff on 15.5% of open
# reviews and nothing in the daily email surfaced it PER AGENT — the
# aggregate not_reviewed count (asserted above) dilutes a single misbehaving
# agent into the whole standing backlog. These tests pin the new
# "Per-Agent Review Health" block against a fixture reviews.db, reusing
# make_reviews_db_fixture()'s agent/model support added for this feature.
#
# Unlike the above-threshold/unparseable blocks (which query CLOSED=0 open
# findings only), the per-agent block queries EVERY completed review in the
# last 7 days regardless of open/closed status — agent health is about
# whether the review ran, not what happened to the finding afterwards. The
# fixture rows created by make_reviews_db_fixture()'s `findings=` arg are
# all closed=0/verdict_bool=0, which is exactly "a completed review that
# produced an open, unresolved finding" — a subset of, not different from,
# what the per-agent query counts.

test_that("llm#1044: per-agent table shows a 100% not-reviewed rate for a single-agent, single-not-reviewed fixture", {
  skip_if_not_installed("blastula")
  db_path <- make_reviews_db_fixture(
    findings = list(
      list(output = NOT_REVIEWED_EXACT_OUTPUT, age_hours = 1,
           agent = "gemini", model = "gemini-2.5-flash-lite")
    )
  )
  snap <- make_synthetic_snapshot()
  combined <- paste(
    run_email_dry_run(snap, extra_env = paste0("ROBOREV_DB=", db_path)),
    collapse = "\n")
  expect_true(grepl("QA:agent_rate_available=true", combined, fixed = TRUE),
    info = "a working DB query must mark agent_rate_available=true")
  expect_true(grepl("QA:agent_rate_n_combos=1", combined, fixed = TRUE))
  expect_true(grepl("Per-Agent Review Health", combined, fixed = TRUE))
  expect_true(grepl(">gemini<", combined, fixed = TRUE))
  expect_true(grepl(">gemini-2.5-flash-lite<", combined, fixed = TRUE))
  expect_true(grepl(">100.0%<", combined, fixed = TRUE),
    info = "the lone review is not_reviewed, so the agent's rate must be 100%")
})

test_that("llm#1044: per-agent table splits mixed not_reviewed/passed outcomes by agent+model, rate computed per group", {
  skip_if_not_installed("blastula")
  db_path <- make_reviews_db_fixture(
    findings = list(
      # gemini/flash-lite: 1 of 2 not_reviewed -> 50.0%
      list(output = NOT_REVIEWED_EXACT_OUTPUT, age_hours = 1,
           agent = "gemini", model = "gemini-2.5-flash-lite"),
      list(output = PASSED_THRESHOLD_MET_OUTPUT, age_hours = 1,
           agent = "gemini", model = "gemini-2.5-flash-lite"),
      # claude-code/sonnet: 0 of 1 not_reviewed -> 0.0%, must stay a
      # SEPARATE row/rate from the gemini group above
      list(output = PASSED_THRESHOLD_MET_OUTPUT, age_hours = 1,
           agent = "claude-code", model = "sonnet")
    )
  )
  snap <- make_synthetic_snapshot()
  combined <- paste(
    run_email_dry_run(snap, extra_env = paste0("ROBOREV_DB=", db_path)),
    collapse = "\n")
  expect_true(grepl("QA:agent_rate_n_combos=2", combined, fixed = TRUE),
    info = "two distinct agent+model groups must not be merged")
  expect_true(grepl(">50.0%<", combined, fixed = TRUE),
    info = "gemini/gemini-2.5-flash-lite must show 1 of 2 not_reviewed = 50.0%")
  expect_true(grepl(">0.0%<", combined, fixed = TRUE),
    info = "claude-code/sonnet must show 0 of 1 not_reviewed = 0.0%, unaffected by gemini's rate")
  expect_true(grepl(">claude-code<", combined, fixed = TRUE))
  expect_true(grepl(">sonnet<", combined, fixed = TRUE))
})

test_that("llm#1044: missing reviews.db renders UNKNOWN, never 0% or a silently-empty table", {
  # checks-must-distinguish-unknown: a DB that cannot be queried must not
  # read as \"all agents healthy\". Points ROBOREV_DB at a path that does
  # not exist -- query_reviews_db() returns NULL, classify_by_agent(NULL)
  # returns NULL, and the render step must take the explicit UNKNOWN branch.
  skip_if_not_installed("blastula")
  snap <- make_synthetic_snapshot()
  combined <- paste(
    run_email_dry_run(snap, extra_env = "ROBOREV_DB=/nonexistent/path/reviews.db"),
    collapse = "\n")
  expect_true(grepl("QA:agent_rate_available=false", combined, fixed = TRUE),
    info = "a failed query must mark agent_rate_available=false, not true")
  expect_true(grepl("QA:agent_rate_n_combos=0", combined, fixed = TRUE))
  expect_true(grepl("UNKNOWN", combined, fixed = TRUE),
    info = "the block must render an explicit UNKNOWN state, not a 0% rate")
  expect_false(grepl("agent/model combo(s) tracked", combined, fixed = TRUE),
    info = "the 'N combos tracked' summary must not appear when the query failed")
})

test_that("llm#1044: zero completed reviews in the 7d window renders a distinguishable empty state, not UNKNOWN", {
  # Companion to the UNKNOWN test above: an empty RESULT (query ran fine,
  # zero rows) is a different, real state from a FAILED query and must not
  # collapse into the same UNKNOWN rendering.
  skip_if_not_installed("blastula")
  db_path <- make_reviews_db_fixture(findings = list())
  snap <- make_synthetic_snapshot()
  combined <- paste(
    run_email_dry_run(snap, extra_env = paste0("ROBOREV_DB=", db_path)),
    collapse = "\n")
  expect_true(grepl("QA:agent_rate_available=true", combined, fixed = TRUE),
    info = "the query itself succeeded (zero rows is not a failure)")
  expect_true(grepl("QA:agent_rate_n_combos=0", combined, fixed = TRUE))
  expect_true(grepl("no completed reviews in the last 7 days", combined, fixed = TRUE))
  expect_false(grepl("Could not query reviews.db", combined, fixed = TRUE),
    info = "an empty result must not be reported as a query failure")
})


# ── Tests: llm#984 item 2 / llm#1044 items 2+3 / llm#1123 addendum 1 ─────────
#
# Report-only health additions to the per-agent block:
#   (a) completed jobs that ran longer than the effective job_timeout_minutes
#   (b) a daily per-agent quality history + day-over-day jump flag
#   (c) a reviewer-config fingerprint with a "re-run roborev_eval_run.sh" line
#   (d) acknowledged unclassified findings counted separately
# Every input is injected through an env seam (ROBOREV_CONFIG_TOML,
# ROBOREV_ACKS_JSONL, ROBOREV_HEALTH_STATE_DIR, ROBOREV_DB); run_email_dry_run()
# defaults all of them to nonexistent temp paths so nothing live is read.

health_lib_path <- function() {
  p <- system.file("scripts/roborev_health_lib.R", package = "llm", mustWork = FALSE)
  if (!nzchar(p) || !file.exists(p)) {
    p <- normalizePath(
      file.path(dirname(dirname(testthat::test_path())),
                ".claude", "scripts", "roborev_health_lib.R"),
      mustWork = FALSE)
  }
  p
}

write_toml <- function(lines) {
  f <- tempfile("roborev_cfg_", fileext = ".toml")
  writeLines(lines, f)
  f
}

utc_day <- function(offset_days = 0) {
  format(Sys.time() + offset_days * 86400, "%Y-%m-%d", tz = "UTC")
}

write_history <- function(rows) {
  d <- tempfile("health_state_")
  dir.create(d, recursive = TRUE)
  lines <- vapply(rows, function(r) {
    sprintf('{"date":"%s","agent":"%s","model":"%s","reviews":%d,"not_reviewed":%d}',
            r[[1]], r[[2]], r[[3]], r[[4]], r[[5]])
  }, "")
  writeLines(lines, file.path(d, "agent_quality_daily.jsonl"))
  d
}

# -- (a) over-timeout ---------------------------------------------------------

test_that("llm#984: a 59-min completed job under a 30-min limit is counted; a 10-min job is not", {
  skip_if_not_installed("blastula")
  cfg <- write_toml(c("job_timeout_minutes = 30"))
  db_path <- make_reviews_db_fixture(findings = list(
    list(output = PASSED_THRESHOLD_MET_OUTPUT, age_hours = 2, agent = "claude-code",
         model = "sonnet", duration_min = 59.2),
    list(output = PASSED_THRESHOLD_MET_OUTPUT, age_hours = 3, agent = "claude-code",
         model = "sonnet", duration_min = 10),
    list(output = PASSED_THRESHOLD_MET_OUTPUT, age_hours = 4, agent = "claude-code",
         model = "sonnet", duration_min = 10)
  ))
  combined <- paste(run_email_dry_run(make_synthetic_snapshot(), extra_env = c(
    paste0("ROBOREV_DB=", db_path), paste0("ROBOREV_CONFIG_TOML=", cfg))), collapse = "\n")
  expect_true(grepl("QA:over_timeout_total=1", combined, fixed = TRUE),
    info = "exactly the 59.2-min job exceeds the 30-min limit")
  expect_true(grepl("Over timeout", combined, fixed = TRUE))
  expect_true(grepl(">1<", combined, fixed = TRUE), info = "per-agent cell shows 1")
})

test_that("llm#984: only 10-min jobs -> over_timeout_total=0 (not unknown)", {
  skip_if_not_installed("blastula")
  cfg <- write_toml(c("job_timeout_minutes = 30"))
  db_path <- make_reviews_db_fixture(findings = list(
    list(output = PASSED_THRESHOLD_MET_OUTPUT, age_hours = 2, duration_min = 10)))
  combined <- paste(run_email_dry_run(make_synthetic_snapshot(), extra_env = c(
    paste0("ROBOREV_DB=", db_path), paste0("ROBOREV_CONFIG_TOML=", cfg))), collapse = "\n")
  expect_true(grepl("QA:over_timeout_total=0", combined, fixed = TRUE))
})

test_that("llm#984: unreadable timeout config renders 'unknown', never 0", {
  skip_if_not_installed("blastula")
  db_path <- make_reviews_db_fixture(findings = list(
    list(output = PASSED_THRESHOLD_MET_OUTPUT, age_hours = 2, duration_min = 59)))
  # default ROBOREV_CONFIG_TOML points at a nonexistent file
  combined <- paste(run_email_dry_run(make_synthetic_snapshot(),
    extra_env = paste0("ROBOREV_DB=", db_path)), collapse = "\n")
  expect_true(grepl("QA:over_timeout_total=unknown", combined, fixed = TRUE))
  expect_false(grepl("QA:over_timeout_total=0", combined, fixed = TRUE))
})

test_that("llm#984: a per-repo job_timeout_minutes override replaces the global limit", {
  skip_if_not_installed("blastula")
  root <- tempfile("repo_root_"); dir.create(root)
  writeLines("job_timeout_minutes = 90", file.path(root, ".roborev.toml"))
  cfg <- write_toml(c("job_timeout_minutes = 30"))
  db_path <- make_reviews_db_fixture(findings = list(
    list(output = PASSED_THRESHOLD_MET_OUTPUT, age_hours = 2, duration_min = 59.2)),
    repo_root = root)
  combined <- paste(run_email_dry_run(make_synthetic_snapshot(), extra_env = c(
    paste0("ROBOREV_DB=", db_path), paste0("ROBOREV_CONFIG_TOML=", cfg))), collapse = "\n")
  expect_true(grepl("QA:over_timeout_total=0", combined, fixed = TRUE),
    info = "59.2 min is under the repo's 90-min override")
})

# -- (b) daily quality history + jump flag -----------------------------------

test_that("llm#1044: stable week -> no jump flag", {
  skip_if_not_installed("blastula")
  state <- write_history(lapply(1:6, function(i)
    list(utc_day(-i), "gemini", "flash", 10L, 1L)))
  combined <- paste(run_email_dry_run(make_synthetic_snapshot(), extra_env = c(
    paste0("ROBOREV_DB=", make_reviews_db_fixture()),
    paste0("ROBOREV_HEALTH_STATE_DIR=", state))), collapse = "\n")
  expect_true(grepl("QA:quality_jump_n=0", combined, fixed = TRUE))
  expect_false(grepl("quality jump", combined, ignore.case = TRUE))
})

test_that("llm#1044: a +30-point day-over-day jump on >=5 reviews is flagged", {
  skip_if_not_installed("blastula")
  state <- write_history(list(
    list(utc_day(-2), "gemini", "flash", 10L, 0L),
    list(utc_day(-1), "gemini", "flash", 10L, 3L)))
  combined <- paste(run_email_dry_run(make_synthetic_snapshot(), extra_env = c(
    paste0("ROBOREV_DB=", make_reviews_db_fixture()),
    paste0("ROBOREV_HEALTH_STATE_DIR=", state))), collapse = "\n")
  expect_true(grepl("QA:quality_jump_n=1", combined, fixed = TRUE))
  expect_true(grepl("quality jump", combined, ignore.case = TRUE))
  expect_true(grepl("gemini", combined, fixed = TRUE))
})

test_that("llm#1044: too few reviews that day -> not judged, no false alarm", {
  skip_if_not_installed("blastula")
  state <- write_history(list(
    list(utc_day(-2), "gemini", "flash", 10L, 0L),
    list(utc_day(-1), "gemini", "flash", 3L, 3L)))   # 100% but only 3 reviews
  combined <- paste(run_email_dry_run(make_synthetic_snapshot(), extra_env = c(
    paste0("ROBOREV_DB=", make_reviews_db_fixture()),
    paste0("ROBOREV_HEALTH_STATE_DIR=", state))), collapse = "\n")
  expect_true(grepl("QA:quality_jump_n=0", combined, fixed = TRUE))
  expect_false(grepl("quality jump", combined, ignore.case = TRUE))
})

test_that("llm#1044: a rise under the 10-point threshold is not flagged", {
  skip_if_not_installed("blastula")
  state <- write_history(list(
    list(utc_day(-2), "gemini", "flash", 20L, 2L),    # 10%
    list(utc_day(-1), "gemini", "flash", 20L, 4L)))   # 20% -> +10 is the threshold
  state2 <- write_history(list(
    list(utc_day(-2), "gemini", "flash", 40L, 4L),    # 10%
    list(utc_day(-1), "gemini", "flash", 40L, 7L)))   # 17.5% -> +7.5, below threshold
  combined <- paste(run_email_dry_run(make_synthetic_snapshot(), extra_env = c(
    paste0("ROBOREV_DB=", make_reviews_db_fixture()),
    paste0("ROBOREV_HEALTH_STATE_DIR=", state2))), collapse = "\n")
  expect_true(grepl("QA:quality_jump_n=0", combined, fixed = TRUE))
  # exactly at the threshold (+10 points) IS flagged (>=)
  combined2 <- paste(run_email_dry_run(make_synthetic_snapshot(), extra_env = c(
    paste0("ROBOREV_DB=", make_reviews_db_fixture()),
    paste0("ROBOREV_HEALTH_STATE_DIR=", state))), collapse = "\n")
  expect_true(grepl("QA:quality_jump_n=1", combined2, fixed = TRUE))
})

test_that("llm#1044: unparseable history lines are skipped with a note, never a crash", {
  skip_if_not_installed("blastula")
  d <- tempfile("health_state_"); dir.create(d)
  writeLines(c("not json at all", "{broken"), file.path(d, "agent_quality_daily.jsonl"))
  out <- run_email_dry_run(make_synthetic_snapshot(), extra_env = c(
    paste0("ROBOREV_DB=", make_reviews_db_fixture()),
    paste0("ROBOREV_HEALTH_STATE_DIR=", d)))
  combined <- paste(out, collapse = "\n")
  expect_true(grepl("QA:quality_jump_n=0", combined, fixed = TRUE))
  expect_true(grepl("dry-run complete", combined, fixed = TRUE))
})

# -- (c) reviewer-config fingerprint ------------------------------------------

test_that("llm#1044: reviewer-config hash change -> prominent re-run line; no change -> none; unreadable -> unknown", {
  skip_if_not_installed("blastula")
  skip_if_not_installed("jsonlite")
  lib <- health_lib_path()
  expect_true(file.exists(lib))
  e <- new.env(); sys.source(lib, envir = e)

  cfg <- write_toml(c("default_agent = 'claude-code'", "review_agent = 'claude-code'",
                      "review_model = ''", "job_timeout_minutes = 30"))
  fp <- e$rh_config_fingerprint(cfg)
  expect_identical(fp$status, "ok")

  state_same <- tempfile("health_state_"); dir.create(state_same)
  writeLines(fp$hash, file.path(state_same, "reviewer_config.hash"))
  state_diff <- tempfile("health_state_"); dir.create(state_diff)
  writeLines("0000deadbeef", file.path(state_diff, "reviewer_config.hash"))

  db <- paste0("ROBOREV_DB=", make_reviews_db_fixture())
  run <- function(state, cfg_path) paste(run_email_dry_run(make_synthetic_snapshot(), extra_env = c(
    db, paste0("ROBOREV_CONFIG_TOML=", cfg_path), paste0("ROBOREV_HEALTH_STATE_DIR=", state))),
    collapse = "\n")

  changed <- run(state_diff, cfg)
  expect_true(grepl("QA:reviewer_config_status=changed", changed, fixed = TRUE))
  expect_true(grepl("roborev_eval_run.sh", changed, fixed = TRUE))
  expect_true(grepl("reviewer config changed", changed, ignore.case = TRUE))
  # llm#816: a dry-run preview does not spend review calls; it says so.
  expect_true(grepl("QA:reviewer_eval_status=not_run", changed, fixed = TRUE))

  same <- run(state_same, cfg)
  expect_true(grepl("QA:reviewer_config_status=same", same, fixed = TRUE))
  expect_false(grepl("roborev_eval_run.sh", same, fixed = TRUE))

  unknown <- run(state_diff, file.path(tempdir(), "definitely_missing.toml"))
  expect_true(grepl("QA:reviewer_config_status=unknown", unknown, fixed = TRUE))
  expect_false(grepl("roborev_eval_run.sh", unknown, fixed = TRUE),
    info = "an unreadable config must not be reported as a change")
})

test_that("llm#1044: changing only a non-reviewer key (job_timeout_minutes) does not change the fingerprint", {
  skip_if_not_installed("jsonlite")
  e <- new.env(); sys.source(health_lib_path(), envir = e)
  a <- e$rh_config_fingerprint(write_toml(c("review_agent = 'x'", "job_timeout_minutes = 30")))
  b <- e$rh_config_fingerprint(write_toml(c("review_agent = 'x'", "job_timeout_minutes = 45")))
  c <- e$rh_config_fingerprint(write_toml(c("review_agent = 'y'", "job_timeout_minutes = 30")))
  expect_identical(a$hash, b$hash)
  expect_false(identical(a$hash, c$hash))
})

# -- (d) acknowledged triage ---------------------------------------------------

test_that("llm#1123: acknowledged unclassified reviews are counted separately", {
  skip_if_not_installed("blastula")
  db_path <- make_reviews_db_fixture(findings = list(
    list(output = UNCLASSIFIED_PROSE_OUTPUT, age_hours = 1),   # reviews.id 1
    list(output = UNCLASSIFIED_PROSE_OUTPUT, age_hours = 1),   # reviews.id 2
    list(output = UNCLASSIFIED_PROSE_OUTPUT, age_hours = 1)))  # reviews.id 3
  acks <- tempfile("acks_", fileext = ".jsonl")
  writeLines(c('{"id":1,"reason":"false positive","acked_at":"2026-09-01T00:00:00"}',
               '{"id":2,"reason":"wontfix"}'), acks)
  combined <- paste(run_email_dry_run(make_synthetic_snapshot(), extra_env = c(
    paste0("ROBOREV_DB=", db_path), paste0("ROBOREV_ACKS_JSONL=", acks))), collapse = "\n")
  expect_true(grepl("QA:total_unclassified_open_n=1", combined, fixed = TRUE))
  expect_true(grepl("QA:total_acked_unclassified_open_n=2", combined, fixed = TRUE))
  expect_true(grepl("(+2 acknowledged)", combined, fixed = TRUE))
})

test_that("llm#1123: missing acks file -> nothing acknowledged, with a note, no crash", {
  skip_if_not_installed("blastula")
  db_path <- make_reviews_db_fixture(findings = list(
    list(output = UNCLASSIFIED_PROSE_OUTPUT, age_hours = 1)))
  combined <- paste(run_email_dry_run(make_synthetic_snapshot(),
    extra_env = paste0("ROBOREV_DB=", db_path)), collapse = "\n")
  expect_true(grepl("QA:total_unclassified_open_n=1", combined, fixed = TRUE))
  expect_true(grepl("QA:total_acked_unclassified_open_n=0", combined, fixed = TRUE))
  expect_true(grepl("QA:acks_status=missing", combined, fixed = TRUE))
})

test_that("llm#1123: unparseable acks file -> treated as none, with a note, no crash", {
  skip_if_not_installed("blastula")
  db_path <- make_reviews_db_fixture(findings = list(
    list(output = UNCLASSIFIED_PROSE_OUTPUT, age_hours = 1)))
  acks <- tempfile("acks_", fileext = ".jsonl")
  writeLines(c("this is not json", "{also broken"), acks)
  out <- run_email_dry_run(make_synthetic_snapshot(), extra_env = c(
    paste0("ROBOREV_DB=", db_path), paste0("ROBOREV_ACKS_JSONL=", acks)))
  combined <- paste(out, collapse = "\n")
  expect_true(grepl("QA:total_unclassified_open_n=1", combined, fixed = TRUE))
  expect_true(grepl("QA:acks_status=unparseable", combined, fixed = TRUE))
  expect_true(grepl("dry-run complete", combined, fixed = TRUE))
})

# ── Tests: llm#816 — golden eval runs automatically on reviewer-config change ─
#
# The email script (not the launchd wrapper) is where the config change is
# detected, so that is where the harness is invoked: once per new config hash,
# before the body is built, bounded by a timeout so the email still goes out.
# Every case uses a FAKE runner (a shell script that logs its argv and emits
# canned JSON): no live roborev call, no live DB.

make_fake_eval_runner <- function() {
  dir <- tempfile("fake_eval_"); dir.create(dir)
  runner <- file.path(dir, "fake_runner.sh")
  writeLines(c(
    "#!/usr/bin/env bash",
    'echo "$*" >> "$FAKE_EVAL_LOG"',
    'json_out=""; report=""',
    'while [ $# -gt 0 ]; do',
    '  case "$1" in',
    '    --json-out) json_out="$2"; shift 2 ;;',
    '    --report) report="$2"; shift 2 ;;',
    '    *) shift ;;',
    '  esac',
    'done',
    'if [ -n "$report" ]; then',
    '  if [ -n "${FAKE_EVAL_REPORT_JSON:-}" ]; then',
    '    cp "$FAKE_EVAL_REPORT_JSON" "$json_out"; exit "${FAKE_EVAL_REPORT_RC:-0}"',
    '  fi',
    '  echo \'{"overall":"INDETERMINATE","reason":"no fixture results","fixtures":[],"n_fixtures":0}\' > "$json_out"',
    '  exit 3',
    'fi',
    '[ -n "${FAKE_EVAL_SLEEP:-}" ] && sleep "$FAKE_EVAL_SLEEP"',
    '[ -n "${FAKE_EVAL_RUN_JSON:-}" ] && cp "$FAKE_EVAL_RUN_JSON" "$json_out"',
    'exit "${FAKE_EVAL_RUN_RC:-0}"'
  ), runner)
  Sys.chmod(runner, "0755")
  list(runner = runner, log = file.path(dir, "calls.log"), dir = dir)
}

eval_json <- function(overall, fixtures, reason = "") {
  f <- tempfile("eval_", fileext = ".json")
  fx <- vapply(fixtures, function(x) {
    sprintf('{"fixture":"%s","verdict":"%s","flaky":%s,"attempts":[%s],"reason":"r"}',
            x$name, x$verdict, if (isTRUE(x$flaky)) "true" else "false",
            paste0('"', x$attempts, '"', collapse = ","))
  }, "")
  writeLines(sprintf('{"overall":"%s","reason":"%s","fixtures":[%s],"n_fixtures":%d}',
                     overall, reason, paste(fx, collapse = ","), length(fixtures)), f)
  f
}

eval_calls <- function(fake) {
  if (!file.exists(fake$log)) character(0) else readLines(fake$log)
}
run_calls <- function(fake) Filter(function(l) !grepl("--report", l, fixed = TRUE), eval_calls(fake))

load_health_lib <- function() {
  e <- new.env(); sys.source(health_lib_path(), envir = e); e
}
changed_state <- list(status = "changed", prev = "old", cur = "new")
ok_fp <- list(status = "ok", hash = "md5hash", sha256 = strrep("a", 64), text = "global:review_agent=x\n")

test_that("llm#816: config fingerprint carries a sha256 of the effective config, not its text", {
  e <- load_health_lib()
  fp <- e$rh_config_fingerprint(write_toml(c("review_agent = 'x'")))
  expect_match(fp$sha256, "^[0-9a-f]{64}$")
  expect_false(grepl("review_agent", fp$sha256, fixed = TRUE))
  fp2 <- e$rh_config_fingerprint(write_toml(c("review_agent = 'y'")))
  expect_false(identical(fp$sha256, fp2$sha256))
})

test_that("llm#816: unchanged config -> not_needed and the runner is never called", {
  e <- load_health_lib(); fake <- make_fake_eval_runner()
  withr::local_envvar(FAKE_EVAL_LOG = fake$log)
  for (st in c("same", "first", "unknown")) {
    res <- e$rh_eval_on_config_change(list(status = st), ok_fp, fake$runner, timeout_secs = 10)
    expect_identical(res$status, "not_needed", info = st)
  }
  expect_length(eval_calls(fake), 0L)
})

test_that("llm#816: changed config -> runner invoked exactly once with --runs 3 and the sha256", {
  e <- load_health_lib(); fake <- make_fake_eval_runner()
  run_json <- eval_json("PASS", list(
    list(name = "01_real_bug", verdict = "PASS", flaky = TRUE, attempts = c("PASS", "PASS", "FAIL")),
    list(name = "02_clean", verdict = "PASS", flaky = FALSE, attempts = c("PASS", "PASS", "PASS"))))
  withr::local_envvar(FAKE_EVAL_LOG = fake$log, FAKE_EVAL_RUN_JSON = run_json, FAKE_EVAL_RUN_RC = "0")
  res <- e$rh_eval_on_config_change(changed_state, ok_fp, fake$runner, timeout_secs = 10)
  expect_identical(res$status, "ran")
  expect_identical(res$overall, "PASS")
  expect_length(run_calls(fake), 1L)
  expect_match(run_calls(fake), "--runs 3", fixed = TRUE)
  expect_match(run_calls(fake), paste0("--config-hash ", strrep("a", 64)), fixed = TRUE)
  expect_identical(vapply(res$fixtures, function(x) x$fixture, ""), c("01_real_bug", "02_clean"))
  expect_true(res$fixtures[[1]]$flaky)
})

test_that("llm#816: a hash that already has a stored run is reported, not re-run", {
  e <- load_health_lib(); fake <- make_fake_eval_runner()
  stored <- eval_json("PASS", list(
    list(name = "01_real_bug", verdict = "PASS", flaky = FALSE, attempts = c("PASS", "PASS", "PASS"))))
  withr::local_envvar(FAKE_EVAL_LOG = fake$log, FAKE_EVAL_REPORT_JSON = stored, FAKE_EVAL_REPORT_RC = "0")
  res <- e$rh_eval_on_config_change(changed_state, ok_fp, fake$runner, timeout_secs = 10)
  expect_identical(res$status, "reported")
  expect_identical(res$overall, "PASS")
  expect_length(run_calls(fake), 0L)
})

test_that("llm#816: a stored INDETERMINATE run does not count as evaluated -> re-run", {
  e <- load_health_lib(); fake <- make_fake_eval_runner()
  stored <- eval_json("INDETERMINATE", list(
    list(name = "01_real_bug", verdict = "ERROR", flaky = FALSE, attempts = c("ERROR", "ERROR", "ERROR"))),
    reason = "01_real_bug: roborev review did not complete")
  run_json <- eval_json("PASS", list(
    list(name = "01_real_bug", verdict = "PASS", flaky = FALSE, attempts = c("PASS", "PASS", "PASS"))))
  withr::local_envvar(FAKE_EVAL_LOG = fake$log, FAKE_EVAL_REPORT_JSON = stored,
                      FAKE_EVAL_REPORT_RC = "3", FAKE_EVAL_RUN_JSON = run_json)
  res <- e$rh_eval_on_config_change(changed_state, ok_fp, fake$runner, timeout_secs = 10)
  expect_identical(res$status, "ran")
  expect_length(run_calls(fake), 1L)
})

test_that("llm#816: eval FAIL (exit 1) -> overall FAIL", {
  e <- load_health_lib(); fake <- make_fake_eval_runner()
  run_json <- eval_json("FAIL", list(
    list(name = "01_real_bug", verdict = "FAIL", flaky = FALSE, attempts = c("FAIL", "FAIL", "FAIL"))))
  withr::local_envvar(FAKE_EVAL_LOG = fake$log, FAKE_EVAL_RUN_JSON = run_json, FAKE_EVAL_RUN_RC = "1")
  res <- e$rh_eval_on_config_change(changed_state, ok_fp, fake$runner, timeout_secs = 10)
  expect_identical(res$overall, "FAIL")
})

test_that("llm#816: eval that hangs past the timeout -> INDETERMINATE, not a pass, not a crash", {
  e <- load_health_lib(); fake <- make_fake_eval_runner()
  withr::local_envvar(FAKE_EVAL_LOG = fake$log, FAKE_EVAL_SLEEP = "30")
  t0 <- Sys.time()
  res <- e$rh_eval_on_config_change(changed_state, ok_fp, fake$runner, timeout_secs = 2)
  expect_lt(as.numeric(difftime(Sys.time(), t0, units = "secs")), 20)
  expect_identical(res$overall, "INDETERMINATE")
  expect_match(res$reason, "timed out", ignore.case = TRUE)
})

test_that("llm#816: runner exits with no result file -> INDETERMINATE with the exit code", {
  e <- load_health_lib(); fake <- make_fake_eval_runner()
  withr::local_envvar(FAKE_EVAL_LOG = fake$log, FAKE_EVAL_RUN_RC = "2")
  res <- e$rh_eval_on_config_change(changed_state, ok_fp, fake$runner, timeout_secs = 10)
  expect_identical(res$overall, "INDETERMINATE")
  expect_match(res$reason, "exit 2", fixed = TRUE)
})

test_that("llm#816: disabled / dry-run / missing runner -> not_run with a reason, runner not invoked", {
  e <- load_health_lib(); fake <- make_fake_eval_runner()
  withr::local_envvar(FAKE_EVAL_LOG = fake$log)
  r1 <- e$rh_eval_on_config_change(changed_state, ok_fp, fake$runner, enabled = FALSE)
  expect_identical(r1$status, "not_run"); expect_match(r1$reason, "disabled")
  r2 <- e$rh_eval_on_config_change(changed_state, ok_fp, fake$runner, dry_run = TRUE)
  expect_identical(r2$status, "not_run"); expect_match(r2$reason, "dry-run")
  r3 <- e$rh_eval_on_config_change(changed_state, ok_fp, file.path(fake$dir, "nope.sh"))
  expect_identical(r3$status, "not_run"); expect_match(r3$reason, "not found")
  expect_length(run_calls(fake), 0L)
})

email_with_eval <- function(state_hash, fake, extra = character(0)) {
  cfg <- write_toml(c("default_agent = 'claude-code'", "review_agent = 'claude-code'"))
  state <- tempfile("health_state_"); dir.create(state)
  writeLines(state_hash, file.path(state, "reviewer_config.hash"))
  paste(run_email_dry_run(make_synthetic_snapshot(), extra_env = c(
    paste0("ROBOREV_DB=", make_reviews_db_fixture()),
    paste0("ROBOREV_CONFIG_TOML=", cfg),
    paste0("ROBOREV_HEALTH_STATE_DIR=", state),
    paste0("ROBOREV_EVAL_RUNNER=", fake$runner),
    "ROBOREV_EVAL_IN_DRYRUN=1",
    paste0("FAKE_EVAL_LOG=", fake$log),
    extra)), collapse = "\n")
}

test_that("llm#816: email, config unchanged -> no eval, no eval wording", {
  skip_if_not_installed("blastula"); skip_if_not_installed("jsonlite")
  e <- load_health_lib(); fake <- make_fake_eval_runner()
  cfg_hash <- e$rh_config_fingerprint(write_toml(c("default_agent = 'claude-code'",
                                                   "review_agent = 'claude-code'")))$hash
  out <- email_with_eval(cfg_hash, fake)
  expect_true(grepl("QA:reviewer_config_status=same", out, fixed = TRUE))
  expect_length(eval_calls(fake), 0L)
  expect_false(grepl("QA:reviewer_eval_status=", out, fixed = TRUE))
})

test_that("llm#816: email, config changed -> eval invoked once, per-fixture verdicts + flaky + PASS line", {
  skip_if_not_installed("blastula"); skip_if_not_installed("jsonlite")
  fake <- make_fake_eval_runner()
  run_json <- eval_json("PASS", list(
    list(name = "01_real_bug", verdict = "PASS", flaky = TRUE, attempts = c("PASS", "PASS", "FAIL")),
    list(name = "02_clean", verdict = "PASS", flaky = FALSE, attempts = c("PASS", "PASS", "PASS"))))
  out <- email_with_eval("0000deadbeef", fake,
    extra = c(paste0("FAKE_EVAL_RUN_JSON=", run_json)))
  expect_length(run_calls(fake), 1L)
  expect_true(grepl("QA:reviewer_eval_status=PASS", out, fixed = TRUE))
  expect_true(grepl("01_real_bug", out, fixed = TRUE))
  expect_true(grepl("02_clean", out, fixed = TRUE))
  expect_true(grepl("flaky", out, ignore.case = TRUE))
  expect_false(grepl("re-run roborev_eval_run.sh", out, fixed = TRUE),
    info = "the 're-run' advice is replaced by the result")
})

test_that("llm#816: email, eval FAIL -> regression wording", {
  skip_if_not_installed("blastula"); skip_if_not_installed("jsonlite")
  fake <- make_fake_eval_runner()
  run_json <- eval_json("FAIL", list(
    list(name = "01_real_bug", verdict = "FAIL", flaky = FALSE, attempts = c("FAIL", "FAIL", "FAIL"))))
  out <- email_with_eval("0000deadbeef", fake,
    extra = c(paste0("FAKE_EVAL_RUN_JSON=", run_json), "FAKE_EVAL_RUN_RC=1"))
  expect_true(grepl("QA:reviewer_eval_status=FAIL", out, fixed = TRUE))
  expect_true(grepl("regression", out, ignore.case = TRUE))
  expect_true(grepl("do not trust the new reviewer config", out, fixed = TRUE))
})

test_that("llm#816: email, eval timeout -> email still built, INDETERMINATE line with the reason", {
  skip_if_not_installed("blastula"); skip_if_not_installed("jsonlite")
  fake <- make_fake_eval_runner()
  out <- email_with_eval("0000deadbeef", fake,
    extra = c("FAKE_EVAL_SLEEP=30", "ROBOREV_EVAL_TIMEOUT_SECS=2"))
  expect_true(grepl("dry-run complete", out, fixed = TRUE),
    info = "the email body must still be produced when the eval hangs")
  expect_true(grepl("QA:reviewer_eval_status=INDETERMINATE", out, fixed = TRUE))
  expect_true(grepl("eval could not complete", out, fixed = TRUE))
  expect_true(grepl("timed out", out, fixed = TRUE))
})

test_that("llm#816: email dry-run without the seam does not spend review calls; says why", {
  skip_if_not_installed("blastula"); skip_if_not_installed("jsonlite")
  fake <- make_fake_eval_runner()
  out <- email_with_eval("0000deadbeef", fake, extra = "ROBOREV_EVAL_IN_DRYRUN=0")
  expect_length(run_calls(fake), 0L)
  expect_true(grepl("QA:reviewer_eval_status=not_run", out, fixed = TRUE))
  expect_true(grepl("not run", out, ignore.case = TRUE))
  expect_true(grepl("dry-run", out, fixed = TRUE))
})
