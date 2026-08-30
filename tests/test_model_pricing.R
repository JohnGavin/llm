#!/usr/bin/env Rscript
# tests/test_model_pricing.R
#
# testthat tests for the versioned, date-effective model_pricing lookup in
# .claude/scripts/roborev_metrics_etl.R (llm#795).
#
# Strategy:
#   1. Extracts the PRICING_BLOCK_START..PRICING_BLOCK_END text region out of
#      roborev_metrics_etl.R into a temp .R file, so the test exercises the
#      REAL production pricing logic (not a duplicated copy) without running
#      the rest of the ETL (arg parsing, jobs_raw, duck_con, etc. are not
#      needed by this block and are not available at test time).
#   2. Builds a scratch DuckDB from the real roborev_metrics_schema.sql
#      (creates model_pricing + seeds the real production rates) — NEVER
#      touches ~/.claude/logs/unified.duckdb.
#   3. Inserts two rows for a synthetic, never-real model_prefix
#      ("test-widget-model") with different effective_from dates, so the
#      date-window assertions do NOT rely on the real seed data changing.
#   4. Sources the extracted block with UNIFIED_DB pointed at the scratch DB,
#      then asserts: a record dated BEFORE the price change prices at the
#      old rate, a record dated AFTER prices at the new rate, and an unknown
#      model still routes to the sonnet-tier default.
#
# Run:
#   nix-shell default.nix --run "Rscript tests/test_model_pricing.R"
#
# Tracked in llm#795.

suppressPackageStartupMessages({
  library(testthat)
  library(DBI)
  library(duckdb)
})

`%||%` <- function(a, b) if (!is.null(a) && length(a) > 0L) a else b

# ── Locate the ETL script + schema file ───────────────────────────────────

this_file <- tryCatch(
  normalizePath(sys.frames()[[1L]]$ofile, mustWork = FALSE),
  error = function(e) {
    args <- commandArgs(trailingOnly = FALSE)
    file_flag <- grep("^--file=", args, value = TRUE)
    if (length(file_flag) > 0L) sub("^--file=", "", file_flag[1L]) else "."
  }
)
script_dir <- normalizePath(dirname(this_file), mustWork = FALSE)

etl_script    <- normalizePath(
  file.path(script_dir, "..", ".claude", "scripts", "roborev_metrics_etl.R"),
  mustWork = FALSE
)
schema_file   <- normalizePath(
  file.path(script_dir, "..", ".claude", "scripts", "roborev_metrics_schema.sql"),
  mustWork = FALSE
)

if (!file.exists(etl_script)) {
  candidates <- file.path(Sys.getenv("HOME"), "docs_gh", "llm", ".claude",
                          "scripts", "roborev_metrics_etl.R")
  etl_script <- candidates[file.exists(candidates)][1L] %||% etl_script
}
if (!file.exists(schema_file)) {
  candidates <- file.path(Sys.getenv("HOME"), "docs_gh", "llm", ".claude",
                          "scripts", "roborev_metrics_schema.sql")
  schema_file <- candidates[file.exists(candidates)][1L] %||% schema_file
}

test_that("ETL script and schema file exist", {
  # .Rbuildignore excludes .claude/ from the package build, so under
  # covr::package_coverage() / R CMD check these files are genuinely absent —
  # skip (not fail) in that case. skip_if_not() reports the test as SKIPPED,
  # distinct from both PASS and FAIL, so a real regression (script present
  # but broken) still fails loudly while a build-tree exclusion does not.
  testthat::skip_if_not(
    file.exists(etl_script),
    sprintf(
      "roborev_metrics_etl.R not found at %s (expected under covr/R CMD check, where .Rbuildignore excludes .claude/)",
      etl_script
    )
  )
  testthat::skip_if_not(
    file.exists(schema_file),
    sprintf(
      "roborev_metrics_schema.sql not found at %s (expected under covr/R CMD check, where .Rbuildignore excludes .claude/)",
      schema_file
    )
  )
  expect_true(file.exists(etl_script))
  expect_true(file.exists(schema_file))
})

if (!file.exists(etl_script) || !file.exists(schema_file)) {
  message("Skipping execution tests — ETL script or schema file not found")
  q(status = 0L)
}

# ── Extract the pricing block in isolation ────────────────────────────────

etl_lines  <- readLines(etl_script, warn = FALSE)
start_idx  <- grep("PRICING_BLOCK_START", etl_lines)
end_idx    <- grep("PRICING_BLOCK_END", etl_lines)

test_that("pricing block markers are present exactly once", {
  expect_length(start_idx, 1L)
  expect_length(end_idx, 1L)
  expect_true(start_idx < end_idx)
})

if (length(start_idx) != 1L || length(end_idx) != 1L || !(start_idx < end_idx)) {
  message("Skipping execution tests — pricing block markers malformed")
  q(status = 0L)
}

pricing_code_lines <- etl_lines[(start_idx + 1L):(end_idx - 1L)]
pricing_tmp_file   <- tempfile("roborev_pricing_block_", fileext = ".R")
writeLines(pricing_code_lines, pricing_tmp_file)
on.exit(unlink(pricing_tmp_file), add = TRUE)

# ── Build a scratch DuckDB from the real schema (never unified.duckdb) ────

scratch_db <- tempfile("pricing_test_", fileext = ".duckdb")
on.exit(unlink(scratch_db), add = TRUE)

apply_schema <- function(db_path, schema_path) {
  schema_sql  <- readLines(schema_path, warn = FALSE)
  schema_text <- paste(schema_sql, collapse = "\n")
  schema_text <- gsub("--[^\n]*", "", schema_text)
  stmts       <- strsplit(schema_text, ";")[[1L]]
  stmts       <- trimws(stmts)
  stmts       <- stmts[nzchar(stmts)]

  con <- DBI::dbConnect(duckdb::duckdb(), db_path)
  on.exit(tryCatch(DBI::dbDisconnect(con, shutdown = TRUE), error = function(e) NULL),
          add = TRUE)
  for (stmt in stmts) {
    DBI::dbExecute(con, stmt)
  }
  invisible(NULL)
}

apply_schema(scratch_db, schema_file)

# Insert two rows for a synthetic prefix that never collides with real
# production model ids — the date-window assertions below depend ONLY on
# these two rows, not on the real seed data.
insert_test_prefix_rows <- function(db_path) {
  con <- DBI::dbConnect(duckdb::duckdb(), db_path)
  on.exit(tryCatch(DBI::dbDisconnect(con, shutdown = TRUE), error = function(e) NULL),
          add = TRUE)
  DBI::dbExecute(con, "
    INSERT INTO model_pricing
      (model_prefix, input_usd_per_mtok, output_usd_per_mtok, effective_from, source_url)
    VALUES
      ('test-widget-model', 1.00, 2.00,  DATE '2024-01-01', 'https://example.test/old'),
      ('test-widget-model', 5.00, 10.00, DATE '2026-06-01', 'https://example.test/new')
    ON CONFLICT (model_prefix, effective_from) DO NOTHING")
  invisible(NULL)
}

insert_test_prefix_rows(scratch_db)

test_that("scratch DB has model_pricing with our synthetic rows", {
  con <- DBI::dbConnect(duckdb::duckdb(), scratch_db, read_only = TRUE)
  on.exit(tryCatch(DBI::dbDisconnect(con, shutdown = TRUE), error = function(e) NULL))
  n <- DBI::dbGetQuery(con, "
    SELECT COUNT(*) AS n FROM model_pricing WHERE model_prefix = 'test-widget-model'")$n
  expect_equal(as.integer(n), 2L)
})

# ── Source the real pricing block, pointed at the scratch DB ──────────────

UNIFIED_DB <- scratch_db          # nolint: used by the sourced pricing block
log_msg    <- function(...) invisible(NULL)  # stub — pricing block only calls this on error

source(pricing_tmp_file)

test_that("PRICING_DF loaded from the scratch DB (not just the R-side seed)", {
  expect_true(exists("PRICING_DF"))
  expect_true("test-widget-model" %in% PRICING_DF$model_prefix)
})

# ── Date-window assertions (llm#795 core requirement) ─────────────────────

test_that("a record dated BEFORE the price change prices at the OLD rate", {
  p <- model_pricing("test-widget-model-v1", at_date = as.Date("2025-01-01"))
  expect_equal(p$input,  1.00)
  expect_equal(p$output, 2.00)
})

test_that("a record dated AFTER the price change prices at the NEW rate", {
  p <- model_pricing("test-widget-model-v1", at_date = as.Date("2026-06-15"))
  expect_equal(p$input,  5.00)
  expect_equal(p$output, 10.00)
})

test_that("an unknown model still routes to the sonnet-tier default", {
  p <- model_pricing("totally-unknown-model-zzz", at_date = as.Date("2026-06-15"))
  expect_equal(p$input,  3.00)
  expect_equal(p$output, 15.00)
})

test_that("compute_cost_usd reflects the date-windowed rate change", {
  cost_old <- compute_cost_usd(1e6, 1e6, "test-widget-model-v1", at_date = as.Date("2025-01-01"))
  cost_new <- compute_cost_usd(1e6, 1e6, "test-widget-model-v1", at_date = as.Date("2026-06-15"))
  expect_equal(cost_old, 1.00 + 2.00)
  expect_equal(cost_new, 5.00 + 10.00)
})

test_that("compute_cost_usd spot-check matches prior embedded-literal behaviour", {
  # claude-opus-4: input 15.00 / output 75.00 per 1M tokens (unchanged, llm#795
  # is a behaviour-preserving migration).
  cost <- compute_cost_usd(1e6, 1e6, "claude-opus-4", at_date = as.Date("2026-07-30"))
  expect_equal(cost, 15.00 + 75.00)
})

# ── Fallback-hit counter (llm#793 item 3) ──────────────────────────────────

test_that("PRICING_FALLBACK_HITS exists and starts/reset at zero", {
  expect_true(exists("PRICING_FALLBACK_HITS"))
  expect_true(exists("reset_pricing_fallback_counter"))
  reset_pricing_fallback_counter()
  expect_equal(PRICING_FALLBACK_HITS$n, 0L)
})

test_that("PRICING_FALLBACK_HITS does NOT increment for a recognised model id", {
  reset_pricing_fallback_counter()
  # "claude-opus-4" is a real seeded prefix (roborev_metrics_schema.sql) —
  # this must match a real pricing row, not the __default__ fallback.
  p <- model_pricing("claude-opus-4", at_date = as.Date("2026-07-30"))
  expect_equal(p$input, 15.00)
  expect_equal(p$output, 75.00)
  expect_equal(PRICING_FALLBACK_HITS$n, 0L)
})

test_that("PRICING_FALLBACK_HITS increments once for an unrecognised model id", {
  reset_pricing_fallback_counter()
  model_pricing("totally-unknown-model-zzz", at_date = as.Date("2026-06-15"))
  expect_equal(PRICING_FALLBACK_HITS$n, 1L)
})

test_that("PRICING_FALLBACK_HITS increments for NA/empty/'unknown' model ids", {
  reset_pricing_fallback_counter()
  model_pricing(NA_character_, at_date = as.Date("2026-06-15"))
  model_pricing("", at_date = as.Date("2026-06-15"))
  model_pricing("unknown", at_date = as.Date("2026-06-15"))
  expect_equal(PRICING_FALLBACK_HITS$n, 3L)
})

test_that("PRICING_FALLBACK_HITS accumulates across mixed recognised/unrecognised calls", {
  reset_pricing_fallback_counter()
  model_pricing("claude-sonnet-4", at_date = as.Date("2026-07-30"))   # recognised: no increment
  model_pricing("some-brand-new-model", at_date = as.Date("2026-07-30")) # unrecognised: +1
  model_pricing("claude-haiku-4", at_date = as.Date("2026-07-30"))    # recognised: no increment
  model_pricing("another-unseen-model", at_date = as.Date("2026-07-30")) # unrecognised: +1
  expect_equal(PRICING_FALLBACK_HITS$n, 2L)
})

cat("\n--- All tests completed ---\n")
