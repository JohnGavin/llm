# Dots Forwarding Patterns

How to pass `...` through to dplyr verbs correctly.

## Simple Forwarding (Most Common)

No special syntax needed — just pass `...` directly:

```r
my_group_by <- function(.data, ...) {
  .data |> dplyr::group_by(...)
}

my_select <- function(.data, ...) {
  .data |> dplyr::select(...)
}

my_filter <- function(.data, ...) {
  .data |> dplyr::filter(...)
}
```

## Tidy-Select in `c(...)` Context

Some args expect a single tidy-select expression. Wrap `...` in `c()`:

```r
my_pivot_longer <- function(.data, ...) {
  .data |> tidyr::pivot_longer(c(...))
}

my_relocate <- function(.data, ...) {
  .data |> dplyr::relocate(c(...))
}
```

## Dots with Named Arguments

Prefix non-column args with `.` to avoid column-name collision:

```r
my_summary <- function(.data, ..., .na_rm = TRUE) {
  .data |>
    dplyr::summarise(
      dplyr::across(c(...), ~ mean(.x, na.rm = .na_rm))
    )
}
```

## Checking Dots

Prevent typos and unused arguments:

```r
# Error if unexpected args in ...
strict_fn <- function(x, ..., na.rm = TRUE) {
  rlang::check_dots_empty()
  mean(x, na.rm = na.rm)
}

# Warn if ... args went unused
flexible_fn <- function(x, ...) {
  rlang::check_dots_used()
  plot(x, ...)
}
```

## Dynamic Dots with `list2()`

Enable `!!!` splicing and `:=` naming in `...`:

```r
my_tibble <- function(...) {
  dots <- rlang::list2(...)
  tibble::tibble(!!!dots)
}

# Supports: normal args, !!!list() splicing,
# "{name}" := value, trailing commas
my_tibble(x = 1, y = 2,)  # trailing comma OK
```
