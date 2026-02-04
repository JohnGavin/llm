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

Validation should prevent downstream steps from consuming bad data.

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
      
      # If configured to STOP, targets errors out here.
      # If WARN, it proceeds but logs issues.
      if (!all_passed(res)) {
         # Optional: Send alert email
         # email_blast(res) 
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

## Metrics & Error Handling

*   **Adherence Score:** `res$validation_set$fraction_pass`
*   **Drift Detection:** Compare `scan_data(new_data)` fingerprint with `scan_data(old_data)`.

**API:**
*   `validate_contract(data, schema)`: Returns TRUE/FALSE.
*   `get_violation_report(agent)`: Returns tibble of failing rows.
