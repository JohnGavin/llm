# targets Pipeline Specification

## Description

Canonical patterns for organizing targets pipelines in R packages. Covers modular plan files, crew integration, and anti-patterns to avoid.

## Purpose

Use this skill when:
- Setting up a new targets pipeline
- Refactoring an existing _targets.R file
- Adding crew parallel execution
- Reviewing pipeline structure for best practices

## Core Architecture

### Directory Structure

```
project/
├── _targets.R              # Orchestrator ONLY (no target definitions)
├── R/
│   └── tar_plans/          # Modular pipeline components
│       ├── plan_data_acquisition.R
│       ├── plan_quality_control.R
│       ├── plan_analysis.R
│       ├── plan_visualization.R
│       ├── plan_vignette_outputs.R
│       └── plan_pkgctx.R
└── _targets/               # Cache (gitignored)
```

### _targets.R Structure (Orchestrator Only)

```r
# _targets.R - ORCHESTRATION ONLY
# NO tar_target() definitions here!

library(targets)
library(tarchetypes)

# Set global options
tar_option_set(
  packages = c("dplyr", "ggplot2", "arrow"),
  format = "qs",  # Fast serialization
  memory = "transient",
  garbage_collection = TRUE
)

# Optional: crew parallel execution
tar_option_set(
  controller = crew::crew_controller_local(
    workers = parallel::detectCores() - 1,
    seconds_idle = 60
  )
)

# Source package functions (exclude dev/ and tar_plans/)
for (file in list.files("R", pattern = "\\.R$", full.names = TRUE)) {
  if (!grepl("R/(dev|tar_plans)/", file)) source(file)
}

# Source and combine all plans
plan_files <- list.files(
  "R/tar_plans",
  pattern = "^plan_.*\\.R$",
  full.names = TRUE
)
for (plan_file in plan_files) source(plan_file)

# Combine all plans (each plan_*.R defines a list)
c(
  plan_data_acquisition,
  plan_quality_control,
  plan_analysis,
  plan_visualization,
  plan_vignette_outputs
)
```

### Plan File Structure

Each `R/tar_plans/plan_*.R` file:

```r
# R/tar_plans/plan_data_acquisition.R

#' @title Data Acquisition Pipeline
#' @description Targets for fetching and loading raw data

plan_data_acquisition <- list(
  # Raw data loading
  tar_target(
    raw_data_path,
    "data-raw/input.csv",
    format = "file"
  ),

  tar_target(
    raw_data,
    read_csv(raw_data_path)
  ),

  # Validation
  tar_target(
    data_validated,
    validate_schema(raw_data)
  )
)
```

## Plan Naming Convention

| Plan File | Purpose | Typical Targets |
|-----------|---------|-----------------|
| `plan_data_acquisition.R` | Load external data | raw_*, fetch_* |
| `plan_quality_control.R` | Validation, QC | qc_*, validate_* |
| `plan_analysis.R` | Core analysis | model_*, result_* |
| `plan_visualization.R` | Plots and tables | plot_*, table_* |
| `plan_vignette_outputs.R` | Vignette data | vig_* |
| `plan_doc_examples.R` | Code examples | code_example_* |
| `plan_pkgctx.R` | Package context | pkgctx_* |
| `plan_telemetry.R` | Pipeline metrics | telem_* |

## Crew Integration Patterns

### Basic Local Controller

```r
tar_option_set(
  controller = crew::crew_controller_local(
    workers = 4,
    seconds_idle = 60
  )
)
```

### With Logging and Metrics

```r
tar_option_set(
  controller = crew::crew_controller_local(
    workers = parallel::detectCores() - 1,
    seconds_idle = 120,
    options_local = crew::crew_options_local(
      log_directory = "logs/crew/"
    ),
    options_metrics = crew::crew_options_metrics(
      path = "/dev/stdout",
      seconds_interval = 5
    )
  )
)
```

### Resource-Specific Controllers

```r
# Different controllers for different target types
ctrl_fast <- crew::crew_controller_local(
  name = "fast",
  workers = 4
)

ctrl_memory <- crew::crew_controller_local(
  name = "memory_intensive",
  workers = 2  # Fewer workers for memory-heavy tasks
)

tar_option_set(
  controller = crew::crew_controller_group(ctrl_fast, ctrl_memory)
)

# In plan file:
tar_target(
  heavy_computation,
  run_heavy_task(data),
  resources = tar_resources(
    crew = tar_resources_crew(controller = "memory_intensive")
  )
)
```

## Target Patterns

### Dynamic Branching

```r
# Map over files
tar_target(input_files, list.files("data", full.names = TRUE)),
tar_target(
  processed,
  process_file(input_files),
  pattern = map(input_files)
)

# Cross parameter grid
tar_target(params, expand.grid(a = 1:3, b = c("x", "y"))),
tar_target(
  results,
  run_model(params$a, params$b),
  pattern = map(params)
)
```

### File Targets

```r
# Track input file changes
tar_target(
  config_file,
  "config.yaml",
  format = "file"
)

# Generate output file
tar_target(
  report,
  {
    render("report.Rmd")
    "report.html"
  },
  format = "file"
)
```

### Vignette Data Pattern

```r
# plan_vignette_outputs.R
plan_vignette_outputs <- list(
  # Pre-compute summary for vignette
  tar_target(
    vig_summary_table,
    create_summary_table(analysis_results)
  ),

  # Pre-compute plot
  tar_target(
    vig_main_plot,
    create_main_visualization(analysis_results)
  ),

  # Validation gate - ensures all vignette data ready
  tar_target(
    vig_ready,
    {
      stopifnot(!is.null(vig_summary_table))
      stopifnot(!is.null(vig_main_plot))
      TRUE
    }
  )
)
```

## Anti-Patterns (NEVER DO)

### ❌ Targets in _targets.R

```r
# BAD: _targets.R with inline targets
library(targets)
list(
  tar_target(data, load_data()),  # ❌ Should be in plan file
  tar_target(model, fit(data))    # ❌ Should be in plan file
)
```

### ❌ Computation in Vignettes

```r
# BAD: Vignette running queries
```{r}
data <- DBI::dbGetQuery(con, "SELECT * FROM table")  # ❌
summary(data)
```
```

### ❌ Storing htmlwidgets in Targets

```r
# BAD: tar_visnetwork() inside tar_target() (targets >= 1.3)
tar_target(
  pipeline_viz,
  tar_visnetwork()  # ❌ Can't serialize htmlwidgets
)
```

### ❌ Side Effects in Target Commands

```r
# BAD: Writing files as side effect
tar_target(
  result,
  {
    data <- compute()
    saveRDS(data, "output.rds")  # ❌ Side effect
    data
  }
)

# GOOD: Use format = "file" for outputs
tar_target(
  result_file,
  {
    data <- compute()
    path <- "output.rds"
    saveRDS(data, path)
    path  # Return the path
  },
  format = "file"
)
```

### ❌ Missing Dependencies

```r
# BAD: Implicit dependency via global variable
my_param <- 42
tar_target(result, compute(my_param))  # ❌ my_param not tracked

# GOOD: Explicit target dependency
tar_target(my_param, 42),
tar_target(result, compute(my_param))  # ✓ Tracked
```

## Debugging Targets

### Check Pipeline State

```r
tar_manifest()      # List all targets
tar_outdated()      # What needs to run
tar_visnetwork()    # DAG visualization
tar_meta()          # Build metadata
```

### Debug Specific Target

```r
tar_load_globals()           # Load all upstream dependencies
tar_read(upstream_target)    # Read specific target
# Now interactively run target code

# Or use debug mode
tar_option_set(debug = "problem_target")
tar_make()
```

### Validate Pipeline

```r
tar_validate()  # Check for errors in _targets.R
```

## Best Practices Checklist

- [ ] `_targets.R` contains NO `tar_target()` calls
- [ ] Each `plan_*.R` returns a list of targets
- [ ] Targets have meaningful names (not `x`, `data1`)
- [ ] Dynamic branching uses `pattern = map()`
- [ ] File outputs use `format = "file"`
- [ ] Vignette data has `vig_` prefix
- [ ] crew workers set via `tar_option_set()`
- [ ] `_targets/` in `.gitignore`
- [ ] `tar_validate()` passes

## Related Skills

- `crew-operations` - Advanced crew patterns
- `targets-vignettes` - Pre-calculating vignette data
- `pipeline-choice` - When to use targets vs rixpress

## Resources

- [targets Manual](https://books.ropensci.org/targets/)
- [targets + crew](https://books.ropensci.org/targets/crew.html)
- [tarchetypes](https://docs.ropensci.org/tarchetypes/)
