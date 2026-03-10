# Telemetry Functions Reference

Full implementations for `R/telemetry.R`.

## Git Changelog (per-vignette footer)

```r
#' Parse git log with numstat for changelog display
#' @param max_commits Maximum number of commits to parse
#' @return tibble with date, type, summary, n_files, lines_added, lines_removed, file_categories
parse_git_changelog <- function(max_commits = 20) {
  if (!requireNamespace("gert", quietly = TRUE)) return(NULL)
  log_df <- gert::git_log(max = max_commits)

  numstat_raw <- system2(
    "git",
    c("log", paste0("-", max_commits), "--numstat", "--format=COMMIT:%H"),
    stdout = TRUE, stderr = FALSE
  )

  current_hash <- NA_character_
  records <- list()
  for (line in numstat_raw) {
    if (grepl("^COMMIT:", line)) {
      current_hash <- sub("^COMMIT:", "", line)
    } else if (nzchar(trimws(line)) && !is.na(current_hash)) {
      parts <- strsplit(trimws(line), "\t")[[1]]
      if (length(parts) == 3) {
        records[[length(records) + 1]] <- data.frame(
          hash = current_hash,
          added = suppressWarnings(as.integer(parts[1])),
          deleted = suppressWarnings(as.integer(parts[2])),
          file = parts[3], stringsAsFactors = FALSE
        )
      }
    }
  }

  numstat_df <- if (length(records) > 0) do.call(rbind, records)
    else data.frame(hash = character(), added = integer(),
                    deleted = integer(), file = character(),
                    stringsAsFactors = FALSE)

  # Categorize files and commits
  categorize_file <- function(f) {
    dplyr::case_when(
      grepl("^R/", f) ~ "R Source", grepl("^tests/", f) ~ "Tests",
      grepl("^vignettes/", f) ~ "Vignettes", grepl("^\\.github/", f) ~ "CI/CD",
      grepl("^man/", f) ~ "Docs",
      grepl("DESCRIPTION|NAMESPACE|\\.yml$|\\.yaml$", f) ~ "Config",
      TRUE ~ "Other"
    )
  }
  categorize_commit <- function(msg) {
    msg <- trimws(msg)
    dplyr::case_when(
      grepl("^feat[:(]", msg, ignore.case = TRUE) ~ "New Feature",
      grepl("^fix[:(]", msg, ignore.case = TRUE) ~ "Bug Fix",
      grepl("^docs[:(]", msg, ignore.case = TRUE) ~ "Documentation",
      grepl("^ci[:(]", msg, ignore.case = TRUE) ~ "CI/CD",
      grepl("^refactor[:(]", msg, ignore.case = TRUE) ~ "Refactoring",
      grepl("^test[:(]", msg, ignore.case = TRUE) ~ "Tests",
      grepl("^chore[:(]", msg, ignore.case = TRUE) ~ "Maintenance",
      grepl("^style[:(]", msg, ignore.case = TRUE) ~ "Style",
      grepl("^perf[:(]", msg, ignore.case = TRUE) ~ "Performance",
      TRUE ~ "Other"
    )
  }

  if (nrow(numstat_df) > 0) {
    numstat_df$category <- categorize_file(numstat_df$file)
    agg <- numstat_df |>
      dplyr::group_by(hash) |>
      dplyr::summarise(
        n_files = dplyr::n(),
        lines_added = sum(added, na.rm = TRUE),
        lines_removed = sum(deleted, na.rm = TRUE),
        file_categories = paste(sort(unique(category)), collapse = ", "),
        .groups = "drop"
      )
  } else {
    agg <- data.frame(hash = character(), n_files = integer(),
                      lines_added = integer(), lines_removed = integer(),
                      file_categories = character(), stringsAsFactors = FALSE)
  }

  log_df$hash <- substr(log_df$commit, 1, 40)
  agg$hash <- substr(agg$hash, 1, 40)

  result <- dplyr::left_join(
    tibble::tibble(date = as.Date(log_df$time), hash = log_df$hash,
                   message = log_df$message),
    agg, by = "hash"
  )
  result$type <- categorize_commit(result$message)
  result$summary <- vapply(strsplit(result$message, "\n"), `[`, character(1), 1)
  result$n_files[is.na(result$n_files)] <- 0L
  result$lines_added[is.na(result$lines_added)] <- 0L
  result$lines_removed[is.na(result$lines_removed)] <- 0L
  result$file_categories[is.na(result$file_categories)] <- ""

  result[, c("date", "type", "summary", "n_files",
             "lines_added", "lines_removed", "file_categories")]
}
```

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
