#!/usr/bin/env Rscript
# backfill_skill_usage.R — one-time (repeatable) historical backfill for the
# skill_usage table from Claude Code session transcripts.
#
# Card 1b (own-your-context plan). skill_usage had only ~29 rows against
# 3,783 sessions because the only writer was a nightly ETL scanning a narrow
# literal-match pattern (skill_usage_etl.R). log_skill_use.sh now captures
# Skill invocations going forward in real time; this script fills in the
# historical gap by parsing the same JSONL transcripts directly for Skill
# tool_use blocks and inserting one row per invocation with backfilled=TRUE.
#
# Extracts ONLY: session_id, skill_name, timestamp, project path. It does
# NOT read or store any transcript content beyond the `skill` and `args`
# fields of the tool_use block itself, and `args` is reduced to a fixed-
# length hash (never stored as free text) — consistent with
# log_skill_use.sh's privacy stance.
#
# Idempotent: dedupes on (session_id, skill_name, ts) via NOT EXISTS at
# insert time, so re-running never increases the row count.
#
# Usage:
#   Rscript backfill_skill_usage.R [--apply] [--db PATH] [--projects-dir PATH]
#
#   --apply           Write to the DB (default: dry-run, print summary only)
#   --db PATH         DuckDB file path (default: ~/.claude/logs/unified.duckdb)
#   --projects-dir P  Transcript root (default: ~/.claude/projects)
#
# Tables written:
#   skill_usage(session_id, skill_name, project_path, args_hash, ts, backfilled)
#     — additive columns alongside the legacy session_date/project/
#     invocations/etl_run_at columns written by skill_usage_etl.R; see
#     skill_usage_staging_import.sh header comment for the coexistence
#     rationale.
#
# Also registers/refreshes the `skill_usage` row in `etl_freshness` (#309
# Card 1a; defensive — creates the table if 1a has not merged yet).

suppressPackageStartupMessages({
  library(jsonlite)
  library(dplyr)
  library(duckdb)
  library(purrr)
  library(fs)
  library(tibble)
  library(stringr)
})

# ── Args ──────────────────────────────────────────────────────────────────────
args    <- commandArgs(trailingOnly = TRUE)
dry_run <- !"--apply" %in% args

db_idx  <- which(args == "--db") + 1L
db_path <- if (length(db_idx) && db_idx <= length(args))
             args[[db_idx]] else path.expand("~/.claude/logs/unified.duckdb")

proj_idx     <- which(args == "--projects-dir") + 1L
projects_dir <- if (length(proj_idx) && proj_idx <= length(args))
                  args[[proj_idx]] else path.expand("~/.claude/projects")

cat(sprintf("backfill_skill_usage: dry_run=%s db=%s projects_dir=%s\n",
            dry_run, db_path, projects_dir))

# ── args_hash: fixed-length fingerprint, never store args text itself ───────
hash_args <- function(x) {
  if (is.null(x) || !nzchar(x)) return(NA_character_)
  out <- tryCatch(
    system2("shasum", c("-a", "256"), input = x, stdout = TRUE),
    error = function(e) character()
  )
  if (!length(out)) return(NA_character_)
  substr(strsplit(out[[1]], "\\s+")[[1]][[1]], 1, 16)
}

# ── JSONL parsing: one row per Skill tool_use block ──────────────────────────
extract_skill_events <- function(msg, session_id, project) {
  content <- msg$message$content
  if (!is.list(content)) return(NULL)
  ts <- msg$timestamp %||% NA_character_

  rows <- compact(map(content, function(block) {
    if (!identical(block$type, "tool_use")) return(NULL)
    if (!identical(block$name %||% "", "Skill")) return(NULL)
    sn <- block$input$skill %||% NA_character_
    if (is.na(sn) || !nzchar(sn)) return(NULL)
    tibble(
      session_id   = session_id,
      skill_name   = sn,
      project_path = project,
      args_hash    = hash_args(block$input$args %||% NULL),
      ts           = ts
    )
  }))
  if (!length(rows)) return(NULL)
  bind_rows(rows)
}

parse_file <- function(path) {
  lines <- tryCatch(readLines(path, warn = FALSE), error = function(e) character())
  if (!length(lines)) return(NULL)

  # The parent directory name is a lossily-encoded project path (Claude Code
  # replaces every "/" with "-", so a real "-" in the path, e.g. "docs_gh",
  # is indistinguishable from an encoded "/"). Reverse-decoding it by
  # gsub("-", "/") therefore corrupts real paths (docs_gh -> docs/gh). The
  # transcript's own top-level `cwd` field carries the real, unambiguous
  # path, so prefer that; only fall back to the (deliberately un-decoded)
  # encoded directory name when no line in the transcript carries `cwd`.
  project_enc <- basename(dirname(as.character(path)))
  session_id  <- tools::file_path_sans_ext(basename(as.character(path)))
  if (!nzchar(session_id)) return(NULL)

  msgs <- map(lines, function(line) {
    tryCatch(fromJSON(line, simplifyVector = FALSE), error = function(e) NULL)
  })

  project <- NULL
  for (msg in msgs) {
    cwd <- msg$cwd %||% NULL
    if (!is.null(cwd) && nzchar(cwd)) {
      project <- cwd
      break
    }
  }
  if (is.null(project)) project <- project_enc

  events <- compact(map(msgs, function(msg) {
    if (is.null(msg) || !identical(msg$type, "assistant")) return(NULL)
    extract_skill_events(msg, session_id, project)
  }))
  if (!length(events)) return(NULL)
  bind_rows(events)
}

jsonl_files <- tryCatch(dir_ls(projects_dir, recurse = TRUE, glob = "*.jsonl"),
                        error = function(e) character())
cat(sprintf("Scanning %d JSONL files under %s...\n", length(jsonl_files), projects_dir))

parsed  <- compact(map(jsonl_files, parse_file))
events_df <- if (length(parsed)) bind_rows(parsed) else tibble(
  session_id = character(), skill_name = character(),
  project_path = character(), args_hash = character(), ts = character()
)

cat(sprintf("Found %d historical Skill invocations across %d files\n",
            nrow(events_df), length(jsonl_files)))

if (nrow(events_df) > 0) {
  cat("\nTop skills by historical invocation count:\n")
  events_df |> count(skill_name, sort = TRUE) |> print(n = 20L)
}

if (dry_run) {
  cat("\nDRY RUN — pass --apply to write to DB\n")
  quit(status = 0L)
}

# ── DB write ──────────────────────────────────────────────────────────────────
con <- dbConnect(duckdb(), db_path)
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

# Ensure schema — additive; identical DDL to skill_usage_staging_import.sh so
# either writer can run first against a fresh DB.
invisible(dbExecute(con, "
  CREATE TABLE IF NOT EXISTS skill_usage (
    session_id   VARCHAR,
    skill_name   VARCHAR,
    project_path VARCHAR,
    args_hash    VARCHAR,
    ts           TIMESTAMP,
    backfilled   BOOLEAN DEFAULT FALSE
  )"))
for (col_ddl in c(
  "ALTER TABLE skill_usage ADD COLUMN IF NOT EXISTS project_path VARCHAR",
  "ALTER TABLE skill_usage ADD COLUMN IF NOT EXISTS args_hash VARCHAR",
  "ALTER TABLE skill_usage ADD COLUMN IF NOT EXISTS ts TIMESTAMP",
  "ALTER TABLE skill_usage ADD COLUMN IF NOT EXISTS backfilled BOOLEAN DEFAULT FALSE"
)) {
  tryCatch(dbExecute(con, col_ddl), error = function(e) invisible(NULL))
}

if (nrow(events_df) > 0) {
  # Register the candidate rows in a temp view, then insert only the ones
  # not already present (dedupe on session_id, skill_name, ts) — idempotent.
  events_df <- events_df |>
    mutate(ts = as.character(ts), backfilled = TRUE) |>
    filter(!is.na(ts), nzchar(ts))

  dbWriteTable(con, "skill_usage_backfill_staging", events_df, overwrite = TRUE)

  n_inserted <- dbExecute(con, "
    INSERT INTO skill_usage (session_id, skill_name, project_path, args_hash, ts, backfilled)
    SELECT
      s.session_id, s.skill_name, s.project_path, s.args_hash,
      CAST(s.ts AS TIMESTAMP) AS ts, TRUE
    FROM skill_usage_backfill_staging s
    WHERE NOT EXISTS (
      SELECT 1 FROM skill_usage u
      WHERE u.session_id = s.session_id
        AND u.skill_name = s.skill_name
        AND date_trunc('second', u.ts) = date_trunc('second', CAST(s.ts AS TIMESTAMP))
    )
  ")
  invisible(dbExecute(con, "DROP TABLE IF EXISTS skill_usage_backfill_staging"))
  cat(sprintf("Inserted %d new rows (skipped duplicates already present)\n", n_inserted))
}

# ── etl_freshness registration (defensive re: #309 Card 1a coordination) ────
# Mirrors skill_usage_staging_import.sh: use the shared helper if present,
# else fall back to an inline upsert with the identical schema.
raw_args   <- commandArgs(trailingOnly = FALSE)
file_arg   <- grep("^--file=", raw_args, value = TRUE)
script_dir <- if (length(file_arg))
  dirname(normalizePath(sub("^--file=", "", file_arg[[1]]))) else getwd()
freshness_helper <- file.path(script_dir, "etl_freshness_upsert.sh")

used_helper <- FALSE
if (nzchar(freshness_helper) && file.exists(freshness_helper) &&
    file.access(freshness_helper, mode = 1)[[1]] == 0) {
  status <- tryCatch(
    system2(freshness_helper,
            c("skill_usage", shQuote(db_path), "", "--table", "skill_usage", "--ts-col", "ts"),
            stdout = FALSE, stderr = FALSE),
    error = function(e) 1L
  )
  used_helper <- identical(status, 0L)
}
if (!used_helper) {
  invisible(dbExecute(con, "
    CREATE TABLE IF NOT EXISTS etl_freshness (
      source_name            VARCHAR PRIMARY KEY,
      last_row_ts             TIMESTAMP,
      last_etl_run_ts         TIMESTAMP,
      expected_cadence_hours  DOUBLE,
      status                  VARCHAR
    )"))
  invisible(dbExecute(con, "
    INSERT OR REPLACE INTO etl_freshness
      (source_name, last_row_ts, last_etl_run_ts, expected_cadence_hours, status)
    SELECT 'skill_usage', (SELECT MAX(ts) FROM skill_usage), current_timestamp, NULL, 'unknown'
  "))
}

final_count <- dbGetQuery(con, "SELECT COUNT(*) AS n FROM skill_usage")$n
cat(sprintf("\nDone. skill_usage now has %d total rows. DB: %s\n", final_count, db_path))
