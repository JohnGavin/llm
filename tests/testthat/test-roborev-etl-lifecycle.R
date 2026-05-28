# Tests for roborev_review_lifecycle closed_at + close_reason population.
# Tracks llm#310.
#
# Tests verify:
#   1. derive_close_reason() logic: all 5 vocabulary values + NA
#   2. build_review_lifecycle() integration: closed_at / close_reason populated
#   3. Idempotence: running twice yields identical results
#   4. No silent NULLs: all closed=1 reviews have non-NA closed_at + close_reason
#
# Strategy: source only lines 350-585 of the ETL script (the pure function
# block — SEVERITY constants + parse_max_severity + derive_close_reason +
# build_review_lifecycle).  These lines have no I/O side effects.

library(testthat)

# ── Load ETL function block ─────────────────────────────────────────────────

.etl_fn_start <- 358L   # SEVERITY_PATTERN <- line (first assignment, no leading comment)
.etl_fn_end   <- 605L   # closing } of build_review_lifecycle

etl_script <- file.path(pkgload::pkg_path(),
                         ".claude", "scripts", "roborev_metrics_etl.R")

skip_if_not(file.exists(etl_script), "ETL script not found at expected path")

all_lines <- readLines(etl_script)
fn_block  <- all_lines[.etl_fn_start:.etl_fn_end]
eval(parse(text = paste(fn_block, collapse = "\n")), envir = globalenv())

# ── DuckDB / SQLite fixture ─────────────────────────────────────────────────
#
# 7 review cases (see test descriptions for expected close_reason):
#   rv=1 job=1  closed=1 verdict=1  marker: clean verdict (id=1)      → clean-verdict
#   rv=2 job=2  closed=1 verdict=0  marker: severity<=medium (id=2)   → severity-medium
#   rv=3 job=3  closed=1 verdict=0  marker: clean verdict (id=3)      → clean-verdict-pre-fix
#   rv=4 job=4  closed=1 verdict=1  no marker                         → clean-verdict-pre-fix
#   rv=5 job=5  closed=1 verdict=0  no marker                         → manual
#   rv=6 job=6  closed=0 verdict=0  no marker                         → NA (open)
#   rv=7 job=7  closed=1 verdict=0  two markers; latest=severity<=low → severity-low

make_fixture <- function(dir) {
  skip_if_not_installed("duckdb")
  db_path <- file.path(dir, "reviews_fixture.db")

  con <- DBI::dbConnect(duckdb::duckdb(), ":memory:")
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(con, "LOAD sqlite")
  DBI::dbExecute(con, sprintf("ATTACH '%s' AS fix (TYPE sqlite)", db_path))

  DBI::dbExecute(con, "CREATE TABLE fix.repos (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
  DBI::dbExecute(con, "INSERT INTO fix.repos VALUES (1, 'llm')")

  DBI::dbExecute(con, "
    CREATE TABLE fix.review_jobs (
      id INTEGER PRIMARY KEY,
      repo_id INTEGER,
      agent TEXT DEFAULT 'claude-code',
      model TEXT,
      branch TEXT DEFAULT 'main',
      status TEXT DEFAULT 'done',
      enqueued_at TEXT,
      started_at TEXT,
      finished_at TEXT,
      source TEXT,
      token_usage TEXT
    )
  ")
  for (i in 1:7) {
    DBI::dbExecute(con, sprintf(
      "INSERT INTO fix.review_jobs (id, repo_id, enqueued_at, started_at, finished_at)
       VALUES (%d, 1, '2026-05-27 10:00:00', '2026-05-27 10:00:01', '2026-05-27 10:00:10')",
      i
    ))
  }

  DBI::dbExecute(con, "
    CREATE TABLE fix.reviews (
      id INTEGER PRIMARY KEY,
      job_id INTEGER,
      agent TEXT DEFAULT 'claude-code',
      prompt TEXT DEFAULT '',
      output TEXT DEFAULT '',
      created_at TEXT DEFAULT '2026-05-27 10:00:00',
      closed INTEGER DEFAULT 0,
      verdict_bool INTEGER,
      updated_at TEXT
    )
  ")
  cases <- data.frame(
    id           = 1:7,
    job_id       = 1:7,
    closed       = c(1L, 1L, 1L, 1L, 1L, 0L, 1L),
    verdict_bool = c(1L, 0L, 0L, 1L, 0L, 0L, 0L),
    updated_at   = c(
      "2026-05-27T18:00:00+01:00",
      "2026-05-27T18:00:00+01:00",
      "2026-05-27T18:00:00+01:00",
      "2026-05-27T18:00:00+01:00",
      "2026-05-27T18:00:00+01:00",
      NA_character_,
      "2026-05-27T18:00:00+01:00"
    ),
    stringsAsFactors = FALSE
  )
  for (i in seq_len(nrow(cases))) {
    upd <- if (is.na(cases$updated_at[i])) "NULL" else
      sprintf("'%s'", cases$updated_at[i])
    DBI::dbExecute(con, sprintf(
      "INSERT INTO fix.reviews (id, job_id, closed, verdict_bool, updated_at)
       VALUES (%d, %d, %d, %d, %s)",
      cases$id[i], cases$job_id[i], cases$closed[i], cases$verdict_bool[i], upd
    ))
  }

  DBI::dbExecute(con, "
    CREATE TABLE fix.responses (
      id INTEGER PRIMARY KEY,
      job_id INTEGER,
      responder TEXT DEFAULT 'autoclose',
      response TEXT NOT NULL,
      created_at TEXT DEFAULT '2026-05-27 18:00:00'
    )
  ")
  DBI::dbExecute(con, "INSERT INTO fix.responses VALUES
    (1, 1, 'autoclose', 'auto-closed: clean verdict [run:2026-05-27T17:00:00Z]', '2026-05-27 18:00:00'),
    (2, 2, 'autoclose', 'auto-closed: severity<=medium [config:global] [run:2026-05-27T17:00:00Z]', '2026-05-27 18:00:00'),
    (3, 3, 'autoclose', 'auto-closed: clean verdict [run:2026-05-27T16:00:00Z]', '2026-05-27 17:00:00'),
    (4, 7, 'autoclose', 'auto-closed: clean verdict [run:2026-05-27T15:00:00Z]', '2026-05-27 16:00:00'),
    (5, 7, 'autoclose', 'auto-closed: severity<=low [config:global] [run:2026-05-27T17:00:00Z]', '2026-05-27 18:00:00')")

  db_path
}

read_fixture <- function(db_path) {
  con <- DBI::dbConnect(duckdb::duckdb(), ":memory:")
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(con, "LOAD sqlite")
  DBI::dbExecute(con, sprintf("ATTACH '%s' AS src (TYPE sqlite, READ_ONLY)", db_path))

  jobs <- DBI::dbGetQuery(con, "
    SELECT rj.id AS job_id, rp.name AS repo,
           rj.agent, rj.model, rj.branch, rj.status,
           rj.enqueued_at, rj.started_at, rj.finished_at, rj.source
    FROM src.review_jobs rj JOIN src.repos rp ON rp.id = rj.repo_id
  ")
  reviews <- DBI::dbGetQuery(con, "
    SELECT rv.id AS review_id, rv.job_id, rv.closed, rv.verdict_bool,
           rv.output, rv.created_at, rv.updated_at
    FROM src.reviews rv
  ")
  markers <- DBI::dbGetQuery(con, "
    SELECT rsp.job_id, rsp.response AS marker
    FROM src.responses rsp
    WHERE rsp.response LIKE 'auto-closed:%'
    AND rsp.id IN (
      SELECT MAX(id) FROM src.responses
      WHERE response LIKE 'auto-closed:%'
      GROUP BY job_id
    )
  ")
  list(jobs = jobs, reviews = reviews, markers = markers)
}

# ── derive_close_reason unit tests ─────────────────────────────────────────

test_that("derive_close_reason: clean-verdict marker + verdict_bool=1 → clean-verdict", {
  expect_equal(
    derive_close_reason("auto-closed: clean verdict [run:2026-05-27T17:00:00Z]", 1L, TRUE),
    "clean-verdict"
  )
})

test_that("derive_close_reason: severity<=medium marker → severity-medium", {
  expect_equal(
    derive_close_reason("auto-closed: severity<=medium [config:global] [run:2026-05-27T17:00:00Z]", 0L, TRUE),
    "severity-medium"
  )
})

test_that("derive_close_reason: severity<=low marker → severity-low", {
  expect_equal(
    derive_close_reason("auto-closed: severity<=low [config:flag] [run:2026-05-21T19:29:11Z]", 0L, TRUE),
    "severity-low"
  )
})

test_that("derive_close_reason: clean-verdict marker + verdict_bool=0 → clean-verdict-pre-fix", {
  expect_equal(
    derive_close_reason("auto-closed: clean verdict [run:2026-05-27T16:00:00Z]", 0L, TRUE),
    "clean-verdict-pre-fix"
  )
})

test_that("derive_close_reason: no marker + verdict_bool=1 → clean-verdict-pre-fix", {
  expect_equal(derive_close_reason(NA_character_, 1L, TRUE), "clean-verdict-pre-fix")
})

test_that("derive_close_reason: no marker + verdict_bool=0 → manual", {
  expect_equal(derive_close_reason(NA_character_, 0L, TRUE), "manual")
})

test_that("derive_close_reason: open review (is_closed=FALSE) → NA", {
  expect_equal(
    derive_close_reason("auto-closed: clean verdict [run:2026-05-27T17:00:00Z]", 1L, FALSE),
    NA_character_
  )
  expect_equal(derive_close_reason(NA_character_, NA_integer_, FALSE), NA_character_)
})

# ── build_review_lifecycle integration tests ──────────────────────────────

test_that("build_review_lifecycle: all closed=1 have non-null closed_at + close_reason", {
  skip_if_not_installed("duckdb")

  tmp    <- withr::local_tempdir()
  db     <- make_fixture(tmp)
  tables <- read_fixture(db)
  res    <- build_review_lifecycle(tables$jobs, tables$reviews, tables$markers)

  closed_ids <- tables$reviews$review_id[tables$reviews$closed == 1L]
  closed_res <- res[res$review_id %in% closed_ids, ]

  expect_true(all(!is.na(closed_res$closed_at)),
              info = "All closed reviews must have non-null closed_at")
  expect_true(all(!is.na(closed_res$close_reason)),
              info = "All closed reviews must have non-null close_reason")
})

test_that("build_review_lifecycle: correct close_reason per fixture case", {
  skip_if_not_installed("duckdb")

  tmp    <- withr::local_tempdir()
  db     <- make_fixture(tmp)
  tables <- read_fixture(db)
  res    <- build_review_lifecycle(tables$jobs, tables$reviews, tables$markers)

  get_reason <- function(id) res$close_reason[res$review_id == id]

  expect_equal(get_reason(1L), "clean-verdict",
               info = "rv1: clean-verdict marker + verdict=1")
  expect_equal(get_reason(2L), "severity-medium",
               info = "rv2: severity<=medium marker")
  expect_equal(get_reason(3L), "clean-verdict-pre-fix",
               info = "rv3: clean-verdict marker + verdict=0 (pre-#311)")
  expect_equal(get_reason(4L), "clean-verdict-pre-fix",
               info = "rv4: no marker + verdict=1")
  expect_equal(get_reason(5L), "manual",
               info = "rv5: no marker + verdict=0")
  expect_true(is.na(get_reason(6L)),
              info = "rv6: open → NA")
  expect_equal(get_reason(7L), "severity-low",
               info = "rv7: latest marker is severity<=low (response id=5 > id=4)")
})

test_that("build_review_lifecycle: closed_at parsed correctly from TZ-offset timestamp", {
  skip_if_not_installed("duckdb")

  tmp    <- withr::local_tempdir()
  db     <- make_fixture(tmp)
  tables <- read_fixture(db)
  res    <- build_review_lifecycle(tables$jobs, tables$reviews, tables$markers)

  r1 <- res[res$review_id == 1L, ]
  expect_false(is.na(r1$closed_at), info = "rv1 closed_at must not be NA")
  # "2026-05-27T18:00:00+01:00" == 17:00:00 UTC
  expect_equal(format(r1$closed_at, "%H:%M:%S", tz = "UTC"), "17:00:00",
               info = "closed_at must be 17:00:00 UTC (18:00 +01:00)")

  r6 <- res[res$review_id == 6L, ]
  expect_true(is.na(r6$closed_at), info = "rv6 (open) closed_at must be NA")
})

test_that("build_review_lifecycle: idempotent — two runs produce identical results", {
  skip_if_not_installed("duckdb")

  tmp    <- withr::local_tempdir()
  db     <- make_fixture(tmp)
  tables <- read_fixture(db)

  res1 <- build_review_lifecycle(tables$jobs, tables$reviews, tables$markers)
  res2 <- build_review_lifecycle(tables$jobs, tables$reviews, tables$markers)

  expect_equal(nrow(res1), nrow(res2))
  expect_equal(res1$close_reason, res2$close_reason)
  expect_equal(as.numeric(res1$closed_at), as.numeric(res2$closed_at))
})
