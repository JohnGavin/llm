#!/usr/bin/env Rscript
# skill_usage_etl.R — comprehensive config-usage ETL for the llm project.
#
# Parses ~/.claude/projects/**/*.jsonl to extract:
#   - Skill tool invocations     → skill_usage table
#   - Agent tool dispatches      → agent_usage table
#   - Read/Edit/Write to .claude → config_access table
# Scans filesystem for:
#   - .claude/skills/, rules/, memory/, hooks/ → config_inventory table
#
# Staleness view (config_staleness) is created/replaced on each run.
#
# Args:
#   --apply              write to DB (default: dry-run, print only)
#   --since YYYY-MM-DD   scan JSONL files modified on or after this date
#                        (default: yesterday)
#   --all                scan ALL JSONL files regardless of mtime
#   --db PATH            DuckDB file path
#                        (default: ~/.claude/logs/unified.duckdb)
#   --inventory-only     skip JSONL parsing; refresh config_inventory only
#
# Tables written:
#   skill_usage(session_id, session_date, project, skill_name,
#               invocations, etl_run_at)
#   agent_usage(session_id, session_date, project, agent_type,
#               model, has_isolation, dispatches, etl_run_at)
#   config_access(session_id, session_date, project, file_path,
#                 access_type, accesses, etl_run_at)
#   config_inventory(item_type, name, file_path, file_size_bytes,
#                    last_modified, has_paths_scope, etl_run_at)
#
# View created:
#   config_staleness — joins inventory with usage; flags never_used /
#                      stale_90d / stale_30d / active per item

suppressPackageStartupMessages({
  library(jsonlite)
  library(dplyr)
  library(duckdb)
  library(purrr)
  library(fs)
  library(tibble)
  library(tidyr)
  library(stringr)
})

# ── Args ──────────────────────────────────────────────────────────────────────
args           <- commandArgs(trailingOnly = TRUE)
dry_run        <- !"--apply" %in% args
scan_all       <- "--all" %in% args
inventory_only <- "--inventory-only" %in% args

since_idx <- which(args == "--since") + 1L
since     <- if (length(since_idx) && since_idx <= length(args))
               as.Date(args[[since_idx]]) else Sys.Date() - 1L

db_idx  <- which(args == "--db") + 1L
db_path <- if (length(db_idx) && db_idx <= length(args))
             args[[db_idx]] else path.expand("~/.claude/logs/unified.duckdb")

llm_root     <- path.expand("~/docs_gh/llm")
projects_dir <- path.expand("~/.claude/projects")

cat(sprintf(
  "skill_usage_etl: dry_run=%s scan_all=%s inventory_only=%s since=%s db=%s\n",
  dry_run, scan_all, inventory_only, since, db_path
))

# ── JSONL parsing ─────────────────────────────────────────────────────────────

# Parse one message block for tool calls we care about.
# Returns a named list: skills, agents, config_reads
extract_tool_calls <- function(msg, session_id, session_date, project) {
  content <- msg$message$content
  if (!is.list(content)) return(NULL)

  skills  <- character()
  agents  <- list()
  configs <- list()

  for (block in content) {
    if (!identical(block$type, "tool_use")) next
    nm <- block$name %||% ""

    if (identical(nm, "Skill")) {
      sn <- block$input$skill %||% "unknown"
      if (!nzchar(sn)) sn <- "unknown"
      skills <- c(skills, sn)

    } else if (identical(nm, "Agent")) {
      agents[[length(agents) + 1L]] <- list(
        agent_type    = block$input$subagent_type %||% "general-purpose",
        model         = block$input$model %||% NA_character_,
        has_isolation = identical(block$input$isolation, "worktree")
      )

    } else if (nm %in% c("Read", "Edit", "Write")) {
      fp <- block$input$file_path %||% block$input$path %||% ""
      if (nzchar(fp) && str_detect(fp, fixed(".claude/"))) {
        configs[[length(configs) + 1L]] <- list(
          file_path   = fp,
          access_type = tolower(nm)
        )
      }
    }
  }

  list(skills = skills, agents = agents, configs = configs,
       session_id = session_id, session_date = session_date, project = project)
}

parse_file <- function(path) {
  lines <- tryCatch(readLines(path, warn = FALSE), error = function(e) character())
  if (!length(lines)) return(NULL)

  project_enc <- basename(dirname(as.character(path)))
  project     <- sub("^-", "/", gsub("-", "/", project_enc))
  session_id  <- tools::file_path_sans_ext(basename(as.character(path)))
  session_date <- as.Date(NA_character_)

  all_skills  <- character()
  all_agents  <- list()
  all_configs <- list()

  for (line in lines) {
    msg <- tryCatch(fromJSON(line, simplifyVector = FALSE), error = function(e) NULL)
    if (is.null(msg)) next
    if (is.na(session_date) && !is.null(msg$timestamp))
      session_date <- tryCatch(as.Date(substr(msg$timestamp, 1L, 10L)),
                               error = function(e) as.Date(NA_character_))
    if (!identical(msg$type, "assistant")) next
    r <- extract_tool_calls(msg, session_id, session_date %||% Sys.Date(), project)
    if (is.null(r)) next
    all_skills  <- c(all_skills, r$skills)
    all_agents  <- c(all_agents, r$agents)
    all_configs <- c(all_configs, r$configs)
  }

  if (!nzchar(session_id)) return(NULL)
  sd <- if (is.na(session_date)) Sys.Date() else session_date

  list(
    session_id   = session_id,
    session_date = sd,
    project      = project,
    skills       = all_skills,
    agents       = all_agents,
    configs      = all_configs
  )
}

# ── Filesystem inventory ───────────────────────────────────────────────────────

build_config_inventory <- function(llm_root) {
  now <- Sys.time()

  scan_dir <- function(dir, item_type, glob = "*.md") {
    p <- path(llm_root, dir)
    if (!dir_exists(p)) return(tibble())
    files <- dir_ls(p, recurse = TRUE, glob = glob)
    if (!length(files)) return(tibble())
    info <- file_info(files)
    tibble(
      item_type       = item_type,
      name            = tools::file_path_sans_ext(basename(as.character(files))),
      file_path       = as.character(files),
      file_size_bytes = as.integer(info$size),
      last_modified   = as.Date(info$modification_time),
      has_paths_scope = NA  # filled below for rules
    )
  }

  skills  <- scan_dir(".claude/skills",  "skill",  "*.md")
  rules   <- scan_dir(".claude/rules",   "rule",   "*.md")
  memory  <- scan_dir(".claude/memory",  "memory", "*.md")
  hooks   <- scan_dir(".claude/hooks",   "hook",   "*.sh")
  scripts <- scan_dir(".claude/scripts", "script", "*.sh")

  # For rules: check if the file has a `paths:` key in YAML frontmatter
  if (nrow(rules) > 0) {
    rules$has_paths_scope <- map_lgl(rules$file_path, function(fp) {
      tryCatch({
        hd <- readLines(fp, n = 20L, warn = FALSE)
        # frontmatter is between the first two "---" lines
        dashes <- which(hd == "---")
        if (length(dashes) < 2L) return(FALSE)
        fm <- hd[seq(dashes[[1L]] + 1L, dashes[[2L]] - 1L)]
        any(str_starts(fm, "paths:"))
      }, error = function(e) FALSE)
    })
  }

  bind_rows(skills, rules, memory, hooks, scripts) |>
    mutate(etl_run_at = now)
}

# ── Aggregate helpers ─────────────────────────────────────────────────────────

agg_skills <- function(parsed) {
  rows <- compact(map(parsed, function(p) {
    if (!length(p$skills)) return(NULL)
    tibble(session_id = p$session_id, session_date = p$session_date,
           project = p$project, skill_name = p$skills)
  }))
  if (!length(rows)) return(tibble())
  bind_rows(rows) |>
    count(session_date, project, skill_name, session_id, name = "invocations") |>
    mutate(etl_run_at = Sys.time())
}

agg_agents <- function(parsed) {
  rows <- compact(map(parsed, function(p) {
    if (!length(p$agents)) return(NULL)
    bind_rows(map(p$agents, as_tibble)) |>
      mutate(session_id = p$session_id, session_date = p$session_date,
             project = p$project)
  }))
  if (!length(rows)) return(tibble())
  bind_rows(rows) |>
    count(session_date, project, agent_type, model, has_isolation, session_id,
          name = "dispatches") |>
    mutate(etl_run_at = Sys.time())
}

agg_configs <- function(parsed) {
  rows <- compact(map(parsed, function(p) {
    if (!length(p$configs)) return(NULL)
    bind_rows(map(p$configs, as_tibble)) |>
      mutate(session_id = p$session_id, session_date = p$session_date,
             project = p$project)
  }))
  if (!length(rows)) return(tibble())
  bind_rows(rows) |>
    count(session_date, project, file_path, access_type, session_id,
          name = "accesses") |>
    mutate(etl_run_at = Sys.time())
}

# ── Staleness view DDL ────────────────────────────────────────────────────────

STALENESS_VIEW_DDL <- "
CREATE OR REPLACE VIEW config_staleness AS
WITH skill_agg AS (
  SELECT skill_name AS name, 'skill' AS usage_table,
         MAX(session_date)           AS last_used,
         COUNT(DISTINCT session_id)  AS session_count,
         SUM(invocations)            AS total_invocations,
         SUM(CASE WHEN session_date >= CURRENT_DATE - 30  THEN invocations ELSE 0 END) AS inv_last_30d,
         SUM(CASE WHEN session_date >= CURRENT_DATE - 90  THEN invocations ELSE 0 END) AS inv_last_90d
  FROM skill_usage GROUP BY skill_name
),
agent_agg AS (
  SELECT agent_type AS name, 'agent' AS usage_table,
         MAX(session_date)           AS last_used,
         COUNT(DISTINCT session_id)  AS session_count,
         SUM(dispatches)             AS total_invocations,
         SUM(CASE WHEN session_date >= CURRENT_DATE - 30  THEN dispatches ELSE 0 END) AS inv_last_30d,
         SUM(CASE WHEN session_date >= CURRENT_DATE - 90  THEN dispatches ELSE 0 END) AS inv_last_90d
  FROM agent_usage GROUP BY agent_type
),
config_agg AS (
  SELECT regexp_replace(file_path, '.*/\\.claude/(rules|memory|hooks|scripts)/', '') AS name,
         'config' AS usage_table,
         MAX(session_date)          AS last_used,
         COUNT(DISTINCT session_id) AS session_count,
         SUM(accesses)              AS total_invocations,
         SUM(CASE WHEN session_date >= CURRENT_DATE - 30 THEN accesses ELSE 0 END) AS inv_last_30d,
         SUM(CASE WHEN session_date >= CURRENT_DATE - 90 THEN accesses ELSE 0 END) AS inv_last_90d
  FROM config_access GROUP BY regexp_replace(file_path, '.*/\\.claude/(rules|memory|hooks|scripts)/', '')
),
usage AS (
  SELECT * FROM skill_agg
  UNION ALL SELECT * FROM agent_agg
  UNION ALL SELECT * FROM config_agg
)
SELECT
  i.item_type,
  i.name,
  i.file_path,
  i.file_size_bytes,
  i.last_modified                                          AS file_last_modified,
  i.has_paths_scope,
  u.last_used,
  u.session_count,
  u.total_invocations,
  u.inv_last_30d,
  u.inv_last_90d,
  CASE
    WHEN u.last_used IS NULL                                    THEN 'never_used'
    WHEN u.last_used < CURRENT_DATE - 90                       THEN 'stale_90d'
    WHEN u.last_used < CURRENT_DATE - 30                       THEN 'stale_30d'
    WHEN u.last_used < CURRENT_DATE - 7                        THEN 'stale_7d'
    ELSE                                                              'active'
  END                                                      AS staleness_status,
  DATEDIFF('day', u.last_used, CURRENT_DATE)              AS days_since_last_use
FROM config_inventory i
LEFT JOIN usage u ON lower(i.name) = lower(u.name)
ORDER BY i.item_type, staleness_status DESC, i.name
"

# ── DB helpers ────────────────────────────────────────────────────────────────

ensure_tables <- function(con) {
  dbExecute(con, "
    CREATE TABLE IF NOT EXISTS skill_usage (
      session_id TEXT, session_date DATE, project TEXT,
      skill_name TEXT, invocations INTEGER, etl_run_at TIMESTAMP
    )")
  dbExecute(con, "
    CREATE TABLE IF NOT EXISTS agent_usage (
      session_id TEXT, session_date DATE, project TEXT,
      agent_type TEXT, model TEXT, has_isolation BOOLEAN,
      dispatches INTEGER, etl_run_at TIMESTAMP
    )")
  dbExecute(con, "
    CREATE TABLE IF NOT EXISTS config_access (
      session_id TEXT, session_date DATE, project TEXT,
      file_path TEXT, access_type TEXT,
      accesses INTEGER, etl_run_at TIMESTAMP
    )")
  dbExecute(con, "
    CREATE TABLE IF NOT EXISTS config_inventory (
      item_type TEXT, name TEXT, file_path TEXT,
      file_size_bytes INTEGER, last_modified DATE,
      has_paths_scope BOOLEAN, etl_run_at TIMESTAMP
    )")
}

upsert_by_sessions <- function(con, table, df, key_col = "session_id") {
  if (nrow(df) == 0) return(invisible(NULL))
  ids <- paste0("'", unique(df[[key_col]]), "'", collapse = ", ")
  dbExecute(con, sprintf("DELETE FROM %s WHERE %s IN (%s)", table, key_col, ids))
  dbAppendTable(con, table, df)
  cat(sprintf("  %s: wrote %d rows\n", table, nrow(df)))
}

# ── Main ──────────────────────────────────────────────────────────────────────

# Inventory (always refreshed — fast filesystem scan)
cat("Building config_inventory from filesystem...\n")
inventory <- build_config_inventory(llm_root)
cat(sprintf("  %d items found (%s)\n", nrow(inventory),
            paste(sort(unique(inventory$item_type)), collapse = ", ")))

# JSONL parsing (skip if --inventory-only)
skills_df <- tibble(); agents_df <- tibble(); configs_df <- tibble()

if (!inventory_only) {
  jsonl_files <- dir_ls(projects_dir, recurse = TRUE, glob = "*.jsonl")
  if (!scan_all) {
    mtimes <- file_info(jsonl_files)$modification_time
    jsonl_files <- jsonl_files[!is.na(mtimes) & mtimes >= as.POSIXct(since)]
  }
  cat(sprintf("Scanning %d JSONL files...\n", length(jsonl_files)))

  parsed <- compact(map(jsonl_files, parse_file))

  skills_df  <- agg_skills(parsed)
  agents_df  <- agg_agents(parsed)
  configs_df <- agg_configs(parsed)

  cat(sprintf(
    "Found: %d skill records, %d agent records, %d config-access records\n",
    nrow(skills_df), nrow(agents_df), nrow(configs_df)
  ))

  # Print staleness preview (top stale by item type)
  if (nrow(skills_df) > 0) {
    cat("\nTop skills by invocations:\n")
    skills_df |>
      count(skill_name, wt = invocations, name = "total") |>
      arrange(desc(total)) |>
      print(n = 20L)
  }
  if (nrow(agents_df) > 0) {
    cat("\nAgent dispatches:\n")
    agents_df |>
      count(agent_type, wt = dispatches, name = "total") |>
      arrange(desc(total)) |>
      print(n = 20L)
  }
}

if (dry_run) {
  cat("\nDRY RUN — pass --apply to write to DB\n")
  quit(status = 0L)
}

# Write to DuckDB
con <- dbConnect(duckdb(), db_path)
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

ensure_tables(con)

# Inventory: full replace on every run (filesystem is authoritative)
dbExecute(con, "DELETE FROM config_inventory")
dbAppendTable(con, "config_inventory", inventory)
cat(sprintf("  config_inventory: wrote %d rows\n", nrow(inventory)))

if (!inventory_only) {
  upsert_by_sessions(con, "skill_usage",  skills_df)
  upsert_by_sessions(con, "agent_usage",  agents_df)
  upsert_by_sessions(con, "config_access", configs_df)
}

# Recreate staleness view
dbExecute(con, STALENESS_VIEW_DDL)
cat("  config_staleness view: refreshed\n")

cat(sprintf("\nDone. DB: %s\n", db_path))
