#!/usr/bin/env Rscript
# Import existing JSON cache files into DuckDB for historical preservation
# This ensures we don't lose data that falls outside ccusage's rolling window

library(DBI)
library(duckdb)
library(jsonlite)
library(dplyr)

# Define null-coalescing operator
`%||%` <- function(x, y) if (is.null(x) || is.na(x)) y else x

message("=== Importing existing data to DuckDB ===")

# Database path
DB_PATH <- "inst/extdata/llm_usage_history.duckdb"
dir.create("inst/extdata", recursive = TRUE, showWarnings = FALSE)

# Connect to DuckDB
con <- dbConnect(duckdb(), dbdir = DB_PATH)

# Create tables
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

message("Database tables created")

# Import existing daily data
if (file.exists("inst/extdata/ccusage_daily_all.json")) {
  message("Importing existing daily data...")

  daily_json <- fromJSON("inst/extdata/ccusage_daily_all.json")

  if (!is.null(daily_json$projects)) {
    records_added <- 0

    for (project_name in names(daily_json$projects)) {
      project_data <- daily_json$projects[[project_name]]

      if (is.data.frame(project_data) && nrow(project_data) > 0) {
        for (i in 1:nrow(project_data)) {
          row <- project_data[i, ]

          # Format SQL with values directly (avoiding parameter issues)
          sql <- sprintf("
            INSERT OR REPLACE INTO daily_usage VALUES (
              '%s', '%s', %s, %s, %s, %s, %s, %f, '%s', 'ccusage_import', CURRENT_TIMESTAMP
            )",
            row$date,
            project_name,
            as.integer(row$inputTokens %||% 0),
            as.integer(row$outputTokens %||% 0),
            as.integer(row$cacheCreationTokens %||% 0),
            as.integer(row$cacheReadTokens %||% 0),
            as.integer(row$totalTokens %||% 0),
            as.numeric(row$totalCost %||% 0),
            ifelse(is.null(row$modelsUsed), "NULL",
                   gsub("'", "''", toJSON(row$modelsUsed, auto_unbox = TRUE)))
          )

          dbExecute(con, sql)
          records_added <- records_added + 1
        }
      }
    }

    message(sprintf("Imported %d daily records", records_added))
  }
}

# Import existing session data
if (file.exists("inst/extdata/ccusage_session_all.json")) {
  message("Importing existing session data...")

  session_json <- fromJSON("inst/extdata/ccusage_session_all.json")

  if (!is.null(session_json$sessions)) {
    sessions <- session_json$sessions
    records_added <- 0

    for (i in 1:nrow(sessions)) {
      row <- sessions[i, ]

      # Handle potential NULLs and ensure single values
      session_id <- as.character(row$id)[1]
      project_id <- ifelse(is.null(row$projectId) || is.na(row$projectId),
                           "unknown", as.character(row$projectId)[1])
      started_at <- ifelse(is.null(row$startedAt) || is.na(row$startedAt),
                           "1970-01-01", as.character(row$startedAt)[1])
      duration <- as.integer(ifelse(is.null(row$durationMinutes) || is.na(row$durationMinutes),
                                    0, row$durationMinutes))[1]

      # Format SQL with values directly
      sql <- sprintf("
        INSERT OR REPLACE INTO session_usage VALUES (
          '%s', '%s', '%s', %d, %s, %s, %s, %s, %s, %f, 'ccusage_import', CURRENT_TIMESTAMP
        )",
        session_id,
        project_id,
        started_at,
        duration,
        as.integer(row$inputTokens %||% 0),
        as.integer(row$outputTokens %||% 0),
        as.integer(row$cacheCreationTokens %||% 0),
        as.integer(row$cacheReadTokens %||% 0),
        as.integer(row$totalTokens %||% 0),
        as.numeric(row$totalCost %||% 0)
      )

      dbExecute(con, sql)
      records_added <- records_added + 1
    }

    message(sprintf("Imported %d session records", records_added))
  }
}

# Check what we have
stats <- dbGetQuery(con, "
  SELECT
    'daily' as table_name,
    COUNT(*) as records,
    MIN(date) as earliest,
    MAX(date) as latest
  FROM daily_usage
  UNION ALL
  SELECT
    'sessions' as table_name,
    COUNT(*) as records,
    MIN(DATE(started_at)) as earliest,
    MAX(DATE(started_at)) as latest
  FROM session_usage
")

message("\n=== Import Summary ===")
print(stats)

# Show a sample of daily data
sample_daily <- dbGetQuery(con, "
  SELECT date, project, total_tokens, total_cost
  FROM daily_usage
  ORDER BY date DESC
  LIMIT 5
")

message("\nSample of recent daily data:")
print(sample_daily)

dbDisconnect(con)
message("\nImport complete. Database saved to: ", DB_PATH)