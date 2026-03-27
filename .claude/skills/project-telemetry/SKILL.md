# Project Telemetry and Logging

## Description

This skill implements comprehensive project telemetry, logging, and statistics tracking for R packages. It covers logging with the logger package, creating telemetry vignettes with targets, and tracking project health metrics.

## Reference Files

| Topic | File |
|-------|------|
| Logger setup, rotation, usage patterns, best practices | `references/logging-infrastructure.md` |
| Full R function implementations (git, coverage, pipeline, GitHub) | `references/telemetry-functions.md` |
| Complete Rmd vignette template | `references/vignette-template.md` |
| Mandatory vignette spec, required targets, implementation patterns, checklist | `references/mandatory-vignette-spec.md` |

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
- Rotate logs at 5MB, keep 3 versions (essential for launchd/cron)

### Grep-Parseable Error Format (MANDATORY)

Every error MUST produce a single-line `ERROR:` entry that `grep` can find:

```r
# WRONG: multi-line cli message only (human-friendly but not grep-able)
cli::cli_abort(c("x" = "Failed to fetch data", "i" = "Check API key"))

# RIGHT: log a grep-able line THEN abort with structured message
logger::log_error("ERROR: Failed to fetch data — check API key")
cli::cli_abort(c("x" = "Failed to fetch data", "i" = "Check API key"))
```

**Rule:** `logger::log_error("ERROR: {reason}")` on a single line before every `cli::cli_abort()`. This ensures CI logs, pipeline output, and session logs are all searchable with `grep ERROR`.

```bash
# Find all errors in pipeline log
grep "^ERROR:" inst/logs/pipeline.log

# Count errors in CI output
grep -c "ERROR:" ci-output.txt
```

### Telemetry as Documentation

- Create vignette showing project health
- Track pipeline execution statistics
- Visualize git history and contributions
- Show test coverage metrics
- Document package structure

### Targets Integration

- Pre-calculate all telemetry statistics via targets
- Load statistics in vignette via `safe_tar_read()` — zero inline computation
- Update telemetry before major releases
- Version control telemetry results

## How It Works

### Step 1: Setup Logger Infrastructure

See `references/logging-infrastructure.md` for full code.

Key files:
- `R/zzz.R` — configure logger on package load
- `R/setup/init_logging.R` — create log directories
- `R/utils/log_rotation.R` — rotate logs at 5MB

```r
# Minimal setup in R/zzz.R
.onLoad <- function(libname, pkgname) {
  logger::log_appender(logger::appender_file("inst/logs/package.log"))
  logger::log_threshold(logger::INFO)
  logger::log_info("Package {pkgname} loaded")
}
```

### Step 2: Use Logger Throughout Package

See `references/logging-infrastructure.md` for usage patterns in package functions, dev scripts, and git/GitHub operation logs.

Quick reference:
```r
logger::log_info("Starting process: {param}")
logger::log_debug("Detail: {value}")
logger::log_error("Failed: {e$message}")
```

### Step 3: Create Telemetry Targets Pipeline

Add to `R/tar_plans/plan_telemetry.R`:

```r
# R/tar_plans/plan_telemetry.R
plan_telemetry <- list(
  # Git statistics
  tar_target(git_history, get_git_history()),
  tar_target(git_contributors, get_git_contributors()),

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

  # GitHub statistics
  tar_target(github_stats, get_github_stats()),
  tar_target(workflow_status, get_workflow_status()),

  # Mandatory vignette targets (see references/mandatory-vignette-spec.md)
  tar_target(vig_pipeline_summary, ..., cue = tar_cue(mode = "always")),
  tar_target(vig_commit_velocity, ...),
  tar_target(vig_github_activity, ..., cue = tar_cue(mode = "always")),
  tar_target(vig_codebase_metrics, ...)
)
```

See `references/telemetry-functions.md` for all function implementations.

### Step 4: Create Telemetry Vignette

See `references/vignette-template.md` for the full Rmd template.

See `references/mandatory-vignette-spec.md` for the complete mandatory section structure and pre-commit checklist.

Quick section structure:
```
# LLM Usage & Costs       — cost trends, cumulative, breakdowns
# Session Efficiency       — duration, cost efficiency, model breakdown
# Pipeline Metrics         — plans/targets, top by size, top by compute time
# GitHub Activity          — commit velocity, issues/PRs, CI runtimes
# Project Structure        — codebase metrics, file counts, GitHub stats
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
│   └── telemetry.qmd          # Telemetry vignette
└── R/tar_plans/
    └── plan_telemetry.R       # Telemetry targets
```

## Integration with pkgdown

```yaml
# _pkgdown.yml
articles:
  - title: Project Info
    contents:
      - telemetry
      - architecture
```

## Automated Updates Before Release

```r
# R/setup/prepare_release.R
library(logger)
library(targets)

log_info("Preparing release")
tar_make()
log_info("Running targets pipeline complete")

devtools::build_vignettes()
log_info("Vignettes built")

pkgdown::build_site()
log_info("Release preparation complete")
```

## CI Run Time Analysis (MANDATORY)

Every telemetry vignette MUST include CI run time distributions. Required visualizations:

1. Summary table: Mean, median, min, max, SD per workflow
2. Box plot: Distribution comparison across workflows
3. Histogram: Run time frequency per workflow
4. Trend plot: Run times over time (detect regressions)
5. Success rate table: Percentage by workflow

See `references/telemetry-functions.md` for the `get_workflow_runs()` implementation.

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
