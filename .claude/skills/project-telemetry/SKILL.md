# Project Telemetry and Logging

## Description

This skill implements comprehensive project telemetry, logging, and statistics tracking for R packages. It covers logging with the logger package, creating telemetry vignettes with targets, and tracking project health metrics.

## Purpose

Use this skill when:
- Setting up logging infrastructure for R packages
- Creating telemetry vignettes to document project statistics
- Tracking git history and development metrics
- Monitoring test coverage and package health
- Documenting package file structure
- Creating comprehensive project documentation

## Key Principles

### Centralized Logging

- Use the logger package for all logging
- Store logs in `inst/logs/` directory
- Separate logs by purpose (git, setup, development)
- Include timestamps and log levels
- Make logs reproducible and parseable

### Log Rotation for Automation

Implement automatic log rotation to prevent unbounded growth in long-running processes:

- **Size limit**: Rotate logs at 5MB to keep them manageable
- **Version retention**: Keep 3 old versions (.1, .2, .3)
- **Automatic cleanup**: Oldest logs are automatically removed
- **Use cases**: Essential for launchd jobs, cron tasks, and automated scripts

**Implementation for shell scripts:**

```bash
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
            echo "$(date '+%Y-%m-%d %H:%M:%S'): Log rotated (was $((size/1024/1024))MB)" >> "$log_file"
        fi
    fi
}

# Call at script start
rotate_logs "$LOG_FILE"
rotate_logs "$ERROR_LOG"
```

### Telemetry as Documentation

- Create vignette showing project health
- Track pipeline execution statistics
- Visualize git history and contributions
- Show test coverage metrics
- Document package structure

### Targets Integration

- Pre-calculate all telemetry statistics via targets
- Load statistics in vignette (don't compute inline)
- Update telemetry before major releases
- Version control telemetry results

## How It Works

### 1. Setup Logger Infrastructure

**Create logging configuration:**

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

**Create log directories:**

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

**Implement log rotation in R:**

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

### 2. Use Logger Throughout Package

**In package functions:**

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

**In development scripts:**

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

**For git/GitHub operations:**

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

### 3. Create Telemetry Targets Pipeline

```r
# _targets.R
library(targets)
library(tarchetypes)

tar_source()

tar_plan(
  # Main package targets
  # ... your regular targets ...

  # === TELEMETRY TARGETS ===

  # Git statistics
  tar_target(git_history, get_git_history()),
  tar_target(git_contributors, get_git_contributors()),
  tar_target(git_branch_graph, plot_git_branches()),

  # Package structure
  tar_target(package_tree, get_package_tree()),
  tar_target(file_counts, count_files_by_type()),

  # Test coverage
  tar_target(coverage_data, get_test_coverage()),
  tar_target(coverage_plot, plot_coverage(coverage_data)),

  # Pipeline statistics
  tar_target(pipeline_meta, tar_meta()),
  tar_target(pipeline_timing, analyze_pipeline_timing(pipeline_meta)),
  tar_target(pipeline_plot, plot_pipeline_timing(pipeline_timing)),

  # Session information
  tar_target(session_info, get_session_info()),
  tar_target(package_versions, get_package_versions()),

  # GitHub statistics
  tar_target(github_stats, get_github_stats()),
  tar_target(workflow_status, get_workflow_status())
)
```

### 4. Implement Telemetry Functions

```r
# R/telemetry.R

#' Get git commit history
#' @export
get_git_history <- function() {
  library(gert)
  library(dplyr)

  log <- gert::git_log(max = 1000)

  log |>
    mutate(
      date = as.Date(time),
      hour = lubridate::hour(time),
      weekday = lubridate::wday(time, label = TRUE),
      week = lubridate::week(time)
    ) |>
    select(commit, author, time, date, message, files, merge)
}

#' Get unique contributors
#' @export
get_git_contributors <- function() {
  library(gert)
  library(dplyr)

  log <- gert::git_log(max = 1000)

  log |>
    group_by(author) |>
    summarise(
      commits = n(),
      first_commit = min(time),
      last_commit = max(time),
      .groups = "drop"
    ) |>
    arrange(desc(commits))
}

#' Create package file tree
#' @export
get_package_tree <- function() {
  library(fs)

  tree_lines <- capture.output(
    fs::dir_tree(
      recurse = TRUE,
      type = "any",
      regexp = "^(?!.*(\\.git|_targets|renv)).*$"
    )
  )

  paste(tree_lines, collapse = "\n")
}

#' Count files by type
#' @export
count_files_by_type <- function() {
  library(fs)
  library(dplyr)

  all_files <- fs::dir_ls(recurse = TRUE, type = "file")

  data.frame(path = all_files) |>
    mutate(
      extension = tools::file_ext(path),
      directory = dirname(path)
    ) |>
    count(extension, name = "count") |>
    arrange(desc(count))
}

#' Get test coverage
#' @export
get_test_coverage <- function() {
  library(covr)

  cov <- package_coverage()

  list(
    percent = percent_coverage(cov),
    by_file = tidy_coverage(cov)
  )
}

#' Plot test coverage
#' @export
plot_coverage <- function(coverage_data) {
  library(ggplot2)

  coverage_data$by_file |>
    ggplot(aes(x = reorder(filename, coverage), y = coverage)) +
    geom_col(fill = "steelblue") +
    geom_hline(yintercept = 80, linetype = "dashed", color = "red") +
    coord_flip() +
    labs(
      title = "Test Coverage by File",
      x = NULL,
      y = "Coverage (%)"
    ) +
    theme_minimal()
}

#' Analyze pipeline timing
#' @export
analyze_pipeline_timing <- function(meta) {
  library(dplyr)

  meta |>
    filter(!is.na(seconds)) |>
    arrange(desc(seconds)) |>
    mutate(
      minutes = seconds / 60,
      hours = minutes / 60
    ) |>
    select(name, seconds, minutes, size, bytes)
}

#' Plot pipeline timing
#' @export
plot_pipeline_timing <- function(timing_data) {
  library(ggplot2)

  timing_data |>
    head(20) |>
    ggplot(aes(x = reorder(name, seconds), y = seconds)) +
    geom_col(fill = "steelblue") +
    coord_flip() +
    labs(
      title = "Top 20 Targets by Execution Time",
      x = NULL,
      y = "Time (seconds)"
    ) +
    theme_minimal()
}

#' Get session information
#' @export
get_session_info <- function() {
  info <- sessionInfo()

  list(
    r_version = paste(info$R.version$major, info$R.version$minor, sep = "."),
    platform = info$platform,
    os = info$running,
    packages = data.frame(
      package = names(info$otherPkgs),
      version = sapply(info$otherPkgs, function(x) as.character(x$Version))
    )
  )
}

#' Get GitHub repository statistics
#' @export
get_github_stats <- function() {
  library(gh)

  repo_info <- gh::gh("/repos/{owner}/{repo}",
                      owner = "username",
                      repo = "reponame")

  list(
    stars = repo_info$stargazers_count,
    forks = repo_info$forks_count,
    open_issues = repo_info$open_issues_count,
    watchers = repo_info$watchers_count,
    size = repo_info$size,
    created = repo_info$created_at,
    updated = repo_info$updated_at
  )
}

#' Get GitHub Actions workflow status
#' @export
get_workflow_status <- function() {
  library(gh)

  runs <- gh::gh("/repos/{owner}/{repo}/actions/runs",
                 owner = "username",
                 repo = "reponame",
                 per_page = 10)

  data.frame(
    workflow = sapply(runs$workflow_runs, function(x) x$name),
    status = sapply(runs$workflow_runs, function(x) x$status),
    conclusion = sapply(runs$workflow_runs, function(x) x$conclusion %||% "running"),
    created = sapply(runs$workflow_runs, function(x) x$created_at)
  )
}
```

### 5. Create Telemetry Vignette

```r
# vignettes/telemetry.Rmd
---
title: "Project Telemetry and Statistics"
output: rmarkdown::html_vignette
vignette: >
  %\VignetteIndexEntry{Project Telemetry and Statistics}
  %\VignetteEngine{knitr::rmarkdown}
  %\VignetteEncoding{UTF-8}
---

```{r setup, include = FALSE}
knitr::opts_chunk$set(
  collapse = TRUE,
  comment = "#>",
  echo = FALSE,
  message = FALSE,
  warning = FALSE
)

library(targets)
library(knitr)
library(ggplot2)
```

## Overview

This vignette provides comprehensive statistics and telemetry for the package,
including git history, test coverage, pipeline performance, and project structure.

## Git History

### Contributors

```{r}
tar_load(git_contributors)
kable(git_contributors)
```

### Commit Activity

```{r}
tar_load(git_history)

# Plot commits over time
library(dplyr)
git_history |>
  count(date) |>
  ggplot(aes(x = date, y = n)) +
  geom_line() +
  geom_smooth(se = FALSE) +
  labs(title = "Commit Activity", x = "Date", y = "Commits") +
  theme_minimal()
```

## Test Coverage

```{r}
tar_load(coverage_data)
tar_load(coverage_plot)
```

Overall coverage: **`r round(coverage_data$percent, 1)`%**

```{r}
print(coverage_plot)
```

## Pipeline Performance

```{r}
tar_load(pipeline_timing)
tar_load(pipeline_plot)
```

Total targets: **`r nrow(pipeline_timing)`**

```{r}
kable(head(pipeline_timing, 10))
print(pipeline_plot)
```

## Package Structure

```{r}
tar_load(package_tree)
tar_load(file_counts)
```

### File Counts by Type

```{r}
kable(file_counts)
```

### Directory Tree

```{r, comment = ""}
cat(package_tree)
```

## Session Information

```{r}
tar_load(session_info)
```

R Version: **`r session_info$r_version`**

Platform: **`r session_info$platform`**

Operating System: **`r session_info$os`**

### Loaded Packages

```{r}
kable(session_info$packages)
```

## GitHub Statistics

```{r}
tar_load(github_stats)
tar_load(workflow_status)
```

- Stars: **`r github_stats$stars`**
- Forks: **`r github_stats$forks`**
- Open Issues: **`r github_stats$open_issues`**
- Watchers: **`r github_stats$watchers`**

### Recent Workflow Runs

```{r}
kable(workflow_status)
```

## Build Information

Built on: **`r Sys.time()`**

Package version: **`r packageVersion("yourpackage")`**
```

## File Structure

```
package/
├── inst/
│   └── logs/
│       ├── package.log        # General package logging
│       ├── dev_session.log    # Development session logs
│       └── git_gh.log         # Git/GitHub operation logs
├── R/
│   ├── zzz.R                  # Package load hooks
│   ├── telemetry.R            # Telemetry functions
│   ├── setup/
│   │   ├── init_logging.R     # Setup logging infrastructure
│   │   └── dev_log.R          # Development session log
│   └── log/
│       └── git_gh.R           # Git/GitHub operations log
├── vignettes/
│   └── telemetry.Rmd          # Telemetry vignette
└── _targets.R                 # Include telemetry targets
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

## Integration with pkgdown

```yaml
# _pkgdown.yml
articles:
  - title: Documentation
    contents:
      - introduction
      - usage

  - title: Project Info
    contents:
      - telemetry
      - architecture

navbar:
  structure:
    right: [articles, reference, github]
```

## Automated Updates

### Update Telemetry Before Release

```r
# R/setup/prepare_release.R
library(logger)
library(targets)

log_info("Preparing release")

# Update telemetry
log_info("Running targets pipeline")
tar_make()

# Build vignettes
log_info("Building vignettes")
devtools::build_vignettes()

# Build site
log_info("Building pkgdown site")
pkgdown::build_site()

log_info("Release preparation complete")
```

## GitHub CI Workflow Run Time Analysis (MANDATORY)

Every telemetry vignette MUST include CI run time distributions. This helps identify:
- Slow workflows that need optimization
- Regressions in CI performance
- Success/failure patterns

### Implementation

```r
library(gh)
library(dplyr)
library(ggplot2)

# Fetch workflow runs
get_workflow_runs <- function(owner, repo, per_page = 100) {
  runs <- gh::gh(
    "/repos/{owner}/{repo}/actions/runs",
    owner = owner, repo = repo,
    per_page = per_page
  )

  tibble(
    name = sapply(runs$workflow_runs, `[[`, "name"),
    conclusion = sapply(runs$workflow_runs, function(x) x$conclusion %||% NA),
    run_started_at = sapply(runs$workflow_runs, `[[`, "run_started_at"),
    updated_at = sapply(runs$workflow_runs, `[[`, "updated_at")
  ) |>
    mutate(
      run_started_at = lubridate::ymd_hms(run_started_at),
      updated_at = lubridate::ymd_hms(updated_at),
      duration_minutes = as.numeric(difftime(updated_at, run_started_at, units = "mins"))
    )
}

# Get last 10 runs per workflow
runs <- get_workflow_runs("owner", "repo") |>
  filter(conclusion == "success") |>
  group_by(name) |>
  slice_head(n = 10)

# Summary statistics
runs |>
  summarise(
    mean_min = mean(duration_minutes),
    median_min = median(duration_minutes),
    sd_min = sd(duration_minutes)
  )

# Box plot
ggplot(runs, aes(x = name, y = duration_minutes)) +
  geom_boxplot() +
  coord_flip() +
  labs(title = "CI Run Time Distribution")
```

### Required Visualizations

1. **Summary table**: Mean, median, min, max, SD per workflow
2. **Box plot**: Distribution comparison across workflows
3. **Histogram**: Run time frequency per workflow
4. **Trend plot**: Run times over time (detect regressions)
5. **Success rate table**: Percentage by workflow

**Template:** See `vignettes/telemetry.qmd` in the llm project.

## Mandatory Vignette Sections (ALL PROJECTS)

Every `telemetry.qmd` vignette MUST include ALL of the following sections.
Each section consumes pre-computed targets via `safe_tar_read()` — zero inline computation.

### Required Section Structure

```
# LLM Usage & Costs
  ## Cost Trends          — daily cost trend with LOESS
  ## Cumulative Cost      — cumulative spending trajectory
  ## Breakdowns           — cost by model + token composition
  ## Gemini Analytics     — Gemini costs (if applicable)

# Session Efficiency
  ## Duration Trends      — avg session duration over time
  ## Cost Efficiency      — cost per minute trend
  ## Cost vs Duration     — scatter: longer sessions more efficient?
  ## Model Breakdown      — faceted by model variant
  ## Max5 Block History   — recent usage blocks table

# Pipeline Metrics                    ← NEW (MANDATORY)
  ## Plans & Targets      — plan file names, target count per plan
  ## Top by Size          — top 5 targets by stored bytes
  ## Top by Compute Time  — top 5 targets by execution seconds

# GitHub Activity                     ← NEW (MANDATORY)
  ## Commit Velocity      — weekly commit counts with timeline
  ## Issues & PRs         — open/closed/merged counts
  ## CI Workflow Runtimes — box plot of successful run durations
  ## Git History          — daily commit frequency

# Project Structure
  ## Codebase             ← NEW (MANDATORY)
                          — R files, test files, vignettes,
                            plans, exports, lines of code, version
  ## File Counts          — file type distribution
  ## GitHub Stats         — stars, forks, branches, last commit
```

### Required Targets (plan_vignette_outputs.R or plan_telemetry.R)

Every project MUST define these targets in its telemetry plan:

| Target | Section | What it computes |
|--------|---------|-----------------|
| `vig_pipeline_summary` | Pipeline Metrics | Scans `R/tar_plans/plan_*.R`, counts `tar_target()` calls, reads `tar_meta()` for size/time |
| `vig_pipeline_plans_table` | Plans & Targets | DT table of plan files and target counts |
| `vig_pipeline_top_size_table` | Top by Size | DT table of top 5 targets by bytes |
| `vig_pipeline_top_time_table` | Top by Compute Time | DT table of top 5 targets by seconds |
| `vig_commit_velocity` | Commit Velocity | Weekly commit counts from `gert::git_log()` |
| `vig_commit_velocity_table` | Commit Velocity | DT table with week labels and counts |
| `vig_github_activity` | Issues & PRs | Fetches issues/PRs/workflows via `gh::gh()` |
| `vig_github_activity_table` | Issues & PRs | DT summary table |
| `vig_codebase_metrics` | Codebase | R files, tests, exports, LOC, version |

### Implementation Pattern

**Pipeline summary target** (adapt owner/repo per project):

```r
tar_target(
  vig_pipeline_summary,
  {
    meta <- targets::tar_meta()
    plan_files <- list.files("R/tar_plans", pattern = "^plan_.*\\.R$",
                             full.names = TRUE)
    plan_counts <- lapply(plan_files, function(f) {
      code <- readLines(f, warn = FALSE)
      n <- sum(grepl("tar_target\\(|tar_quarto\\(", code))
      tibble::tibble(plan = basename(f), targets = n)
    })
    plan_tbl <- dplyr::bind_rows(plan_counts) |>
      dplyr::arrange(dplyr::desc(targets))

    top_size <- meta |>
      dplyr::filter(!is.na(bytes), bytes > 0) |>
      dplyr::arrange(dplyr::desc(bytes)) |>
      dplyr::slice_head(n = 5)

    top_time <- meta |>
      dplyr::filter(!is.na(seconds), seconds > 0) |>
      dplyr::arrange(dplyr::desc(seconds)) |>
      dplyr::slice_head(n = 5)

    list(plan_tbl = plan_tbl,
         total_plans = nrow(plan_tbl),
         total_targets = sum(plan_tbl$targets),
         top_size = top_size, top_time = top_time)
  },
  cue = tar_cue(mode = "always")
)
```

**GitHub activity target** (adapt owner/repo per project):

```r
tar_target(
  vig_github_activity,
  {
    owner <- "JohnGavin"
    repo <- "YOURPACKAGE"  # ← Change per project
    issues_open <- gh::gh("/repos/{owner}/{repo}/issues",
      owner = owner, repo = repo, state = "open", per_page = 100)
    issues_closed <- gh::gh("/repos/{owner}/{repo}/issues",
      owner = owner, repo = repo, state = "closed", per_page = 100)
    # Filter out PRs
    issues_open <- Filter(function(x) is.null(x$pull_request), issues_open)
    issues_closed <- Filter(function(x) is.null(x$pull_request), issues_closed)
    prs_closed <- gh::gh("/repos/{owner}/{repo}/pulls",
      owner = owner, repo = repo, state = "closed", per_page = 100)
    list(
      issues_open = length(issues_open),
      issues_closed = length(issues_closed),
      prs_merged = sum(sapply(prs_closed, function(x) !is.null(x$merged_at))),
      # ... etc
    )
  },
  cue = tar_cue(mode = "always")
)
```

**Codebase metrics target:**

```r
tar_target(
  vig_codebase_metrics,
  {
    r_files <- list.files("R", pattern = "\\.R$", full.names = TRUE,
                          recursive = TRUE)
    r_files <- r_files[!grepl("R/dev/", r_files)]
    test_files <- list.files("tests/testthat", pattern = "^test-.*\\.R$")
    lines_of_code <- sum(sapply(r_files, function(f) {
      code <- readLines(f, warn = FALSE)
      sum(nchar(trimws(code)) > 0 & !grepl("^\\s*#", code))
    }))
    exports <- sum(grepl("^export\\(", readLines("NAMESPACE", warn = FALSE)))
    desc <- read.dcf("DESCRIPTION", fields = c("Version", "Package"))
    tibble::tibble(
      Metric = c("R source files", "Test files", "Exported functions",
                 "Lines of R code", "Version"),
      Count = c(length(r_files), length(test_files), exports,
                format(lines_of_code, big.mark = ","), desc[1, "Version"])
    ) |> DT::datatable(caption = sprintf("%s codebase.", desc[1, "Package"]),
                       rownames = FALSE, options = list(dom = "t"))
  }
)
```

### Reference Implementations

| Project | Plan file | Vignette |
|---------|-----------|----------|
| **llm** (canonical) | `R/tar_plans/plan_vignette_outputs.R` | `vignettes/telemetry.qmd` |
| **irishbuoys** (most complete) | `R/tar_plans/plan_telemetry.R` | `vignettes/telemetry.qmd` |

### Checklist Before Commit

- [ ] All 6 mandatory sections present in telemetry.qmd
- [ ] Pipeline Metrics section has Plans & Targets, Top by Size, Top by Compute Time tabs
- [ ] GitHub Activity section has Commit Velocity, Issues & PRs, CI Runtimes, Git History tabs
- [ ] Project Structure section has Codebase, File Counts, GitHub Stats tabs
- [ ] All sections consume targets via `safe_tar_read()` — zero computation
- [ ] All DT tables have `caption=`
- [ ] All plots have `fig.cap=` in chunk headers
- [ ] `owner` and `repo` adapted to current project in GitHub API targets

## Resources

- **logger package**: https://daroczig.github.io/logger/
- **covr package**: https://covr.r-lib.org/
- **targets telemetry**: https://books.ropensci.org/targets/debugging.html
- **gert package**: https://docs.ropensci.org/gert/
- **gh package**: https://gh.r-lib.org/
- **Template vignette**: https://github.com/JohnGavin/llm/blob/main/vignettes/telemetry.qmd

## Related Skills

- targets-vignettes
- r-package-workflow
- nix-rix-r-environment
