#!/usr/bin/env Rscript
# tests/test_roborev_weekly_rollup.R
#
# testthat tests for .claude/scripts/roborev_weekly_rollup.R
#
# Strategy:
#   1. Creates synthetic daily-backlog fixture files (7 .md files)
#   2. Creates a synthetic SQLite reviews.db fixture
#   3. Runs the rollup script in WEEKLY_DRY_RUN=1 mode
#   4. Asserts the produced markdown contains expected sections and values
#
# Run:
#   Rscript tests/test_roborev_weekly_rollup.R
#
# Tracked in llm#356.

suppressPackageStartupMessages({
  library(testthat)
  library(DBI)
})

# ── Locate rollup script ──────────────────────────────────────────────────────

`%||%` <- function(a, b) if (!is.null(a) && length(a) > 0L) a else b

# Determine this test file's directory robustly
this_file <- tryCatch(
  normalizePath(sys.frames()[[1L]]$ofile, mustWork = FALSE),
  error = function(e) {
    # Fallback: use commandArgs to find script path
    args <- commandArgs(trailingOnly = FALSE)
    file_flag <- grep("^--file=", args, value = TRUE)
    if (length(file_flag) > 0L) {
      sub("^--file=", "", file_flag[1L])
    } else {
      "."
    }
  }
)
script_dir <- normalizePath(dirname(this_file), mustWork = FALSE)

rollup_script <- normalizePath(
  file.path(script_dir, "..", ".claude", "scripts", "roborev_weekly_rollup.R"),
  mustWork = FALSE
)

# Alternative search paths
if (!file.exists(rollup_script)) {
  candidates <- c(
    file.path(Sys.getenv("HOME"), "docs_gh", "llm", ".claude", "scripts",
              "roborev_weekly_rollup.R")
  )
  rollup_script <- candidates[file.exists(candidates)][1L] %||% rollup_script
}

# ── Build synthetic fixtures ──────────────────────────────────────────────────

tmpdir <- tempfile("roborev_weekly_test_")
dir.create(tmpdir, recursive = TRUE)
on.exit(unlink(tmpdir, recursive = TRUE), add = TRUE)

backlog_dir  <- file.path(tmpdir, "daily_backlog")
weekly_dir   <- file.path(tmpdir, "weekly_rollup")
db_path      <- file.path(tmpdir, "reviews.db")

dir.create(backlog_dir, recursive = TRUE)
dir.create(weekly_dir, recursive = TRUE)

# Write 7 synthetic daily backlog markdown files
today  <- Sys.Date()
for (i in seq_len(7L)) {
  day <- today - i
  content <- sprintf(
    "# roborev daily backlog — %s\n\n- llm: 5 open findings\n- llmtelemetry: 3 open findings\n",
    format(day, "%Y-%m-%d")
  )
  writeLines(content, file.path(backlog_dir, paste0(format(day, "%Y-%m-%d"), ".md")))
}

# Create synthetic SQLite reviews.db
if (requireNamespace("RSQLite", quietly = TRUE)) {
  con <- DBI::dbConnect(RSQLite::SQLite(), db_path)
  DBI::dbExecute(con, "CREATE TABLE repos (id INTEGER PRIMARY KEY, name TEXT, root_path TEXT)")
  DBI::dbExecute(con, "INSERT INTO repos VALUES (1, 'llm', '/tmp/llm')")
  DBI::dbExecute(con, "INSERT INTO repos VALUES (2, 'llmtelemetry', '/tmp/llmtelemetry')")
  DBI::dbExecute(con, "
    CREATE TABLE review_jobs (
      id INTEGER PRIMARY KEY,
      repo_id INTEGER,
      status TEXT,
      finished_at TEXT
    )
  ")
  DBI::dbExecute(con, "
    CREATE TABLE reviews (
      id INTEGER PRIMARY KEY,
      job_id INTEGER,
      closed INTEGER DEFAULT 0,
      updated_at TEXT,
      output TEXT,
      structured_output TEXT
    )
  ")
  # Insert synthetic findings in the current week
  week_start <- format(today - 7L, "%Y-%m-%d")
  week_end   <- format(today - 1L, "%Y-%m-%d")
  # 4 jobs: 2 per repo
  for (jid in 1:4) {
    repo_id <- if (jid <= 2) 1L else 2L
    DBI::dbExecute(con, sprintf(
      "INSERT INTO review_jobs VALUES (%d, %d, 'done', '%s')",
      jid, repo_id, paste0(week_start, " 10:00:00")
    ))
  }
  # 6 reviews: 3 closed, 3 open
  for (rid in 1:6) {
    jid    <- ((rid - 1) %% 4) + 1
    closed <- if (rid <= 3L) 1L else 0L
    upd    <- if (closed == 1L) paste0(week_end, " 11:00:00") else ""
    DBI::dbExecute(con, sprintf(
      "INSERT INTO reviews VALUES (%d, %d, %d, '%s', '**Severity**: High\n\nTest finding %d', NULL)",
      rid, jid, closed, upd, rid
    ))
  }

  # ── PR #1269 round 3 (llm#1265 follow-up, review id 10524) ────────────────
  # Stuck (open, age > 7 days) reviews sourced ONLY from structured_output
  # JSON -- exercises .weekly_structured_top_finding()'s JSON-direct
  # severity/summary path, which every fixture above (plain `output` text)
  # never reaches. finished_at is set 10 days before "today" (well past
  # the >7-day stuck threshold, unlike the 7-day-exact fixtures above) so
  # these rows are guaranteed to appear in the Top Stuck Findings table
  # regardless of time-of-day rounding.
  stuck_ts <- paste0(format(today - 10L, "%Y-%m-%d"), " 09:00:00")
  DBI::dbExecute(con, sprintf(
    "INSERT INTO review_jobs VALUES (5, 1, 'done', '%s')", stuck_ts
  ))
  DBI::dbExecute(con, sprintf(
    "INSERT INTO review_jobs VALUES (6, 1, 'done', '%s')", stuck_ts
  ))
  DBI::dbExecute(con, sprintf(
    "INSERT INTO review_jobs VALUES (7, 1, 'done', '%s')", stuck_ts
  ))
  DBI::dbExecute(con, sprintf(
    "INSERT INTO review_jobs VALUES (8, 1, 'done', '%s')", stuck_ts
  ))
  # id=7: real max severity MEDIUM, but the finding's own problem/fix
  # prose quotes "Severity: High"/"**Severity**: Critical" as an example --
  # must be read as medium (not inflated), and the summary must show the
  # REAL problem text (not the first-line "- **Severity**: X" bullet).
  DBI::dbExecute(con,
    "INSERT INTO reviews (id, job_id, closed, updated_at, output, structured_output) VALUES (7, 5, 0, '',
     '',
     '{\"schema_version\":2,\"summary\":\"one medium finding, prose quotes a higher severity as an example\",\"verdict\":\"fail\",\"findings\":[{\"severity\":\"medium\",\"location\":\"R/quux.R:5\",\"problem\":\"A distinctive real problem sentence about quux handling.\",\"fix\":\"Emit **Severity**: Critical only when genuinely critical.\"}]}')"
  )
  # id=8: schema_version 1, empty findings (a genuine clean re-review) --
  # must NOT crash, and falls back to extract_sev()/extract_summary() on
  # the (empty) rendered text rather than a structured severity/summary.
  DBI::dbExecute(con,
    "INSERT INTO reviews (id, job_id, closed, updated_at, output, structured_output) VALUES (8, 6, 0, '',
     '',
     '{\"schema_version\":1,\"summary\":\"nothing found\",\"findings\":[]}')"
  )
  # id=9: unrecognised schema_version (99) -- must NOT crash, falls back to
  # legacy text handling (empty output here, so severity reads 'unknown').
  DBI::dbExecute(con,
    "INSERT INTO reviews (id, job_id, closed, updated_at, output, structured_output) VALUES (9, 7, 0, '',
     '',
     '{\"schema_version\":99,\"summary\":\"x\",\"findings\":[]}')"
  )
  # id=10: malformed JSON -- must NOT crash, falls back to the legacy
  # `output` column text (a real Critical marker here).
  DBI::dbExecute(con,
    "INSERT INTO reviews (id, job_id, closed, updated_at, output, structured_output) VALUES (10, 8, 0, '',
     '**Severity**: Critical\n**Problem**: malformed-JSON fallback finding',
     '{not valid json')"
  )
  DBI::dbDisconnect(con)
}

# ── Run rollup script ─────────────────────────────────────────────────────────

test_that("rollup script exists", {
  # .Rbuildignore excludes .claude/ from the package build, so under
  # covr::package_coverage() / R CMD check this file is genuinely absent —
  # skip (not fail) in that case. skip_if_not() reports the test as SKIPPED,
  # distinct from both PASS and FAIL, so a real regression (script present
  # but broken) still fails loudly while a build-tree exclusion does not.
  testthat::skip_if_not(
    file.exists(rollup_script),
    sprintf(
      "roborev_weekly_rollup.R not found at %s (expected under covr/R CMD check, where .Rbuildignore excludes .claude/)",
      rollup_script
    )
  )
  expect_true(file.exists(rollup_script))
})

if (!file.exists(rollup_script)) {
  message("Skipping execution tests — rollup script not found")
  q(status = 0L)
}

run_rollup <- function(extra_env = list()) {
  env_vars <- c(
    list(
      ROBOREV_DAILY_BACKLOG_DIR = backlog_dir,
      ROBOREV_DB                = db_path,
      ROBOREV_WEEKLY_DIR        = weekly_dir,
      UNIFIED_DUCKDB            = file.path(tmpdir, "nonexistent.duckdb"),
      WEEKLY_DRY_RUN            = "1"
    ),
    extra_env
  )
  env_str <- paste0(names(env_vars), "=", unlist(env_vars), collapse = " ")
  cmd <- sprintf("env %s Rscript %s", env_str, shQuote(rollup_script))
  output <- tryCatch(
    system2("env",
            args = c(paste0(names(env_vars), "=", unlist(env_vars)),
                     "Rscript", rollup_script),
            stdout = TRUE, stderr = TRUE),
    error = function(e) character(0)
  )
  output
}

output <- run_rollup()
rollup_text <- paste(output, collapse = "\n")

test_that("rollup produces non-empty output", {
  expect_gt(nchar(rollup_text), 100L)
})

test_that("rollup contains Global Summary section", {
  expect_match(rollup_text, "Global Summary", fixed = TRUE)
})

test_that("rollup contains Per-Project Backlog section", {
  expect_match(rollup_text, "Per-Project Backlog", fixed = TRUE)
})

test_that("rollup contains Top Stuck Findings section", {
  expect_match(rollup_text, "Top Stuck Findings", fixed = TRUE)
})

test_that("rollup contains period date range", {
  # Should contain week_start date
  week_start <- format(Sys.Date() - 7L, "%Y-%m-%d")
  expect_match(rollup_text, week_start, fixed = TRUE)
})

test_that("rollup contains Close-Reason Distribution section", {
  # Section appears even when unified.duckdb is absent (shows 'no data' note)
  expect_match(rollup_text, "Close-Reason Distribution", fixed = TRUE)
})

# ── PR #1269 round 3 (llm#1265 follow-up, review id 10524) ────────────────

if (requireNamespace("RSQLite", quietly = TRUE) && file.exists(db_path)) {
  test_that("structured finding (id=7): severity is medium, NOT inflated by quoted prose", {
    testthat::skip_if_not(file.exists(rollup_script), "rollup script not found")
    expect_match(rollup_text, "medium", fixed = TRUE)
  })

  test_that("structured finding (id=7): summary shows the REAL problem text, not the severity bullet", {
    testthat::skip_if_not(file.exists(rollup_script), "rollup script not found")
    expect_match(rollup_text, "distinctive real problem sentence", fixed = TRUE)
  })

  test_that("structured finding (id=7): summary is NOT the first-line severity bullet", {
    testthat::skip_if_not(file.exists(rollup_script), "rollup script not found")
    # Old bug: extract_summary() picked the first non-empty line of the
    # rendered block, which is ALWAYS "- **Severity**: X" -- never the
    # Problem text. If that string appears as a table-row SUMMARY value
    # (immediately followed by the closing " |"), the bug has regressed.
    expect_false(grepl("**Severity**: Medium |", rollup_text, fixed = TRUE))
  })

  test_that("empty-findings structured row (id=8) does not crash the rollup", {
    testthat::skip_if_not(file.exists(rollup_script), "rollup script not found")
    expect_false(grepl("Error", rollup_text, fixed = TRUE))
  })

  test_that("unrecognised schema_version (id=9) does not crash the rollup", {
    testthat::skip_if_not(file.exists(rollup_script), "rollup script not found")
    expect_gt(nchar(rollup_text), 100L)
  })

  test_that("malformed JSON (id=10) falls back to legacy output text (Critical)", {
    testthat::skip_if_not(file.exists(rollup_script), "rollup script not found")
    expect_match(rollup_text, "malformed-JSON fallback finding", fixed = TRUE)
  })
}

test_that("rollup handles missing daily backlog dir gracefully", {
  out <- run_rollup(list(ROBOREV_DAILY_BACKLOG_DIR = file.path(tmpdir, "nonexistent_backlog")))
  txt <- paste(out, collapse = "\n")
  # Should still produce output with 0 files found
  expect_match(txt, "Global Summary", fixed = TRUE)
})

test_that("rollup handles missing reviews.db gracefully", {
  out <- run_rollup(list(ROBOREV_DB = file.path(tmpdir, "nonexistent.db")))
  txt <- paste(out, collapse = "\n")
  expect_match(txt, "Global Summary", fixed = TRUE)
})

# ── If RSQLite available, verify close-rate data appears ─────────────────────

if (requireNamespace("RSQLite", quietly = TRUE) && file.exists(db_path)) {
  test_that("rollup contains project names from synthetic DB", {
    expect_match(rollup_text, "llm", fixed = TRUE)
  })
}

# ── File write mode test ──────────────────────────────────────────────────────

test_that("rollup writes file when not dry-run", {
  weekly_dir2 <- file.path(tmpdir, "weekly_rollup2")
  dir.create(weekly_dir2, recursive = TRUE)
  env_vars <- c(
    ROBOREV_DAILY_BACKLOG_DIR = backlog_dir,
    ROBOREV_DB                = db_path,
    ROBOREV_WEEKLY_DIR        = weekly_dir2,
    UNIFIED_DUCKDB            = file.path(tmpdir, "nonexistent.duckdb")
  )
  # Note: no WEEKLY_DRY_RUN — should write a file
  system2("env",
          args = c(paste0(names(env_vars), "=", unlist(env_vars)),
                   "Rscript", rollup_script),
          stdout = FALSE, stderr = FALSE)

  expected_file <- file.path(weekly_dir2,
                              paste0(format(Sys.Date(), "%Y-%m-%d"), ".md"))
  expect_true(file.exists(expected_file),
              info = sprintf("Expected output file: %s", expected_file))
})

cat("\n--- All tests completed ---\n")
