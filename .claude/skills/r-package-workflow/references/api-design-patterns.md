# API Design Patterns for Exported Functions

Patterns for designing user-friendly, tidyverse-compatible function APIs.

## 1. The `.by` Parameter Pattern

Allow per-operation grouping instead of requiring `group_by()`:

```r
#' @export
my_summarise <- function(.data, ..., .by = NULL) {
  .data |>
    dplyr::summarise(..., .by = {{ .by }})
}

# User can group inline
my_summarise(mtcars, mean_mpg = mean(mpg), .by = cyl)
my_summarise(mtcars, mean_mpg = mean(mpg), .by = c(cyl, gear))
```

## 2. The `{{ }}` Forwarding Pattern

Accept column names as arguments:

```r
#' @param .data A data frame
#' @param group_col Column to group by (tidy-select)
#' @param value_col Column to summarise (data-masked)
#' @export
my_summary <- function(.data, group_col, value_col) {
  .data |>
    dplyr::group_by({{ group_col }}) |>
    dplyr::summarise(
      mean = mean({{ value_col }}, na.rm = TRUE),
      .groups = "drop"
    )
}
```

## 3. Consistent Return Types

Always return tibbles from data functions:

```r
# GOOD: always returns tibble, even with 0 rows
#' @export
find_matches <- function(.data, pattern) {
  .data |>
    dplyr::filter(stringr::str_detect(.data$name, pattern))
  # Returns tibble — 0 rows if no matches, never NULL
}
```

## 4. The `...` Forwarding Pattern

Prefix non-column args with `.` to avoid name collisions:

```r
#' @export
my_select <- function(.data, ..., .cols = NULL) {
  if (!is.null(.cols)) {
    .data |> dplyr::select(all_of(.cols))
  } else {
    .data |> dplyr::select(...)
  }
}
```

## 5. Internal vs Exported Decision Criteria

| Criterion | Export | Keep Internal |
|-----------|--------|---------------|
| Used by other packages | Yes | — |
| Part of stable API | Yes | — |
| Implementation detail | — | Yes (prefix with `.`) |
| Helper used by 1 function | — | Yes |
| Could change without notice | — | Yes |
| Needs documentation | Yes | Optional |

```r
# Exported: stable, documented
#' @export
process_data <- function(.data, ...) { ... }

# Internal: prefix with `.`, can change freely
.validate_columns <- function(.data, required) { ... }
.transform_step <- function(.data) { ... }
```

## 6. Error Messages with Context

```r
#' @export
read_data <- function(path, format = c("csv", "parquet")) {
  format <- rlang::arg_match(format)  # nice error on typo
  if (!file.exists(path)) {
    cli::cli_abort(c(
      "File not found.",
      "x" = "Path: {.file {path}}",
      "i" = "Check working directory: {.path {getwd()}}"
    ))
  }
  switch(format,
    csv = readr::read_csv(path, show_col_types = FALSE),
    parquet = arrow::read_parquet(path)
  )
}
```

## 7. Documentation Tags

```r
#' @param col <[`data-masked`][dplyr::dplyr_data_masking]> Column to operate on
#' @param cols <[`tidy-select`][dplyr::dplyr_tidy_select]> Columns to select
#' @param ... <[`dynamic-dots`][rlang::dyn-dots]> Additional arguments
```
