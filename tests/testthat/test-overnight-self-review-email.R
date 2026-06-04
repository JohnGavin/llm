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
  # Fallback: dev-time source tree
  if (!nzchar(s) || !file.exists(s)) {
    s <- normalizePath(
      file.path(
        dirname(dirname(testthat::test_path())),
        ".claude", "scripts", "send_overnight_self_review_email.R"
      ),
      mustWork = FALSE
    )
  }
  s
})

.plist_path <- normalizePath(
  file.path(
    dirname(dirname(testthat::test_path())),
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
  system2(
    "Rscript",
    args   = .email_script,
    stdout = TRUE,
    stderr = TRUE,
    env    = c(Sys.getenv(), env_vars)
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
  expect_gt(nchar(combined), 200L,
            info = "dry-run output is too short — likely an early error")
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

  n_details <- length(gregexpr("<details", combined)[[1]])
  expect_gte(n_details, 4L,
             info = paste("Expected ≥4 <details> blocks, found:", n_details))
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
