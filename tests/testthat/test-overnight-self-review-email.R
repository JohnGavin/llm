# test-overnight-self-review-email.R
#
# Smoke tests for send_overnight_self_review_email.R
#
# Coverage:
#   - dry-run produces non-empty HTML output
#   - dry-run output contains QA markers (overnight_self_review_email, n_new_findings_24h,
#     n_stale_tables, overnight_email_date)
#   - dry-run output contains at least 4 <details> collapsible blocks
#   - dry-run output contains all 4 source table names in Section 2
#   - script exits non-zero when DB is absent
#   - plist passes xmllint syntax check (if xmllint available)
#
# Tests run against the dev-time source tree path, with the installed package
# path (system.file) as the primary fallback when available.
#
# Environment:
#   UNIFIED_DB_PATH  may point to a real or dummy DuckDB file
#   EMAIL_DRY_RUN    forced to "1" in all tests

library(testthat)

# ── Locate sender script ──────────────────────────────────────────────────────

.email_script <- local({
  # Primary: installed package (CI)
  s <- system.file(
    "scripts/send_overnight_self_review_email.R",
    package  = "llm",
    mustWork = FALSE
  )
  # Fallback: dev-time source tree.
  # pkgload::pkg_path() resolves the package root regardless of the working
  # directory; dirname(dirname(test_path())) did not — under test_local()
  # test_path() errors with "Can't find 'tests/testthat'", so this fallback
  # never produced a usable path and every test here failed to locate the
  # script. See #871.
  if (!nzchar(s) || !file.exists(s)) {
    s <- normalizePath(
      file.path(
        pkgload::pkg_path(),
        ".claude", "scripts", "send_overnight_self_review_email.R"
      ),
      mustWork = FALSE
    )
  }
  s
})

.plist_path <- normalizePath(
  file.path(
    pkgload::pkg_path(),
    ".claude", "launchd", "com.claude.overnight-self-review-email.plist"
  ),
  mustWork = FALSE
)

# ── Real DuckDB (if available) ─────────────────────────────────────────────────

.real_db <- normalizePath("~/.claude/logs/unified.duckdb", mustWork = FALSE)

run_dry_run <- function(db_path = .real_db, extra_env = character(0)) {
  skip_if_not(
    nzchar(.email_script) && file.exists(.email_script),
    "send_overnight_self_review_email.R not found"
  )
  env_vars <- c(
    "EMAIL_DRY_RUN=1",
    paste0("UNIFIED_DB_PATH=", db_path),
    "GMAIL_USERNAME=",
    "GMAIL_APP_PASSWORD=",
    "REPORT_RECIPIENT=",
    extra_env
  )
  # env = env_vars, NOT c(Sys.getenv(), env_vars) — same defect #848/#851 fixed
  # in test-kb-digest.R. system2() renders `env` as `env NAME=VAL ... cmd`, and
  # `env` already inherits the parent environment, so splicing all of
  # Sys.getenv() in only produces a vast command line whose quoting mangles the
  # invocation. The script then produced no usable output and the QA-marker and
  # source-table assertions failed against an empty string. See #871.
  system2(
    "Rscript",
    args   = .email_script,
    stdout = TRUE,
    stderr = TRUE,
    env    = env_vars
  )
}

# ── Tests ─────────────────────────────────────────────────────────────────────

test_that("sender script exists", {
  # Was skip_if_not() with no expectation after it -- a test that can only
  # ever SKIP or pass-with-zero-assertions can never go red (Trap A,
  # verification-before-completion). Assert directly instead: this is a real
  # falsifiable check (fails if the script is ever moved/renamed) rather than
  # a guard for tests further down the file. See llm#1192.
  expect_true(
    nzchar(.email_script) && file.exists(.email_script),
    info = paste("Script not found at:", .email_script)
  )
})

test_that("dry-run output is non-empty when DB present", {
  skip_if_not_installed("blastula")
  skip_if_not_installed("duckdb")
  skip_if_not(file.exists(.real_db), "unified.duckdb not available in test environment")

  out      <- run_dry_run()
  combined <- paste(out, collapse = "\n")
  # expect_gt() has no `info` argument (signature is object/expected/label/
  # expected.label) — passing one raised "unused argument" instead of asserting,
  # so this check never actually ran. Context goes in `label`. See #871.
  expect_gt(nchar(combined), 200L,
            label = "dry-run output length (short output usually means an early error)")
})

test_that("dry-run output contains required QA markers", {
  skip_if_not_installed("blastula")
  skip_if_not_installed("duckdb")
  skip_if_not(file.exists(.real_db), "unified.duckdb not available in test environment")

  out      <- run_dry_run()
  combined <- paste(out, collapse = "\n")

  expect_true(grepl("QA:overnight_self_review_email=true", combined),
              info = "Missing QA:overnight_self_review_email marker")
  expect_true(grepl("QA:n_new_findings_24h=", combined),
              info = "Missing QA:n_new_findings_24h marker")
  expect_true(grepl("QA:n_stale_tables=", combined),
              info = "Missing QA:n_stale_tables marker")
  expect_true(grepl("QA:overnight_email_date=", combined),
              info = "Missing QA:overnight_email_date marker")
})

test_that("dry-run output contains at least 4 collapsible <details> blocks", {
  skip_if_not_installed("blastula")
  skip_if_not_installed("duckdb")
  skip_if_not(file.exists(.real_db), "unified.duckdb not available in test environment")

  out      <- run_dry_run()
  combined <- paste(out, collapse = "\n")

  # gregexpr() returns -1 for "no match", and length(-1) is 1 — so the old
  # `length(gregexpr(...)[[1]])` reported 1 block when there were none. Count
  # actual match positions instead. See #871.
  n_details <- sum(gregexpr("<details", combined)[[1]] > 0)
  # Same as above: expect_gte() takes no `info`. testthat already reports the
  # actual value, so `label` only needs to name the quantity. See #871.
  expect_gte(n_details, 4L, label = "number of <details> blocks")
})

test_that("dry-run output contains all 4 source table names in Section 2", {
  skip_if_not_installed("blastula")
  skip_if_not_installed("duckdb")
  skip_if_not(file.exists(.real_db), "unified.duckdb not available in test environment")

  out      <- run_dry_run()
  combined <- paste(out, collapse = "\n")

  for (tbl in c("sessions", "agent_runs", "hook_events", "errors")) {
    expect_true(grepl(tbl, combined),
                info = sprintf("Source table '%s' not found in output", tbl))
  }
})

test_that("dry-run output references llm#491", {
  skip_if_not_installed("blastula")
  skip_if_not_installed("duckdb")
  skip_if_not(file.exists(.real_db), "unified.duckdb not available in test environment")

  out      <- run_dry_run()
  combined <- paste(out, collapse = "\n")

  expect_true(grepl("491", combined),
              info = "Issue #491 reference not found in dry-run output")
})

test_that("dry-run output contains action-required verdict (llm#749 Part B)", {
  skip_if_not_installed("blastula")
  skip_if_not_installed("duckdb")
  skip_if_not(file.exists(.real_db), "unified.duckdb not available in test environment")

  out      <- run_dry_run()
  combined <- paste(out, collapse = "\n")

  expect_true(grepl("QA:n_action_items=", combined),
              info = "Missing QA:n_action_items marker")
  # No `^` anchor: `combined` is every stdout/stderr line joined with "\n"
  # into ONE string, and a preceding line (e.g. an auto-printed icu
  # LOAD/INSTALL result) can precede SUBJECT -- `^` anchors to the start of
  # the whole string, not each line, so it would false-negative here.
  expect_true(grepl("SUBJECT: \\[llm\\] Overnight", combined, fixed = FALSE),
              info = "Subject line not printed in dry-run output")
  # Exactly one of the two verdict renderings must appear -- the subject
  # leads with the verdict (ACTION(n) or all-clear), never raw counts.
  has_action    <- grepl("ACTION\\(\\d+\\)", combined)
  has_all_clear <- grepl("all clear", combined, fixed = TRUE)
  expect_true(has_action || has_all_clear,
              info = "Subject line does not encode ACTION(n) or all-clear verdict")
  expect_false(has_action && has_all_clear,
               info = "Subject line rendered both ACTION and all-clear -- verdict logic is inconsistent")
})

test_that("script exits non-zero when DB path does not exist", {
  skip_if_not_installed("blastula")
  skip_if_not_installed("duckdb")

  fake_db <- "/tmp/does_not_exist_test_overnight.duckdb"
  if (file.exists(fake_db)) file.remove(fake_db)

  cmd <- sprintf(
    "EMAIL_DRY_RUN=1 UNIFIED_DB_PATH='%s' Rscript '%s' > /dev/null 2>&1; echo $?",
    fake_db, .email_script
  )
  exit_code <- as.integer(trimws(system(cmd, intern = TRUE)))
  expect_true(exit_code != 0L,
              info = sprintf("Expected non-zero exit for missing DB, got %d", exit_code))
})

test_that("launchd plist passes xmllint syntax check", {
  skip_if_not(file.exists(.plist_path),
              "Plist not found — skipping xmllint check")
  xmllint <- Sys.which("xmllint")
  skip_if(xmllint == "", "xmllint not available")

  exit_code <- system2(xmllint,
                       args = c("--noout", .plist_path),
                       stdout = FALSE, stderr = FALSE)
  expect_equal(exit_code, 0L,
               info = "Plist does not pass xmllint syntax check")
})

test_that("launchd plist file exists", {
  # Same defect as "sender script exists" above: skip_if_not() with no
  # expectation after it is an empty test that can never fail. Assert
  # directly. See llm#1192.
  expect_true(
    file.exists(.plist_path),
    info = paste("Plist not found at:", .plist_path)
  )
})

# llm#1192: this test used to assert a literal 06:30 schedule. Commit
# 26c7514 (llm#1122/#1125) deliberately moved the job to 08:45 because 06:30
# was 1h45m BEFORE com.claude.staleness-collect's own 08:15 daily run --
# every morning's email read YESTERDAY's staleness snapshot and reported
# healthy jobs as stale. The test was never updated, so `main` has been red
# since that commit landed.
#
# Re-pinning the literal (06:30 -> 08:45) would reproduce the exact failure
# mode: the NEXT deliberate schedule change breaks the test again, for the
# same reason. What the original assertion was actually defending is an
# ordering INVARIANT -- "runs after the staleness snapshot it reads, before
# the 09:00 job-peak contention window" -- so assert that instead, derived
# from the plists themselves rather than restated as a new magic number.

#' Extract StartCalendarInterval Hour/Minute from a launchd plist as
#' minutes-since-midnight. Handles only the single-<dict> StartCalendarInterval
#' form (sufficient for every plist referenced below); returns NA_integer_ if
#' the file is unreadable or the keys can't be found, so callers can
#' distinguish "could not parse" from a real time value.
.schedule_minutes <- function(plist_path) {
  if (!file.exists(plist_path)) {
    return(NA_integer_)
  }
  plist_text <- paste(readLines(plist_path), collapse = "\n")
  hour_m   <- regexpr("<key>Hour</key>\\s*<integer>(\\d+)</integer>", plist_text)
  minute_m <- regexpr("<key>Minute</key>\\s*<integer>(\\d+)</integer>", plist_text)
  if (hour_m == -1L || minute_m == -1L) {
    return(NA_integer_)
  }
  hour   <- as.integer(sub(".*<integer>(\\d+)</integer>.*", "\\1", regmatches(plist_text, hour_m)))
  minute <- as.integer(sub(".*<integer>(\\d+)</integer>.*", "\\1", regmatches(plist_text, minute_m)))
  hour * 60L + minute
}

.hhmm <- function(minutes) sprintf("%02d:%02d", minutes %/% 60L, minutes %% 60L)

.staleness_plist_path <- normalizePath(
  file.path(
    pkgload::pkg_path(),
    ".claude", "launchd", "com.claude.staleness-collect.plist"
  ),
  mustWork = FALSE
)

# config-pulse fires at exactly 09:00 -- the earliest of the named 09:00
# job-peak cluster (worktree-gc 09:06, roborev-project-backlog 09:04,
# roborev-poll-merges 09:02) -- so it is the tightest available boundary for
# "before the 09:00 peak" and, being a single-<dict> StartCalendarInterval
# (unlike roborev-poll-merges' per-weekday <array> form), is directly
# parseable by .schedule_minutes().
.peak_plist_path <- normalizePath(
  file.path(
    pkgload::pkg_path(),
    ".claude", "launchd", "com.claude.config-pulse.plist"
  ),
  mustWork = FALSE
)

test_that("overnight email is scheduled after staleness-collect (llm#1122, llm#1192)", {
  skip_if_not(file.exists(.plist_path), "overnight-self-review-email plist not found")
  # A missing reference plist is INDETERMINATE, not a pass: the ordering
  # invariant literally cannot be checked without it. skip (not pass)
  # distinguishes "did not check" from "checked and fine".
  skip_if_not(
    file.exists(.staleness_plist_path),
    "staleness-collect plist not found -- cannot verify ordering invariant"
  )

  email_minutes      <- .schedule_minutes(.plist_path)
  staleness_minutes  <- .schedule_minutes(.staleness_plist_path)
  skip_if(
    is.na(email_minutes) || is.na(staleness_minutes),
    "Could not parse StartCalendarInterval Hour/Minute from one or both plists"
  )

  expect_true(
    email_minutes > staleness_minutes,
    info = sprintf(
      paste(
        "overnight-self-review-email must run AFTER staleness-collect so it",
        "reads the same morning's snapshot (llm#1122): email=%s,",
        "staleness-collect=%s"
      ),
      .hhmm(email_minutes), .hhmm(staleness_minutes)
    )
  )
})

test_that("overnight email is scheduled before the 09:00 job peak (llm#1122, llm#1192)", {
  skip_if_not(file.exists(.plist_path), "overnight-self-review-email plist not found")
  skip_if_not(
    file.exists(.peak_plist_path),
    "config-pulse plist not found -- cannot verify ordering invariant"
  )

  email_minutes <- .schedule_minutes(.plist_path)
  peak_minutes  <- .schedule_minutes(.peak_plist_path)
  skip_if(
    is.na(email_minutes) || is.na(peak_minutes),
    "Could not parse StartCalendarInterval Hour/Minute from one or both plists"
  )

  expect_true(
    email_minutes < peak_minutes,
    info = sprintf(
      paste(
        "overnight-self-review-email must run BEFORE the 09:00 job peak",
        "(llm#1122): email=%s, config-pulse=%s"
      ),
      .hhmm(email_minutes), .hhmm(peak_minutes)
    )
  )
})

# ── Cron-health "indeterminate" bucket (llm#1145) ──────────────────────────
#
# llm#1145: the cron-health section (Section 3e) folded a heartbeat status
# of 'partial' into the same bucket as a confirmed 'failed', and silently
# resolved a raw-state/exit-code vs derived-heartbeat contradiction in
# favour of whichever side happened to be checked -- both hid a genuine
# INDETERMINATE signal behind a summary line that only distinguished ok
# from failed. `com.claude.launchd_health` sat 'partial' for 27 consecutive
# runs (~4 weeks) while the report's own summary read "0 unknown".
#
# These tests build a scratch COPY of the real unified.duckdb (never the
# live file itself), clear launchd_health_events/housekeeping_runs in the
# copy, and insert exactly the rows under test -- isolating the assertion
# from whatever the real, live cron-health state happens to be on the day
# the suite runs (which, as of llm#1145, already contains a genuine partial
# row and a genuine contradiction row).

#' Build a scratch unified.duckdb fixture: a copy of `.real_db` with
#' launchd_health_events/housekeeping_runs replaced by exactly the rows in
#' `hk_row` / `ev_row` (one row each, as named lists).
#' @return path to the scratch DB, or NULL if prerequisites are unavailable.
.build_cron_fixture_db <- function(hk_row, ev_row) {
  if (!file.exists(.real_db)) return(NULL)
  if (!requireNamespace("DBI", quietly = TRUE)) return(NULL)
  if (!requireNamespace("duckdb", quietly = TRUE)) return(NULL)

  dst <- tempfile(fileext = ".duckdb")
  if (!file.copy(.real_db, dst, overwrite = TRUE)) return(NULL)

  con <- DBI::dbConnect(duckdb::duckdb(), dst, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  DBI::dbExecute(con, "DELETE FROM launchd_health_events")
  DBI::dbExecute(con, "DELETE FROM housekeeping_runs")

  now_utc <- format(Sys.time(), "%Y-%m-%d %H:%M:%S", tz = "UTC")

  if (!is.null(hk_row)) {
    DBI::dbExecute(con, sprintf(
      "INSERT INTO housekeeping_runs
         (id, task, source_script, started_at, ended_at, status, rows_written)
       VALUES ('fixture-hk', %s, 'test-fixture', TIMESTAMPTZ '%s', TIMESTAMPTZ '%s', %s, %d)",
      DBI::dbQuoteString(con, hk_row$task), now_utc, now_utc,
      DBI::dbQuoteString(con, hk_row$status), hk_row$rows_written
    ))
  }

  DBI::dbExecute(con, sprintf(
    "INSERT INTO launchd_health_events
       (id, fired_at, source, plist_label, state, last_exit_code, last_fired_at, next_fire_at, detail)
     VALUES ('fixture-ev', TIMESTAMPTZ '%s', 'test-fixture', %s, %s, %s, %s, NULL, NULL)",
    now_utc,
    DBI::dbQuoteString(con, ev_row$plist_label),
    DBI::dbQuoteString(con, ev_row$state),
    if (is.na(ev_row$last_exit_code)) "NULL" else ev_row$last_exit_code,
    if (isTRUE(ev_row$last_fired_at_now)) sprintf("TIMESTAMPTZ '%s'", now_utc) else "NULL"
  ))

  dst
}

# `com.claude.worktree-gc` is used as the plist_label for every fixture
# below because it must have a real .plist file under ~/Library/LaunchAgents
# -- the sender script's plist-existence filter is not env-overridable, so
# a synthetic label with no matching file would be silently dropped from
# the table (0 rows), not tested.
.WORKTREE_GC_PLIST <- file.path(
  path.expand("~"), "Library", "LaunchAgents", "com.claude.worktree-gc.plist"
)

test_that("cron-health: partial heartbeat renders as indeterminate, not ok or failed (llm#1145)", {
  skip_if_not_installed("blastula")
  skip_if_not_installed("duckdb")
  skip_if_not(file.exists(.WORKTREE_GC_PLIST),
              "com.claude.worktree-gc.plist not installed -- fixture row would be filtered out")

  db <- .build_cron_fixture_db(
    hk_row = list(task = "worktree_gc", status = "partial", rows_written = 42L),
    ev_row = list(plist_label = "com.claude.worktree-gc", state = "loaded_ok",
                   last_exit_code = 0L, last_fired_at_now = TRUE)
  )
  skip_if(is.null(db), "could not build cron-health fixture DB")

  out      <- run_dry_run(db_path = db)
  combined <- paste(out, collapse = "\n")

  expect_true(grepl("indeterminate", combined, fixed = TRUE),
              info = "partial heartbeat did not render as indeterminate")
  expect_true(grepl("1 indeterminate", combined, fixed = TRUE),
              info = "summary line did not count the partial row as indeterminate")
  expect_false(grepl("plists · 1 ok ·", combined, fixed = TRUE),
               info = "partial heartbeat was folded into the ok count")
})

test_that("cron-health: raw-exit-code vs heartbeat contradiction renders as indeterminate with both values (llm#1145 Finding 2, narrowed by llm#1188)", {
  skip_if_not_installed("blastula")
  skip_if_not_installed("duckdb")
  skip_if_not(file.exists(.WORKTREE_GC_PLIST),
              "com.claude.worktree-gc.plist not installed -- fixture row would be filtered out")

  # llm#1188 narrowed the contradiction check so that exit 1 alongside
  # heartbeat 'ok' is no longer flagged (that combination is the documented
  # exit-code-conventions findings shape -- see the dedicated test below).
  # This fixture uses exit 2 (usage error per exit-code-conventions), which
  # is NOT part of that convention and must still read as a genuine,
  # unresolved contradiction.
  db <- .build_cron_fixture_db(
    hk_row = list(task = "worktree_gc", status = "ok", rows_written = 168L),
    ev_row = list(plist_label = "com.claude.worktree-gc", state = "loaded_recent_fail",
                   last_exit_code = 2L, last_fired_at_now = TRUE)
  )
  skip_if(is.null(db), "could not build cron-health fixture DB")

  out      <- run_dry_run(db_path = db)
  combined <- paste(out, collapse = "\n")

  expect_true(grepl("indeterminate", combined, fixed = TRUE),
              info = "raw-state/exit-code contradiction did not render as indeterminate")
  expect_true(grepl("raw exit 2", combined, fixed = TRUE),
              info = "raw exit code value not shown in the contradiction label")
  expect_true(grepl("heartbeat 'ok", combined, fixed = TRUE),
              info = "heartbeat-derived value not shown in the contradiction label")
  expect_false(grepl("plists · 1 ok · 0 failed · 0 indeterminate", combined, fixed = TRUE),
               info = "contradiction was silently resolved as a clean ok")
})

test_that("cron-health: exit 1 alongside heartbeat 'ok' renders as a determinate ok, not indeterminate (llm#1188, narrows llm#1145 Finding 2)", {
  skip_if_not_installed("blastula")
  skip_if_not_installed("duckdb")
  skip_if_not(file.exists(.WORKTREE_GC_PLIST),
              "com.claude.worktree-gc.plist not installed -- fixture row would be filtered out")

  # exit-code-conventions: 0 PASS / 1 FAIL findings / 2 usage error /
  # 3 INDETERMINATE. A scanner exiting 1 with a heartbeat of 'ok' ran
  # cleanly and found N rows worth flagging -- this is exactly the
  # secret_exposure_scan.sh / private_data_history_audit.sh shape that was
  # wrongly reported "indeterminate" every day before llm#1188.
  db <- .build_cron_fixture_db(
    hk_row = list(task = "worktree_gc", status = "ok", rows_written = 138L),
    ev_row = list(plist_label = "com.claude.worktree-gc", state = "loaded_recent_fail",
                   last_exit_code = 1L, last_fired_at_now = TRUE)
  )
  skip_if(is.null(db), "could not build cron-health fixture DB")

  out      <- run_dry_run(db_path = db)
  combined <- paste(out, collapse = "\n")

  expect_true(grepl("0 indeterminate", combined, fixed = TRUE),
              info = "exit 1 + heartbeat ok was still counted as indeterminate")
  expect_true(grepl("plists · 1 ok · 0 failed · 0 indeterminate", combined, fixed = TRUE),
              info = "exit 1 + heartbeat ok was not counted as a clean ok in the summary line")
  expect_true(grepl("138 finding row(s)", combined, fixed = TRUE),
              info = "row-level label did not state the finding count")
  expect_true(grepl("exit 1 = findings, per exit-code-conventions", combined, fixed = TRUE),
              info = "row-level label did not explain why exit 1 is not a failure")
  expect_false(grepl("raw exit 1 vs heartbeat", combined, fixed = TRUE),
               info = "exit 1 + heartbeat ok was still rendered as a raw-exit-vs-heartbeat contradiction")
})

test_that("cron-health: exit 0 alongside heartbeat 'failed' still renders as indeterminate (unchanged by llm#1188)", {
  skip_if_not_installed("blastula")
  skip_if_not_installed("duckdb")
  skip_if_not(file.exists(.WORKTREE_GC_PLIST),
              "com.claude.worktree-gc.plist not installed -- fixture row would be filtered out")

  # The llm#1188 narrowing only exempts exit 1 + heartbeat 'ok'. The
  # opposite disagreement -- a clean exit code alongside a heartbeat that
  # recorded a hard failure -- is not part of the findings convention at
  # all and must remain a flagged, unresolved contradiction.
  db <- .build_cron_fixture_db(
    hk_row = list(task = "worktree_gc", status = "failed", rows_written = 0L),
    ev_row = list(plist_label = "com.claude.worktree-gc", state = "loaded_ok",
                   last_exit_code = 0L, last_fired_at_now = TRUE)
  )
  skip_if(is.null(db), "could not build cron-health fixture DB")

  out      <- run_dry_run(db_path = db)
  combined <- paste(out, collapse = "\n")

  expect_true(grepl("indeterminate", combined, fixed = TRUE),
              info = "exit 0 + heartbeat failed did not render as indeterminate")
  expect_true(grepl("raw exit 0", combined, fixed = TRUE),
              info = "raw exit code value not shown in the contradiction label")
  expect_true(grepl("heartbeat 'failed", combined, fixed = TRUE),
              info = "heartbeat-derived value not shown in the contradiction label")
})

test_that("cron-health: zero indeterminate is rendered explicitly, not omitted (llm#1145)", {
  skip_if_not_installed("blastula")
  skip_if_not_installed("duckdb")
  skip_if_not(file.exists(.WORKTREE_GC_PLIST),
              "com.claude.worktree-gc.plist not installed -- fixture row would be filtered out")

  db <- .build_cron_fixture_db(
    hk_row = list(task = "worktree_gc", status = "ok", rows_written = 5L),
    ev_row = list(plist_label = "com.claude.worktree-gc", state = "loaded_ok",
                   last_exit_code = 0L, last_fired_at_now = TRUE)
  )
  skip_if(is.null(db), "could not build cron-health fixture DB")

  out      <- run_dry_run(db_path = db)
  combined <- paste(out, collapse = "\n")

  expect_true(grepl("0 indeterminate", combined, fixed = TRUE),
              info = "zero-indeterminate case did not explicitly print '0 indeterminate'")
})

# ── Lessons-captured section ─────────────────────────────────────────────────
# Every Stage-1 detector reads telemetry only, so a lesson written to
# .claude/memory/ or .claude/rules/ was invisible to the whole report. These
# three tests pin the two things that matter about the new section: it CAN go
# non-empty (Trap A — a check that can never fire is not a check), and a broken
# dependency renders distinguishably from a genuine "nothing captured"
# (`checks-must-distinguish-unknown`).

test_that("lessons section reports INDETERMINATE, not 'none', when the repo is unreadable", {
  skip_if_not_installed("blastula")
  skip_if_not_installed("duckdb")
  skip_if_not(file.exists(.real_db), "unified.duckdb not available in test environment")

  bad_root <- file.path(tempdir(), "lessons-not-a-repo")
  dir.create(bad_root, showWarnings = FALSE, recursive = TRUE)
  on.exit(unlink(bad_root, recursive = TRUE), add = TRUE)

  out      <- run_dry_run(extra_env = paste0("LLM_REPO_ROOT=", bad_root))
  combined <- paste(out, collapse = "\n")

  expect_true(grepl("Could not determine", combined, fixed = TRUE),
              info = "Broken repo path did not render an indeterminate marker")
  # The load-bearing assertion: a dependency failure must NOT be reported as a
  # clean negative result. These two share no exit.
  expect_false(grepl("No commit touched", combined, fixed = TRUE),
               info = "Unreadable repo rendered as a determinate 'no lessons' result")
})

test_that("lessons section lists commits touching .claude/memory (the check can go non-empty)", {
  skip_if_not_installed("blastula")
  skip_if_not_installed("duckdb")
  skip_if_not(file.exists(.real_db), "unified.duckdb not available in test environment")
  skip_if(unname(Sys.which("git")) == "", "git not on PATH")

  fixture <- file.path(tempdir(), "lessons-fixture-repo")
  unlink(fixture, recursive = TRUE)
  dir.create(file.path(fixture, ".claude", "memory"), recursive = TRUE, showWarnings = FALSE)
  on.exit(unlink(fixture, recursive = TRUE), add = TRUE)

  git <- function(...) system2("git", shQuote(c("-C", fixture, ...)),
                               stdout = FALSE, stderr = FALSE)
  git("init", "--quiet")
  git("config", "user.email", "test@example.invalid")
  git("config", "user.name", "Test")
  writeLines("lesson body", file.path(fixture, ".claude", "memory", "feedback_probe.md"))
  git("add", "-A")
  git("commit", "--quiet", "-m", "docs(memory): PROBE-LESSON-MARKER")

  out      <- run_dry_run(extra_env = paste0("LLM_REPO_ROOT=", fixture))
  combined <- paste(out, collapse = "\n")

  expect_true(grepl("PROBE-LESSON-MARKER", combined, fixed = TRUE),
              info = "A memory-file commit inside the 24h window was not surfaced")
  expect_false(grepl("Could not determine", combined, fixed = TRUE),
               info = "A healthy fixture repo was reported as indeterminate")
})

test_that("the all-clear box states what it did NOT check, and never claims 'nothing needs action'", {
  skip_if_not_installed("blastula")
  skip_if_not_installed("duckdb")
  skip_if_not(file.exists(.real_db), "unified.duckdb not available in test environment")

  out      <- run_dry_run()
  combined <- paste(out, collapse = "\n")

  # The verdict escalates on critical/major findings, cron failures and stale
  # tables only. `info`/`minor` findings never reach it, so an unqualified
  # "nothing needs action" overclaims across surfaces this report cannot see —
  # and contradicts the scope banner rendered immediately above it.
  expect_false(grepl("nothing needs action", combined, fixed = TRUE),
               info = "Verdict still claims 'nothing needs action' beyond its own scope")

  if (grepl("QA:n_action_items=0", combined, fixed = TRUE)) {
    expect_true(grepl("No action-level findings", combined, fixed = TRUE),
                info = "Zero action items did not render the scoped all-clear wording")
    expect_true(grepl("Not checked: config, rules, code", combined, fixed = TRUE),
                info = "All-clear box omitted the not-checked scope disclaimer")
  }
})
