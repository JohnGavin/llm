# test-self-review-content-signals.R
#
# Unit tests for .claude/scripts/lib/self_review_content_signals.R, the two
# "content" sections of the overnight self-review email (llm#235 steps 1-2):
#   1. conversation signals read from the codex-overnight-learning digest
#   2. open roborev findings from the last 24 h, by severity, per repo
#
# Every section has THREE distinguishable outcomes (checks-must-distinguish-
# unknown): data present, data present but nothing to report, and "could not
# read it" (with a reason). The tests pin that these never share a rendering.
#
# The tests drive the library functions directly with fixture digests and a
# fixture SQLite db; they do not need the live unified.duckdb.

library(testthat)

.scs_root <- function() getOption("llm.test_pkg_root", pkgload::pkg_path())

.scs_lib <- file.path(.scs_root(), ".claude", "scripts", "lib",
                      "self_review_content_signals.R")
.scs_styles <- file.path(.scs_root(), ".claude", "scripts", "email_styles.R")

skip_if_stripped <- function() {
  skip_if(!dir.exists(file.path(.scs_root(), ".claude")),
          ".claude/ not in build tree (.Rbuildignore, e.g. under covr)")
}

load_lib <- function(env = parent.frame()) {
  skip_if_stripped()
  expect_true(file.exists(.scs_lib), info = paste("missing", .scs_lib))
  source(.scs_styles, local = env)
  source(.scs_lib, local = env)
}

NOW <- as.POSIXct("2026-10-10 08:45:00", tz = "UTC")

write_digest <- function(dir, date = "2026-10-10",
                         generated = "2026-10-10T05:10:04.503050+00:00",
                         signals = list(), session_count = 18L,
                         raw = NULL) {
  dir.create(dir, showWarnings = FALSE, recursive = TRUE)
  path <- file.path(dir, paste0(date, "-summary.json"))
  if (!is.null(raw)) {
    writeLines(raw, path)
    return(invisible(path))
  }
  cats <- vapply(signals, function(s) s$category, character(1))
  payload <- list(
    summary_date = date, generated_at_utc = generated,
    session_count = session_count,
    counts = list(
      workflow_candidates = sum(cats == "workflow"),
      correction_candidates = sum(cats == "correction"),
      failure_candidates = sum(cats == "failure")
    ),
    top_signals = list(),
    all_signals = signals
  )
  writeLines(jsonlite::toJSON(payload, auto_unbox = TRUE), path)
  invisible(path)
}

sig <- function(category, title, reps, sessions) {
  list(category = category, title = title, target = "rule",
       repetition_count = reps, session_count = sessions,
       details = "d", sources = list("claude:a"))
}

# ── Step 1: conversation signals ─────────────────────────────────────────────

test_that("fresh digest with signals: corrections and failures show counts", {
  load_lib()
  d <- file.path(tempfile("digest"))
  write_digest(d, signals = list(
    sig("correction", "Do not edit default.nix directly", 20L, 11L),
    sig("failure", "Repeated exit 1: grep", 8L, 8L),
    sig("workflow", "nix environment verification", 12L, 12L)
  ))
  res <- scr_read_digest(d, now = NOW)
  expect_equal(res$status, "fresh")
  expect_equal(res$date, "2026-10-10")
  html <- scr_render_signals(res)$body
  expect_match(html, "Do not edit default.nix directly", fixed = TRUE)
  expect_match(html, "Repeated exit 1: grep", fixed = TRUE)
  expect_match(html, "2026-10-10", fixed = TRUE)
  # title, repetition count, session count are all present
  expect_match(html, ">20<", fixed = TRUE)
  expect_match(html, ">11<", fixed = TRUE)
  # workflows are not corrections/failures and must not be listed
  expect_no_match(html, "nix environment verification", fixed = TRUE)
})

test_that("digest with zero corrections/failures says 'no repeated signals'", {
  load_lib()
  d <- file.path(tempfile("digest"))
  write_digest(d, signals = list(sig("workflow", "repo triage workflow", 2L, 2L)))
  res <- scr_read_digest(d, now = NOW)
  expect_equal(res$status, "empty")
  out <- scr_render_signals(res)
  expect_match(paste(out$summary, out$body), "no repeated", ignore.case = TRUE)
  expect_no_match(paste(out$summary, out$body), "unavailable", ignore.case = TRUE)
})

test_that("a digest that analysed 0 sessions is not rendered as 'no repeated signals'", {
  load_lib()
  d <- file.path(tempfile("digest"))
  write_digest(d, signals = list(), session_count = 0L)
  res <- scr_read_digest(d, now = NOW)
  expect_equal(res$status, "empty_input")
  out <- scr_render_signals(res)
  expect_match(paste(out$summary, out$body), "0 sessions", fixed = TRUE)
  expect_no_match(paste(out$summary, out$body), "no repeated", ignore.case = TRUE)
})

test_that("missing digest directory/file renders an unavailable line with a reason", {
  load_lib()
  res <- scr_read_digest(file.path(tempfile("nonexistent")), now = NOW)
  expect_equal(res$status, "unavailable")
  out <- scr_render_signals(res)
  expect_match(out$body, "conversation signals unavailable:", fixed = TRUE)
  expect_match(out$body, "no digest", ignore.case = TRUE)

  empty <- tempfile("emptydir"); dir.create(empty)
  res2 <- scr_read_digest(empty, now = NOW)
  expect_equal(res2$status, "unavailable")
})

test_that("stale digest (older than ~26 h) is unavailable, not shown", {
  load_lib()
  d <- file.path(tempfile("digest"))
  write_digest(d, date = "2026-10-08",
               generated = "2026-10-08T05:10:04+00:00",
               signals = list(sig("correction", "OLD-CORRECTION", 3L, 2L)))
  res <- scr_read_digest(d, now = NOW)
  expect_equal(res$status, "unavailable")
  out <- scr_render_signals(res)
  expect_match(out$body, "conversation signals unavailable:", fixed = TRUE)
  expect_match(out$body, "stale", ignore.case = TRUE)
  expect_no_match(out$body, "OLD-CORRECTION", fixed = TRUE)
})

test_that("unparseable or malformed digest is unavailable", {
  load_lib()
  d1 <- tempfile("digest")
  write_digest(d1, raw = "{ this is not json")
  expect_equal(scr_read_digest(d1, now = NOW)$status, "unavailable")

  d2 <- tempfile("digest")
  write_digest(d2, raw = '{"summary_date":"2026-10-10","generated_at_utc":"2026-10-10T05:10:04+00:00"}')
  r2 <- scr_read_digest(d2, now = NOW)
  expect_equal(r2$status, "unavailable")
  expect_match(r2$reason, "all_signals", fixed = TRUE)
})

test_that("shown titles are redacted: paths and URLs never appear", {
  load_lib()
  d <- tempfile("digest")
  write_digest(d, signals = list(
    sig("correction",
        "Repeated user correction: do not touch /Users/someone/secret/dir/file.R or https://example.com/x?token=abc",
        3L, 2L)
  ))
  html <- scr_render_signals(scr_read_digest(d, now = NOW))$body
  expect_no_match(html, "/Users/someone", fixed = TRUE)
  expect_no_match(html, "secret/dir", fixed = TRUE)
  expect_no_match(html, "token=abc", fixed = TRUE)
  expect_match(html, "&lt;PATH&gt;", fixed = TRUE)
})

test_that("shown titles are HTML-escaped", {
  load_lib()
  d <- tempfile("digest")
  write_digest(d, signals = list(sig("failure", "Repeated exit 1: <script>x</script>", 2L, 2L)))
  html <- scr_render_signals(scr_read_digest(d, now = NOW))$body
  expect_no_match(html, "<script>", fixed = TRUE)
})

test_that("only the top N signals per category are listed, by sessions then repetitions", {
  load_lib()
  d <- tempfile("digest")
  sigs <- lapply(1:8, function(i) sig("failure", sprintf("FAIL-%d", i), i, i))
  write_digest(d, signals = sigs)
  html <- scr_render_signals(scr_read_digest(d, now = NOW), top_n = 3L)$body
  expect_match(html, "FAIL-8", fixed = TRUE)
  expect_match(html, "FAIL-6", fixed = TRUE)
  expect_no_match(html, "FAIL-5", fixed = TRUE)
})

# ── Step 2: roborev findings ─────────────────────────────────────────────────

rb_rows <- function(...) {
  data.frame(
    id = c(1L, 2L, 3L, 4L, 5L, 6L),
    created_at = c(rep("2026-10-10 06:00:00", 6)),
    closed = c(0L, 0L, 0L, 1L, 0L, 0L),
    repo = c("alpha", "alpha", "beta", "alpha", "beta", "beta"),
    severity = c("high", "medium", "medium", "high", "clean", NA),
    stringsAsFactors = FALSE
  )
}

test_that("roborev rows summarise to per-repo open High/Medium counts", {
  load_lib()
  s <- scr_roborev_summarise(rb_rows())
  expect_equal(s$n_reviews, 6L)
  by <- s$by_repo
  expect_equal(by$high[by$repo == "alpha"], 1L)    # id 4 is closed: excluded
  expect_equal(by$medium[by$repo == "alpha"], 1L)
  expect_equal(by$medium[by$repo == "beta"], 1L)
  expect_equal(by$high[by$repo == "beta"], 0L)
  expect_equal(s$n_unscored, 1L)                    # NA severity, not "clean"
  html <- scr_render_roborev(list(status = "ok", summary = s))$body
  expect_match(html, "alpha", fixed = TRUE)
  expect_match(html, "unscored", ignore.case = TRUE)
})

test_that("reviews in the window with no open High/Medium say so explicitly", {
  load_lib()
  rows <- rb_rows()
  rows$severity <- "clean"
  s <- scr_roborev_summarise(rows)
  out <- scr_render_roborev(list(status = "ok", summary = s))
  expect_match(paste(out$summary, out$body), "0 open", fixed = TRUE)
  expect_no_match(paste(out$summary, out$body), "unavailable", ignore.case = TRUE)
})

test_that("zero reviews in the window is 'nothing reviewed', not 'clean'", {
  load_lib()
  s <- scr_roborev_summarise(rb_rows()[0, ])
  out <- scr_render_roborev(list(status = "ok", summary = s))
  expect_match(paste(out$summary, out$body), "no roborev reviews", ignore.case = TRUE)
  expect_no_match(paste(out$summary, out$body), "0 open", fixed = TRUE)
})

test_that("severity is read from structured_output JSON, max across findings", {
  load_lib()
  so <- '{"schema_version":2,"findings":[{"severity":"low"},{"severity":"high"}]}'
  expect_equal(scr_row_severity(so, ""), "high")
  expect_equal(scr_row_severity('{"schema_version":2,"findings":[]}', ""), "clean")
  # prose quoting a severity marker inside a finding must not win over JSON
  so2 <- '{"schema_version":2,"findings":[{"severity":"low","problem":"**Severity**: Critical"}]}'
  expect_equal(scr_row_severity(so2, ""), "low")
  # legacy output text fallback
  expect_equal(scr_row_severity("", "- **Severity**: Medium\n"), "medium")
  # nothing usable: unscored (NA), never "clean"
  expect_true(is.na(scr_row_severity("", "")))
  expect_true(is.na(scr_row_severity("not json", "")))
})

test_that("unreadable reviews db renders an unavailable line with a reason", {
  load_lib()
  res <- scr_roborev_fetch(file.path(tempfile("nope"), "reviews.db"), now = NOW)
  expect_equal(res$status, "unavailable")
  out <- scr_render_roborev(res)
  expect_match(out$body, "roborev findings unavailable:", fixed = TRUE)

  garbage <- tempfile(fileext = ".db")
  writeLines("this is not a sqlite database", garbage)
  res2 <- scr_roborev_fetch(garbage, now = NOW)
  expect_equal(res2$status, "unavailable")
})

test_that("roborev fetch reads a real sqlite fixture end to end", {
  load_lib()
  skip_if_not_installed("duckdb")
  skip_if_not_installed("DBI")
  db <- tempfile(fileext = ".db")
  con <- DBI::dbConnect(duckdb::duckdb(), ":memory:")
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  ok <- tryCatch({
    DBI::dbExecute(con, "LOAD sqlite")
    TRUE
  }, error = function(e) {
    tryCatch({
      DBI::dbExecute(con, "INSTALL sqlite")
      DBI::dbExecute(con, "LOAD sqlite")
      TRUE
    }, error = function(e2) FALSE)
  })
  skip_if(!ok, "duckdb sqlite extension unavailable")
  DBI::dbExecute(con, sprintf("ATTACH '%s' AS fx (TYPE sqlite)", db))
  DBI::dbExecute(con, "CREATE TABLE fx.repos (id INTEGER, root_path TEXT, name TEXT)")
  DBI::dbExecute(con, "CREATE TABLE fx.review_jobs (id INTEGER, repo_id INTEGER)")
  DBI::dbExecute(con, "CREATE TABLE fx.reviews (id INTEGER, job_id INTEGER, created_at TEXT, closed INTEGER, output TEXT, structured_output TEXT)")
  DBI::dbExecute(con, "INSERT INTO fx.repos VALUES (1, '/x/alpha', 'alpha'), (2, '/x/beta', 'beta')")
  DBI::dbExecute(con, "INSERT INTO fx.review_jobs VALUES (10, 1), (11, 2), (12, 1)")
  hi  <- "{\"schema_version\":2,\"findings\":[{\"severity\":\"high\"}]}"
  med <- "{\"schema_version\":2,\"findings\":[{\"severity\":\"medium\"}]}"
  DBI::dbExecute(con, sprintf("INSERT INTO fx.reviews VALUES
    (1, 10, '2026-10-10 06:00:00', 0, '', '%s'),
    (2, 11, '2026-10-10 07:00:00', 0, '', '%s'),
    (3, 12, '2026-10-08 06:00:00', 0, '', '%s')", hi, med, hi))
  DBI::dbExecute(con, "DETACH fx")

  res <- scr_roborev_fetch(db, now = NOW)
  expect_equal(res$status, "ok")
  by <- res$summary$by_repo
  expect_equal(res$summary$n_reviews, 2L)       # id 3 is 2 days old: outside 24h
  expect_equal(by$high[by$repo == "alpha"], 1L)
  expect_equal(by$medium[by$repo == "beta"], 1L)
})

# ── Wiring into the email ────────────────────────────────────────────────────

test_that("email scope sentence names what is now inspected and what still is not", {
  skip_if_stripped()
  src <- paste(readLines(file.path(.scs_root(), ".claude", "scripts",
                                   "send_overnight_self_review_email.R")),
               collapse = "\n")
  # grepl + expect_true: expect_match() would dump the whole 3000-line script
  # into the failure message.
  expect_false(grepl("Not checked: config, rules, code, or anything said in a conversation",
                     src, fixed = TRUE),
               label = "stale 'does not inspect conversation' disclaimer is gone")
  expect_true(grepl("\"conversation signals (learning digest, pattern-based)\"", src, fixed = TRUE),
              label = "disclaimer can list conversation signals as checked")
  expect_true(grepl("\"roborev code findings\"", src, fixed = TRUE),
              label = "disclaimer can list roborev code findings as checked")
  expect_true(grepl("semantic review of conversations (planned, #235)", src, fixed = TRUE),
              label = "disclaimer names what is still not checked")
  expect_true(grepl("scr_read_digest(", src, fixed = TRUE),
              label = "email script calls the conversation-signals reader")
  expect_true(grepl("scr_roborev_fetch(", src, fixed = TRUE),
              label = "email script calls the roborev reader")
})

# ── End-to-end dry run through the real email script ─────────────────────────

.scs_email <- file.path(.scs_root(), ".claude", "scripts", "send_overnight_self_review_email.R")
.scs_real_db <- normalizePath("~/.claude/logs/unified.duckdb", mustWork = FALSE)

.scs_dry_run <- function(extra_env) {
  skip_if_stripped()
  skip_if_not_installed("blastula")
  skip_if_not_installed("duckdb")
  skip_if_not(file.exists(.scs_real_db), "unified.duckdb not available in test environment")
  out <- suppressWarnings(system2(
    "Rscript", args = .scs_email, stdout = TRUE, stderr = TRUE,
    env = c("EMAIL_DRY_RUN=1", paste0("UNIFIED_DB_PATH=", .scs_real_db),
            "GMAIL_USERNAME=", "GMAIL_APP_PASSWORD=", "REPORT_RECIPIENT=", extra_env)
  ))
  combined <- paste(out, collapse = "\n")
  # A locked/unreadable unified.duckdb aborts before any section renders; that
  # is an environment problem, not a verdict on this feature.
  skip_if(!grepl("QA:overnight_self_review_email=true", combined, fixed = TRUE),
          "dry run did not complete (unified.duckdb locked or unreadable)")
  combined
}

test_that("dry run: fresh digest + unreadable roborev db render distinct sections", {
  d <- tempfile("digest")
  today <- format(Sys.time(), "%Y-%m-%d", tz = "UTC")
  write_digest(d, date = today,
               generated = format(Sys.time() - 3600, "%Y-%m-%dT%H:%M:%S+00:00", tz = "UTC"),
               signals = list(sig("correction", "FIXTURE-CORRECTION-TITLE", 4L, 3L)))
  combined <- .scs_dry_run(c(paste0("CODEX_LEARNING_DIR=", d),
                             paste0("ROBOREV_DB=", file.path(tempfile("nope"), "reviews.db"))))
  expect_true(grepl("FIXTURE-CORRECTION-TITLE", combined, fixed = TRUE),
              label = "fresh digest correction shown in email")
  expect_true(grepl("roborev findings unavailable:", combined, fixed = TRUE),
              label = "unreadable roborev db shows an unavailable line")
  expect_false(grepl("conversation signals unavailable:", combined, fixed = TRUE),
               label = "a fresh digest is not reported unavailable")
  # The scope sentence (only present when the verdict box is the all-clear
  # variant) must not claim roborev was checked when it was unavailable.
  if (grepl("Not checked: the meaning of rules or config", combined, fixed = TRUE)) {
    expect_true(grepl("Unavailable today: roborev code findings", combined, fixed = TRUE))
  }
})

test_that("dry run: missing digest dir renders unavailable, never an empty/clean section", {
  combined <- .scs_dry_run(c(paste0("CODEX_LEARNING_DIR=", tempfile("nope"))))
  expect_true(grepl("conversation signals unavailable:", combined, fixed = TRUE))
  expect_false(grepl("no repeated corrections or failures", combined, fixed = TRUE))
})
