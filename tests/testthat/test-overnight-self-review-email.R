# test-overnight-self-review-email.R
#
# Smoke tests for send_overnight_self_review_email.R
#
# Coverage:
#   - dry-run produces non-empty HTML output
#   - dry-run output contains QA markers (overnight_self_review_email, n_new_findings_24h,
#     n_stale_tables, overnight_email_date)
#   - dry-run output contains at least 4 <details> collapsible blocks
#   - Section 2 table has a row for each of the 4 detector-input tables
#   - errors table idle / empty / missing: IDLE vs UNKNOWN (never all-clear)
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

# TRUE when the .claude/ tree is absent from the package root -- i.e. a build
# tree with .Rbuildignore (`^\.claude$`) applied, as under
# covr::package_coverage(). Skipping on THIS condition (not on the individual
# file being missing) keeps the "exists" assertions below falsifiable: with
# .claude/ present, a moved/renamed file still fails. The pkg root can be
# overridden via option llm.test_pkg_root (used to falsify this in testing).
.claude_tree_stripped <- function() {
  root <- getOption("llm.test_pkg_root", pkgload::pkg_path())
  !dir.exists(file.path(root, ".claude"))
}

# ── Real DuckDB (if available) ─────────────────────────────────────────────────

.real_db <- normalizePath("~/.claude/logs/unified.duckdb", mustWork = FALSE)

# llm#1405: NO test copies or reads rows from the live DB. The live file is
# opened READ-ONLY once, only to learn the table/view SCHEMA; every fixture is
# a small tempfile DB holding empty tables of that shape plus the rows under
# test. Every per-test copy is removed at the end of its test.
.fx <- new.env(parent = emptyenv())

#' Schema-only base fixture (cached for the file, removed at teardown).
#' Empty copies of every base table, then every view, from the live DB.
#' @return path to the base DB, or NULL if the live schema is unavailable
#'   (callers skip).
.schema_base_db <- function() {
  if (!is.null(.fx$base) && file.exists(.fx$base)) return(.fx$base)
  if (!file.exists(.real_db)) return(NULL)
  if (!requireNamespace("DBI", quietly = TRUE)) return(NULL)
  if (!requireNamespace("duckdb", quietly = TRUE)) return(NULL)
  dst <- tempfile("overnight_schema_", fileext = ".duckdb")
  con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dst), error = function(e) NULL)
  if (is.null(con)) return(NULL)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  ok <- FALSE
  for (attempt in 1:5) {   # live DB may be write-locked for a moment
    ok <- tryCatch({
      DBI::dbExecute(con, sprintf("ATTACH '%s' AS live (READ_ONLY)", .real_db))
      TRUE
    }, error = function(e) FALSE)
    if (ok) break
    Sys.sleep(2)
  }
  if (!ok) { unlink(dst); return(NULL) }
  tbls <- DBI::dbGetQuery(con, "SELECT table_name FROM duckdb_tables()
                                WHERE database_name = 'live' AND schema_name = 'main'")$table_name
  for (t in tbls) {
    DBI::dbExecute(con, sprintf(
      "CREATE TABLE main.%s AS SELECT * FROM live.main.%s LIMIT 0",
      DBI::dbQuoteIdentifier(con, t), DBI::dbQuoteIdentifier(con, t)))
  }
  views <- DBI::dbGetQuery(con, "SELECT view_name, sql FROM duckdb_views()
                                 WHERE database_name = 'live' AND NOT internal
                                   AND schema_name = 'main'")
  pending <- views$sql
  for (pass in seq_len(nrow(views) + 1L)) {   # views may reference views
    pending <- Filter(function(s) !tryCatch({
      DBI::dbExecute(con, s); TRUE }, error = function(e) FALSE), pending)
    if (!length(pending)) break
  }
  DBI::dbExecute(con, "DETACH live")
  if (length(pending)) { unlink(dst); return(NULL) }
  DBI::dbExecute(con, "CHECKPOINT")
  .fx$base <- dst
  withr::defer(unlink(dst), envir = testthat::teardown_env())
  dst
}

#' A fresh, small, per-test copy of the schema-only base DB. Removed when the
#' calling test ends. @return path, or NULL if the base is unavailable.
.new_fixture_db <- function(envir = parent.frame()) {
  base <- .schema_base_db()
  if (is.null(base)) return(NULL)
  dst <- tempfile("overnight_fixture_", fileext = ".duckdb")
  if (!file.copy(base, dst)) return(NULL)
  withr::defer(unlink(dst), envir = envir)
  dst
}

run_dry_run <- function(db_path = NULL, extra_env = character(0)) {
  skip_if_not(
    nzchar(.email_script) && file.exists(.email_script),
    "send_overnight_self_review_email.R not found"
  )
  if (is.null(db_path)) db_path <- .schema_base_db()
  skip_if(is.null(db_path), "live unified.duckdb schema not available in test environment")
  env_vars <- c(
    "EMAIL_DRY_RUN=1",
    paste0("UNIFIED_DB_PATH=", db_path),
    "GMAIL_USERNAME=",
    "GMAIL_APP_PASSWORD=",
    "REPORT_RECIPIENT=",
    extra_env
  )
  # The GitHub-run retry step must never reach the real gh from a test: unless a case
  # supplies its own fake, use a no-op script.
  if (!any(startsWith(extra_env, "GH_RUN_RETRY_SCRIPT="))) {
    noop <- tempfile("gh_run_retry_noop_", fileext = ".sh")
    writeLines(c("#!/bin/bash", "exit 0"), noop)
    on.exit(unlink(noop), add = TRUE)
    env_vars <- c(env_vars, paste0("GH_RUN_RETRY_SCRIPT=", noop))
  }
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
  skip_if(
    .claude_tree_stripped(),
    ".claude/ not in build tree (.Rbuildignore, e.g. under covr)"
  )
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

# ── Section 2 helpers (review F3/F6) ──────────────────────────────────────────

# The Section 2 table only: from its title to the first closing </table>. A
# whole-document grep for a table name (the old F6 test) is satisfied by any
# unrelated mention, e.g. Section 3's cumulative-totals table.
.section2_html <- function(combined) {
  start <- regexpr("Source table volume (last 24h)", combined, fixed = TRUE)
  if (start < 0L) return(NA_character_)
  rest <- substring(combined, start)
  end  <- regexpr("</table>", rest, fixed = TRUE)
  if (end < 0L) return(NA_character_)
  substr(rest, 1L, end)
}

# Status badge text ("live", "IDLE", "UNKNOWN", ...) of one table's Section 2 row.
.section2_status <- function(sec2, tbl) {
  m <- regexec(
    sprintf("(?s)>%s</td>.*?font-weight:bold;\">([A-Za-z]+)</span>", tbl),
    sec2, perl = TRUE
  )
  hit <- regmatches(sec2, m)[[1]]
  if (length(hit) < 2L) NA_character_ else hit[[2]]
}

# Make a small schema-only fixture DB (llm#1405: never a copy of the live DB)
# and apply `mutate_sql` (via DBI, so no CLI DROP is involved). The fixture is
# removed when the calling test ends.
.mutated_db <- function(mutate_sql, envir = parent.frame()) {
  skip_if_not_installed("duckdb")
  tmp <- .new_fixture_db(envir = envir)
  skip_if(is.null(tmp), "unified.duckdb schema not available in test environment")
  con <- DBI::dbConnect(duckdb::duckdb(), tmp)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  for (s in mutate_sql) DBI::dbExecute(con, s)
  tmp
}

test_that("Section 2 table lists all 4 detector-input tables as rows (review F3/F6)", {
  skip_if_not_installed("blastula")
  skip_if_not_installed("duckdb")
  skip_if_not(file.exists(.real_db), "unified.duckdb not available in test environment")

  combined <- paste(run_dry_run(), collapse = "\n")
  sec2 <- .section2_html(combined)
  expect_false(is.na(sec2), label = "could locate the Section 2 table")

  for (tbl in c("sessions", "agent_runs", "hook_events", "errors")) {
    expect_true(grepl(sprintf(">%s</td>", tbl), sec2, fixed = TRUE),
                info = sprintf("Source table '%s' has no row in the Section 2 table", tbl))
  }
  # ...and the header count must equal the number of rows (was "of 3" while
  # four tables fed the detectors).
  expect_true(grepl("of 4 source tables", combined, fixed = TRUE),
              info = "header does not report 4 source tables")
})

test_that("errors quiet for a long time is IDLE (informational), not stale, and does not raise an action item (review F3)", {
  skip_if_not_installed("blastula")
  # Schema-only fixture has an empty errors table: insert the one old row
  # under test (a long-quiet but non-empty table is what makes it IDLE).
  db <- .mutated_db(paste("INSERT INTO errors (id, session_id, source, error_text, context, logged_at)",
                          "VALUES (1, 'fixture', 'test', 'old error', 'fixture', TIMESTAMP '2026-01-01 00:00:00')"))
  on.exit(unlink(db), add = TRUE)
  combined <- paste(run_dry_run(db), collapse = "\n")
  sec2 <- .section2_html(combined)
  expect_equal(.section2_status(sec2, "errors"), "IDLE")
})

test_that("errors table EMPTY is UNKNOWN and forces a non-all-clear verdict (review F3, checks-must-distinguish-unknown)", {
  skip_if_not_installed("blastula")
  db <- .mutated_db("DELETE FROM errors")
  on.exit(unlink(db), add = TRUE)
  combined <- paste(run_dry_run(db), collapse = "\n")
  sec2 <- .section2_html(combined)
  expect_equal(.section2_status(sec2, "errors"), "UNKNOWN")
  expect_false(grepl("QA:n_stale_tables=0 ", combined, fixed = TRUE),
               label = "empty errors table left n_stale_tables at 0")
  expect_false(grepl("all clear", combined, fixed = TRUE),
               label = "empty errors table still produced an all-clear subject")
})

test_that("errors table MISSING is UNKNOWN and forces a non-all-clear verdict (review F3)", {
  skip_if_not_installed("blastula")
  db <- .mutated_db("ALTER TABLE errors RENAME TO errors_renamed_by_test")
  on.exit(unlink(db), add = TRUE)
  combined <- paste(run_dry_run(db), collapse = "\n")
  sec2 <- .section2_html(combined)
  expect_equal(.section2_status(sec2, "errors"), "UNKNOWN")
  expect_false(grepl("all clear", combined, fixed = TRUE),
               label = "missing errors table still produced an all-clear subject")
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
  skip_if(
    .claude_tree_stripped(),
    ".claude/ not in build tree (.Rbuildignore, e.g. under covr)"
  )
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
# These tests build a scratch SCHEMA-ONLY fixture (llm#1405: empty tables, no
# live rows), and insert exactly the rows under test -- isolating the assertion
# from whatever the real, live cron-health state happens to be on the day
# the suite runs (which, as of llm#1145, already contains a genuine partial
# row and a genuine contradiction row).

#' Build a scratch unified.duckdb fixture: the schema-only base with
#' launchd_health_events/housekeeping_runs holding exactly the rows in
#' `hk_row` / `ev_row` (one row each, as named lists).
#' `prev_hk_row` (optional) adds an earlier ok run of the same task 2 days
#' before, as the baseline for the new-vs-known finding split. `findings`
#' (optional) is a list(latest = data.frame(detector,file_path,line_num,name),
#' prev = same) written to secret_scan_findings for 'fixture-hk' /
#' 'fixture-hk-prev'.
#' @return path to the scratch DB, or NULL if prerequisites are unavailable.
.build_cron_fixture_db <- function(hk_row, ev_row, prev_hk_row = NULL, findings = NULL,
                                   hist = NULL) {
  # llm#1405: schema-only fixture (small), removed when the calling test ends.
  dst <- .new_fixture_db(envir = parent.frame())
  if (is.null(dst)) return(NULL)
  con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dst, read_only = FALSE),
                  error = function(e) NULL)
  if (is.null(con)) return(NULL)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  DBI::dbExecute(con, "DELETE FROM launchd_health_events")
  DBI::dbExecute(con, "DELETE FROM housekeeping_runs")
  DBI::dbExecute(con, "DELETE FROM secret_scan_findings")

  now_utc <- format(Sys.time(), "%Y-%m-%d %H:%M:%S", tz = "UTC")

  if (!is.null(hk_row)) {
    # hk_row$age_h (optional): the row started that many hours ago, and a
    # 'running' row then has no ended_at (a run killed before it finalised).
    hk_start <- if (is.null(hk_row$age_h)) now_utc else
      format(Sys.time() - hk_row$age_h * 3600, "%Y-%m-%d %H:%M:%S", tz = "UTC")
    hk_end <- if (identical(hk_row$status, "running")) "NULL" else
      sprintf("TIMESTAMPTZ '%s'", hk_start)
    DBI::dbExecute(con, sprintf(
      "INSERT INTO housekeeping_runs
         (id, task, source_script, started_at, ended_at, status, rows_written)
       VALUES ('fixture-hk', %s, 'test-fixture', TIMESTAMPTZ '%s', %s, %s, %d)",
      DBI::dbQuoteString(con, hk_row$task), hk_start, hk_end,
      DBI::dbQuoteString(con, hk_row$status), hk_row$rows_written
    ))
  }

  if (!is.null(prev_hk_row)) {
    prev_utc <- format(Sys.time() - 2 * 86400, "%Y-%m-%d %H:%M:%S", tz = "UTC")
    DBI::dbExecute(con, sprintf(
      "INSERT INTO housekeeping_runs
         (id, task, source_script, started_at, ended_at, status, rows_written)
       VALUES ('fixture-hk-prev', %s, 'test-fixture', TIMESTAMPTZ '%s', TIMESTAMPTZ '%s', %s, %d)",
      DBI::dbQuoteString(con, prev_hk_row$task), prev_utc, prev_utc,
      DBI::dbQuoteString(con, prev_hk_row$status), prev_hk_row$rows_written
    ))
  }
  for (nm in c("latest", "prev")) {
    f <- findings[[nm]]
    if (is.null(f) || nrow(f) == 0L) next
    for (i in seq_len(nrow(f))) {
      DBI::dbExecute(con, sprintf(
        "INSERT INTO secret_scan_findings
           (id, run_id, fired_at, detector, severity, file_path, line_num, name, note)
         VALUES ('fx-%s-%d', %s, TIMESTAMPTZ '%s', %s, 'high', %s, %s, %s, 'fixture')",
        nm, i, DBI::dbQuoteString(con, if (nm == "latest") "fixture-hk" else "fixture-hk-prev"),
        now_utc, DBI::dbQuoteString(con, f$detector[[i]]),
        DBI::dbQuoteString(con, f$file_path[[i]]), DBI::dbQuoteString(con, f$line_num[[i]]),
        DBI::dbQuoteString(con, f$name[[i]])))
    }
  }

  # hist = list(n_run =, n_old =): synthetic rows in the per-finding ledger
  # private_data_history_findings -- n_run rows first seen during the latest
  # run's window, n_old rows first seen 2 days earlier (standing). The table
  # is created from the REAL schema file so the DDL under test is the shipped
  # one; paths are invented.
  if (!is.null(hist)) {
    schema <- readLines(file.path(pkgload::pkg_path(), ".claude", "scripts",
                                  "housekeeping_schema_init.sql"))
    s <- grep("^CREATE TABLE IF NOT EXISTS private_data_history_findings", schema)
    e <- s + which(grepl("^\\);", schema[s:length(schema)]))[[1]] - 1L
    DBI::dbExecute(con, paste(schema[s:e], collapse = "\n"))
    old_utc <- format(Sys.time() - 2 * 86400, "%Y-%m-%d %H:%M:%S", tz = "UTC")
    ins <- function(i, at) DBI::dbExecute(con, sprintf(
      "INSERT INTO private_data_history_findings
         (fingerprint, repo, rule, src, severity, commit_sha, path, line_num, first_seen, last_seen, status)
       VALUES ('fp-%s-%d', 'synthetic/repo', 'uk-postcode', 'generic', 'high', 'aaaaaaaaaaaa',
               'synthetic/path-%d.txt', '1', TIMESTAMPTZ '%s', TIMESTAMPTZ '%s', 'known')",
      at, i, i, if (at == "run") now_utc else old_utc, if (at == "run") now_utc else old_utc))
    n_run <- if (is.null(hist$n_run)) 0L else hist$n_run
    n_old <- if (is.null(hist$n_old)) 0L else hist$n_old
    for (i in seq_len(n_run)) ins(i, "run")
    for (i in seq_len(n_old)) ins(i, "old")
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
                   last_exit_code = 1L, last_fired_at_now = TRUE),
    # baseline: same count last time => nothing new (see the new-vs-known
    # tests below for what happens without a baseline or when the count rises)
    prev_hk_row = list(task = "worktree_gc", status = "ok", rows_written = 138L)
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


# ── Status accuracy: skipped / exit-1 consistency / new findings ─────────────

.SECRET_SCAN_PLIST <- file.path(
  path.expand("~"), "Library", "LaunchAgents", "com.claude.secret-exposure-scan.plist"
)
.CONFIG_DIGEST_PLIST <- file.path(
  path.expand("~"), "Library", "LaunchAgents", "com.claude.config-digest-email.plist"
)

test_that("cron-health: heartbeat 'skipped' renders as ok, not indeterminate (llm#1340/#1341)", {
  skip_if_not_installed("blastula")
  skip_if_not_installed("duckdb")
  skip_if_not(file.exists(.CONFIG_DIGEST_PLIST), "com.claude.config-digest-email.plist not installed")

  db <- .build_cron_fixture_db(
    hk_row = list(task = "config_digest", status = "skipped", rows_written = 0L),
    ev_row = list(plist_label = "com.claude.config-digest-email", state = "loaded_ok",
                   last_exit_code = 0L, last_fired_at_now = TRUE)
  )
  skip_if(is.null(db), "could not build cron-health fixture DB")
  combined <- paste(run_dry_run(db_path = db), collapse = "\n")

  expect_true(grepl("ok — skipped (no changes to report)", combined, fixed = TRUE))
  expect_true(grepl("plists · 1 ok · 0 failed · 0 indeterminate", combined, fixed = TRUE),
              info = "skipped was not counted as a clean ok")
  expect_false(grepl("heartbeat could not confirm", combined, fixed = TRUE))
})

test_that("cron-health: exit-1 findings job shows a Raw state consistent with its ok Result", {
  skip_if_not_installed("blastula")
  skip_if_not_installed("duckdb")
  skip_if_not(file.exists(.WORKTREE_GC_PLIST), "worktree-gc plist not installed")

  db <- .build_cron_fixture_db(
    hk_row = list(task = "worktree_gc", status = "ok", rows_written = 7L),
    ev_row = list(plist_label = "com.claude.worktree-gc", state = "loaded_recent_fail",
                   last_exit_code = 1L, last_fired_at_now = TRUE),
    prev_hk_row = list(task = "worktree_gc", status = "ok", rows_written = 7L)
  )
  skip_if(is.null(db), "could not build cron-health fixture DB")
  combined <- paste(run_dry_run(db_path = db), collapse = "\n")

  expect_true(grepl("ok (ran)", combined, fixed = TRUE))
  expect_true(grepl("loaded (exit 1 = findings)", combined, fixed = TRUE),
              info = "Raw state column should explain exit 1, not read as a failure")
  expect_false(grepl("loaded_recent_fail", combined, fixed = TRUE),
               info = "Raw state still says loaded_recent_fail next to an ok Result")
})

test_that("cron-health: NEW scanner findings are not plain ok and become an action item", {
  skip_if_not_installed("blastula")
  skip_if_not_installed("duckdb")
  skip_if_not(file.exists(.SECRET_SCAN_PLIST), "secret-exposure-scan plist not installed")

  known <- data.frame(detector = "1", file_path = "a.R", line_num = "3", name = "cred-shape")
  new1  <- data.frame(detector = "2", file_path = "b.R", line_num = "9", name = "plaintext")
  db <- .build_cron_fixture_db(
    hk_row = list(task = "secret_exposure_scan", status = "ok", rows_written = 2L),
    ev_row = list(plist_label = "com.claude.secret-exposure-scan", state = "loaded_recent_fail",
                   last_exit_code = 1L, last_fired_at_now = TRUE),
    prev_hk_row = list(task = "secret_exposure_scan", status = "ok", rows_written = 1L),
    findings = list(latest = rbind(known, new1), prev = known)
  )
  skip_if(is.null(db), "could not build cron-health fixture DB")
  combined <- paste(run_dry_run(db_path = db), collapse = "\n")

  expect_true(grepl("1 new finding(s) need triage", combined, fixed = TRUE))
  expect_true(grepl("Action required", combined, fixed = TRUE),
              info = "new findings did not reach the action-required section")
  expect_true(grepl("1 need triage", combined, fixed = TRUE))
  expect_false(grepl("plists · 1 ok ·", combined, fixed = TRUE),
               info = "new findings were counted as a plain ok")
})

# llm#1458 part 2: new scanner rows are classified by .claude/state/scanner_policy.tsv.
# Only rows that need the owner reach "Action required"; a handled row needs
# an outcome file for THAT run (scratch dir via SCANNER_TRIAGE_DIR), and a
# missing outcome is indeterminate, never ok.
.triage_fixture_args <- function(new_name) {
  known <- data.frame(detector = "1", file_path = "a.R", line_num = "3", name = "cred-shape")
  new1  <- data.frame(detector = "2", file_path = "b.R", line_num = "9", name = new_name)
  list(
    hk_row = list(task = "secret_exposure_scan", status = "ok", rows_written = 2L),
    ev_row = list(plist_label = "com.claude.secret-exposure-scan", state = "loaded_recent_fail",
                   last_exit_code = 1L, last_fired_at_now = TRUE),
    prev_hk_row = list(task = "secret_exposure_scan", status = "ok", rows_written = 1L),
    findings = list(latest = rbind(known, new1), prev = known)
  )
}
# Scratch outcome dir (removed when the CALLING test ends); outcome = JSON text or NULL.
.triage_outcome_dir <- function(outcome = NULL, envir = parent.frame()) {
  dir <- tempfile("triage_outcome_")
  dir.create(dir)
  withr::defer(unlink(dir, recursive = TRUE), envir = envir)
  if (!is.null(outcome)) writeLines(outcome, file.path(dir, "2000-01-01.json"))
  dir
}
.triage_outcome_json <- function(filed = 1L, status = "done") {
  sprintf('{"date":"2000-01-01","run_id":"fixture-hk","scanner":"secret_exposure_scan","mode":"apply","status":"%s","why":"",
"fixed":0,"filed":%d,"tracked":0,"already_ok":0,"needs_you":0,
"types":{"fixed":{},"filed":{"cred-shape":%d},"tracked":{},"already_ok":{},"needs_you":{}},"reverts":[]}',
          status, filed, filed)
}

test_that("cron-health: a NEW auto-file scanner row with a triage outcome is handled, not an action item (llm#1458)", {
  skip_if_not_installed("blastula")
  skip_if_not_installed("duckdb")
  skip_if_not_installed("jsonlite")
  skip_if_not(file.exists(.SECRET_SCAN_PLIST), "secret-exposure-scan plist not installed")
  db <- do.call(.build_cron_fixture_db, .triage_fixture_args("cred-shape"))
  odir <- .triage_outcome_dir(.triage_outcome_json(1L))
  skip_if(is.null(db), "could not build cron-health fixture DB")
  combined <- paste(run_dry_run(db_path = db, extra_env = paste0("SCANNER_TRIAGE_DIR=", odir)), collapse = "\n")

  expect_true(grepl("handled by scanner triage", combined, fixed = TRUE))
  expect_true(grepl("Scanner triage", combined, fixed = TRUE))
  expect_true(grepl("fixed 0, filed 1, tracked 0, needs you 0", combined, fixed = TRUE))
  expect_true(grepl("plists · 1 ok · 0 failed · 0 indeterminate · 0 need triage", combined, fixed = TRUE))
  expect_false(grepl("need triage (fixed", combined, fixed = TRUE),
               info = "a handled row still reached the triage bucket")
})

test_that("cron-health: a NEW auto-file scanner row with NO triage outcome is indeterminate (llm#1458)", {
  skip_if_not_installed("blastula")
  skip_if_not_installed("duckdb")
  skip_if_not_installed("jsonlite")
  skip_if_not(file.exists(.SECRET_SCAN_PLIST), "secret-exposure-scan plist not installed")
  db <- do.call(.build_cron_fixture_db, .triage_fixture_args("cred-shape"))
  odir <- .triage_outcome_dir(NULL)
  skip_if(is.null(db), "could not build cron-health fixture DB")
  combined <- paste(run_dry_run(db_path = db, extra_env = paste0("SCANNER_TRIAGE_DIR=", odir)), collapse = "\n")

  expect_true(grepl("plists · 0 ok · 0 failed · 1 indeterminate · 0 need triage", combined, fixed = TRUE),
              info = "missing outcome was counted ok or action instead of indeterminate")
  expect_true(grepl("scanner triage has no outcome for this run", combined, fixed = TRUE))
})

test_that("cron-health: a NEW human/unlisted scanner row still needs the owner even when triage ran (llm#1458)", {
  skip_if_not_installed("blastula")
  skip_if_not_installed("duckdb")
  skip_if_not_installed("jsonlite")
  skip_if_not(file.exists(.SECRET_SCAN_PLIST), "secret-exposure-scan plist not installed")
  db <- do.call(.build_cron_fixture_db, .triage_fixture_args("brand-new-type"))
  odir <- .triage_outcome_dir(.triage_outcome_json(0L))
  skip_if(is.null(db), "could not build cron-health fixture DB")
  combined <- paste(run_dry_run(db_path = db, extra_env = paste0("SCANNER_TRIAGE_DIR=", odir)), collapse = "\n")

  expect_true(grepl("1 new finding(s) need triage", combined, fixed = TRUE))
  expect_true(grepl("needs you 1", combined, fixed = TRUE))
  expect_true(grepl("Action required", combined, fixed = TRUE))
})

test_that("cron-health: STANDING scanner findings stay ok but say 0 new", {
  skip_if_not_installed("blastula")
  skip_if_not_installed("duckdb")
  skip_if_not(file.exists(.SECRET_SCAN_PLIST), "secret-exposure-scan plist not installed")

  known <- data.frame(detector = "1", file_path = "a.R", line_num = "3", name = "cred-shape")
  db <- .build_cron_fixture_db(
    hk_row = list(task = "secret_exposure_scan", status = "ok", rows_written = 1L),
    ev_row = list(plist_label = "com.claude.secret-exposure-scan", state = "loaded_recent_fail",
                   last_exit_code = 1L, last_fired_at_now = TRUE),
    prev_hk_row = list(task = "secret_exposure_scan", status = "ok", rows_written = 1L),
    findings = list(latest = known, prev = known)
  )
  skip_if(is.null(db), "could not build cron-health fixture DB")
  combined <- paste(run_dry_run(db_path = db), collapse = "\n")

  expect_true(grepl("1 finding row(s), 0 new, standing", combined, fixed = TRUE))
  expect_true(grepl("plists · 1 ok · 0 failed · 0 indeterminate · 0 need triage", combined, fixed = TRUE))
})

test_that("cron-health: scanner findings with no baseline run are indeterminate, not ok", {
  skip_if_not_installed("blastula")
  skip_if_not_installed("duckdb")
  skip_if_not(file.exists(.SECRET_SCAN_PLIST), "secret-exposure-scan plist not installed")

  known <- data.frame(detector = "1", file_path = "a.R", line_num = "3", name = "cred-shape")
  db <- .build_cron_fixture_db(
    hk_row = list(task = "secret_exposure_scan", status = "ok", rows_written = 1L),
    ev_row = list(plist_label = "com.claude.secret-exposure-scan", state = "loaded_recent_fail",
                   last_exit_code = 1L, last_fired_at_now = TRUE),
    findings = list(latest = known)
  )
  skip_if(is.null(db), "could not build cron-health fixture DB")
  combined <- paste(run_dry_run(db_path = db), collapse = "\n")

  expect_true(grepl("cannot tell new from known", combined, fixed = TRUE))
  expect_true(grepl("1 indeterminate", combined, fixed = TRUE))
})

test_that("cron-health: count-based scanner (no findings table) flags a rising count as new", {
  skip_if_not_installed("blastula")
  skip_if_not_installed("duckdb")
  skip_if_not(file.exists(.WORKTREE_GC_PLIST), "worktree-gc plist not installed")

  db <- .build_cron_fixture_db(
    hk_row = list(task = "worktree_gc", status = "ok", rows_written = 12L),
    ev_row = list(plist_label = "com.claude.worktree-gc", state = "loaded_recent_fail",
                   last_exit_code = 1L, last_fired_at_now = TRUE),
    prev_hk_row = list(task = "worktree_gc", status = "ok", rows_written = 10L)
  )
  skip_if(is.null(db), "could not build cron-health fixture DB")
  combined <- paste(run_dry_run(db_path = db), collapse = "\n")

  expect_true(grepl("2 new finding(s) need triage", combined, fixed = TRUE))
})

.HISTORY_AUDIT_PLIST <- file.path(
  path.expand("~"), "Library", "LaunchAgents", "com.claude.private-data-history-audit.plist"
)

test_that("cron-health: history audit reads NEW from the per-finding ledger, not from a count diff", {
  skip_if_not_installed("blastula")
  skip_if_not_installed("duckdb")
  skip_if_not(file.exists(.HISTORY_AUDIT_PLIST), "private-data-history-audit plist not installed")

  # 700 standing + 2 first seen in the latest run; heartbeat rows_written is
  # the NEW count (2). The previous heartbeat carries a different total (764)
  # that the old count-based path would have diffed -- it must be irrelevant.
  db <- .build_cron_fixture_db(
    hk_row = list(task = "private_data_history_audit", status = "ok", rows_written = 2L),
    ev_row = list(plist_label = "com.claude.private-data-history-audit", state = "loaded_recent_fail",
                   last_exit_code = 1L, last_fired_at_now = TRUE),
    prev_hk_row = list(task = "private_data_history_audit", status = "ok", rows_written = 764L),
    hist = list(n_run = 2L, n_old = 30L)
  )
  skip_if(is.null(db), "could not build cron-health fixture DB")
  combined <- paste(run_dry_run(db_path = db), collapse = "\n")

  expect_true(grepl("2 new finding(s) need triage", combined, fixed = TRUE))
  expect_true(grepl("32 tracked finding(s)", combined, fixed = TRUE))
  expect_false(grepl("count-based", combined, fixed = TRUE),
               info = "history audit still fell through to the count-diff path")
  expect_false(grepl("no per-finding table", combined, fixed = TRUE))
})

test_that("cron-health: history audit with a heartbeat the ledger contradicts is indeterminate", {
  skip_if_not_installed("blastula")
  skip_if_not_installed("duckdb")
  skip_if_not(file.exists(.HISTORY_AUDIT_PLIST), "private-data-history-audit plist not installed")

  # Pre-fingerprint run: rows_written was the TOTAL (768); the ledger shows
  # nothing first seen in that run. Never guessed as "768 new".
  db <- .build_cron_fixture_db(
    hk_row = list(task = "private_data_history_audit", status = "ok", rows_written = 768L),
    ev_row = list(plist_label = "com.claude.private-data-history-audit", state = "loaded_recent_fail",
                   last_exit_code = 1L, last_fired_at_now = TRUE),
    hist = list(n_run = 0L, n_old = 5L)
  )
  skip_if(is.null(db), "could not build cron-health fixture DB")
  combined <- paste(run_dry_run(db_path = db), collapse = "\n")

  expect_true(grepl("cannot tell new from known", combined, fixed = TRUE))
  expect_false(grepl("768 new finding", combined, fixed = TRUE))
})

test_that("cron-health: history audit exit 3 with heartbeat 'partial' renders indeterminate, never findings", {
  skip_if_not_installed("blastula")
  skip_if_not_installed("duckdb")
  skip_if_not(file.exists(.HISTORY_AUDIT_PLIST), "private-data-history-audit plist not installed")

  db <- .build_cron_fixture_db(
    hk_row = list(task = "private_data_history_audit", status = "partial", rows_written = 0L),
    ev_row = list(plist_label = "com.claude.private-data-history-audit", state = "loaded_recent_fail",
                   last_exit_code = 3L, last_fired_at_now = TRUE),
    hist = list(n_run = 0L, n_old = 5L)
  )
  skip_if(is.null(db), "could not build cron-health fixture DB")
  combined <- paste(run_dry_run(db_path = db), collapse = "\n")

  expect_true(grepl("1 indeterminate", combined, fixed = TRUE))
  expect_false(grepl("need triage (of", combined, fixed = TRUE),
               info = "an INDETERMINATE audit was rendered as findings needing triage")
})

test_that("cron-health: a stale 'running' heartbeat is failed (killed or crashed), a fresh one is not (llm#1435)", {
  skip_if_not_installed("blastula")
  skip_if_not_installed("duckdb")
  skip_if_not(file.exists(.HISTORY_AUDIT_PLIST), "private-data-history-audit plist not installed")

  # (built inline, not via a helper closure: the fixture DB is deleted when
  # the frame that called .build_cron_fixture_db() exits)
  ev <- list(plist_label = "com.claude.private-data-history-audit", state = "loaded_recent_fail",
             last_exit_code = 124L, last_fired_at_now = TRUE)
  db <- .build_cron_fixture_db(
    hk_row = list(task = "private_data_history_audit", status = "running",
                  rows_written = 0L, age_h = 20),
    ev_row = ev)
  skip_if(is.null(db), "could not build cron-health fixture DB")
  # The shipped job_failure_policy.tsv explains exit 124 for this job (known),
  # so the failed-vs-fresh behaviour is checked against a scratch policy that
  # does not mention it; the shipped table is checked just below.
  pol <- tempfile(fileext = ".tsv")
  writeLines(c("job\tcause_regex\tclass\tissue\tnote",
               "com.claude.some-other-job\texit:124\tknown\t1\tunrelated"), pol)
  withr::defer(unlink(pol))
  combined <- paste(run_dry_run(db_path = db, extra_env = paste0("JOB_FAILURE_POLICY_FILE=", pol)),
                    collapse = "\n")
  expect_true(grepl("killed or crashed", combined, fixed = TRUE),
              info = "a 20h-old 'running' row was not reported as killed or crashed")
  expect_false(grepl("1 indeterminate", combined, fixed = TRUE))

  # With the shipped table the same failure is the KNOWN exit-124 timeout:
  # one line with the issue link, not counted as failed.
  combined_known <- paste(run_dry_run(db_path = db), collapse = "\n")
  expect_true(grepl("killed at the 1200 s limit", combined_known, fixed = TRUE))
  expect_true(grepl("issues/1435", combined_known, fixed = TRUE))
  expect_true(grepl("0 failed", combined_known, fixed = TRUE))
  expect_true(grepl("1 known", combined_known, fixed = TRUE))

  db2 <- .build_cron_fixture_db(
    hk_row = list(task = "private_data_history_audit", status = "running",
                  rows_written = 0L, age_h = 0.1),
    ev_row = ev)
  combined2 <- paste(run_dry_run(db_path = db2, extra_env = paste0("JOB_FAILURE_POLICY_FILE=", pol)),
                     collapse = "\n")
  expect_false(grepl("killed or crashed", combined2, fixed = TRUE),
               info = "a fresh 'running' row (possibly a live run) was reported as killed")
})

# Retry before reporting: the email runs job_failure_retry.sh first. A fake
# script (JOB_FAILURE_RETRY_SCRIPT) stands in so nothing is kicked; EMAIL_DRY_RUN=1
# means the real call would be report-only anyway.
.fake_retry_script <- function(lines, status = 0L) {
  f <- withr::local_tempfile(fileext = ".sh", .local_envir = parent.frame())
  writeLines(c("#!/bin/bash", vapply(lines, function(l) sprintf("printf '%%s\\n' '%s'", l), ""),
               sprintf("exit %d", status)), f)
  f
}

test_that("cron-health: a job that recovered after the retry is not reported; one still failing says 'retried once'; an INDETERMINATE retry is stated (llm failure self-heal)", {
  skip_if_not_installed("blastula")
  skip_if_not_installed("duckdb")
  skip_if_not(file.exists(.HISTORY_AUDIT_PLIST), "private-data-history-audit plist not installed")
  ev <- list(plist_label = "com.claude.private-data-history-audit", state = "loaded_recent_fail",
             last_exit_code = 124L, last_fired_at_now = TRUE)
  db <- .build_cron_fixture_db(
    hk_row = list(task = "private_data_history_audit", status = "running",
                  rows_written = 0L, age_h = 20),
    ev_row = ev)
  skip_if(is.null(db), "could not build cron-health fixture DB")
  lbl <- "com.claude.private-data-history-audit"

  base <- paste(run_dry_run(db_path = db, extra_env = paste0("JOB_FAILURE_RETRY_SCRIPT=",
                .fake_retry_script(character(0)))), collapse = "\n")
  expect_true(grepl("1 known", base, fixed = TRUE), info = "baseline: the shipped table shows it as known")
  expect_false(grepl("Automatic retry of failed jobs", base, fixed = TRUE),
               info = "a retry that ran cleanly must not add a warning line")

  rec <- paste(run_dry_run(db_path = db, extra_env = paste0("JOB_FAILURE_RETRY_SCRIPT=",
               .fake_retry_script(sprintf("RETRY\t%s\trecovered", lbl)))), collapse = "\n")
  expect_true(grepl("recovered after one automatic retry", rec, fixed = TRUE))
  expect_false(grepl("1 known", rec, fixed = TRUE), info = "a recovered job was still reported as failed/known")
  expect_true(grepl("0 failed", rec, fixed = TRUE))

  still <- paste(run_dry_run(db_path = db, extra_env = paste0("JOB_FAILURE_RETRY_SCRIPT=",
                 .fake_retry_script(sprintf("RETRY\t%s\tstill-failing", lbl), status = 1L))), collapse = "\n")
  expect_true(grepl("retried once, still failing", still, fixed = TRUE))
  expect_true(grepl("1 failed", still, fixed = TRUE), info = "a job still failing after its retry must count as failed")

  ind <- paste(run_dry_run(db_path = db, extra_env = paste0("JOB_FAILURE_RETRY_SCRIPT=",
               .fake_retry_script("INDETERMINATE: policy table not usable (empty)", status = 3L))), collapse = "\n")
  expect_true(grepl("Automatic retry of failed jobs: INDETERMINATE (policy table not usable (empty))", ind, fixed = TRUE),
              info = "an INDETERMINATE retry must be said on one line, never silently omitted")

  gone <- paste(run_dry_run(db_path = db, extra_env = "JOB_FAILURE_RETRY_SCRIPT=/nonexistent/retry.sh"), collapse = "\n")
  expect_true(grepl("Automatic retry of failed jobs: INDETERMINATE (retry script not found)", gone, fixed = TRUE),
              info = "a retry script that cannot be run must be said, never silently omitted")
})

# Retry of failed scheduled GitHub runs: the email runs gh_run_retry.sh first and shows
# each re-run on one line with its state read at send time (pending is NOT failed).
.jf_lib <- file.path(dirname(.email_script), "lib", "job_failure_lib.R")

test_that("gh_run_retry lib: parse, state mapping, script exit codes, INDETERMINATE note", {
  skip_if_not(file.exists(.jf_lib), "job_failure_lib.R not found")
  e <- new.env()
  sys.source(.jf_lib, envir = e)
  p <- e$gh_run_retry_parse(c("owner/pub-a Nightly build run 11 retried (a)",
                              "owner/pub-b Docs run 12 retried (b)",
                              "owner/pub-a Nightly run 13 would retry (a)",
                              "owner/pub-a Nightly run 14 retry failed (a)",
                              "INDETERMINATE: x", "garbage", NA))
  expect_equal(p$run, c("11", "12"))
  expect_equal(p$workflow, c("Nightly build", "Docs"))
  expect_equal(p$class, c("a", "b"))
  expect_equal(nrow(e$gh_run_retry_parse(character(0))), 0L)
  st <- function(out) e$gh_run_retry_state("o/r", "1", runner = function(a) out)
  expect_equal(st("in_progress\t"), "pending")
  expect_equal(st("queued\t"), "pending")
  expect_equal(st("completed\tsuccess"), "succeeded")
  expect_equal(st("completed\tfailure"), "failed")
  expect_equal(st("completed\tcancelled"), "failed")
  expect_equal(st(character(0)), "unknown")
  expect_equal(st(structure("x", status = 1L)), "unknown")
  expect_equal(st("completed\t"), "unknown")
  scr <- withr::local_tempfile(fileext = ".sh"); writeLines("#!/bin/bash", scr)
  rn <- function(out, rc) function(a) structure(out, status = rc)
  ok <- e$gh_run_retry_run(scr, apply = TRUE, runner = rn("owner/pub-a W run 5 retried (a)", 1L))
  expect_equal(ok$status, "ok"); expect_equal(ok$runs$run, "5")
  expect_equal(e$gh_run_retry_note(ok), "")
  ind <- e$gh_run_retry_run(scr, apply = TRUE, runner = rn("INDETERMINATE: gh not authenticated", 3L))
  expect_equal(ind$status, "indeterminate")
  expect_match(e$gh_run_retry_note(ind), "INDETERMINATE (gh not authenticated)", fixed = TRUE)
  expect_equal(e$gh_run_retry_run(scr, runner = rn(character(0), 2L))$status, "indeterminate")
  expect_match(e$gh_run_retry_run("/nonexistent.sh")$note, "not found")
  expect_equal(e$gh_run_retry_run(scr, runner = function(a) stop("boom"))$status, "indeterminate")
  expect_match(e$gh_run_retry_note(NULL), "INDETERMINATE", fixed = TRUE)
  # apply = FALSE must pass no --apply
  seen <- NULL
  e$gh_run_retry_run(scr, apply = FALSE, runner = function(a) { seen <<- a; character(0) })
  expect_false("--apply" %in% seen)
  e$gh_run_retry_run(scr, apply = TRUE, runner = function(a) { seen <<- a; character(0) })
  expect_true("--apply" %in% seen)
})

test_that("email: re-run GitHub runs are one line each with their state; pending is not failed; INDETERMINATE is stated (llm failure self-heal)", {
  skip_if_not_installed("blastula")
  skip_if_not_installed("duckdb")
  db <- .build_cron_fixture_db(
    hk_row = list(task = "private_data_history_audit", status = "ok", rows_written = 1L, age_h = 2),
    ev_row = list(plist_label = "com.claude.private-data-history-audit", state = "loaded_ok",
                  last_exit_code = 0L, last_fired_at_now = TRUE))
  skip_if(is.null(db), "could not build cron-health fixture DB")
  state_gh <- withr::local_tempfile(fileext = ".sh")
  writeLines(c("#!/bin/bash",
               'case "$3" in',
               "11) printf 'in_progress\\t\\n' ;;",
               "12) printf 'completed\\tsuccess\\n' ;;",
               "13) printf 'completed\\tfailure\\n' ;;",
               "esac"), state_gh)
  Sys.chmod(state_gh, "755")   # it is run directly, as gh is
  env <- function(...) c(paste0("GH_RUN_RETRY_GH=", state_gh), ...)
  runs <- c("owner/pub-a Nightly run 11 retried (a)", "owner/pub-b Docs run 12 retried (b)")
  out <- paste(run_dry_run(db_path = db, extra_env = env(paste0("GH_RUN_RETRY_SCRIPT=",
               .fake_retry_script(runs)))), collapse = "\n")
  expect_true(grepl("owner/pub-a Nightly run 11 (transient log pattern) - re-run still pending", out, fixed = TRUE))
  expect_true(grepl("owner/pub-b Docs run 12 (runner never started) - re-run succeeded", out, fixed = TRUE))
  expect_false(grepl("re-run FAILED", out, fixed = TRUE), info = "pending / succeeded runs must not be called failed")
  expect_false(grepl("Automatic retry of failed GitHub runs", out, fixed = TRUE))
  bad <- paste(run_dry_run(db_path = db, extra_env = env(paste0("GH_RUN_RETRY_SCRIPT=",
               .fake_retry_script("owner/pub-a Nightly run 13 retried (a)", status = 1L)))), collapse = "\n")
  expect_true(grepl("owner/pub-a Nightly run 13 (transient log pattern) - re-run FAILED", bad, fixed = TRUE))
  ind <- paste(run_dry_run(db_path = db, extra_env = env(paste0("GH_RUN_RETRY_SCRIPT=",
               .fake_retry_script("INDETERMINATE: gh not authenticated", status = 3L)))), collapse = "\n")
  expect_true(grepl("Automatic retry of failed GitHub runs: INDETERMINATE (gh not authenticated)", ind, fixed = TRUE),
              info = "an INDETERMINATE retry must be said on one line, never silently omitted")
  gone <- paste(run_dry_run(db_path = db, extra_env = env("GH_RUN_RETRY_SCRIPT=/nonexistent/gh_retry.sh")), collapse = "\n")
  expect_true(grepl("Automatic retry of failed GitHub runs: INDETERMINATE (retry script not found)", gone, fixed = TRUE))
  none <- paste(run_dry_run(db_path = db), collapse = "\n")
  expect_false(grepl("Retried a failed scheduled run", none, fixed = TRUE), info = "nothing retried: no line")
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
    # llm#235 steps 1-2: conversation signals and roborev findings are now
    # inspected, so the old "config, rules, code, or anything said in a
    # conversation" disclaimer would be false. The box must still state what
    # is NOT checked (rule/config meaning, semantic transcript review).
    expect_true(grepl("Not checked: the meaning of rules or config", combined, fixed = TRUE),
                info = "All-clear box omitted the not-checked scope disclaimer")
    expect_false(grepl("anything said in a conversation", combined, fixed = TRUE),
                 info = "All-clear box still claims conversations are not inspected")
  }
})

# ── Header scope paragraph is derived from what was actually inspected ────────
# The header used to say the report "does not inspect ... anything said in a
# conversation" after llm#235 steps 1-2 made that false. It is now derived from
# the same conv_checked / roborev_checked flags as the verdict box.

test_that("header scope states what was inspected and never the stale 'does not inspect' sentence", {
  skip_if_not_installed("blastula")
  skip_if_not_installed("duckdb")
  skip_if_not(file.exists(.real_db), "unified.duckdb not available in test environment")

  combined <- paste(run_dry_run(), collapse = "\n")

  expect_false(grepl("anything said in a conversation", combined, fixed = TRUE),
               info = "Header still carries the stale scope sentence")
  expect_false(grepl("session-telemetry patterns only", combined, fixed = TRUE),
               info = "Header still claims telemetry-only scope")
  expect_true(grepl("Still <b>not</b> inspected: a semantic reading of conversations",
                    combined, fixed = TRUE),
              info = "Header omitted the not-inspected disclaimer")
  expect_true(grepl("llm#235 steps 3-5", combined, fixed = TRUE))
  # llm#1241 caveat is kept.
  expect_true(grepl("not evidence that nothing needs changing", combined, fixed = TRUE))
})

test_that("header does not claim conversation/roborev inspection when those sources are unavailable", {
  skip_if_not_installed("blastula")
  skip_if_not_installed("duckdb")
  skip_if_not(file.exists(.real_db), "unified.duckdb not available in test environment")

  nowhere <- file.path(tempdir(), "does-not-exist")
  combined <- paste(
    run_dry_run(extra_env = c(paste0("CODEX_LEARNING_DIR=", nowhere),
                              paste0("ROBOREV_DB=", file.path(nowhere, "reviews.db")))),
    collapse = "\n"
  )

  expect_true(grepl("Unavailable today, so not inspected:</b> conversation signals, roborev code findings",
                    combined, fixed = TRUE),
              info = "Header did not list the unavailable content sections")
  expect_false(grepl("repeated user corrections and repeated command failures",
                     combined, fixed = TRUE),
               info = "Header claims transcripts were inspected though the digest was unavailable")
  expect_false(grepl("open roborev code findings from the last 24h", combined, fixed = TRUE),
               info = "Header claims roborev was inspected though its DB was unavailable")
})

# ── Repo-visibility diff section (llm#1371) ───────────────────────────────────
# A SMALL scratch DB built by applying the SHIPPED schema file (so the DDL under
# test is the real one). Deliberately not a copy of the 6 GB live DB: the copy
# fixtures above each leave a multi-GB file in tempdir() for the whole session
# and can exhaust the disk. Repo names are invented.
.build_repo_vis_fixture_db <- function(changes = list(), run_status = "ok") {
  if (!requireNamespace("DBI", quietly = TRUE)) return(NULL)
  if (!requireNamespace("duckdb", quietly = TRUE)) return(NULL)
  if (!nzchar(Sys.which("duckdb"))) return(NULL)
  dst <- tempfile(fileext = ".duckdb")
  withr::defer(unlink(dst), envir = parent.frame())
  schema_file <- file.path(pkgload::pkg_path(), ".claude", "scripts", "housekeeping_schema_init.sql")
  rc <- system2("duckdb", c("-init", "/dev/null", dst), input = readLines(schema_file),
                stdout = FALSE, stderr = FALSE)
  if (!identical(rc, 0L) || !file.exists(dst)) return(NULL)
  con <- DBI::dbConnect(duckdb::duckdb(), dst, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  now_utc <- format(Sys.time(), "%Y-%m-%d %H:%M:%S", tz = "UTC")
  DBI::dbExecute(con, sprintf(
    "INSERT INTO housekeeping_runs (id, task, source_script, started_at, ended_at, status, rows_written)
     VALUES ('fx-rv', 'repo_visibility_diff', 'test-fixture', TIMESTAMPTZ '%s', TIMESTAMPTZ '%s', '%s', 0)",
    now_utc, now_utc, run_status))
  for (i in seq_along(changes)) {
    ch <- changes[[i]]
    DBI::dbExecute(con, sprintf(
      "INSERT INTO repo_visibility_changes
         (id, detected_at, snapshot_id, repo, repo_created_at, change_type, prev_visibility, audit_status)
       VALUES ('fx-rv|%d', TIMESTAMPTZ '%s', 'fx-rv', %s, '2024-01-01T00:00:00Z', 'became_public', 'PRIVATE', %s)",
      i, now_utc, DBI::dbQuoteString(con, ch$repo), DBI::dbQuoteString(con, ch$audit_status)))
  }
  dst
}

test_that("repo-visibility section lists a newly public repo and its pending audit (llm#1371)", {
  skip_if_not_installed("blastula")
  skip_if_not_installed("duckdb")
  db <- .build_repo_vis_fixture_db(list(list(repo = "synthetic/zz-newly-public", audit_status = "pending")))
  skip_if(is.null(db), "scratch fixture DB unavailable")
  combined <- paste(run_dry_run(db_path = db), collapse = "\n")
  expect_true(grepl("Repo visibility diff", combined, fixed = TRUE))
  expect_true(grepl("synthetic/zz-newly-public", combined, fixed = TRUE),
              info = "the newly public repo is not named in the email")
  expect_true(grepl("1 new public (24 h)", combined, fixed = TRUE))
  expect_true(grepl("Full-history audit still pending", combined, fixed = TRUE))
})

test_that("repo-visibility section with no events says so, and does not name a repo (llm#1371 falsification)", {
  skip_if_not_installed("blastula")
  skip_if_not_installed("duckdb")
  db <- .build_repo_vis_fixture_db(list())
  skip_if(is.null(db), "scratch fixture DB unavailable")
  combined <- paste(run_dry_run(db_path = db), collapse = "\n")
  expect_true(grepl("0 new public (24 h)", combined, fixed = TRUE))
  expect_false(grepl("synthetic/zz-newly-public", combined, fixed = TRUE))
})

test_that("repo-visibility section renders a partial latest run as INDETERMINATE, not as no-change (llm#1371)", {
  skip_if_not_installed("blastula")
  skip_if_not_installed("duckdb")
  db <- .build_repo_vis_fixture_db(list(), run_status = "partial")
  skip_if(is.null(db), "scratch fixture DB unavailable")
  combined <- paste(run_dry_run(db_path = db), collapse = "\n")
  expect_true(grepl("INDETERMINATE: the latest run could not establish repo visibility",
                    combined, fixed = TRUE))
})
