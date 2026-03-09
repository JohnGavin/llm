# Name Injection Patterns

Create dynamic column names programmatically.

## `:=` with `{{ }}`

The walrus operator creates names from embraced arguments:

```r
my_mean <- function(data, var) {
  data |>
    dplyr::summarise("mean_{{ var }}" := mean({{ var }}, na.rm = TRUE))
}
mtcars |> my_mean(mpg)
# Returns column: mean_mpg
```

## `:=` with Strings

Use glue-style `"{name}"` for string-based names:

```r
name <- "result"
rlang::list2("{name}" := 1)
# list(result = 1)

# In dplyr
col_name <- "score"
data |> dplyr::mutate("{col_name}_scaled" := .data[[col_name]] / 100)
```

## `englue()` for Custom Name Defaults

Allow users to override auto-generated names:

```r
my_mean <- function(data, var, name = rlang::englue("mean_{{ var }}")) {
  data |>
    dplyr::summarise("{name}" := mean({{ var }}, na.rm = TRUE))
}

# Default name:
mtcars |> my_mean(mpg)        # column: mean_mpg

# Custom name:
mtcars |> my_mean(mpg, "avg") # column: avg
```

## Multiple Dynamic Names

```r
my_stats <- function(data, var) {
  data |>
    dplyr::summarise(
      "{{ var }}_mean" := mean({{ var }}, na.rm = TRUE),
      "{{ var }}_sd"   := sd({{ var }}, na.rm = TRUE),
      "{{ var }}_n"    := sum(!is.na({{ var }}))
    )
}
```

## Naming in `across()`

Use `.names` argument for `across()` output names:

```r
data |>
  dplyr::mutate(dplyr::across(
    c(x, y, z),
    list(mean = mean, sd = sd),
    .names = "{.col}_{.fn}"
  ))
# Creates: x_mean, x_sd, y_mean, y_sd, z_mean, z_sd
```

## `as_label()` for Debugging

Extract a human-readable name from a quosure:

```r
debug_fn <- function(data, col) {
  col_quo <- rlang::enquo(col)
  cli::cli_inform("Processing column: {.field {rlang::as_label(col_quo)}}")
  data |> dplyr::select(!!col_quo)
}
```
