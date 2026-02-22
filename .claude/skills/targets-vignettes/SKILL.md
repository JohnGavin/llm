# Targets Pipeline for Vignette Pre-calculation

## Description

This skill implements the pattern of using the targets package to pre-calculate all objects displayed in package vignettes. Vignettes focus on narrative and visualization while all computation happens through the targets pipeline.

## Purpose

Use this skill when:
- Creating R package vignettes that require heavy computation
- Building data analysis pipelines for reproducible research
- Need to separate computation from presentation
- Want vignettes to build quickly without re-running expensive calculations
- Creating telemetry and project statistics vignettes

## Key Principles

### Vignettes Load, Don't Compute

Vignettes should:
- Contain primarily text, explanations, and narrative
- Use `targets::tar_load()` or `targets::tar_read()` to load pre-calculated objects
- Display tables and plots that were computed via targets
- Build quickly since computation already happened

Vignettes should NOT:
- Run expensive computations directly
- Process raw data
- Generate complex visualizations from scratch
- Take a long time to build

## How It Works

### 1. Define Your Pipeline in _targets.R

```r
# _targets.R
library(targets)
library(tarchetypes)

# Source your package functions
tar_source()

# Define the pipeline
tar_plan(
  # Data loading
  tar_target(raw_data, read_raw_data("data-raw/input.csv")),

  # Data processing
  tar_target(clean_data, clean_dataset(raw_data)),
  tar_target(summary_stats, summarize_data(clean_data)),

  # Visualizations (return ggplot objects)
  tar_target(plot_distribution, plot_dist(clean_data)),
  tar_target(plot_trends, plot_time_series(clean_data)),
  tar_target(plot_comparison, plot_compare_groups(clean_data)),

  # Tables (return data frames or gt/kable objects)
  tar_target(table_summary, create_summary_table(summary_stats)),
  tar_target(table_detailed, create_detailed_table(clean_data)),

  # Save outputs for vignette use
  tar_target(
    vignette_objects,
    save_for_vignette(
      plot_distribution,
      plot_trends,
      table_summary
    ),
    format = "file"
  )
)
```

### 2. Create Package Functions That Return Objects

```r
# R/plotting.R

#' Create distribution plot
#'
#' @param data Cleaned data frame
#' @return A ggplot object
#' @export
plot_dist <- function(data) {
  library(ggplot2)

  ggplot(data, aes(x = value)) +
    geom_histogram(bins = 30, fill = "steelblue") +
    theme_minimal() +
    labs(
      title = "Distribution of Values",
      x = "Value",
      y = "Count"
    )
}
```

Key points:
- Functions return plot objects (ggplot), not plot to screen
- Functions return data frames or table objects, not print them
- All logic is in package functions, not in _targets.R
- Functions are documented and tested

### 3. Run the Pipeline Locally

```r
# Run the entire pipeline
targets::tar_make()

# Check what's available
targets::tar_manifest()

# Inspect a specific target
targets::tar_read(plot_distribution)

# Load multiple targets
targets::tar_load(c(plot_distribution, table_summary))
```

### 4. Create Vignettes That Load Results

```r
# vignettes/analysis.Rmd
---
title: "Analysis Results"
output: rmarkdown::html_vignette
vignette: >
  %\VignetteIndexEntry{Analysis Results}
  %\VignetteEngine{knitr::rmarkdown}
  %\VignetteEncoding{UTF-8}
---

```{r setup, include = FALSE}
knitr::opts_chunk$set(
  collapse = TRUE,
  comment = "#>",
  echo = FALSE,  # Hide code by default
  message = FALSE,
  warning = FALSE
)

library(targets)
```

## Introduction

Brief narrative explaining the analysis...

## Data Summary

```{r load-summary}
# Load pre-calculated table
tar_load(table_summary)
```

Here's a summary of the dataset:

```{r display-summary}
knitr::kable(table_summary)
```

## Distribution Analysis

```{r load-plot-dist}
# Load pre-calculated plot
tar_load(plot_distribution)
```

The distribution shows...

```{r display-plot-dist}
print(plot_distribution)
```

## Trends Over Time

```{r}
tar_load(plot_trends)
print(plot_trends)
```

```

## File Structure

```
package/
├── _targets.R              # Pipeline definition
├── _targets/               # Targets cache (gitignored)
│   ├── meta/
│   ├── objects/
│   └── user/
├── R/
│   ├── data_processing.R   # Data cleaning functions
│   ├── plotting.R          # Plotting functions
│   ├── tables.R            # Table generation functions
│   └── utils.R             # Helper functions
├── vignettes/
│   ├── analysis.Rmd        # Vignette loading targets
│   ├── results.Rmd         # Another vignette
│   └── telemetry.Rmd       # Project stats vignette
├── data-raw/
│   ├── input.csv           # Raw data
│   └── prepare_data.R      # Data preparation script
└── inst/
    └── logs/               # Logger output
```

## Common Patterns

### Pattern 1: Multiple Related Plots

```r
# _targets.R
tar_plan(
  # Generate a list of plots
  tar_target(
    plots_by_group,
    create_group_plots(clean_data)
  )
)

# R/plotting.R
create_group_plots <- function(data) {
  groups <- unique(data$group)

  plots <- lapply(groups, function(g) {
    subset_data <- data[data$group == g, ]
    ggplot(subset_data, aes(x = x, y = y)) +
      geom_point() +
      labs(title = paste("Group:", g))
  })

  names(plots) <- groups
  plots
}

# In vignette:
# tar_load(plots_by_group)
# plots_by_group$group1
# plots_by_group$group2
```

### Pattern 2: Conditional Targets

```r
# _targets.R
tar_plan(
  tar_target(use_cache, file.exists("cache/data.rds")),

  tar_target(
    data,
    if (use_cache) {
      readRDS("cache/data.rds")
    } else {
      fetch_and_process_data()
    }
  )
)
```

### Pattern 3: File Targets

```r
# _targets.R
tar_plan(
  # Save a file and track it
  tar_target(
    report_pdf,
    {
      rmarkdown::render("report.Rmd", output_file = "report.pdf")
      "report.pdf"
    },
    format = "file"
  )
)
```

### Pattern 4: Dynamic Branching

```r
# _targets.R
tar_plan(
  tar_target(input_files, list.files("data-raw", full.names = TRUE)),

  tar_target(
    processed_data,
    process_file(input_files),
    pattern = map(input_files)
  ),

  tar_target(combined_data, bind_rows(processed_data))
)
```

## Telemetry Vignette Pattern

Create a vignette that shows project statistics:

```r
# _targets.R
tar_plan(
  # ... your main pipeline ...

  # Telemetry targets
  tar_target(pipeline_meta, tar_meta()),
  tar_target(git_history, get_git_stats()),
  tar_target(package_structure, get_file_tree()),
  tar_target(test_coverage, get_coverage_stats()),
  tar_target(session_info, sessionInfo())
)

# R/telemetry.R
get_git_stats <- function() {
  library(gert)

  log <- gert::git_log(max = 100)

  list(
    total_commits = nrow(log),
    contributors = unique(log$author),
    recent_activity = log[1:10, ]
  )
}

get_file_tree <- function() {
  library(fs)

  tree <- fs::dir_tree(recurse = TRUE)
  capture.output(tree)
}

get_coverage_stats <- function() {
  library(covr)

  cov <- package_coverage()

  list(
    percent = percent_coverage(cov),
    by_file = coverage_by_file(cov)
  )
}
```

## Integration with pkgdown

### Pre-build Vignettes

```r
# _pkgdown.yml
articles:
  - title: Analysis
    contents:
      - analysis
      - results
  - title: Project Info
    contents:
      - telemetry

# Build vignettes first
# targets::tar_make()
# Then build site
# pkgdown::build_site()
```

### Automate in GitHub Actions

```yaml
# .github/workflows/pkgdown.yaml
- name: Build targets
  run: nix-shell default.nix --run "Rscript -e 'targets::tar_make()'"

- name: Build pkgdown site
  run: nix-shell default.nix --run "Rscript -e 'pkgdown::build_site()'"
```

## Code Examples as Targets

Store every static code block displayed in vignettes as a `targets` target.
This ensures code examples stay syntactically valid as APIs evolve.

### Pattern: text -> parse -> validate

1. **Helper function** (defined in `plan_doc_examples.R`):

```r
parse_code_example <- function(code_lines) {
  code_text <- paste(code_lines, collapse = "\n")
  tryCatch(
    {
      parsed <- parse(text = code_text)
      list(valid = TRUE, n_expressions = length(parsed),
           code = code_lines, error = NULL)
    },
    error = function(e) {
      list(valid = FALSE, n_expressions = 0L,
           code = code_lines, error = conditionMessage(e))
    }
  )
}
```

2. **Code text target** (one per display block):

```r
targets::tar_target(
  code_dd_load_data,
  {
    force(file.exists("R/database_parquet.R"))  # dependency tracking
    c(
      "library(coMMpass)",
      "",
      "clinical <- query_commpass_parquet(\"clinical\")"
    )
  }
)
```

3. **Parse validation target**:

```r
targets::tar_target(
  code_parsed_dd_load_data,
  parse_code_example(code_dd_load_data)
)
```

4. **Master validation gate** (fails pipeline on syntax errors):

```r
targets::tar_target(
  doc_examples_validation,
  {
    parse_results <- list(
      dd_load_data = code_parsed_dd_load_data,
      # ... all parse targets
    )
    all_valid <- all(vapply(parse_results, function(x) x$valid, logical(1)))
    if (!all_valid) {
      failed <- names(parse_results)[!vapply(parse_results, function(x) x$valid, logical(1))]
      cli::cli_abort(c("x" = "Code examples failed syntax validation",
                        "i" = "Failed: {paste(failed, collapse = ', ')}"))
    }
    list(all_valid = all_valid, n_examples = length(parse_results))
  }
)
```

### Display in Rmd vignettes

Use `<details>` HTML for show/hide (hidden by default):

````rmd
```{r dd-load-data-code, results='asis'}
code <- safe_tar_read("code_dd_load_data")
if (!is.null(code)) {
  cat("<details>\n<summary>Show code</summary>\n\n```r\n")
  cat(paste(code, collapse = "\n"))
  cat("\n```\n</details>\n")
} else {
  cat("*Code example not available. Run `tar_make()` first.*\n")
}
```
````

### Display in Qmd vignettes

````qmd
```{r}
#| echo: false
#| results: asis
targets::tar_load(code_dd_load_data)
cat("```r\n", paste(code_dd_load_data, collapse = "\n"), "\n```", sep = "")
```
````

### Reference implementations

- **irishbuoys**: `irishbuoys/R/tar_plans/plan_doc_examples.R` (15 code targets, 468 LOC)
- **coMMpass**: `coMMpass/R/tar_plans/plan_doc_examples.R` (4 code targets)

## Best Practices

### 1. Keep Functions Pure

```r
# Good: Pure function that returns an object
create_plot <- function(data) {
  ggplot(data, aes(x, y)) + geom_point()
}

# Bad: Function with side effects
create_plot <- function(data) {
  p <- ggplot(data, aes(x, y)) + geom_point()
  ggsave("plot.png", p)  # Side effect!
  print(p)               # Side effect!
}
```

### 2. Use Meaningful Target Names

```r
# Good
tar_target(summary_statistics_by_group, ...)
tar_target(plot_temporal_trends, ...)

# Bad
tar_target(x, ...)
tar_target(plot1, ...)
```

### 3. Document Expected Outputs

```r
#' Create summary table
#'
#' @param data Cleaned data frame with columns x, y, group
#' @return A data frame with columns: group, mean_x, sd_x, n
#' @export
create_summary_table <- function(data) {
  # ...
}
```

### 4. Version Your Pipeline

Use git to track changes to _targets.R:

```r
# R/log/git_gh.R
library(gert)

gert::git_add("_targets.R")
gert::git_commit("Update pipeline: add new visualization targets")
```

### 5. Invalidate Strategically

Use `tar_invalidate()` when you need to force re-computation:

```r
# Force re-run of specific target
targets::tar_invalidate(plot_distribution)

# Re-run downstream targets
targets::tar_make()
```

## Debugging Targets

### Check Target Status

```r
# See what needs to run
targets::tar_outdated()

# Visualize the pipeline
targets::tar_visnetwork()

# See detailed metadata
targets::tar_meta()
```

### Debug Individual Targets

```r
# Load target dependencies
targets::tar_load_globals()

# Interactively run target code
targets::tar_load(clean_data)
# Now manually run the code for the next target

# Debug mode
targets::tar_option_set(debug = "plot_distribution")
targets::tar_make()
```

## Common Issues

### Vignette can't find targets

**Solution**: Run `targets::tar_make()` before building vignettes

```r
targets::tar_make()
devtools::build_vignettes()
```

### Targets out of date

**Solution**: Check what changed

```r
targets::tar_outdated()
targets::tar_make()
```

### Missing dependencies

**Solution**: Ensure all packages are in DESCRIPTION

```r
usethis::use_package("targets")
usethis::use_package("tarchetypes")
```

## CI Integration

### Vignettes that use `tar_load()` in CI

When vignettes call `tar_load()` or `tar_read()`, CI must have `_targets/` present.
Use the **targets-runs branch pattern** (see `targets-ci-pipeline` skill):

1. Restore `_targets/` from `targets-runs` orphan branch
2. Run `tar_make()` to update targets
3. Render vignettes (tar_load works because `_targets/` is present)
4. Commit rendered outputs to main
5. Save `_targets/` state back to `targets-runs`

**Key points:**
- `_targets/` is gitignored on main — it only exists on the `targets-runs` branch
- Vignette rendering happens AFTER pipeline run, BEFORE state save
- `tar_validate()` runs in R-CMD-check (fast, catches definition errors on every push)
- Full `tar_make()` runs on schedule or manual trigger

### Pipeline validation in R-CMD-check

Every project with `_targets.R` should include `tar_validate()` in R-CMD-check:

```yaml
      - name: Validate targets pipeline
        if: hashFiles('_targets.R') != ''
        run: |
          nix-shell default.nix -A shell --run "Rscript -e '
            targets::tar_validate()
            cat(\"Pipeline valid:\", length(targets::tar_manifest()\$name), \"targets\\n\")
          '"
```

## Resources

- **targets manual**: https://books.ropensci.org/targets/
- **targets package**: https://docs.ropensci.org/targets/
- **Example pipelines**: https://github.com/ropensci/targets/tree/main/inst/examples
- **Best practices**: https://books.ropensci.org/targets/practice.html
- **targets-ci-pipeline skill**: Full CI pipeline patterns
