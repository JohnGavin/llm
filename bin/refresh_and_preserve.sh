#!/bin/bash
# Enhanced refresh script with proper branch management and error handling
# Preserves complete history and handles git operations correctly
# Runs via launchd every 12 hours

set -e

# Configuration
LLM_REPO="/Users/johngavin/docs_gh/llm"
LOG_FILE="$LLM_REPO/inst/logs/refresh_preserve.log"
ERROR_LOG="$LLM_REPO/inst/logs/refresh_preserve_error.log"
LOCK_FILE="/tmp/refresh_preserve.lock"
MAIN_BRANCH="main"

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

error_log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S'): ERROR: $1" | tee -a "$ERROR_LOG" >&2
}

# Log rotation function
rotate_logs() {
    local log_file=$1
    local max_size=5242880  # 5MB in bytes
    local keep_count=3      # Keep 3 old versions

    if [ -f "$log_file" ]; then
        local size=$(stat -f%z "$log_file" 2>/dev/null || stat -c%s "$log_file" 2>/dev/null || echo 0)

        if [ "$size" -gt "$max_size" ]; then
            # Rotate existing logs
            for i in $(seq $((keep_count-1)) -1 1); do
                if [ -f "${log_file}.${i}" ]; then
                    mv "${log_file}.${i}" "${log_file}.$((i+1))"
                fi
            done

            # Move current log to .1
            mv "$log_file" "${log_file}.1"
            touch "$log_file"
            log "Log rotated (was $((size/1024/1024))MB)"
        fi
    fi
}

# Rotate logs at start if needed
rotate_logs "$LOG_FILE"
rotate_logs "$ERROR_LOG"

log "===== Starting history-preserving refresh ====="

cd "$LLM_REPO"

# CRITICAL: Save current branch and ensure we're on main
ORIGINAL_BRANCH=$(git rev-parse --abbrev-ref HEAD)
log "Current branch: $ORIGINAL_BRANCH"

# Stash any uncommitted changes
if ! git diff --quiet || ! git diff --staged --quiet; then
    log "Stashing uncommitted changes..."
    git stash push -m "Auto-stash before ccusage refresh $(date +%Y%m%d_%H%M%S)"
fi

# Switch to main branch
if [ "$ORIGINAL_BRANCH" != "$MAIN_BRANCH" ]; then
    log "Switching to $MAIN_BRANCH branch..."
    git checkout "$MAIN_BRANCH" 2>&1 | tee -a "$LOG_FILE"
fi

# Pull latest changes
log "Pulling latest changes from origin..."
if ! git pull origin "$MAIN_BRANCH" 2>&1 | tee -a "$LOG_FILE"; then
    error_log "Failed to pull from origin"
    # Continue anyway - we can still update locally
fi

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
if nix-shell "$LLM_REPO/default.nix" --attr shell --run "cd $LLM_REPO && Rscript /tmp/refresh_preserve.R && Rscript R/scripts/refresh_gemini_cache.R" >> "$LOG_FILE" 2>&1; then
    log "✓ History preservation and Gemini refresh completed"
else
    error_log "Refresh scripts had issues (exit code: $?)"
fi

# 3. Capture cmonitor data via nix-shell
log "Capturing cmonitor data..."

# Run cmonitor inside nix-shell
if nix-shell "$LLM_REPO/default.nix" --attr shell --run "timeout 60 cmonitor --view daily" > "$LLM_REPO/inst/extdata/cmonitor_daily.txt" 2>> "$LOG_FILE"; then
    log "✓ cmonitor daily data captured"
    
    # Capture monthly data
    nix-shell "$LLM_REPO/default.nix" --attr shell --run "timeout 60 cmonitor --view monthly" > "$LLM_REPO/inst/extdata/cmonitor_monthly.txt" 2>> "$LOG_FILE" || true

    # Extract total cost from cmonitor
    CMONITOR_COST=$(grep "Total Cost:" "$LLM_REPO/inst/extdata/cmonitor_daily.txt" | sed 's/.*\$\([0-9.,]*\).*/\1/' | head -1)
    if [ ! -z "$CMONITOR_COST" ]; then
        log "cmonitor reports total cost: \$$CMONITOR_COST"
    fi
else
    log "⚠ cmonitor failed or not available in nix-shell"
    # Ensure file exists so git add doesn't fail
    touch "$LLM_REPO/inst/extdata/cmonitor_daily.txt"
fi

# 4. ALWAYS stage and commit changes (don't check if files changed)
log "Staging changes..."
# Split git add to handle missing file types gracefully
git add inst/extdata/*.json 2>&1 | tee -a "$LOG_FILE" || true
git add inst/extdata/*.txt 2>&1 | tee -a "$LOG_FILE" || true
git add inst/extdata/*.duckdb* 2>&1 | tee -a "$LOG_FILE" || true
git add inst/extdata/gemini/*.duckdb* 2>&1 | tee -a "$LOG_FILE" || true

# Check if there are staged changes
if git diff --staged --quiet; then
    log "No changes to commit (files unchanged)"
else
    log "Committing changes..."

    # Get summary from latest data
    if [ -f "inst/extdata/ccusage_daily_all.json" ]; then
        TOTAL_COST=$(grep '"totalCost"' inst/extdata/ccusage_daily_all.json | head -1 | sed 's/.*: \(.*\),/\1/')
    fi

    commit_msg="chore: Auto-refresh ccusage cache $(date '+%Y-%m-%d %H:%M')

Updated usage data with complete history preservation.
Total cost: \$$TOTAL_COST

🤖 Automated via launchd (12-hourly)"

    if git commit -m "$commit_msg" 2>&1 | tee -a "$LOG_FILE"; then
        log "✓ Commit successful"

        # Push to remote
        log "Pushing to remote..."
        if git push origin "$MAIN_BRANCH" 2>&1 | tee -a "$LOG_FILE"; then
            log "✓ Push successful"
        else
            error_log "Push failed - may need manual intervention"
            # Don't exit with error - local commit still succeeded
        fi
    else
        error_log "Commit failed"
    fi
fi

# 5. Return to original branch if different
if [ "$ORIGINAL_BRANCH" != "$MAIN_BRANCH" ] && [ "$ORIGINAL_BRANCH" != "HEAD" ]; then
    log "Returning to original branch: $ORIGINAL_BRANCH"
    git checkout "$ORIGINAL_BRANCH" 2>&1 | tee -a "$LOG_FILE"

    # Restore stashed changes if any
    if git stash list | grep -q "Auto-stash before ccusage refresh"; then
        log "Restoring stashed changes..."
        git stash pop 2>&1 | tee -a "$LOG_FILE" || true
    fi
fi

# 6. Clean up old archive directories (keep last 10)
log "Cleaning old archives..."
ls -t "$LLM_REPO/inst/extdata/archive" 2>/dev/null | tail -n +11 | while read dir; do
    rm -rf "$LLM_REPO/inst/extdata/archive/$dir"
    log "Removed old archive: $dir"
done

log "===== Refresh complete ====="

# Print final statistics
if [ -f "$LLM_REPO/inst/extdata/llm_usage_history.duckdb" ]; then
    DB_SIZE=$(du -h "$LLM_REPO/inst/extdata/llm_usage_history.duckdb" | cut -f1)
    log "DuckDB size: $DB_SIZE"
fi

# Exit with success
exit 0