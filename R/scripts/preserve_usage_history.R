#!/usr/bin/env Rscript
# preserve_usage_history.R
# Preserves complete history of LLM usage data by merging new data with historical records
# Handles deduplication and tracks data sources (ccusage vs cmonitor)

library(DBI)
library(duckdb)
library(jsonlite)
library(dplyr)
library(tidyr)
library(lubridate)
library(logger)

# Setup logging
log_appender(appender_file("inst/logs/preserve_history.log"))
log_info("=== Starting usage history preservation ===")

# Database path for persistent storage
DB_PATH <- "inst/extdata/llm_usage_history.duckdb"
dir.create("inst/extdata", recursive = TRUE, showWarnings = FALSE)

# Initialize DuckDB connection
con <- dbConnect(duckdb(), dbdir = DB_PATH)
log_info("Connected to DuckDB: {DB_PATH}")

# Create tables if they don't exist
create_tables <- function(con) {
  # Daily usage table with source tracking
  dbExecute(con, "
    CREATE TABLE IF NOT EXISTS daily_usage (
      date DATE NOT NULL,
      project VARCHAR NOT NULL,
      input_tokens BIGINT,
      output_tokens BIGINT,
      cache_creation_tokens BIGINT,
      cache_read_tokens BIGINT,
      total_tokens BIGINT,
      total_cost DOUBLE,
      models_used VARCHAR,
      data_source VARCHAR NOT NULL,
      collected_at TIMESTAMP NOT NULL,
      PRIMARY KEY (date, project, data_source)
    )
  ")

  # Session usage table
  dbExecute(con, "
    CREATE TABLE IF NOT EXISTS session_usage (
      session_id VARCHAR NOT NULL,
      project VARCHAR,
      started_at TIMESTAMP,
      duration_minutes INTEGER,
      input_tokens BIGINT,
      output_tokens BIGINT,
      cache_creation_tokens BIGINT,
      cache_read_tokens BIGINT,
      total_tokens BIGINT,
      total_cost DOUBLE,
      data_source VARCHAR NOT NULL,
      collected_at TIMESTAMP NOT NULL,
      PRIMARY KEY (session_id, data_source)
    )
  ")

  # Metadata table for tracking collection runs
  dbExecute(con, "
    CREATE TABLE IF NOT EXISTS collection_metadata (
      collected_at TIMESTAMP PRIMARY KEY,
      data_source VARCHAR NOT NULL,
      records_added INTEGER,
      date_range_start DATE,
      date_range_end DATE,
      notes VARCHAR
    )
  ")

  log_info("Database tables ready")
}

# Function to fetch and parse ccusage data
fetch_ccusage_data <- function(type = "daily") {
  log_info("Fetching {type} data from ccusage")

  cmd <- sprintf("npx ccusage %s --json --instances", type)
  if (type == "blocks") {
    cmd <- paste(cmd, "--breakdown")
  }

  tryCatch({
    tmp_file <- tempfile(fileext = ".json")
    on.exit(unlink(tmp_file), add = TRUE)

    exit_code <- system(paste(cmd, ">", shQuote(tmp_file), "2>/dev/null"))
    if (exit_code != 0) {
      log_warn("ccusage command failed with exit code {exit_code}")
      return(NULL)
    }

    json_text <- paste(readLines(tmp_file, warn = FALSE), collapse = "\n")
    json_start <- regexpr("\\{", json_text)
    if (json_start > 0) {
      json_text <- substring(json_text, json_start)
    }

    fromJSON(json_text)
  }, error = function(e) {
    log_error("Failed to fetch {type} data: {e$message}")
    NULL
  })
}

# Process and store daily usage data
process_daily_usage <- function(con, data, source = "ccusage") {
  if (is.null(data$projects)) {
    log_warn("No projects data found")
    return(0)
  }

  collected_at <- Sys.time()
  records_added <- 0

  for (project_name in names(data$projects)) {
    project_data <- data$projects[[project_name]]

    if (is.data.frame(project_data) && nrow(project_data) > 0) {
      # Prepare data for insertion
      df <- project_data %>%
        mutate(
          project = project_name,
          data_source = source,
          collected_at = collected_at,
          # Convert lists to JSON strings for models_used
          models_used = ifelse(
            "modelsUsed" %in% names(.),
            sapply(modelsUsed, function(x) toJSON(x, auto_unbox = TRUE)),
            NA_character_
          )
        ) %>%
        select(
          date, project,
          input_tokens = inputTokens,
          output_tokens = outputTokens,
          cache_creation_tokens = cacheCreationTokens,
          cache_read_tokens = cacheReadTokens,
          total_tokens = totalTokens,
          total_cost = totalCost,
          models_used,
          data_source,
          collected_at
        )

      # Upsert data (INSERT OR REPLACE)
      for (i in 1:nrow(df)) {
        row <- df[i, ]

        # Check if record exists
        existing <- dbGetQuery(con, "
          SELECT 1 FROM daily_usage
          WHERE date = ? AND project = ? AND data_source = ?
        ", list(row$date, row$project, row$data_source))

        if (nrow(existing) == 0) {
          # Insert new record
          dbExecute(con, "
            INSERT INTO daily_usage VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ", as.list(row))
          records_added <- records_added + 1
        } else {
          # Update existing record only if newer data has higher token counts
          dbExecute(con, "
            UPDATE daily_usage
            SET input_tokens = ?, output_tokens = ?,
                cache_creation_tokens = ?, cache_read_tokens = ?,
                total_tokens = ?, total_cost = ?,
                models_used = ?, collected_at = ?
            WHERE date = ? AND project = ? AND data_source = ?
            AND total_tokens <= ?
          ", list(
            row$input_tokens, row$output_tokens,
            row$cache_creation_tokens, row$cache_read_tokens,
            row$total_tokens, row$total_cost,
            row$models_used, row$collected_at,
            row$date, row$project, row$data_source,
            row$total_tokens
          ))
        }
      }
    }
  }

  log_info("Added {records_added} new daily records from {source}")
  return(records_added)
}

# Process session data
process_session_usage <- function(con, data, source = "ccusage") {
  if (is.null(data$sessions)) {
    log_warn("No sessions data found")
    return(0)
  }

  collected_at <- Sys.time()
  records_added <- 0

  sessions_df <- as_tibble(data$sessions) %>%
    mutate(
      data_source = source,
      collected_at = collected_at,
      # Parse timestamps if they're strings
      started_at = ymd_hms(startedAt, quiet = TRUE),
      duration_minutes = as.integer(durationMinutes)
    ) %>%
    select(
      session_id = id,
      project = projectId,
      started_at,
      duration_minutes,
      input_tokens = inputTokens,
      output_tokens = outputTokens,
      cache_creation_tokens = cacheCreationTokens,
      cache_read_tokens = cacheReadTokens,
      total_tokens = totalTokens,
      total_cost = totalCost,
      data_source,
      collected_at
    )

  # Insert new sessions
  for (i in 1:nrow(sessions_df)) {
    row <- sessions_df[i, ]

    existing <- dbGetQuery(con, "
      SELECT 1 FROM session_usage
      WHERE session_id = ? AND data_source = ?
    ", list(row$session_id, row$data_source))

    if (nrow(existing) == 0) {
      dbExecute(con, "
        INSERT INTO session_usage VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ", as.list(row))
      records_added <- records_added + 1
    }
  }

  log_info("Added {records_added} new session records from {source}")
  return(records_added)
}

# Export current complete history to JSON for email script compatibility
export_to_json <- function(con) {
  log_info("Exporting complete history to JSON files")

  # Export daily data - get the most recent version of each date/project combo
  daily_complete <- dbGetQuery(con, "
    WITH ranked AS (
      SELECT *,
             ROW_NUMBER() OVER (PARTITION BY date, project
                                ORDER BY collected_at DESC, total_tokens DESC) as rn
      FROM daily_usage
    )
    SELECT date, project, input_tokens, output_tokens,
           cache_creation_tokens, cache_read_tokens,
           total_tokens, total_cost, models_used, data_source
    FROM ranked
    WHERE rn = 1
    ORDER BY date DESC, project
  ")

  # Format for compatibility with existing email script
  if (nrow(daily_complete) > 0) {
    # Group by project for the expected format
    projects_list <- list()
    for (proj in unique(daily_complete$project)) {
      proj_data <- daily_complete %>%
        filter(project == proj) %>%
        select(-project) %>%
        rename(
          inputTokens = input_tokens,
          outputTokens = output_tokens,
          cacheCreationTokens = cache_creation_tokens,
          cacheReadTokens = cache_read_tokens,
          totalTokens = total_tokens,
          totalCost = total_cost,
          modelsUsed = models_used,
          dataSource = data_source
        )
      projects_list[[proj]] <- proj_data
    }

    # Calculate totals
    totals <- list(
      inputTokens = sum(daily_complete$input_tokens, na.rm = TRUE),
      outputTokens = sum(daily_complete$output_tokens, na.rm = TRUE),
      cacheCreationTokens = sum(daily_complete$cache_creation_tokens, na.rm = TRUE),
      cacheReadTokens = sum(daily_complete$cache_read_tokens, na.rm = TRUE),
      totalTokens = sum(daily_complete$total_tokens, na.rm = TRUE),
      totalCost = sum(daily_complete$total_cost, na.rm = TRUE)
    )

    daily_json <- list(
      projects = projects_list,
      totals = totals,
      generatedAt = format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
      dataSource = "preserved_history"
    )

    write_json(daily_json, "inst/extdata/ccusage_daily_all.json",
               pretty = TRUE, auto_unbox = TRUE)
    log_info("Exported {nrow(daily_complete)} daily records to JSON")
  }

  # Export session data
  sessions_complete <- dbGetQuery(con, "
    WITH ranked AS (
      SELECT *,
             ROW_NUMBER() OVER (PARTITION BY session_id
                                ORDER BY collected_at DESC) as rn
      FROM session_usage
    )
    SELECT * FROM ranked WHERE rn = 1
    ORDER BY started_at DESC
  ")

  if (nrow(sessions_complete) > 0) {
    sessions_json <- list(
      sessions = sessions_complete %>%
        rename(
          id = session_id,
          projectId = project,
          startedAt = started_at,
          durationMinutes = duration_minutes,
          inputTokens = input_tokens,
          outputTokens = output_tokens,
          cacheCreationTokens = cache_creation_tokens,
          cacheReadTokens = cache_read_tokens,
          totalTokens = total_tokens,
          totalCost = total_cost,
          dataSource = data_source
        ) %>%
        select(-collected_at, -rn),
      totals = list(
        inputTokens = sum(sessions_complete$input_tokens, na.rm = TRUE),
        outputTokens = sum(sessions_complete$output_tokens, na.rm = TRUE),
        cacheCreationTokens = sum(sessions_complete$cache_creation_tokens, na.rm = TRUE),
        cacheReadTokens = sum(sessions_complete$cache_read_tokens, na.rm = TRUE),
        totalTokens = sum(sessions_complete$total_tokens, na.rm = TRUE),
        totalCost = sum(sessions_complete$total_cost, na.rm = TRUE)
      ),
      generatedAt = format(Sys.time(), "%Y-%m-%d %H:%M:%S")
    )

    write_json(sessions_json, "inst/extdata/ccusage_session_all.json",
               pretty = TRUE, auto_unbox = TRUE)
    log_info("Exported {nrow(sessions_complete)} session records to JSON")
  }
}

# Main execution
tryCatch({
  create_tables(con)

  # Fetch and process ccusage data
  daily_data <- fetch_ccusage_data("daily")
  if (!is.null(daily_data)) {
    daily_records <- process_daily_usage(con, daily_data, "ccusage")

    # Record metadata
    if (daily_records > 0) {
      dates <- dbGetQuery(con, "
        SELECT MIN(date) as min_date, MAX(date) as max_date
        FROM daily_usage
        WHERE data_source = 'ccusage'
        AND collected_at = (SELECT MAX(collected_at) FROM daily_usage WHERE data_source = 'ccusage')
      ")

      dbExecute(con, "
        INSERT INTO collection_metadata VALUES (?, ?, ?, ?, ?, ?)
      ", list(
        Sys.time(),
        "ccusage",
        daily_records,
        dates$min_date,
        dates$max_date,
        "Automated collection"
      ))
    }
  }

  # Fetch and process session data
  session_data <- fetch_ccusage_data("session")
  if (!is.null(session_data)) {
    session_records <- process_session_usage(con, session_data, "ccusage")
  }

  # Also fetch blocks data for completeness
  blocks_data <- fetch_ccusage_data("blocks")
  if (!is.null(blocks_data)) {
    # Save blocks data as-is for now (can process later if needed)
    write_json(blocks_data, "inst/extdata/ccusage_blocks_all.json",
               pretty = TRUE, auto_unbox = TRUE)
  }

  # Export to JSON for backward compatibility
  export_to_json(con)

  # Report statistics
  stats <- dbGetQuery(con, "
    SELECT
      (SELECT COUNT(DISTINCT date || project) FROM daily_usage) as total_daily_records,
      (SELECT COUNT(DISTINCT session_id) FROM session_usage) as total_sessions,
      (SELECT MIN(date) FROM daily_usage) as earliest_date,
      (SELECT MAX(date) FROM daily_usage) as latest_date,
      (SELECT COUNT(DISTINCT data_source) FROM daily_usage) as num_sources
  ")

  log_info("=== Preservation complete ===")
  log_info("Total daily records: {stats$total_daily_records}")
  log_info("Total sessions: {stats$total_sessions}")
  log_info("Date range: {stats$earliest_date} to {stats$latest_date}")
  log_info("Data sources: {stats$num_sources}")

  # Show recent collections
  recent <- dbGetQuery(con, "
    SELECT * FROM collection_metadata
    ORDER BY collected_at DESC
    LIMIT 5
  ")

  if (nrow(recent) > 0) {
    log_info("Recent collections:")
    for (i in 1:nrow(recent)) {
      log_info("  {recent$collected_at[i]}: {recent$data_source[i]} - {recent$records_added[i]} records")
    }
  }

}, error = function(e) {
  log_error("Fatal error: {e$message}")
}, finally = {
  dbDisconnect(con)
  log_info("Database connection closed")
})