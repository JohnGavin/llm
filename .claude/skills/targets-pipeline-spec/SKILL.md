---
name: targets-pipeline-spec
description: Use when organizing targets pipelines in R packages, setting up modular plan files, integrating crew with targets, or avoiding common targets anti-patterns. Triggers: targets, pipeline, tar_plan, targets architecture, modular plans, _targets.R.
---
# targets Pipeline Specification

## Description

Canonical patterns for organizing targets pipelines in R packages. Covers modular plan files, crew integration, and anti-patterns to avoid.

## Purpose

Use this skill when:
- Setting up a new targets pipeline
- Refactoring an existing _targets.R file
- Adding crew parallel execution
- Reviewing pipeline structure for best practices

## targets Is Not Just for Data Pipelines

`{targets}` is a **general-purpose Make-like build system for R**. Any R object can be a target. In this project, targets manages:

- Data transformations (staging → intermediate → marts)
- Figure generation (plot targets with `format = "file"`)
- Caption text (caption string as a target, referencing data targets)
- Alt-text generation (alt text as a target derived from figure and data targets)
- Vignette pre-computation (`vig_*` prefix)
- pkgdown build artifacts
- pkgctx context generation

This breadth is why targets is the **default orchestrator** for all pipeline work, and why the staging→intermediate→marts layer pattern applies universally — not just to data engineering projects.

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

## Data Layer Architecture (Staging → Intermediate → Marts)

All data pipelines — regardless of domain — follow a three-layer naming convention. This applies to financial data, observational science, clinical data, and any tabular pipeline.

| Layer | Prefix | Responsibility | Example targets |
|-------|--------|----------------|-----------------|
| **Staging** | `stg_` | Load raw source, minimal transforms (cast types, rename cols) | `stg_transactions`, `stg_buoy_obs` |
| **Intermediate** | `int_` | Joins, enrichment, business logic | `int_transactions_categorised`, `int_buoy_flagged` |
| **Marts** | `mart_` | Final aggregations, business-defined summaries | `mart_monthly_spend`, `mart_wave_summary` |

### Rules

- Staging targets read **only** from raw sources (files, APIs). No joins.
- Intermediate targets can join across staging targets but produce **no final summaries**.
- Mart targets are the terminal layer — consumed by vignettes (`vig_*`), Shiny apps, and reports.
- Never skip layers: a target that reads raw data and produces a business summary is doing two layers of work and must be split.

### Plan file mapping

```r
plan_staging.R        # stg_* targets
plan_intermediate.R   # int_* targets  
plan_marts.R          # mart_* targets
plan_vignette_outputs.R  # vig_* targets (consume mart_*)
```

### Example (personal finance pipeline)

```r
# Staging: load raw CSV, cast types only
tar_target(stg_transactions, {
  readr::read_csv("data-raw/bank_export.csv") |>
    dplyr::mutate(
      date = lubridate::ymd(date),
      amount = as.numeric(amount)
    )
}),

# Intermediate: enrich with categories
tar_target(int_transactions_categorised, {
  stg_transactions |>
    fuzzyjoin::stringdist_left_join(
      category_lookup,
      by = c("description" = "pattern"),
      method = "jw", max_dist = 0.2
    )
}),

# Mart: monthly summary
tar_target(mart_monthly_spend, {
  int_transactions_categorised |>
    dplyr::summarise(
      total = sum(amount),
      .by = c(lubridate::floor_date(date, "month"), category)
    )
})
```

## Target Names Are API Contracts (MANDATORY)

Target names are **durable interfaces** consumed by vignettes (`safe_tar_read("vig_X")`), Shiny apps (`tar_read(model_Y)`), cross-project references, and other pipeline plans. Renaming a target breaks all downstream consumers silently.

**Rules:**
- **NEVER rename a target** without updating all consumers (grep the entire project)
- **Use `lifecycle::deprecate_warn()`** pattern: keep the old target as a thin wrapper for one version
- **Prefix conventions are contracts** — `vig_*` = vignette display, `qa_*` = quality gates, `dv_*` = data validation
- **Document breaking changes in CHANGELOG.md** under "Failed Approaches" or "Known Limitations"

```r
# Renaming a target safely
tar_target(new_name, compute_result()),
tar_target(old_name, {
  cli::cli_warn("Target 'old_name' is deprecated. Use 'new_name'.")
  tar_read(new_name)
}),
```

**Before renaming, grep for all consumers:**
```bash
grep -r "old_target_name" vignettes/ R/ inst/shiny/ tests/
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

## Crew Integration

For controller setup, logging/metrics, and resource-specific (multi-controller) configuration, see the `crew-operations` skill — its "Integration with targets" section is canonical. The minimal hook-up is:

```r
tar_option_set(
  controller = crew::crew_controller_local(workers = 4, seconds_idle = 60)
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

### Incremental Deduplication Pattern

When data arrives in append-only batches (e.g., daily API pulls, CSV exports), use MD5 surrogate keys to deduplicate across incremental loads:

```r
tar_target(stg_transactions_deduped, {
  # Generate surrogate key from identifying columns
  stg_transactions |>
    dplyr::mutate(
      row_id = digest::digest(
        paste(date, description, amount, sep = "_"),
        algo = "md5"
      )
    ) |>
    # Deduplicate: keep first occurrence of each row_id
    dplyr::distinct(row_id, .keep_all = TRUE)
})
```

This is the targets equivalent of dbt's `incremental` materialisation. The hash captures logical uniqueness (not row order), so re-importing the same CSV does not duplicate records.

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

### ❌ tar_load() Inside a Target

```r
# BAD: hidden dependency, not picked up by static analysis
tar_target(model, {
  tar_load(data)  # ❌ targets cannot see `data` as an upstream dep
  lm(y ~ x, data = data)
})

# GOOD: name the upstream target as a symbol — auto-detected
tar_target(model, lm(y ~ x, data = data))  # ✓ `data` tracked
```

### ❌ tar_make() in Package Code

```r
# BAD: pipeline execution buried inside a function
my_pipeline <- function() {
  targets::tar_make()  # ❌ side effect, untestable, hides config
}
```

`tar_make()` is a user action invoked from a session, CI job, or `Makefile` — not from inside `R/` functions. Document the entry point in README or a vignette.

## Debugging Targets

### Check Pipeline State

```r
tar_manifest()      # List all targets
tar_outdated()      # What needs to run
tar_visnetwork()    # DAG visualization
tar_meta()          # Build metadata
```

### Interactive Inspection with tar_read()

`tar_read()` is targets' key advantage for debugging — inspect any intermediate object without re-running the pipeline:

```r
# Read a completed target directly
tar_read(int_transactions_categorised)

# Read a specific branch of a mapped target
tar_read(results, branches = 1)

# Use in combination with dplyr for quick exploration
tar_read(mart_monthly_spend) |> dplyr::glimpse()
tar_read(mart_monthly_spend) |> dplyr::filter(total > 1000)
```

**When to use tar_read() vs tar_load():**
- `tar_read()` — returns the value; use in pipes and assignments
- `tar_load()` — loads into `.GlobalEnv` by name; use at top-level interactive debugging

This avoids re-running expensive upstream targets during a debugging session.

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

## Pipeline Tool Choice: targets vs rixpress vs Maestro

| Feature | targets | rixpress | Maestro |
|---|---|---|---|
| Define steps | `tar_target()` | `rxp_r()` | `%>>%` pipe |
| Build | `tar_make()` | `rxp_make()` | `run_schedule()` |
| Read output | `tar_read()` (interactive) | `rxp_read()` | — (no interactive inspect) |
| Visualise | `tar_visnetwork()` | `rxp_ggdag()` | `build_schedule_graph()` |
| Config file | `_targets.R` + plan files | `pipeline.R` | `schedule.R` |
| Built-in scheduler | No (use cron / GH Actions) | No | **Yes (cron-style)** |
| Content-addressed cache | **Yes (hash-based, skips unchanged)** | Yes | No (each run from scratch) |
| Scope of valid targets | General — any R object (plots, captions, HTML, models, text) | General (hermetic per-step) | **Data pipelines only** |
| Parallelism | `crew` controllers (local, SLURM, AWS Batch), `mirai`, `future` | Same as targets | Simple per-task; no worker pool primitive |
| Ecosystem | `tarchetypes`, `stantargets`, `jagstargets`, `geotargets`, `tarflow.iquizoo`, ~10+ extensions | Nascent (single package) | Minimal |
| Deployment | Local store, S3 (`targets.s3upload`), cloud caches | Nix store | Designed for live scheduled jobs, not artifact storage |
| CI fit | Mature — `tar_make()` in GH Actions, partial-run support, `tarchetypes::tar_render` for vignettes | Works in any nix-aware CI | Cron triggers, not commit-triggered |

**Use targets** (default) when: dynamic branching, parallel execution (`crew`), 20+ steps, R-only, HPC, or when targets are non-data objects (plots, captions, alt-text, HTML, models).
**Use rixpress** when: hermetic per-step isolation matters more than caching speed, mixed R+Python steps, <20 steps, regulatory audit needs.
**Use Maestro** when: the primary need is cron-style scheduling of pure-data pipelines, you have no interest in caching across runs, you don't need interactive `tar_read()` debugging, and the pipeline doesn't need to mix in non-data targets (figures, captions, reports). In this project: stay on targets — Maestro's only unique advantage (built-in scheduling) is already covered by GitHub Actions cron triggers and macOS `launchd`. Adopting Maestro would lose `tar_read()` and smart invalidation without buying anything new.
**Never mix** targets with rixpress or Maestro in the same project — they manage overlapping concerns (DAG, caching).

## Related Skills

- `crew-operations` - Advanced crew patterns
- `targets-vignettes` - Pre-calculating vignette data

## Resources

- [targets Manual](https://books.ropensci.org/targets/)
- [targets + crew](https://books.ropensci.org/targets/crew.html)
- [tarchetypes](https://docs.ropensci.org/tarchetypes/)
