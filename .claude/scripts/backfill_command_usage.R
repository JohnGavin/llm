#!/usr/bin/env Rscript
# backfill_command_usage.R — one-time (repeatable) historical backfill for
# the command_usage table from Claude Code session transcripts.
#
# Card 1e (own-your-context plan, #745). skill_usage (Card 1b, #729/#744)
# only captures invocations of the `Skill` tool. Slash commands such as
# /bye, /check, /cleanup, /issue-triage are NOT logged as Skill tool_use
# blocks. Investigation of real transcripts (2026-07-07) found that
# *custom* project/user commands — the ones this card targets — are
# recorded as a top-level record:
#
#   {"type":"attachment","attachment":{"type":"invoked_skills",
#    "skills":[{"name":"bye","path":"userSettings:bye","content":"..."}]},
#    "sessionId":"...","cwd":"...","timestamp":"..."}
#
# This is a DIFFERENT mechanism from the `<command-name>/x</command-name>`
# XML tag embedded in a "user" turn's `message.content` string, which is
# used for Claude Code *built-in* commands (/model, /usage, /exit, ...).
# Confirmed empirically: /issue-triage (a pure custom command with no
# built-in override) produces ONLY the invoked_skills attachment record —
# no <command-name> tag at all in that session. This script parses ONLY
# the invoked_skills attachment shape, matching the "bare tool name, not
# Skill-wrapped" signal called out in #745 (attachment.skills[].name is
# the bare command name, not nested under a "Skill" tool_use block the way
# skill_usage's rows are).
#
# Known data-shape limitation: invoked_skills records observed in the wild
# carry only {name, path, content} per skill — no per-invocation args
# field. args_hash is therefore NA for every historically-backfilled row.
# The forward-capture hook (log_command_use.sh, a UserPromptSubmit hook)
# DOES see per-invocation args, because it reads the raw "/name args..."
# prompt text at submission time — before Claude Code resolves/loads the
# command file into an invoked_skills record. extract_command_events()
# below defensively also checks for an `args` field on the skill object
# (hashed via hash_args(), same convention as the hook) in case a future
# Claude Code version adds one; this keeps the parser forward-compatible
# and lets tests exercise the hashing/dedup logic without contradicting
# today's real transcript shape.
#
# Extracts ONLY: session_id, command_name, timestamp, project path, and
# (when present) a fixed-length args hash. It does NOT store the `content`
# field (the full command markdown body) — that would duplicate the
# command definition file itself in the DB for no analytic benefit.
#
# Idempotent: dedupes on (session_id, command_name, ts, args_hash) via NOT
# EXISTS at insert time, so re-running never increases the row count.
# args_hash is compared with COALESCE(..., '') = COALESCE(..., '') so NULL
# (this script's hash_args() for a no-args command) and '' (the forward
# hook's args_hash for a no-args command) are treated as the SAME value —
# otherwise IS NOT DISTINCT FROM would treat NULL and '' as distinct and
# double-count every no-args command re-seen across the two writers (#747
# review). Two invocations differing only in actual (non-empty) args are
# still never conflated into one row.
#
# Usage:
#   Rscript backfill_command_usage.R [--apply] [--db PATH] [--projects-dir PATH]
#
#   --apply           Write to the DB (default: dry-run, print summary only)
#   --db PATH         DuckDB file path (default: ~/.claude/logs/unified.duckdb)
#   --projects-dir P  Transcript root (default: ~/.claude/projects)
#
# Tables written:
#   command_usage(session_id, command_name, project_path, args_hash, ts, backfilled)
#     — mirrors skill_usage's event-level shape exactly.
#
# Also registers/refreshes the `command_usage` row in `etl_freshness` (#309
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

cat(sprintf("backfill_command_usage: dry_run=%s db=%s projects_dir=%s\n",
            dry_run, db_path, projects_dir))

# ── args_hash: fixed-length fingerprint, never store args text itself ───────
# MUST match log_command_use.sh's hook-time hash exactly: that hook computes
# `printf '%s' "$_args" | shasum -a 256 | cut -c1-16` — i.e. it hashes the raw
# args bytes with NO trailing newline (identical convention to
# log_skill_use.sh / backfill_skill_usage.R's hash_args()). system2(...,
# input = x) is NOT equivalent: it writes x via writeLines(), which appends
# a trailing "\n", producing a different hash for the same string and
# silently breaking cross-writer dedup. Write the bytes to a temp file with
# no newline (cat(..., sep = "")) and hash the file instead of piping via
# stdin, so both writers hash byte-identical input.
hash_args <- function(x) {
  if (is.null(x) || !nzchar(x)) return(NA_character_)
  tmp <- tempfile()
  on.exit(unlink(tmp), add = TRUE)
  cat(x, file = tmp, sep = "")
  out <- tryCatch(
    system2("shasum", c("-a", "256", tmp), stdout = TRUE),
    error = function(e) character()
  )
  if (!length(out)) return(NA_character_)
  substr(strsplit(out[[1]], "\\s+")[[1]][[1]], 1, 16)
}

# ── JSONL parsing: one row per invoked_skills[[i]] entry ─────────────────────
extract_command_events <- function(msg, session_id, project) {
  att <- msg$attachment
  if (is.null(att)) return(NULL)
  if (!identical(att$type %||% "", "invoked_skills")) return(NULL)
  skills <- att$skills
  if (!is.list(skills) || !length(skills)) return(NULL)
  ts <- msg$timestamp %||% NA_character_

  rows <- compact(map(skills, function(sk) {
    nm <- sk$name %||% NA_character_
    if (is.na(nm) || !nzchar(nm)) return(NULL)
    tibble(
      session_id   = session_id,
      command_name = nm,
      project_path = project,
      args_hash    = hash_args(sk$args %||% NULL),
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
  # gsub("-", "/") therefore corrupts real paths (docs_gh -> docs/gh). Every
  # record type in these transcripts (user/assistant/attachment) carries a
  # top-level `cwd` field with the real, unambiguous path, so prefer that;
  # only fall back to the (deliberately un-decoded) encoded directory name
  # when no line in the transcript carries `cwd`.
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
    if (is.null(msg) || !identical(msg$type, "attachment")) return(NULL)
    extract_command_events(msg, session_id, project)
  }))
  if (!length(events)) return(NULL)
  bind_rows(events)
}

jsonl_files <- tryCatch(dir_ls(projects_dir, recurse = TRUE, glob = "*.jsonl"),
                        error = function(e) character())
cat(sprintf("Scanning %d JSONL files under %s...\n", length(jsonl_files), projects_dir))

parsed  <- compact(map(jsonl_files, parse_file))
events_df <- if (length(parsed)) bind_rows(parsed) else tibble(
  session_id = character(), command_name = character(),
  project_path = character(), args_hash = character(), ts = character()
)

cat(sprintf("Found %d historical slash-command invocations across %d files\n",
            nrow(events_df), length(jsonl_files)))

if (nrow(events_df) > 0) {
  cat("\nTop commands by historical invocation count:\n")
  events_df |> count(command_name, sort = TRUE) |> print(n = 20L)
}

if (dry_run) {
  cat("\nDRY RUN — pass --apply to write to DB\n")
  quit(status = 0L)
}

# ── DB write ──────────────────────────────────────────────────────────────────
con <- dbConnect(duckdb(), db_path)
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

invisible(dbExecute(con, "
  CREATE TABLE IF NOT EXISTS command_usage (
    session_id   VARCHAR,
    command_name VARCHAR,
    project_path VARCHAR,
    args_hash    VARCHAR,
    ts           TIMESTAMP,
    backfilled   BOOLEAN DEFAULT FALSE
  )"))

if (nrow(events_df) > 0) {
  # Register the candidate rows in a temp view, then insert only the ones
  # not already present (dedupe on session_id, command_name, ts) — idempotent.
  events_df <- events_df |>
    mutate(ts = as.character(ts), backfilled = TRUE) |>
    filter(!is.na(ts), nzchar(ts))

  dbWriteTable(con, "command_usage_backfill_staging", events_df, overwrite = TRUE)

  n_inserted <- dbExecute(con, "
    INSERT INTO command_usage (session_id, command_name, project_path, args_hash, ts, backfilled)
    SELECT
      s.session_id, s.command_name, s.project_path, s.args_hash,
      CAST(s.ts AS TIMESTAMP) AS ts, TRUE
    FROM command_usage_backfill_staging s
    WHERE NOT EXISTS (
      SELECT 1 FROM command_usage u
      WHERE u.session_id = s.session_id
        AND u.command_name = s.command_name
        AND date_trunc('second', u.ts) = date_trunc('second', CAST(s.ts AS TIMESTAMP))
        AND COALESCE(u.args_hash, '') = COALESCE(s.args_hash, '')
    )
  ")
  invisible(dbExecute(con, "DROP TABLE IF EXISTS command_usage_backfill_staging"))
  cat(sprintf("Inserted %d new rows (skipped duplicates already present)\n", n_inserted))
}

# ── etl_freshness registration (defensive re: #309 Card 1a coordination) ────
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
            c("command_usage", shQuote(db_path), "", "--table", "command_usage", "--ts-col", "ts"),
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
    SELECT 'command_usage', (SELECT MAX(ts) FROM command_usage), current_timestamp, NULL, 'unknown'
  "))
}

final_count <- dbGetQuery(con, "SELECT COUNT(*) AS n FROM command_usage")$n
cat(sprintf("\nDone. command_usage now has %d total rows. DB: %s\n", final_count, db_path))
