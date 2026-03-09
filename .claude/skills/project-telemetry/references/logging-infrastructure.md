# Logging Infrastructure Reference

## Setup Logger Infrastructure

### Create Logging Configuration

```r
# R/zzz.R (runs on package load)
.onLoad <- function(libname, pkgname) {
  # Setup logger
  logger::log_appender(
    logger::appender_file(
      file.path("inst/logs", "package.log")
    )
  )

  logger::log_threshold(logger::INFO)
  logger::log_layout(logger::layout_glue_colors)

  logger::log_info("Package {pkgname} loaded")
}
```

### Create Log Directories

```r
# R/setup/init_logging.R
library(fs)
library(logger)

# Create log directories
dir_create("inst/logs")
dir_create("R/setup")
dir_create("R/log")

log_info("Logging infrastructure initialized")
```

### Log Rotation in R

```r
# R/utils/log_rotation.R
rotate_log <- function(log_file, max_size_mb = 5, keep_count = 3) {
  if (!file.exists(log_file)) return(invisible())

  # Check file size
  size_mb <- file.size(log_file) / (1024 * 1024)

  if (size_mb > max_size_mb) {
    # Rotate existing logs
    for (i in seq(keep_count - 1, 1, -1)) {
      old_name <- paste0(log_file, ".", i)
      new_name <- paste0(log_file, ".", i + 1)
      if (file.exists(old_name)) {
        file.rename(old_name, new_name)
      }
    }

    # Move current log to .1
    file.rename(log_file, paste0(log_file, ".1"))

    # Create new empty log file
    file.create(log_file)

    # Log the rotation
    logger::log_info("Log rotated (was {round(size_mb, 1)}MB)",
                     namespace = "log_rotation")
  }
}

# Use before heavy logging operations
rotate_log("inst/logs/package.log")
rotate_log("inst/logs/dev_session.log")
rotate_log("inst/logs/git_gh.log")
```

### Log Rotation in Shell Scripts (for launchd/cron)

```bash
rotate_logs() {
    local log_file=$1
    local max_size=5242880  # 5MB in bytes
    local keep_count=3      # Keep 3 old versions

    if [ -f "$log_file" ]; then
        local size=$(stat -f%z "$log_file" 2>/dev/null || stat -c%s "$log_file" 2>/dev/null || echo 0)

        if [ "$size" -gt "$max_size" ]; then
            for i in $(seq $((keep_count-1)) -1 1); do
                if [ -f "${log_file}.${i}" ]; then
                    mv "${log_file}.${i}" "${log_file}.$((i+1))"
                fi
            done

            mv "$log_file" "${log_file}.1"
            touch "$log_file"
            echo "$(date '+%Y-%m-%d %H:%M:%S'): Log rotated (was $((size/1024/1024))MB)" >> "$log_file"
        fi
    fi
}

# Call at script start
rotate_logs "$LOG_FILE"
rotate_logs "$ERROR_LOG"
```

## Usage Patterns

### In Package Functions

```r
# R/simulation.R
#' Run simulation
#' @export
run_simulation <- function(grid_size, n_walkers) {
  logger::log_info("Starting simulation: grid_size={grid_size}, n_walkers={n_walkers}")

  tryCatch({
    result <- perform_simulation(grid_size, n_walkers)

    logger::log_info("Simulation completed successfully")
    logger::log_debug("Result details: {str(result)}")

    result
  }, error = function(e) {
    logger::log_error("Simulation failed: {e$message}")
    stop(e)
  })
}
```

### In Development Scripts

```r
# R/setup/dev_log.R
library(logger)
library(gert)
library(devtools)

# Configure logging for this session
log_appender(appender_file("inst/logs/dev_session.log"))
log_info("=== Development session started ===")

# Issue #42: Add new feature
log_info("Working on issue #42")

usethis::pr_init("fix-issue-42-add-feature")
log_info("Created branch: fix-issue-42-add-feature")

# Make changes...
log_info("Modified files: R/new_feature.R, tests/testthat/test-new_feature.R")

gert::git_add(c("R/new_feature.R", "tests/testthat/test-new_feature.R"))
gert::git_commit("Add new feature for issue #42")
log_info("Committed changes")

devtools::document()
log_info("Updated documentation")

devtools::test()
log_info("All tests passed")

devtools::check()
log_info("R CMD check: 0 errors, 0 warnings, 0 notes")

usethis::pr_push()
log_info("Pushed to remote")
```

### For Git/GitHub Operations

```r
# R/log/git_gh.R
library(logger)
library(gert)
library(gh)

log_appender(appender_file("inst/logs/git_gh.log"))
log_threshold(DEBUG)

log_info("=== Git/GitHub operations log ===")

# Git operations
log_debug("Checking git status")
status <- gert::git_status()
log_info("Files changed: {nrow(status)}")

# GitHub operations
log_debug("Fetching open issues")
issues <- gh::gh("/repos/{owner}/{repo}/issues",
                 owner = "username",
                 repo = "reponame",
                 state = "open")
log_info("Open issues: {length(issues)}")
```

## Logger Levels and Usage

### Log Levels

```r
logger::log_trace("Very detailed debugging")
logger::log_debug("Detailed debugging information")
logger::log_info("General informational messages")
logger::log_warn("Warning messages")
logger::log_error("Error messages")
logger::log_fatal("Fatal errors")
```

### Conditional Logging

```r
if (logger::log_threshold() <= logger::DEBUG) {
  logger::log_debug("Expensive debug info: {expensive_computation()}")
}
```

### Structured Logging

```r
logger::log_info(
  "Simulation completed",
  grid_size = grid_size,
  n_walkers = n_walkers,
  elapsed = elapsed_time
)
```

## Best Practices

### 1. Log at Appropriate Levels

```r
# Good: Appropriate levels
logger::log_info("Starting process")
logger::log_debug("Parameter values: {params}")
logger::log_error("Failed to connect: {error}")

# Bad: Everything at same level
logger::log_info("Debug details: {x}")
```

### 2. Include Context in Messages

```r
# Good: Context included
logger::log_info("Processing file {filename}: {n_rows} rows")

# Bad: No context
logger::log_info("Processing")
```

### 3. Separate Logs by Purpose

```r
# Different appenders for different purposes
logger::log_appender(appender_file("inst/logs/dev.log"), namespace = "dev")
logger::log_appender(appender_file("inst/logs/git.log"), namespace = "git")

logger::log_info("Development message", namespace = "dev")
logger::log_info("Git operation", namespace = "git")
```

### 4. Don't Log Sensitive Data

```r
# Good: Redact sensitive info
logger::log_info("API call to {endpoint} with key ***")

# Bad: Logging secrets
# logger::log_info("API key: {api_key}")
```
