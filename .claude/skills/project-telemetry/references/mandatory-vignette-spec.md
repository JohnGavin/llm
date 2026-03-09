# Mandatory Vignette Specification

Every `telemetry.qmd` vignette MUST include ALL sections below.
Each section consumes pre-computed targets via `safe_tar_read()` — zero inline computation.

## Required Section Structure

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

# Pipeline Metrics                    (MANDATORY)
  ## Plans & Targets      — plan file names, target count per plan
  ## Top by Size          — top 5 targets by stored bytes
  ## Top by Compute Time  — top 5 targets by execution seconds

# GitHub Activity                     (MANDATORY)
  ## Commit Velocity      — weekly commit counts with timeline
  ## Issues & PRs         — open/closed/merged counts
  ## CI Workflow Runtimes — box plot of successful run durations
  ## Git History          — daily commit frequency

# Project Structure
  ## Codebase             (MANDATORY)
                          — R files, test files, vignettes,
                            plans, exports, lines of code, version
  ## File Counts          — file type distribution
  ## GitHub Stats         — stars, forks, branches, last commit
```

## Required Targets

Define in `plan_vignette_outputs.R` or `plan_telemetry.R`:

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

## Implementation Patterns

### Pipeline Summary Target

Adapt `owner`/`repo` per project:

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

### GitHub Activity Target

Adapt `owner`/`repo` per project:

```r
tar_target(
  vig_github_activity,
  {
    owner <- "JohnGavin"
    repo <- "YOURPACKAGE"  # Change per project
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
      prs_merged = sum(sapply(prs_closed, function(x) !is.null(x$merged_at)))
    )
  },
  cue = tar_cue(mode = "always")
)
```

### Codebase Metrics Target

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

## Reference Implementations

| Project | Plan file | Vignette |
|---------|-----------|----------|
| **llm** (canonical) | `R/tar_plans/plan_vignette_outputs.R` | `vignettes/telemetry.qmd` |
| **irishbuoys** (most complete) | `R/tar_plans/plan_telemetry.R` | `vignettes/telemetry.qmd` |

## CI Run Time Visualizations (MANDATORY)

Every telemetry vignette MUST include these CI run time visualizations:

1. **Summary table**: Mean, median, min, max, SD per workflow
2. **Box plot**: Distribution comparison across workflows
3. **Histogram**: Run time frequency per workflow
4. **Trend plot**: Run times over time (detect regressions)
5. **Success rate table**: Percentage by workflow

Template: See `vignettes/telemetry.qmd` in the llm project.

## Checklist Before Commit

- [ ] All 6 mandatory sections present in telemetry.qmd
- [ ] Pipeline Metrics section has Plans & Targets, Top by Size, Top by Compute Time tabs
- [ ] GitHub Activity section has Commit Velocity, Issues & PRs, CI Runtimes, Git History tabs
- [ ] Project Structure section has Codebase, File Counts, GitHub Stats tabs
- [ ] All sections consume targets via `safe_tar_read()` — zero computation
- [ ] All DT tables have `caption=`
- [ ] All plots have `fig.cap=` in chunk headers
- [ ] `owner` and `repo` adapted to current project in GitHub API targets
