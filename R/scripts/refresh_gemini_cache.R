# refresh_gemini_cache.R
# Incremental refresh of Gemini usage data from local session logs
# Part of the 12-hourly automation job

library(DBI)
library(duckdb)
library(jsonlite)
library(dplyr)
library(lubridate)
library(purrr)
library(fs)
library(arrow)

message("Starting Gemini usage refresh...")

# --- Configuration ---
LOGS_DIR <- path_expand("~/.gemini/tmp")
DB_PATH <- "inst/extdata/gemini_usage.duckdb"
PARQUET_DIR <- "inst/extdata/gemini/messages"
dir_create(PARQUET_DIR, recurse = TRUE)

# Pricing Table (USD per 1M tokens)
# Ref: January 2026 Pay-as-you-go rates
PRICING <- list(
  "gemini-1.5-flash" = list(input = 0.075, output = 0.30, cached = 0.01875),
  "gemini-2.0-flash" = list(input = 0.100, output = 0.40, cached = 0.025),
  "gemini-3-flash-preview" = list(input = 0.500, output = 3.00, cached = 0.050),
  "gemini-3-pro-preview" = list(input = 2.000, output = 12.00, cached = 0.200)
)

calculate_cost <- function(model, input, output, cached) {
  # Default to 1.5 flash if model unknown
  m_key <- names(PRICING)[sapply(names(PRICING), function(k) grepl(k, model))]
  rates <- if(length(m_key) > 0) PRICING[[m_key[1]]] else PRICING[["gemini-1.5-flash"]]
  (input * rates$input + output * rates$output + cached * rates$cached) / 1e6
}

# --- Database Setup ---
con <- dbConnect(duckdb(), dbdir = DB_PATH)

# Create tables for summaries (These ARE committed to Git)
dbExecute(con, "
  CREATE TABLE IF NOT EXISTS sessions_summary (
    sessionId VARCHAR PRIMARY KEY,
    title VARCHAR,
    project VARCHAR,
    total_tokens BIGINT,
    total_cost DOUBLE,
    start_time TIMESTAMP,
    last_updated TIMESTAMP
  )
")

dbExecute(con, "
  CREATE TABLE IF NOT EXISTS daily_usage (
    date DATE PRIMARY KEY,
    total_tokens BIGINT,
    total_cost DOUBLE,
    message_count INT
  )
")

# --- Scanning Logs ---
message("Scanning for session files...")
session_files <- dir_ls(LOGS_DIR, recurse = TRUE, regexp = "session-.*\\.json$")

# Load existing session IDs to avoid re-parsing
existing_sessions <- dbGetQuery(con, "SELECT sessionId, last_updated FROM sessions_summary")

new_messages_list <- list()

for (f in session_files) {
  # Quick check: has the file changed since last update?
  mtime <- file_info(f)$modification_time
  
  # Extract sessionId from filename (e.g. session-2026-01-13T12-39-ce182e3b.json)
  fname <- path_file(f)
  sid_match <- regexec("session-(.*)\\.json", fname)
  if (sid_match[[1]][1] == -1) next
  sid <- regmatches(fname, sid_match)[[1]][2]
  
  # Check if we already have this session up to date
  prev_update <- existing_sessions$last_updated[existing_sessions$sessionId == sid]
  if (length(prev_update) > 0 && mtime <= prev_update) next
  
  message("Parsing session: ", sid)
  
  session_data <- tryCatch({
    fromJSON(f, simplifyVector = FALSE)
  }, error = function(e) NULL)
  
  if (is.null(session_data)) next
  
  # Process messages
  messages <- session_data$messages %||% session_data
  if (!is.list(messages)) next
  
  for (msg in messages) {
    # Skip non-list elements (metadata/garbage)
    if (!is.list(msg) || is.null(msg$tokens)) next
    
    # Extract data
    timestamp <- ymd_hms(msg$timestamp)
    model <- msg$model %||% "gemini-1.5-flash"
    input <- as.numeric(msg$tokens$input %||% 0)
    output <- as.numeric(msg$tokens$output %||% 0)
    cached <- as.numeric(msg$tokens$cached %||% 0)
    cost <- calculate_cost(model, input, output, cached)
    
    # Create record
    msg_row <- tibble(
      timestamp = timestamp,
      sessionId = sid,
      messageId = msg$id %||% NA,
      role = msg$type %||% "unknown",
      model = model,
      input_tokens = input,
      output_tokens = output,
      cached_tokens = cached,
      cost_usd = cost,
      date = as.Date(timestamp),
      year = year(timestamp),
      month = month(timestamp)
    )
    
    new_messages_list[[length(new_messages_list) + 1]] <- msg_row
  }
}

if (length(new_messages_list) > 0) {
  all_new_msgs <- bind_rows(new_messages_list)
  
  # 1. Update Parquet (Partitioned) - Local only, gitignored
  message("Exporting new messages to Parquet...")
  # We use write_dataset for automatic partitioning
  write_dataset(all_new_msgs, PARQUET_DIR, format = "parquet", 
                partitioning = c("year", "month"),
                existing_data_behavior = "overwrite")
  
  # 2. Update DuckDB Summaries (Publicly shareable)
  message("Updating DuckDB summaries...")
  
  # Session aggregation
  session_agg <- all_new_msgs %>%
    group_by(sessionId) %>%
    summarise(
      total_tokens = sum(input_tokens + output_tokens + cached_tokens),
      total_cost = sum(cost_usd),
      start_time = min(timestamp),
      last_updated = max(timestamp),
      .groups = "drop"
    )
  
  for (i in 1:nrow(session_agg)) {
    row <- session_agg[i,]
    dbExecute(con, sprintf("
      INSERT OR REPLACE INTO sessions_summary 
      VALUES ('%s', NULL, 'llm', %d, %f, '%s', '%s')",
      row$sessionId, 
      as.integer(row$total_tokens),
      row$total_cost,
      format(row$start_time, "%Y-%m-%d %H:%M:%S"),
      format(row$last_updated, "%Y-%m-%d %H:%M:%S")
    ))
  }
  
  # Daily aggregation
  daily_agg <- all_new_msgs %>%
    group_by(date) %>%
    summarise(
      total_tokens = sum(input_tokens + output_tokens + cached_tokens),
      total_cost = sum(cost_usd),
      message_count = n(),
      .groups = "drop"
    )
  
  for (i in 1:nrow(daily_agg)) {
    row <- daily_agg[i,]
    dbExecute(con, sprintf("
      INSERT OR REPLACE INTO daily_usage 
      VALUES ('%s', %d, %f, %d)",
      as.character(row$date),
      as.integer(row$total_tokens),
      row$total_cost,
      as.integer(row$message_count)
    ))
  }
}

dbDisconnect(con, shutdown = TRUE)
message("Gemini refresh complete!")