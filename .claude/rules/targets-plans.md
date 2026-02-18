# Targets Pipeline Rules

**Applies to**: `R/tar_plans/plan_*.R`

## Modular Pipeline Structure

**NEVER place pipeline definitions directly in `_targets.R`.**

Each `plan_*.R` file defines one logical group and returns a list:

```r
# R/tar_plans/plan_data_acquisition.R

#' Data Acquisition Pipeline
#'
#' Targets for fetching and processing buoy data from Marine Institute.
#'
#' @return List of tar_target objects

plan_data_acquisition <- list(

  targets::tar_target(
    raw_buoy_data,
    fetch_buoy_data_from_api()
  ),

  targets::tar_target(
    validated_buoy_data,
    validate_buoy_data(raw_buoy_data)
  ),

  targets::tar_target(
    processed_buoy_data,
    process_buoy_data(validated_buoy_data)
  )
)
```

## _targets.R Structure

The orchestrator file only combines plans:

```r
# _targets.R

library(targets)

# Set global options
tar_option_set(
  packages = c("dplyr", "tidyr", "arrow"),
  format = "qs",
  controller = crew::crew_controller_local(workers = 4)
)

# Source package functions (exclude dev/ and tar_plans/)
r_files <- list.files("R", pattern = "\\.R$", full.names = TRUE)
r_files <- r_files[!grepl("R/(dev|tar_plans)/", r_files)]
for (file in r_files) source(file)

# Source plans
plan_files <- list.files("R/tar_plans", pattern = "^plan_.*\\.R$", full.names = TRUE)
for (plan_file in plan_files) source(plan_file)

# Combine all plans
c(
  plan_data_acquisition,
  plan_quality_control,
  plan_analysis,
  plan_vignettes
)
```

## Naming Conventions

| Component | Convention | Example |
|-----------|------------|---------|
| Plan file | `plan_{domain}.R` | `plan_data_acquisition.R` |
| Plan list | `plan_{domain}` | `plan_data_acquisition` |
| Target | `{noun}_{modifier}` | `buoy_data_raw`, `wave_extremes_filtered` |
| Function | `{verb}_{noun}` | `fetch_buoy_data`, `validate_metrics` |

## Target Dependencies

Explicit dependencies via function arguments:

```r
# Target B depends on Target A
targets::tar_target(
  data_processed,
  process_data(data_raw)  # data_raw is a target
)
```

For multiple dependencies:

```r
targets::tar_target(
  analysis_complete,
  run_analysis(
    data = processed_data,
    config = config_params,
    metadata = station_metadata
  )
)
```

## Branching (Dynamic Targets)

For iterating over values:

```r
# Create branches over stations
targets::tar_target(
  station_ids,
  c("M2", "M3", "M4", "M5", "M6")
),

targets::tar_target(
  station_analysis,
  analyze_station(processed_data, station_id = station_ids),
  pattern = map(station_ids)
)
```

## Formats and Storage

```r
# For large data
targets::tar_target(
  large_dataset,
  process_large_data(raw_data),
  format = "parquet"  # Or "feather", "qs"
)

# For objects with environments (models, etc.)
targets::tar_target(
  fitted_model,
  fit_model(training_data),
  format = "qs"
)
```

## Crew Workers

For parallel execution:

```r
# In _targets.R
tar_option_set(
  controller = crew::crew_controller_local(
    workers = 4,
    seconds_idle = 60
  )
)

# Heavy computation targets run in parallel automatically
```

## Validation Targets

Include validation in pipelines:

```r
targets::tar_target(
  data_validation_results,
  pointblank::create_agent(data = processed_data) |>
    pointblank::col_vals_not_null(columns = c(time, value)) |>
    pointblank::col_vals_gt(columns = value, value = 0) |>
    pointblank::interrogate()
),

targets::tar_target(
  data_validated,
  {
    if (pointblank::all_passed(data_validation_results)) {
      processed_data
    } else {
      cli::cli_abort("Data validation failed")
    }
  }
)
```

## Vignette Pre-Computation

Compute data for vignettes as targets:

```r
# R/tar_plans/plan_vignettes.R

plan_vignettes <- list(

  # Pre-compute summary for vignette
  targets::tar_target(
    vignette_summary_data,
    create_vignette_summary(processed_data)
  ),

  # Pre-render plots
  targets::tar_target(
    vignette_plots,
    create_vignette_plots(vignette_summary_data)
  ),

  # Code examples as text (for validation)
  targets::tar_target(
    code_example_basic,
    c(
      "library(mypackage)",
      "data <- load_buoy_data()",
      "summary(data)"
    )
  ),

  # Validate code syntax
  targets::tar_target(
    code_example_validated,
    {
      parsed <- try(parse(text = paste(code_example_basic, collapse = "\n")))
      if (inherits(parsed, "try-error")) {
        cli::cli_abort("Code example has syntax error")
      }
      list(valid = TRUE, code = code_example_basic)
    }
  )
)
```

## Debugging

```r
# Check pipeline validity
targets::tar_validate()

# Visualize dependencies
targets::tar_visnetwork()

# Run single target
targets::tar_make(names = "specific_target")

# Check what's outdated
targets::tar_outdated()
```

## Evidence Tracking

Add telemetry targets:

```r
# Track pipeline execution
targets::tar_target(
  telemetry_pipeline_run,
  {
    tibble::tibble(
      timestamp = Sys.time(),
      targets_total = length(tar_manifest()$name),
      targets_outdated = length(tar_outdated()),
      duration_sec = as.numeric(Sys.time() - start_time)
    )
  },
  cue = tar_cue(mode = "always")
)
```
