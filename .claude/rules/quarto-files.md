# Quarto File Rules

**Applies to**: `*.qmd`, `*.Rmd`, `vignettes/*.qmd`

## Pre-Computation Pattern (CRITICAL)

**Vignettes do NO computation. All code chunks use `tar_read()` or `tar_load()`.**

```qmd
## Wave Analysis

```{r}
#| echo: false
targets::tar_load(vignette_wave_analysis_data)
targets::tar_load(vignette_wave_plots)
```

### Summary Statistics

```{r}
#| echo: false
vignette_wave_analysis_data$summary_table
```

### Visualization

```{r}
#| echo: false
vignette_wave_plots$extreme_events
```
```

**Why**: Ensures reproducibility, faster rendering, and CI compatibility.

## Unique Chunk Labels (REQUIRED)

Every code chunk MUST have a unique label:

```qmd
```{r setup}
#| include: false
library(targets)
```

```{r load-wave-data}
targets::tar_load(wave_summary)
```

```{r plot-extremes}
#| fig-cap: "Extreme wave events over time"
targets::tar_load(plot_wave_extremes)
plot_wave_extremes
```
```

**Naming convention**: `{verb}-{noun}` (e.g., `load-data`, `plot-summary`, `table-metrics`)

## No Console Prompts (CRITICAL)

**NEVER show code with R prompts or console output markers.**

```r
# WRONG - Cannot copy/paste
> library(mypackage)
> result <- analyze_data(x)
[1] 42

# CORRECT - Clean, copyable code
library(mypackage)
result <- analyze_data(x)
```

## Code Display Standards

```qmd
```{r example-query}
#| echo: true
#| eval: false
# Example: Query buoy data
con <- connect_duckdb("buoy_data.parquet")
result <- query_buoy_data(con, station = "M3")
DBI::dbDisconnect(con)
```
```

**Guidelines**:
- `echo: true` for code users should see
- `eval: false` for examples that shouldn't run during render
- `include: false` for setup code
- Never use `devtools::load_all()` in vignettes

## Code Examples as Targets

Store code examples as targets for validation:

```r
# In R/tar_plans/plan_doc_examples.R
targets::tar_target(
  code_example_query,
  c(
    "con <- connect_duckdb('data.parquet')",
    "result <- query_buoy_data(con, station = 'M3')",
    "DBI::dbDisconnect(con)"
  )
)
```

Display in vignette:
````qmd
```{r}
#| echo: false
#| results: asis
targets::tar_load(code_example_query)
cat("```r\n", paste(code_example_query, collapse = "\n"), "\n```", sep = "")
```
````

## Figure Requirements

```qmd
```{r fig-wave-extremes}
#| fig-cap: "Distribution of extreme wave events by station"
#| fig-alt: "Bar chart showing count of extreme events per buoy station"
#| fig-width: 8
#| fig-height: 5
targets::tar_load(plot_extreme_distribution)
plot_extreme_distribution
```
```

**Required attributes**:
- `fig-cap`: Caption for the figure
- `fig-alt`: Alt text for accessibility
- Reasonable `fig-width` and `fig-height`

## Table Formatting

Use gt or kableExtra for publication-quality tables:

```qmd
```{r tbl-summary}
#| tbl-cap: "Summary statistics by station"
targets::tar_load(summary_table)
summary_table |>
  gt::gt() |>
  gt::fmt_number(columns = where(is.numeric), decimals = 2)
```
```

## Cross-References

Use Quarto cross-reference syntax:

```qmd
As shown in @fig-wave-extremes, the M3 station has the highest frequency
of extreme events. See @tbl-summary for detailed statistics.
```

## Callouts for Important Information

```qmd
::: {.callout-note}
This analysis uses data from 2020-2024.
:::

::: {.callout-warning}
The M6 buoy was offline during January 2023.
:::

::: {.callout-tip}
Use `threshold = 5` for significant wave events.
:::
```

## README.qmd Requirements

For `README.qmd` specifically:

1. **Project structure**: Use `fs::dir_tree(recurse = 2)`
2. **Installation methods**: Standard R, Nix, rix
3. **All code tested**: Every example must work
4. **Generate README.md**: Via `quarto render` or targets

```qmd
## Installation

### Standard R
```{r}
#| eval: false
remotes::install_github("username/package")
```

### Nix Environment
```{bash}
#| eval: false
./default.sh
```

## Project Structure
```{r}
#| echo: false
fs::dir_tree(recurse = 2)
```
```

## Dashboard-Specific Rules

For Quarto dashboards (`format: dashboard`):

1. **Lazy evaluation**: Use DuckDB/Arrow backends
2. **Pre-compute in targets**: Dashboard only displays
3. **Reasonable data size**: Sample for interactive widgets (10K rows max)
4. **Service worker for Shinylive**: Include `shinylive-sw.js` resource

```yaml
---
title: "Buoy Dashboard"
format:
  dashboard:
    orientation: rows
    theme: cosmo
---
```
