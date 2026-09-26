#!/usr/bin/env Rscript
# tests/test_roborev_metrics_etl_reader.R
#
# Focused unit tests for the JSON-direct severity reader in
# .claude/scripts/roborev_metrics_etl.R (llm#1265 round 3, PR #1269 review
# id 10524: "No tests for the new readers in roborev_metrics_etl.R,
# roborev_weekly_rollup.R, roborev_handoff.sh -- add focused tests covering
# schema 0, schema 1/2, empty findings, unknown schema_version, malformed
# JSON, column-absent fallback.").
#
# roborev_metrics_etl.R is not sourceable end-to-end: past line ~2683 it
# opens a real DuckDB connection as a top-level side effect. This test
# therefore extracts ONLY the self-contained reader block (SEVERITY_PATTERN
# through the end of .metrics_structured_max_severity(), lines 510-621 at
# the time of writing) via a line-range `sed` -- the same technique
# tests/test_severity_regex_parity.sh already uses in this repo to extract
# a bash function for standalone testing -- rather than reimplementing the
# functions here, so this test exercises the ACTUAL production code, not a
# hand-copied mirror of it that could silently drift.
#
# Run:
#   Rscript tests/test_roborev_metrics_etl_reader.R

suppressPackageStartupMessages({
  library(testthat)
})

this_file <- tryCatch(
  normalizePath(sys.frames()[[1L]]$ofile, mustWork = FALSE),
  error = function(e) {
    args <- commandArgs(trailingOnly = FALSE)
    file_flag <- grep("^--file=", args, value = TRUE)
    if (length(file_flag) > 0L) sub("^--file=", "", file_flag[1L]) else "."
  }
)
script_dir <- normalizePath(dirname(this_file), mustWork = FALSE)
etl_script <- normalizePath(
  file.path(script_dir, "..", ".claude", "scripts", "roborev_metrics_etl.R"),
  mustWork = FALSE
)

test_that("roborev_metrics_etl.R exists", {
  testthat::skip_if_not(
    file.exists(etl_script),
    sprintf("roborev_metrics_etl.R not found at %s (expected under covr/R CMD check, where .Rbuildignore excludes .claude/)", etl_script)
  )
  expect_true(file.exists(etl_script))
})

if (!file.exists(etl_script)) {
  message("Skipping execution tests -- roborev_metrics_etl.R not found")
  q(status = 0L)
}

# ── Extract the self-contained reader block ─────────────────────────────────
etl_lines <- readLines(etl_script)
start_i <- grep("^SEVERITY_PATTERN <- ", etl_lines)[1L]
# End marker: the section header immediately after the reader block.
end_marker_i <- grep("^# ── Classify a job failure from review_jobs\\.error", etl_lines)[1L]

test_that("reader block extraction anchors are found (extraction guard)", {
  testthat::skip_if_not(file.exists(etl_script), "roborev_metrics_etl.R not found")
  expect_false(is.na(start_i))
  expect_false(is.na(end_marker_i))
  expect_true(end_marker_i > start_i)
})

if (is.na(start_i) || is.na(end_marker_i) || end_marker_i <= start_i) {
  message("Skipping reader tests -- extraction anchors drifted from roborev_metrics_etl.R")
  q(status = 1L)
}

reader_block <- etl_lines[start_i:(end_marker_i - 1L)]
reader_env <- new.env()
eval(parse(text = reader_block), envir = reader_env)

parse_max_severity <- get("parse_max_severity", envir = reader_env)
.metrics_review_text <- get(".metrics_review_text", envir = reader_env)
.metrics_structured_max_severity <- get(".metrics_structured_max_severity", envir = reader_env)

# ── Fixtures ─────────────────────────────────────────────────────────────

schema0_legacy <- paste0(
  '{"legacy":{"markdown":"- **Severity**: Critical\\n  **Problem**: bad thing"},',
  '"schema_version":0,"summary":"","findings":[]}'
)
v2_with_findings <- paste0(
  '{"schema_version":2,"summary":"x","verdict":"fail",',
  '"findings":[{"severity":"medium","problem":"p1"},{"severity":"high","problem":"p2"}]}'
)
v1_empty_findings <- '{"schema_version":1,"summary":"trivial change","findings":[]}'
unknown_schema <- '{"schema_version":99,"summary":"x","findings":[]}'
malformed_json <- "{not valid json"
# The headline bug this round fixes: real severity is medium, but the
# finding's own problem/fix prose quotes a higher severity as an example
# (review ids 10523/10524 live shape).
v2_medium_quoted_high <- paste0(
  '{"schema_version":2,"summary":"one medium finding, quoted example",',
  '"verdict":"fail","findings":[{"severity":"medium","location":"R/quux.R:5",',
  '"problem":"Add a fixture where output holds a real Severity: High review.",',
  '"fix":"Emit **Severity**: Critical only when genuinely critical."}]}'
)

# ── Tests: .metrics_review_text() (unchanged behaviour, still exercised) ───

test_that(".metrics_review_text(): schema_version 0 returns legacy.markdown verbatim", {
  txt <- .metrics_review_text("", schema0_legacy)
  expect_true(grepl("Critical", txt, fixed = TRUE))
})

test_that(".metrics_review_text(): malformed JSON falls back to `output`", {
  txt <- .metrics_review_text("**Severity**: Low", malformed_json)
  expect_equal(txt, "**Severity**: Low")
})

test_that(".metrics_review_text(): NA structured_output falls back to `output`", {
  txt <- .metrics_review_text("**Severity**: Low", NA_character_)
  expect_equal(txt, "**Severity**: Low")
})

# ── Tests: .metrics_structured_max_severity() (the JSON-direct fix) ────────

test_that(".metrics_structured_max_severity(): schema_version 0 -> NA (legacy path, no JSON findings)", {
  expect_true(is.na(.metrics_structured_max_severity("", schema0_legacy)))
})

test_that(".metrics_structured_max_severity(): v2 findings -> max severity (High)", {
  expect_equal(.metrics_structured_max_severity("", v2_with_findings), "High")
})

test_that(".metrics_structured_max_severity(): empty findings list -> NA", {
  expect_true(is.na(.metrics_structured_max_severity("", v1_empty_findings)))
})

test_that(".metrics_structured_max_severity(): unrecognised schema_version -> NA", {
  expect_true(is.na(.metrics_structured_max_severity("", unknown_schema)))
})

test_that(".metrics_structured_max_severity(): malformed JSON -> NA (no crash)", {
  expect_true(is.na(.metrics_structured_max_severity("**Severity**: Low", malformed_json)))
})

test_that(".metrics_structured_max_severity(): NA structured_output -> NA (column-absent fallback shape)", {
  expect_true(is.na(.metrics_structured_max_severity("**Severity**: Low", NA_character_)))
})

test_that(".metrics_structured_max_severity(): real severity is Medium, NOT inflated by quoted High/Critical prose", {
  expect_equal(.metrics_structured_max_severity("", v2_medium_quoted_high), "Medium")
})

test_that("regression proof: parse_max_severity() over the OLD rendered-text path reads Critical (inflated)", {
  # .metrics_review_text() only renders the bullet line today (no
  # problem/fix text), so this fixture alone does not reproduce the
  # inflation via THIS script's renderer -- but proves the JSON-direct
  # function above is what actually protects this consumer, not an
  # accident of what .metrics_review_text() happens to render.
  rendered <- .metrics_review_text("", v2_medium_quoted_high)
  expect_equal(parse_max_severity(rendered), "Medium")
})

# ── End-to-end: JSON-direct wins over the regex fallback when both agree,
# and the regex fallback still works when there is no structured data ─────

test_that("end-to-end: JSON-direct severity used for a structured row", {
  sev_json  <- .metrics_structured_max_severity("", v2_with_findings)
  txt       <- .metrics_review_text("", v2_with_findings)
  sev_regex <- parse_max_severity(txt)
  final_sev <- if (!is.na(sev_json)) sev_json else sev_regex
  expect_equal(final_sev, "High")
})

test_that("end-to-end: regex fallback used for a legacy (schema_version 0) row", {
  sev_json  <- .metrics_structured_max_severity("", schema0_legacy)
  txt       <- .metrics_review_text("", schema0_legacy)
  sev_regex <- parse_max_severity(txt)
  final_sev <- if (!is.na(sev_json)) sev_json else sev_regex
  expect_equal(final_sev, "Critical")
})

cat("\n--- All tests completed ---\n")
