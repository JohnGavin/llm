# Bridge Patterns: Selection ↔ Data-Masking

Convert between tidy-select and data-masking contexts.

## `across()` as Bridge

`across()` accepts tidy-select inside data-masking verbs:

```r
# Tidy-select columns, apply data-masking operation
my_summarise <- function(data, cols) {
  data |>
    dplyr::summarise(dplyr::across({{ cols }}, ~ mean(.x, na.rm = TRUE)))
}
my_summarise(mtcars, c(mpg, wt))
my_summarise(mtcars, where(is.numeric))
```

## Character Vector → Data-Masking

Use `all_of()` inside `across()` to bridge string column names:

```r
my_group_by <- function(data, vars) {
  data |> dplyr::group_by(dplyr::across(all_of(vars)))
}
my_group_by(mtcars, c("cyl", "gear"))
```

## Tidy-Select → Group-By

```r
# User passes tidy-select, function needs group_by
group_and_count <- function(data, cols) {
  data |>
    dplyr::group_by(dplyr::across({{ cols }})) |>
    dplyr::summarise(n = dplyr::n(), .groups = "drop")
}
```

## Single Column in `c(...)` Context

Some verbs (e.g., `pivot_longer(cols = ...)`) expect tidy-select. Wrap
`{{ }}` in `c()` to make it work:

```r
my_pivot <- function(data, cols) {
  data |> tidyr::pivot_longer(c({{ cols }}))
}
```

## Decision Table

| Have | Need | Pattern |
|------|------|---------|
| `{{ col }}` (data-mask) | tidy-select | Wrap in `c({{ col }})` |
| tidy-select `cols` | data-mask `group_by` | `across({{ cols }})` |
| character vector | data-mask | `across(all_of(vars))` |
| character vector | tidy-select | `all_of(vars)` |
| `.data[[var]]` | data-mask | Direct use |
