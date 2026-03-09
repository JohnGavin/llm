# Telemetry Functions Reference

Full implementations for `R/telemetry.R`.

## Git History

```r
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
```

## Package Structure

```r
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
```

## Test Coverage

```r
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
```

## Pipeline Timing

```r
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
```

## Session Info

```r
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
```

## GitHub Statistics

```r
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

## CI Run Time Analysis

```r
# Fetch workflow runs with duration
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
