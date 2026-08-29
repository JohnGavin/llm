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
  expect_true(
    nzchar(.email_script) && file.exists(.email_script),
    info = "send_overnight_self_review_email.R not found"
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
  expect_true(
    file.exists(.plist_path),
    info = paste("Plist not found at:", .plist_path)
  )
})

test_that("launchd plist schedules at hour 6, minute 30", {
  skip_if_not(file.exists(.plist_path), "Plist not found")

  plist_text <- paste(readLines(.plist_path), collapse = "\n")
  # The Hour integer block should be 6
  expect_true(grepl("<key>Hour</key>\\s*<integer>6</integer>", plist_text),
              info = "Plist does not schedule at hour 6")
  expect_true(grepl("<key>Minute</key>\\s*<integer>30</integer>", plist_text),
              info = "Plist does not schedule at minute 30")
})
