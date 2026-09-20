# Consistency of "closed this week" in roborev_weekly_rollup.R.
# Fixture includes reviews opened long BEFORE the week but closed DURING it,
# the exact shape that made per-project "Closed" (activity) disagree with
# global "Closed" (cohort) and produced close rates like 8552%.

rollup_script <- normalizePath(
  file.path(testthat::test_path(), "..", "..", ".claude", "scripts",
            "roborev_weekly_rollup.R"),
  mustWork = FALSE
)

make_fixture_db <- function(path, today) {
  d <- function(off) format(today + off, "%Y-%m-%d")
  con <- DBI::dbConnect(duckdb::duckdb(), ":memory:")
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(con, "LOAD sqlite")
  DBI::dbExecute(con, sprintf("ATTACH '%s' AS f (TYPE sqlite)", path))
  DBI::dbExecute(con, "CREATE TABLE f.repos (id INTEGER, name TEXT, root_path TEXT)")
  DBI::dbExecute(con, "INSERT INTO f.repos VALUES (1,'llm','/tmp/llm'),(2,'tele','/tmp/tele')")
  DBI::dbExecute(con, "CREATE TABLE f.review_jobs (id INTEGER, repo_id INTEGER, status TEXT, finished_at TEXT)")
  DBI::dbExecute(con, "CREATE TABLE f.reviews (id INTEGER, job_id INTEGER, closed INTEGER, updated_at TEXT, output TEXT)")
  jobs <- list(
    c(1, 1, d(-3)),   # llm, opened this week, closed this week  (cohort closed)
    c(2, 1, d(-20)),  # llm, opened long ago, closed this week  (activity only)
    c(3, 2, d(-2)),   # tele, opened this week, still open
    c(4, 2, d(-30)),  # tele, old, closed long ago
    c(5, 2, d(-25))   # tele, old, closed this week             (activity only)
  )
  for (j in jobs) {
    DBI::dbExecute(con, sprintf("INSERT INTO f.review_jobs VALUES (%s,%s,'done','%s 10:00:00')",
                                j[1], j[2], j[3]))
  }
  revs <- list(
    c(1, 1, 1, d(-2)), c(2, 2, 1, d(-2)), c(3, 3, 0, ""),
    c(4, 4, 1, d(-30)), c(5, 5, 1, d(-4))
  )
  for (r in revs) {
    DBI::dbExecute(con, sprintf("INSERT INTO f.reviews VALUES (%s,%s,%s,'%s 11:00:00','out')",
                                r[1], r[2], r[3], r[4]))
  }
  invisible(path)
}

run_rollup <- function(db, extra = character(0)) {
  tmp <- tempfile("rollup_out_")
  dir.create(tmp)
  out <- suppressWarnings(system2(
    "env",
    args = c(paste0("ROBOREV_DB=", db),
             paste0("ROBOREV_DAILY_BACKLOG_DIR=", file.path(tmp, "none")),
             paste0("ROBOREV_WEEKLY_DIR=", tmp),
             paste0("UNIFIED_DUCKDB=", file.path(tmp, "none.duckdb")),
             "INCLUDE_NON_CANONICAL=1", "WEEKLY_DRY_RUN=1", extra,
             "Rscript", rollup_script),
    stdout = TRUE, stderr = TRUE
  ))
  list(text = paste(out, collapse = "\n"),
       status = attr(out, "status") %||% 0L)
}
`%||%` <- function(a, b) if (is.null(a)) b else a

table_cells <- function(text, label_regex) {
  line <- grep(label_regex, strsplit(text, "\n")[[1L]], value = TRUE)[1L]
  trimws(strsplit(line, "|", fixed = TRUE)[[1L]])[-1L]
}

test_that("closed-this-week is one definition; per-project sums to global", {
  skip_if_not(file.exists(rollup_script))
  skip_if_not_installed("duckdb")
  db <- tempfile(fileext = ".db")
  make_fixture_db(db, Sys.Date())
  res <- run_rollup(db)
  expect_equal(res$status, 0L, info = res$text)

  g_opened <- as.integer(table_cells(res$text, "^\\| Opened this week")[2L])
  g_closed <- as.integer(table_cells(res$text, "^\\| Closed this week")[2L])
  expect_equal(c(g_opened, g_closed), c(2L, 3L))

  llm  <- table_cells(res$text, "^\\| llm \\|")
  tele <- table_cells(res$text, "^\\| tele \\|")
  # cols after label: opened, closed(any age), cohort closed, cohort rate
  expect_equal(as.integer(llm[2:4]),  c(1L, 2L, 1L))
  expect_equal(as.integer(tele[2:4]), c(1L, 1L, 0L))
  expect_equal(as.integer(llm[2]) + as.integer(tele[2]), g_opened)
  expect_equal(as.integer(llm[3]) + as.integer(tele[3]), g_closed)

  # Cohort rates cannot exceed 100%.
  rates <- as.numeric(sub("%", "", c(llm[5], tele[5]), fixed = TRUE))
  expect_true(all(rates <= 100))
  expect_equal(rates, c(100, 0))
})

test_that("median time-to-close is a median, not a mean", {
  skip_if_not(file.exists(rollup_script))
  skip_if_not_installed("duckdb")
  db <- tempfile(fileext = ".db")
  make_fixture_db(db, Sys.Date())
  res <- run_rollup(db)
  # closed this week: ttc ~ 25h(job1: -3 10:00 -> -2 11:00), ~ 433h (job2), ~ 505h (job5)
  # median is job2's ~433 h; a mean would be ~321 h.
  cell <- table_cells(res$text, "^\\| Median time-to-close")[2L]
  hrs <- as.numeric(sub(" h$", "", cell))
  expect_gt(hrs, 400)
  expect_lt(hrs, 470)
})
