# test-staleness-collect.R — Regression tests for the llm#893 staleness
# consolidation (steps 1-2: schema + view, collector, session_init banner).
#
# Follows the shell-helper test pattern already used in
# tests/testthat/test-self-review-stage1.R (bash -n syntax check via
# system2()) and extends it with:
#   - executable-bit checks on every new script + launcher (regression guard
#     for llm#886: a missing exec bit on exactly this class of path silently
#     killed all 25 launchd jobs for two days)
#   - schema content checks (NOT NULL cadence, computed-not-stored status view)
#   - staleness_collect.sh --selftest invocation
#   - staleness_banner.sh phase logic tested directly against fixture DBs
#     (collector-stale / other-stale-summary / all-fresh-silent / missing-DB),
#     per llm#893's explicit ask to test the session_init.sh phase logic
#     directly rather than by launching a session.
#
# DuckDB CLI is required for the schema/selftest/banner tests; they are
# skipped where it is unavailable (matches test-self-review-stage1.R).

library(testthat)

# ── Helpers ───────────────────────────────────────────────────────────────────

repo_root <- function() {
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

scripts_dir <- function() file.path(repo_root(), ".claude", "scripts")

duckdb_available <- function() nzchar(Sys.which("duckdb"))

collect_sh <- normalizePath(
  file.path(repo_root(), ".claude", "scripts", "staleness_collect.sh"),
  mustWork = FALSE
)
banner_sh <- normalizePath(
  file.path(repo_root(), ".claude", "scripts", "staleness_banner.sh"),
  mustWork = FALSE
)
schema_apply_sh <- normalizePath(
  file.path(repo_root(), ".claude", "scripts", "staleness_schema_apply.sh"),
  mustWork = FALSE
)
schema_sql <- normalizePath(
  file.path(repo_root(), ".claude", "scripts", "staleness_schema.sql"),
  mustWork = FALSE
)
launcher <- normalizePath(
  file.path(repo_root(), "bin", "launchd-recorders", "staleness-collect"),
  mustWork = FALSE
)

# ── Shell syntax checks ────────────────────────────────────────────────────────

test_that("staleness_collect.sh passes bash -n syntax check", {
  skip_if_not(file.exists(collect_sh), "staleness_collect.sh not found")
  exit_code <- system2("bash", args = c("-n", collect_sh), stdout = FALSE, stderr = FALSE)
  expect_equal(exit_code, 0L, info = "staleness_collect.sh has bash syntax errors")
})

test_that("staleness_banner.sh passes bash -n syntax check", {
  skip_if_not(file.exists(banner_sh), "staleness_banner.sh not found")
  exit_code <- system2("bash", args = c("-n", banner_sh), stdout = FALSE, stderr = FALSE)
  expect_equal(exit_code, 0L, info = "staleness_banner.sh has bash syntax errors")
})

test_that("staleness_schema_apply.sh passes bash -n syntax check", {
  skip_if_not(file.exists(schema_apply_sh), "staleness_schema_apply.sh not found")
  exit_code <- system2("bash", args = c("-n", schema_apply_sh), stdout = FALSE, stderr = FALSE)
  expect_equal(exit_code, 0L, info = "staleness_schema_apply.sh has bash syntax errors")
})

# ── Executable-bit regression guard (llm#886) ─────────────────────────────────
# A missing exec bit on a script invoked from a launchd ProgramArguments array
# (or its launcher) silently kills the job with no readable error — this is
# exactly what killed all 25 jobs for two days. Assert the bit directly so a
# future accidental `chmod -x` or a non-executable re-commit fails CI/tests,
# not just a manual `git ls-files -s` check.

test_that("staleness_collect.sh is executable", {
  skip_if_not(file.exists(collect_sh), "staleness_collect.sh not found")
  expect_equal(file.access(collect_sh, mode = 1)[[1]], 0L,
               info = "staleness_collect.sh is missing the executable bit (llm#886 failure mode)")
})

test_that("staleness_banner.sh is executable", {
  skip_if_not(file.exists(banner_sh), "staleness_banner.sh not found")
  expect_equal(file.access(banner_sh, mode = 1)[[1]], 0L,
               info = "staleness_banner.sh is missing the executable bit (llm#886 failure mode)")
})

test_that("staleness_schema_apply.sh is executable", {
  skip_if_not(file.exists(schema_apply_sh), "staleness_schema_apply.sh not found")
  expect_equal(file.access(schema_apply_sh, mode = 1)[[1]], 0L,
               info = "staleness_schema_apply.sh is missing the executable bit (llm#886 failure mode)")
})

test_that("bin/launchd-recorders/staleness-collect launcher is executable", {
  skip_if_not(file.exists(launcher), "launcher not found")
  expect_equal(file.access(launcher, mode = 1)[[1]], 0L,
               info = "staleness-collect launcher is missing the executable bit (llm#886 failure mode)")
})

# ── Schema content ─────────────────────────────────────────────────────────────

test_that("staleness_schema.sql exists and is non-empty", {
  skip_if_not(file.exists(schema_sql), "staleness_schema.sql not found")
  lines <- readLines(schema_sql, warn = FALSE)
  expect_gt(length(lines), 10L, label = "SQL file appears empty")
})

test_that("staleness_schema.sql makes expected_cadence_hours NOT NULL (defect 2 fix)", {
  skip_if_not(file.exists(schema_sql), "staleness_schema.sql not found")
  sql_text <- paste(readLines(schema_sql, warn = FALSE), collapse = "\n")
  expect_true(
    grepl("expected_cadence_hours\\s+DOUBLE\\s+NOT\\s+NULL", sql_text, ignore.case = TRUE),
    info = "expected_cadence_hours is not NOT NULL — llm#893 defect 2 (silent 'unknown' escape hatch) may have regressed"
  )
})

test_that("staleness_schema.sql computes status via a VIEW, not a stored column (defect 1 fix)", {
  skip_if_not(file.exists(schema_sql), "staleness_schema.sql not found")
  sql_text <- paste(readLines(schema_sql, warn = FALSE), collapse = "\n")
  expect_true(
    grepl("CREATE\\s+OR\\s+REPLACE\\s+VIEW\\s+staleness_status", sql_text, ignore.case = TRUE),
    info = "staleness_status is not a CREATE OR REPLACE VIEW — llm#893 defect 1 (stored status can go stale) may have regressed"
  )
  expect_false(
    grepl("^\\s*status\\s+(VARCHAR|TEXT)", sql_text, ignore.case = TRUE, perl = TRUE),
    info = "the `staleness` TABLE appears to have its own stored status column — status must live only in the view"
  )
})

# ── staleness_collect.sh --selftest ────────────────────────────────────────────

test_that("staleness_collect.sh --selftest passes", {
  skip_if_not(file.exists(collect_sh), "staleness_collect.sh not found")
  skip_if_not(duckdb_available(), "duckdb not available")
  out <- system2("bash", args = c(collect_sh, "--selftest"), stdout = TRUE, stderr = TRUE)
  combined <- paste(out, collapse = "\n")
  expect_true(
    grepl("0 FAIL", combined),
    info = paste0("staleness_collect.sh --selftest reported failures:\n", combined)
  )
})

# ── staleness_banner.sh phase logic — tested directly, not via a session ─────
# Builds three fixture DBs and asserts the exact priority-order behaviour
# required by llm#893 step 2: a stale collector row suppresses every other
# line; otherwise stale non-collector assets are summarised; otherwise silent.

make_fixture_db <- function(sql) {
  db <- tempfile("staleness_banner_test_", fileext = ".duckdb")
  writeLines(sql, tmp <- tempfile(fileext = ".sql"))
  on.exit(unlink(tmp), add = TRUE)
  system2("duckdb", args = c("-init", "/dev/null", db), stdin = tmp,
          stdout = FALSE, stderr = FALSE)
  db
}

run_banner <- function(db) {
  old <- Sys.getenv("STALENESS_DB", unset = NA)
  Sys.setenv(STALENESS_DB = db)
  on.exit({
    if (is.na(old)) Sys.unsetenv("STALENESS_DB") else Sys.setenv(STALENESS_DB = old)
  }, add = TRUE)
  system2("bash", args = banner_sh, stdout = TRUE, stderr = TRUE)
}

schema_and_data <- function(rows_sql) {
  base <- paste(readLines(schema_sql, warn = FALSE), collapse = "\n")
  paste(base, rows_sql, sep = "\n")
}

test_that("staleness_banner.sh prints ONLY the collector-stale line when the collector is stale", {
  skip_if_not(file.exists(schema_sql), "staleness_schema.sql not found")
  skip_if_not(file.exists(banner_sh), "staleness_banner.sh not found")
  skip_if_not(duckdb_available(), "duckdb not available")

  sql <- schema_and_data("
    INSERT INTO staleness
      (asset_kind, asset_id, project, last_seen_ts, expected_cadence_hours, last_exit_code, observed_at)
    VALUES
      ('collector', 'staleness_collect', NULL, current_timestamp - INTERVAL 72 HOUR, 24, 0, current_timestamp),
      ('launchd_job', 'com.claude.worktree-gc', NULL, current_timestamp - INTERVAL 100 HOUR, 24, 0, current_timestamp);
  ")
  db <- make_fixture_db(sql)
  on.exit(unlink(db), add = TRUE)

  out <- run_banner(db)
  expect_length(out, 1L)
  expect_true(grepl("^staleness: COLLECTOR STALE", out[1]))
  expect_false(grepl("worktree-gc", paste(out, collapse = "\n")),
               info = "banner must print ONLY the collector-stale line, nothing else")
})

test_that("staleness_banner.sh summarises other stale assets when the collector is fresh", {
  skip_if_not(file.exists(schema_sql), "staleness_schema.sql not found")
  skip_if_not(file.exists(banner_sh), "staleness_banner.sh not found")
  skip_if_not(duckdb_available(), "duckdb not available")

  sql <- schema_and_data("
    INSERT INTO staleness
      (asset_kind, asset_id, project, last_seen_ts, expected_cadence_hours, last_exit_code, observed_at)
    VALUES
      ('collector', 'staleness_collect', NULL, current_timestamp, 24, 0, current_timestamp),
      ('launchd_job', 'com.claude.worktree-gc', NULL, current_timestamp - INTERVAL 100 HOUR, 24, 0, current_timestamp),
      ('etl_source', 'sessions', NULL, current_timestamp - INTERVAL 300 HOUR, 72, NULL, current_timestamp);
  ")
  db <- make_fixture_db(sql)
  on.exit(unlink(db), add = TRUE)

  out <- run_banner(db)
  combined <- paste(out, collapse = "\n")
  expect_true(grepl("^staleness: 2 stale", combined))
  expect_true(grepl("launchd_job:com\\.claude\\.worktree-gc", combined))
  expect_true(grepl("etl_source:sessions", combined))
})

test_that("staleness_banner.sh is silent when everything is fresh", {
  skip_if_not(file.exists(schema_sql), "staleness_schema.sql not found")
  skip_if_not(file.exists(banner_sh), "staleness_banner.sh not found")
  skip_if_not(duckdb_available(), "duckdb not available")

  sql <- schema_and_data("
    INSERT INTO staleness
      (asset_kind, asset_id, project, last_seen_ts, expected_cadence_hours, last_exit_code, observed_at)
    VALUES
      ('collector', 'staleness_collect', NULL, current_timestamp, 24, 0, current_timestamp),
      ('launchd_job', 'com.claude.worktree-gc', NULL, current_timestamp, 24, 0, current_timestamp);
  ")
  db <- make_fixture_db(sql)
  on.exit(unlink(db), add = TRUE)

  out <- run_banner(db)
  expect_length(out, 0L)
})

test_that("staleness_banner.sh fails open (prints nothing, exits 0) when the DB is missing", {
  skip_if_not(file.exists(banner_sh), "staleness_banner.sh not found")

  missing_db <- tempfile("staleness_banner_missing_", fileext = ".duckdb")
  old <- Sys.getenv("STALENESS_DB", unset = NA)
  Sys.setenv(STALENESS_DB = missing_db)
  on.exit({
    if (is.na(old)) Sys.unsetenv("STALENESS_DB") else Sys.setenv(STALENESS_DB = old)
  }, add = TRUE)

  out <- suppressWarnings(
    system2("bash", args = banner_sh, stdout = TRUE, stderr = TRUE)
  )
  exit_code <- attr(out, "status")
  if (is.null(exit_code)) exit_code <- 0L
  expect_equal(exit_code, 0L, info = "banner must fail open on a missing DB")
  expect_length(out, 0L)
})

# ── _launchd_cadence_hours(): Weekday cadence (roborev#9079) ─────────────────
#
# No prior test coverage existed for this function at all. It is extracted
# directly from the shipped script (not a hand-copied duplicate) and run via
# a throwaway bash wrapper, so these tests exercise the exact code that ships.
#
# roborev#9079's primary High-severity finding (cadence ignoring Weekday) was
# previously addressed only for a single-dict StartCalendarInterval. The real
# multi-fire-per-week case — com.claude.roborev-poll-merges.plist, Mon-Fri x
# {09:02,13:00,17:00}, a LIST of 15 per-weekday dict entries — went through a
# different branch that sorted by minute-of-day alone and took the MINIMUM
# gap (4h, the intra-day gap), completely ignoring the much larger Friday
# 17:00 -> Monday 09:02 weekend gap (~64h). Since expected_cadence_hours is
# compared directly against elapsed time with no multiplier
# (staleness_schema.sql: `now() - last_seen_ts > expected_cadence_hours * 1
# hour`), a 4h cadence on this job would read 'stale' every Saturday and
# Sunday. This was still live when these tests were written and is fixed as
# part of this same change (list branch now special-cases any entry carrying
# a Weekday and computes the true maximum gap around the full weekly cycle).

extract_cadence_fn <- function() {
  skip_if_not(file.exists(collect_sh), "staleness_collect.sh not found")
  lines <- readLines(collect_sh, warn = FALSE)
  start <- grep("^_launchd_cadence_hours\\(\\) \\{", lines)[1]
  skip_if_not(!is.na(start), "_launchd_cadence_hours() not found in staleness_collect.sh")
  rel_end <- which(lines[(start + 1L):length(lines)] == "}")[1]
  skip_if_not(!is.na(rel_end), "could not find end of _launchd_cadence_hours()")
  end <- start + rel_end
  paste(lines[start:end], collapse = "\n")
}

run_cadence <- function(json) {
  skip_if_not(nzchar(Sys.which("python3")), "python3 not available")
  fn_src <- extract_cadence_fn()
  script <- paste(
    "#!/usr/bin/env bash",
    "PYTHON3=$(command -v python3)",
    fn_src,
    sprintf("_launchd_cadence_hours %s", shQuote(json)),
    sep = "\n"
  )
  tmp <- tempfile(fileext = ".sh")
  writeLines(script, tmp)
  on.exit(unlink(tmp), add = TRUE)
  # stderr = FALSE keeps stdout clean of any diagnostic noise from the
  # wrapper itself, so a coercion failure below reflects a real problem in
  # _launchd_cadence_hours()'s own output, not stderr bleeding into stdout.
  out <- system2("bash", args = tmp, stdout = TRUE, stderr = FALSE)
  raw <- out[length(out)]
  val <- as.numeric(raw)
  if (is.na(val)) {
    fail(sprintf(
      "_launchd_cadence_hours did not print a numeric cadence (got: %s)",
      raw
    ))
  }
  val
}

weekday_json <- function(weekday, hour, minute) {
  sprintf('{"Weekday":%d,"Hour":%d,"Minute":%d}', weekday, hour, minute)
}

poll_merges_json <- function() {
  entries <- unlist(lapply(1:5, function(wd) {
    c(weekday_json(wd, 9, 2), weekday_json(wd, 13, 0), weekday_json(wd, 17, 0))
  }))
  sprintf('{"StartCalendarInterval":[%s]}', paste(entries, collapse = ","))
}

test_that("_launchd_cadence_hours: Mon-Fri x 3-times-daily list returns the true weekend gap, not the 4h intra-day gap (roborev#9079)", {
  skip_if_not(file.exists(collect_sh), "staleness_collect.sh not found")
  skip_if_not(nzchar(Sys.which("python3")), "python3 not available")

  cadence <- run_cadence(poll_merges_json())

  # Fri 17:00 -> Mon 09:02 = 64h 2m = 64.0333h -- the TRUE maximum gap around
  # the weekly cycle. The pre-fix implementation returned 3.9667h (the
  # 09:02 -> 13:00 intra-day gap), which is smaller than the real weekend
  # gap and would make the collector flag this job stale every weekend.
  expect_equal(cadence, 64.0333, tolerance = 0.001)
  expect_gt(cadence, 24, label = "cadence must reflect the multi-day weekend gap, not an intra-day gap")
})

test_that("_launchd_cadence_hours: single-dict Weekday schedule is unaffected (168h weekly)", {
  skip_if_not(file.exists(collect_sh), "staleness_collect.sh not found")
  skip_if_not(nzchar(Sys.which("python3")), "python3 not available")

  cadence <- run_cadence('{"StartCalendarInterval":{"Weekday":1,"Hour":9,"Minute":0}}')
  expect_equal(cadence, 168, tolerance = 0.001)
})

test_that("_launchd_cadence_hours: a single Weekday-carrying list entry falls back to weekly (168h)", {
  skip_if_not(file.exists(collect_sh), "staleness_collect.sh not found")
  skip_if_not(nzchar(Sys.which("python3")), "python3 not available")

  cadence <- run_cadence('{"StartCalendarInterval":[{"Weekday":1,"Hour":9,"Minute":0}]}')
  expect_equal(cadence, 168, tolerance = 0.001)
})

test_that("_launchd_cadence_hours: daily multi-time list with NO Weekday key is unchanged (4h)", {
  skip_if_not(file.exists(collect_sh), "staleness_collect.sh not found")
  skip_if_not(nzchar(Sys.which("python3")), "python3 not available")

  cadence <- run_cadence('{"StartCalendarInterval":[{"Hour":9,"Minute":0},{"Hour":13,"Minute":0}]}')
  expect_equal(cadence, 4, tolerance = 0.001)
})

test_that("_launchd_cadence_hours: no declared schedule falls back to the documented daily default (24h)", {
  skip_if_not(file.exists(collect_sh), "staleness_collect.sh not found")
  skip_if_not(nzchar(Sys.which("python3")), "python3 not available")

  cadence <- run_cadence("{}")
  expect_equal(cadence, 24, tolerance = 0.001)
})
