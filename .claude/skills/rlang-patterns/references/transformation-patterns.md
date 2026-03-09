# Transformation Patterns

Wrapping, transforming, and augmenting tidy eval arguments.

## Wrapping a Single Argument

Apply a transformation around an embraced column:

```r
my_mean <- function(data, var) {
  data |>
    dplyr::summarise(mean = mean({{ var }}, na.rm = TRUE))
}

my_log_mean <- function(data, var) {
  data |>
    dplyr::summarise(log_mean = mean(log({{ var }}), na.rm = TRUE))
}
```

## Transforming Multiple Columns via `across()`

```r
# Apply function to selected columns
my_scale <- function(data, ...) {
  data |>
    dplyr::mutate(dplyr::across(
      c(...),
      ~ (.x - mean(.x, na.rm = TRUE)) / sd(.x, na.rm = TRUE),
      .names = "{.col}_z"
    ))
}
mtcars |> my_scale(mpg, wt, hp)
```

## Named Function Lists

```r
my_stats <- function(data, cols) {
  data |>
    dplyr::summarise(dplyr::across(
      {{ cols }},
      list(
        mean = \(x) mean(x, na.rm = TRUE),
        sd   = \(x) sd(x, na.rm = TRUE),
        n    = \(x) sum(!is.na(x))
      ),
      .names = "{.col}_{.fn}"
    ))
}
```

## Manual Transformation with `enquos()` + `purrr::map()`

For advanced cases where `across()` won't work:

```r
my_cumulative <- function(data, ...) {
  dots <- rlang::enquos(...)
  cum_exprs <- purrr::map(dots, \(dot) {
    rlang::expr(cumsum(!!dot))
  })
  names(cum_exprs) <- paste0("cum_", purrr::map_chr(dots, rlang::as_label))
  data |> dplyr::mutate(!!!cum_exprs)
}
mtcars |> my_cumulative(mpg, wt)
# Creates: cum_mpg, cum_wt
```

## Conditional Column Creation

```r
my_flag <- function(data, col, threshold) {
  data |>
    dplyr::mutate(
      "{{ col }}_flag" := dplyr::if_else(
        {{ col }} > .env$threshold, "high", "low"
      )
    )
}
```

## Augmenting: Keep Original + Add Transformed

```r
my_augment <- function(data, col) {
  data |>
    dplyr::mutate(
      "{{ col }}_log"    := log({{ col }}),
      "{{ col }}_scaled" := {{ col }} / max({{ col }}, na.rm = TRUE)
    )
}
```
