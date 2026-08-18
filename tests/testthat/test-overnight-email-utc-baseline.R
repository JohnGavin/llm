# test-overnight-email-utc-baseline.R
#
# Regression test for llm#959: send_overnight_self_review_email.R's "last 24h"
# / "last 7d" windows were computed as
#   WHERE <col> >= current_timestamp::TIMESTAMP - INTERVAL '24' HOUR
# which yields a LOCAL wall-clock baseline (DuckDB's TimeZone is
# auto-detected from the OS). Several producer columns
# (sessions.started_at, agent_runs.started_at, hook_events.fired_at,
# roborev's review_jobs.enqueued_at) are NAIVE TIMESTAMP columns holding a
# UTC clock VALUE (written via `date -u` in the producing shell script).
# Comparing a UTC-valued naive column against a LOCAL naive baseline makes
# every window short by the local UTC offset -- 0 under GMT (seasonally
# invisible in winter), 1h under IST/BST. The fix is `sql_utc_now()` in
# send_overnight_self_review_email.R: `(now() AT TIME ZONE 'UTC')`.
#
# This test PINS the session TimeZone to a fixed, non-DST offset
# (Asia/Kolkata, UTC+5:30 year-round) so the assertion is deterministic
# regardless of the season or the machine's local timezone -- a test that
# only pins nothing would pass every winter regardless of whether the bug
# is present, and is worthless as a regression guard (see llm#959).
#
# Does NOT invoke the full 2000-line email script (which requires a live
# unified.duckdb, SMTP config, etc.) -- it tests the SQL PATTERN the fix
# relies on directly, against a scratch in-memory DuckDB seeded to
# reproduce the exact producer/reader mismatch.

library(testthat)

test_named_tz <- "Asia/Kolkata"  # UTC+5:30, no DST -- fixed offset year-round

test_that("24h window is correct under a pinned non-UTC TimeZone (llm#959)", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("DBI")
  skip_if_not_installed("withr")

  withr::local_envvar(TZ = test_named_tz)

  con <- DBI::dbConnect(duckdb::duckdb(), ":memory:")
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  tz_ok <- tryCatch({
    DBI::dbExecute(con, "INSTALL icu")
    DBI::dbExecute(con, "LOAD icu")
    TRUE
  }, error = function(e) FALSE)
  skip_if_not(tz_ok, "duckdb icu extension unavailable in this environment")

  observed_tz <- DBI::dbGetQuery(con, "SELECT current_setting('TimeZone') AS tz")$tz
  skip_if_not(
    identical(observed_tz, test_named_tz),
    sprintf("duckdb did not pick up the pinned TZ (got '%s', expected '%s') -- environment quirk, not the bug under test",
            observed_tz, test_named_tz)
  )

  # Simulate a producer column: a NAIVE TIMESTAMP holding a UTC clock value,
  # exactly matching sessions.started_at / agent_runs.started_at /
  # hook_events.fired_at / roborev's enqueued_at in production (see the
  # sql_utc_now() doc comment in send_overnight_self_review_email.R for the
  # per-column verification of each).
  DBI::dbExecute(con, "CREATE TABLE probe (fired_at TIMESTAMP)")

  # A row 23h behind the TRUE UTC now: inside a correct 24h UTC window, but
  # would fall OUTSIDE a window computed from a +5:30 LOCAL "now" (whose
  # cutoff is 5.5h later than the true UTC cutoff).
  DBI::dbExecute(con, "
    INSERT INTO probe VALUES ((now() AT TIME ZONE 'UTC') - INTERVAL 23 HOUR)
  ")

  # THE FIX: sql_utc_now() in send_overnight_self_review_email.R returns
  # exactly this fragment. Kept in sync with the shipped helper's source
  # text below.
  n_utc_baseline <- DBI::dbGetQuery(con, "
    SELECT COUNT(*) AS n FROM probe
    WHERE fired_at >= (now() AT TIME ZONE 'UTC') - INTERVAL 24 HOUR
  ")$n

  # THE BUG (pre-fix call-site pattern, still used for the deliberately-NOT-
  # UTC columns like self_review_findings_stage1.detected_at -- see the
  # sql_utc_now() doc comment for why those are left alone).
  n_local_baseline <- DBI::dbGetQuery(con, "
    SELECT COUNT(*) AS n FROM probe
    WHERE fired_at >= current_timestamp::TIMESTAMP - INTERVAL 24 HOUR
  ")$n

  expect_equal(n_utc_baseline, 1L,
    info = "UTC-baseline query must include a UTC-valued row from 23h ago")
  expect_equal(n_local_baseline, 0L,
    info = paste(
      "This demonstrates the llm#959 bug under a pinned +5:30 TZ: the OLD",
      "local-baseline query wrongly excludes a row that IS inside the true",
      "24h UTC window. If this assertion starts failing (n_local_baseline",
      "becomes 1), DuckDB's naive-TIMESTAMP comparison semantics changed --",
      "re-verify every call site listed in sql_utc_now()'s doc comment in",
      "send_overnight_self_review_email.R before assuming the bug is gone."
    ))
})

test_that("sql_utc_now() helper source matches the verified fix expression", {
  email_script <- local({
    s <- system.file(
      "scripts/send_overnight_self_review_email.R",
      package  = "llm",
      mustWork = FALSE
    )
    if (!nzchar(s) || !file.exists(s)) {
      s <- normalizePath(
        file.path(pkgload::pkg_path(), ".claude", "scripts",
                  "send_overnight_self_review_email.R"),
        mustWork = FALSE
      )
    }
    s
  })
  skip_if_not(file.exists(email_script), "send_overnight_self_review_email.R not found")

  src <- readLines(email_script, warn = FALSE)
  helper_line <- grep("^sql_utc_now <- function", src, value = TRUE)

  expect_length(helper_line, 1L)
  expect_true(
    grepl("now\\(\\) AT TIME ZONE 'UTC'", helper_line),
    info = "sql_utc_now() must return the UTC-baseline fragment verified above"
  )
})
