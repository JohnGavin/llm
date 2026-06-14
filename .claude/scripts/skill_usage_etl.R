#!/usr/bin/env Rscript
# skill_usage_etl.R — parse ~/.claude/projects/**/*.jsonl for Skill tool calls
# and write per-session-skill counts to unified.duckdb (skill_usage table).
#
# Args:
#   --apply              write to DB (default: dry-run)
#   --since YYYY-MM-DD   only scan JSONL files modified on or after this date
#                        (default: yesterday)
#   --db PATH            path to DuckDB file
#                        (default: ~/.claude/logs/unified.duckdb)
#   --all                scan ALL JSONL files regardless of mtime
#
# Schema (skill_usage table):
#   session_id   TEXT    — UUID from JSONL filename
#   session_date DATE    — date of first timestamped message in session
#   project      TEXT    — decoded project path from directory name
#   skill_name   TEXT    — value of Skill tool input.skill
#   invocations  INTEGER — count of Skill calls for this skill in this session
#   etl_run_at   TIMESTAMP

suppressPackageStartupMessages({
  library(jsonlite)
  library(dplyr)
  library(duckdb)
  library(purrr)
  library(fs)
  library(tibble)
})

# ── Args ──────────────────────────────────────────────────────────────────────
args      <- commandArgs(trailingOnly = TRUE)
dry_run   <- !"--apply" %in% args
scan_all  <- "--all" %in% args
since_idx <- which(args == "--since") + 1
since     <- if (length(since_idx) > 0 && since_idx <= length(args))
               as.Date(args[since_idx]) else Sys.Date() - 1
db_idx    <- which(args == "--db") + 1
db_path   <- if (length(db_idx) > 0 && db_idx <= length(args))
               args[db_idx] else path.expand("~/.claude/logs/unified.duckdb")

projects_dir <- path.expand("~/.claude/projects")

# ── Discover JSONL files ───────────────────────────────────────────────────────
jsonl_files <- dir_ls(projects_dir, recurse = TRUE, glob = "*.jsonl")
if (!scan_all) {
  mtimes <- file_info(jsonl_files)$modification_time
  jsonl_files <- jsonl_files[!is.na(mtimes) & mtimes >= as.POSIXct(since)]
}
cat(sprintf("Scanning %d JSONL files (since %s, scan_all=%s)\n",
            length(jsonl_files), since, scan_all))

# ── Parse one file ────────────────────────────────────────────────────────────
parse_file <- function(path) {
  lines <- tryCatch(readLines(path, warn = FALSE), error = function(e) character())
  if (!length(lines)) return(NULL)

  project_enc <- basename(dirname(as.character(path)))
  # Decode directory name: leading "-" removed, remaining "-" → "/" except within
  # UUID segments. Simple heuristic: replace leading hyphen-Users with /Users.
  project <- sub("^-", "/", gsub("-", "/", project_enc))

  session_id <- tools::file_path_sans_ext(basename(as.character(path)))

  # Find the first timestamp in the file for session_date
  session_date <- NA_character_
  skill_rows   <- list()

  for (line in lines) {
    msg <- tryCatch(fromJSON(line, simplifyVector = FALSE), error = function(e) NULL)
    if (is.null(msg)) next

    if (is.na(session_date) && !is.null(msg$timestamp)) {
      session_date <- substr(msg$timestamp, 1, 10)
    }

    if (!identical(msg$type, "assistant")) next
    content <- msg$message$content
    if (!is.list(content)) next

    for (block in content) {
      if (!identical(block$type, "tool_use")) next
      if (!identical(block$name, "Skill"))    next
      sn <- block$input$skill
      if (is.null(sn) || !nzchar(sn)) sn <- "unknown"
      skill_rows[[length(skill_rows) + 1]] <- sn
    }
  }

  if (!length(skill_rows)) return(NULL)

  sd <- tryCatch(as.Date(session_date), error = function(e) Sys.Date())
  if (is.na(sd)) sd <- Sys.Date()

  tibble(
    session_id   = session_id,
    session_date = sd,
    project      = project,
    skill_name   = unlist(skill_rows)
  )
}

# ── Run over all files ─────────────────────────────────────────────────────────
results <- map(jsonl_files, parse_file)
df      <- bind_rows(compact(results))

if (nrow(df) == 0) {
  cat("No skill invocations found in scan window — nothing to do.\n")
  quit(status = 0)
}

# ── Aggregate ─────────────────────────────────────────────────────────────────
agg <- df |>
  count(session_date, project, skill_name, session_id, name = "invocations") |>
  mutate(etl_run_at = Sys.time())

cat(sprintf("\nFound %d records (%d unique skills, %d sessions):\n",
            nrow(agg), n_distinct(agg$skill_name), n_distinct(agg$session_id)))
agg |>
  count(skill_name, wt = invocations, name = "total") |>
  arrange(desc(total)) |>
  print(n = 50)

if (dry_run) {
  cat("\nDRY RUN — pass --apply to write to DB\n")
  quit(status = 0)
}

# ── Write to DuckDB ───────────────────────────────────────────────────────────
con <- dbConnect(duckdb(), db_path)
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

dbExecute(con, "
  CREATE TABLE IF NOT EXISTS skill_usage (
    session_id   TEXT      NOT NULL,
    session_date DATE      NOT NULL,
    project      TEXT      NOT NULL,
    skill_name   TEXT      NOT NULL,
    invocations  INTEGER   NOT NULL,
    etl_run_at   TIMESTAMP NOT NULL
  )
")

# Upsert: delete existing rows for this batch of sessions, then re-insert
ids_sql <- paste0("'", unique(agg$session_id), "'", collapse = ", ")
dbExecute(con, sprintf("DELETE FROM skill_usage WHERE session_id IN (%s)", ids_sql))
dbAppendTable(con, "skill_usage", agg)
cat(sprintf("Wrote %d rows to skill_usage in %s\n", nrow(agg), db_path))
