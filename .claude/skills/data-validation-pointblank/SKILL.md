---
name: data-validation-pointblank
description: Use when implementing data contracts, automated validation with pointblank, integrating validation into targets pipelines, or setting up data quality checks with crew. Triggers: pointblank, data validation, data contracts, data quality, validation rules.
---
# Data Validation with pointblank

This skill defines the workflow for implementing **Data Contracts** and **Automated Validation** using the `pointblank` package. It integrates closely with `targets` for orchestration and `crew` for distributed execution.

## Core Concepts

-   **Agent**: The validation engine. It collects data, rules, and execution plans.
-   **Informant**: The metadata engine. It tracks schema info, snippets, and summary stats (Data Dictionary).
-   **Interrogate**: The action of running the rules against the data.
-   **Action Levels**: Thresholds for deciding if a violation is a `WARN` (log it) or `STOP` (halt pipeline).

## Column Name Contracts (Metaprogramming)

Don't write 100 manual rules. Use **metaprogramming** to enforce rules based on column prefixes (Emily Riederer's pattern).

```r
#' Auto-generate rules based on column prefixes
#' @param agent A pointblank agent
#' @return An updated agent
enforce_naming_conventions <- function(agent) {
  # Get column names from the target data
  cols <- agent$tbl |> colnames()
  
  agent |>
    # n_* columns must be non-negative integers
    col_vals_gte(columns = matches("^n_"), value = 0) |>
    col_is_integer(columns = matches("^n_")) |>
    
    # is_* columns must be logical (0/1 or TRUE/FALSE)
    col_vals_in_set(columns = matches("^is_"), set = c(0, 1, TRUE, FALSE)) |>
    
    # pct_* columns must be between 0 and 1
    col_vals_between(columns = matches("^pct_"), left = 0, right = 1) |>
    
    # dt_* columns must be dates (not strings)
    col_is_date(columns = matches("^dt_"))
}
```

## Targets Integration (The Gatekeeper)

Validation should prevent downstream steps from consuming bad data. Use `cli::cli_abort()` for informative error messages (Tidyverse style).

```r
# _targets.R
list(
  # 1. Load Data
  tar_target(raw_file, "data/raw.csv", format = "file"),
  tar_target(raw_data, read_csv(raw_file)),
  
  # 2. Define Validation Agent
  tar_target(
    validation_agent,
    create_agent(raw_data) |>
      enforce_naming_conventions() |>
      # Strict: Stop if > 0.1% fail, Warn if any fail
      action_levels(warn_at = 1, stop_at = 0.001)
  ),
  
  # 3. Interrogate (The Gate)
  tar_target(
    validation_results,
    command = {
      res <- interrogate(validation_agent)
      
      # Tidyverse-style error handling
      if (!all_passed(res)) {
         cli::cli_abort(
           c(
             "x" = "Data Contract Violation: Rules failed.",
             "i" = "Inspect the validation report at {.file docs/data_quality/raw_report.html}",
             "!" = "Pipeline stopped to prevent propagation of corrupt data."
           ),
           class = "pointblank_error"
         )
      }
      res
    }
  ),
  
  # 4. Save Report (Artifact)
  tar_target(
    validation_report,
    export_report(validation_results, filename = "docs/data_quality/raw_report.html"),
    format = "file"
  ),
  
  # 5. Downstream (Only runs if Step 3 succeeds)
  tar_target(clean_data, process(raw_data)) # depends on validation implicit success
)
```

## Crew Integration (Parallel Validation)

For massive datasets, move validation to a worker to keep the main R session free.

```r
tar_target(
  validation_results,
  command = interrogate(validation_agent),
  deployment = "worker", # Runs on crew worker
  storage = "worker",
  retrieval = "worker"
)
```

## YAML-Driven Contracts (Infrastructure as Code)

Store rules in `inst/contracts/` to allow non-coders to edit them.

```yaml
# inst/contracts/sales_data.yml
tbl: sales_data
steps:
  - col_vals_gte:
      columns: n_units
      value: 0
  - col_vals_not_null:
      columns: [id_transaction, dt_sale]
```

**Loading in R:**
```r
agent <- yaml_read_agent("inst/contracts/sales_data.yml") |>
  set_tbl(actual_data) |>
  interrogate()
```

## Integration with readr

### Validating Parse Problems

Combine readr's `problems()` with pointblank validation:

```r
#' Validate parse problems from readr
#' @param df Parsed tibble (may have problems attribute)
#' @param max_problems Maximum allowed problems before failing
validate_parse_quality <- function(df, max_problems = 10L) {
  probs <- readr::problems(df)
  n_probs <- nrow(probs)

  if (n_probs > max_problems) {
    cli::cli_abort(c(
      "x" = "Too many parse problems: {n_probs} (max: {max_problems})",
      "i" = "Use readr::problems(df) to inspect",
      "!" = "Fix source data or adjust column types"
    ))
  }

  if (n_probs > 0L) {
    cli::cli_warn("{n_probs} parse problems (within threshold)")
  }

  invisible(df)
}
```

### Combined Pipeline

```r
# _targets.R
list(
  # 1. Read with explicit types
  tar_target(raw_file, "data/raw.csv", format = "file"),

  tar_target(
    raw_data,
    {
      df <- readr::read_csv(
        raw_file,
        col_types = readr::cols(
          id = readr::col_integer(),
          amount = readr::col_double(),
          date = readr::col_date(),
          .default = readr::col_character()
        ),
        na = c("", "NA", "N/A", "n/a", "-", "NULL")
      )

      # Validate parse quality
      validate_parse_quality(df, max_problems = 50L)
    }
  ),

  # 2. pointblank validation (runs after parse validation)
  tar_target(
    validated_data,
    {
      agent <- create_agent(raw_data) |>
        col_vals_not_null(columns = c(id, date)) |>
        col_vals_gte(columns = amount, value = 0, na_pass = TRUE) |>
        interrogate()

      if (!all_passed(agent)) {
        cli::cli_abort("Data contract violation")
      }

      raw_data
    }
  )
)
```

### NA Rate Validation

Add NA rate checks to pointblank agents:

```r
#' Check NA rates are within acceptable thresholds
#' @param agent pointblank agent
#' @param critical_cols Columns that must have <1% NA
#' @param warn_threshold Threshold for warnings
add_na_rate_checks <- function(agent, critical_cols, warn_threshold = 0.01) {
  tbl <- agent$tbl
  n_rows <- nrow(tbl)

  for (col in critical_cols) {
    na_rate <- sum(is.na(tbl[[col]])) / n_rows
    if (na_rate > warn_threshold) {
      cli::cli_warn(c(
        "!" = "Column {.field {col}} has {.pct {round(na_rate * 100, 2)}}% NA",
        "i" = "Threshold: {.pct {warn_threshold * 100}}%"
      ))
    }
  }

  agent |>
    col_vals_not_null(columns = tidyselect::all_of(critical_cols))
}
```

## Metrics & Error Handling Style

Follow [Tidyverse Error Style](https://style.tidyverse.org/errors.html):

1.  **Use `cli::cli_abort()`**: Never use base `stop()`.
2.  **Structured Messages**: Use bullets (`x`, `i`, `!`, `*`) to separate the error, context, and hints.
3.  **Classes**: Assign a specific error class (e.g., `data_contract_error`) for programmatic handling.

**Bad:**
```r
stop("Data is bad")
```

**Good:**
```r
cli::cli_abort(
  c(
    "x" = "Validation failed for table {.val {table_name}}.",
    "i" = "{n_fail} rows violated the 'no negative costs' rule.",
    "!" = "Check source file {.file {source_path}}."
  ),
  class = "data_contract_error"
)
```