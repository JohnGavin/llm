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

## Resources

- **logger package**: https://daroczig.github.io/logger/
- **covr package**: https://covr.r-lib.org/
- **targets telemetry**: https://books.ropensci.org/targets/debugging.html
- **gert package**: https://docs.ropensci.org/gert/
- **gh package**: https://gh.r-lib.org/

## Related Skills

- targets-vignettes
- r-package-workflow
- nix-rix-r-environment
