#!/bin/bash
# Enhanced refresh script that preserves complete history
# Prevents data loss from ccusage/cmonitor rolling windows
# Runs via launchd every 12 hours

set -e

# Configuration
LLM_REPO="/Users/johngavin/docs_gh/llm"
LOG_FILE="$LLM_REPO/inst/logs/refresh_preserve.log"
LOCK_FILE="/tmp/refresh_preserve.lock"

# Source Nix if available
if [ -e "/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh" ]; then
    . "/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh"
fi
if [ -e "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
    . "$HOME/.nix-profile/etc/profile.d/nix.sh"
fi

# Add common paths
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# Ensure only one instance runs
if [ -f "$LOCK_FILE" ]; then
    pid=$(cat "$LOCK_FILE")
    if kill -0 "$pid" 2>/dev/null; then
        echo "$(date): Another instance running (PID $pid), exiting" >> "$LOG_FILE"
        exit 0
    fi
fi
echo $$ > "$LOCK_FILE"
trap "rm -f $LOCK_FILE" EXIT

# Create directories if needed
mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$LLM_REPO/inst/extdata"
mkdir -p "$LLM_REPO/inst/extdata/archive"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $1" | tee -a "$LOG_FILE"
}

log "===== Starting history-preserving refresh ====="

cd "$LLM_REPO"

# 1. Archive current JSON files (in case something goes wrong)
ARCHIVE_DIR="$LLM_REPO/inst/extdata/archive/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$ARCHIVE_DIR"
cp inst/extdata/*.json "$ARCHIVE_DIR/" 2>/dev/null || true
log "Archived existing JSON files to $ARCHIVE_DIR"

# 2. Run the R script that preserves history
log "Running history preservation script..."

# Create the R script inline to avoid dependency issues
cat > /tmp/refresh_preserve.R << 'EOF'
#!/usr/bin/env Rscript

library(DBI)
library(duckdb)
library(jsonlite)
library(dplyr)
library(lubridate)

`%||%` <- function(x, y) if (is.null(x) || is.na(x)) y else x

message("Starting refresh with history preservation...")

DB_PATH <- "inst/extdata/llm_usage_history.duckdb"
dir.create("inst/extdata", recursive = TRUE, showWarnings = FALSE)

# Connect to database
con <- dbConnect(duckdb(), dbdir = DB_PATH)

# Create tables if needed
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

# Fetch new data from ccusage
message("Fetching fresh data from ccusage...")
daily_fresh <- tryCatch({
  tmp_file <- tempfile(fileext = ".json")
  system(sprintf("npx ccusage daily --json --instances > %s 2>/dev/null", tmp_file))
  fromJSON(tmp_file)
}, error = function(e) NULL)

# Import fresh daily data
if (!is.null(daily_fresh$projects)) {
  collected_at <- Sys.time()
  records_added <- 0

  for (project_name in names(daily_fresh$projects)) {
    project_data <- daily_fresh$projects[[project_name]]

    if (is.data.frame(project_data) && nrow(project_data) > 0) {
      for (i in 1:nrow(project_data)) {
        row <- project_data[i, ]

        # Use INSERT OR REPLACE to handle duplicates
        sql <- sprintf("
          INSERT OR REPLACE INTO daily_usage VALUES (
            '%s', '%s', %s, %s, %s, %s, %s, %f, '%s', 'ccusage', '%s'
          )",
          row$date,
          project_name,
          as.integer(row$inputTokens %||% 0),
          as.integer(row$outputTokens %||% 0),
          as.integer(row$cacheCreationTokens %||% 0),
          as.integer(row$cacheReadTokens %||% 0),
          as.integer(row$totalTokens %||% 0),
          as.numeric(row$totalCost %||% 0),
          "[]",
          format(collected_at, "%Y-%m-%d %H:%M:%S")
        )

        dbExecute(con, sql)
        records_added <- records_added + 1
      }
    }
  }
  message(sprintf("Added/updated %d daily records", records_added))
}

# Export complete history back to JSON
message("Exporting complete history to JSON...")

daily_complete <- dbGetQuery(con, "
  WITH ranked AS (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY date, project
                              ORDER BY collected_at DESC) as rn
    FROM daily_usage
  )
  SELECT date, project, input_tokens, output_tokens,
         cache_creation_tokens, cache_read_tokens,
         total_tokens, total_cost, data_source
  FROM ranked
  WHERE rn = 1
  ORDER BY date DESC, project
")

if (nrow(daily_complete) > 0) {
  # Group by project for expected format
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
    dataSource = "preserved_history",
    recordCount = nrow(daily_complete),
    dateRange = list(
      earliest = min(daily_complete$date),
      latest = max(daily_complete$date)
    )
  )

  write_json(daily_json, "inst/extdata/ccusage_daily_all.json",
             pretty = TRUE, auto_unbox = TRUE)
  message(sprintf("Exported %d daily records spanning %s to %s",
                 nrow(daily_complete),
                 min(daily_complete$date),
                 max(daily_complete$date)))
}

# Also preserve session and blocks data
message("Fetching session data...")
system("npx ccusage session --json --instances > inst/extdata/ccusage_session_all.json 2>/dev/null || true")

message("Fetching blocks data...")
system("npx ccusage blocks --json --instances --breakdown > inst/extdata/ccusage_blocks_all.json 2>/dev/null || true")

# Print summary
stats <- dbGetQuery(con, "
  SELECT
    COUNT(DISTINCT date || project) as total_records,
    COUNT(DISTINCT date) as unique_days,
    MIN(date) as earliest_date,
    MAX(date) as latest_date,
    SUM(total_cost) as grand_total_cost
  FROM (
    SELECT date, project, MAX(total_cost) as total_cost
    FROM daily_usage
    GROUP BY date, project
  )
")

cat("\n=== History Summary ===\n")
cat(sprintf("Total records: %d\n", stats$total_records))
cat(sprintf("Unique days: %d\n", stats$unique_days))
cat(sprintf("Date range: %s to %s\n", stats$earliest_date, stats$latest_date))
cat(sprintf("Grand total cost: $%.2f\n", stats$grand_total_cost))

dbDisconnect(con)
message("\nRefresh complete!")
EOF

# Run the R script via nix-shell
if nix-shell "$LLM_REPO/default.nix" --attr shell --run "cd $LLM_REPO && Rscript /tmp/refresh_preserve.R" >> "$LOG_FILE" 2>&1; then
    log "✓ History preservation completed"
else
    log "⚠ Preservation script had issues (exit code: $?)"
fi

# 3. Capture cmonitor data if available
if command -v cmonitor &> /dev/null; then
    log "Capturing cmonitor data..."

    # Get cmonitor data in different views
    cmonitor --view daily 2>&1 | head -100 > "$LLM_REPO/inst/extdata/cmonitor_daily.txt" || true
    cmonitor --view monthly 2>&1 | head -50 > "$LLM_REPO/inst/extdata/cmonitor_monthly.txt" || true

    # Extract total cost from cmonitor
    CMONITOR_COST=$(cmonitor --view daily 2>&1 | grep "Total Cost:" | sed 's/.*\$\([0-9.,]*\).*/\1/' | head -1)
    if [ ! -z "$CMONITOR_COST" ]; then
        log "cmonitor reports total cost: \$$CMONITOR_COST"
    fi
else
    log "⚠ cmonitor not available"
fi

# 4. Check for changes and commit
if git diff --quiet inst/extdata/*.json inst/extdata/*.txt 2>/dev/null; then
    log "No changes to commit"
else
    log "Committing changes..."
    git add inst/extdata/*.json inst/extdata/*.txt inst/extdata/*.duckdb* 2>/dev/null || true

    commit_msg="chore: Auto-refresh usage data with history preservation $(date '+%Y-%m-%d %H:%M')

Preserved complete history in DuckDB to prevent data loss.
ccusage rolling window no longer causes data loss.
DuckDB database maintains full history.

🤖 Automated via launchd (12-hourly)"

    git commit -m "$commit_msg" >> "$LOG_FILE" 2>&1

    # Push to remote
    log "Pushing to remote..."
    if git push >> "$LOG_FILE" 2>&1; then
        log "✓ Push successful"
    else
        log "⚠ Push failed - may need manual intervention"
    fi
fi

# 5. Clean up old archive directories (keep last 10)
log "Cleaning old archives..."
ls -t "$LLM_REPO/inst/extdata/archive" | tail -n +11 | while read dir; do
    rm -rf "$LLM_REPO/inst/extdata/archive/$dir"
    log "Removed old archive: $dir"
done

log "===== Refresh complete ====="

# Print final statistics
if [ -f "$LLM_REPO/inst/extdata/llm_usage_history.duckdb" ]; then
    DB_SIZE=$(du -h "$LLM_REPO/inst/extdata/llm_usage_history.duckdb" | cut -f1)
    log "DuckDB size: $DB_SIZE"
fi