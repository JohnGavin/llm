# Advanced Injection and Defusing Patterns

Deep-dive reference for programmatic tidy evaluation beyond the basics covered
in the main SKILL.md.

## Quosure Internals

A quosure bundles an expression with the environment where it should be
evaluated. Understanding this is key to advanced patterns.

```r
# Inspect a quosure
my_fun <- function(x) {
	q <- rlang::enquo(x)
	list(
		expr = rlang::quo_get_expr(q),
		env = rlang::quo_get_env(q),
		label = rlang::as_label(q),
		name = rlang::as_name(q)  # only works for symbols
	)
}

my_fun(mpg)
#> $expr: mpg
#> $env: <environment: R_GlobalEnv>
#> $label: "mpg"
#> $name: "mpg"

my_fun(mpg * 2)
#> $expr: mpg * 2
#> $env: <environment: R_GlobalEnv>
#> $label: "mpg * 2"
#> $name: Error -- not a simple symbol
```

### `as_label()` vs `as_name()`

| Function | Input | Output | Use When |
|----------|-------|--------|----------|
| `as_label()` | Any expression | Human-readable string | Column headers, messages |
| `as_name()` | Symbol only | String name | Need exact column name as string |

```r
# as_label() is always safe
rlang::as_label(rlang::expr(mean(x)))  #> "mean(x)"
rlang::as_label(rlang::expr(x))        #> "x"

# as_name() only for symbols
rlang::as_name(rlang::expr(x))         #> "x"
rlang::as_name(rlang::expr(mean(x)))   #> Error!
```

## Dynamic Tidyselect

### Selecting with String Vectors

```r
select_strings <- function(data, cols) {
  data |> dplyr::select(dplyr::all_of(cols))
}

# all_of() errors if columns missing
# any_of() silently drops missing columns
select_available <- function(data, cols) {
  data |> dplyr::select(dplyr::any_of(cols))
}
```

### Combining Tidyselect with Embrace

```r
summarise_with_extras <- function(data, value_col, ...) {
  # value_col via embrace, ... forwarded to group_by
  data |>
    dplyr::group_by(...) |>
    dplyr::summarise(
      result = mean({{ value_col }}, na.rm = TRUE),
      .groups = "drop"
    )
}
```

### Programmatic Tidyselect Predicates

```r
select_numeric_matching <- function(data, pattern) {
  data |>
    dplyr::select(
      dplyr::where(is.numeric) & dplyr::matches(pattern)
    )
}
```

## Expression Surgery

Modify expressions before evaluation.

### Building Expressions with `expr()`

```r
# Create unevaluated expressions
e <- rlang::expr(mean(x, na.rm = TRUE))
eval(e, list(x = 1:10))  #> 5.5

# Inject values into expressions
col_sym <- rlang::sym("mpg")
rlang::expr(mean(!!col_sym, na.rm = TRUE))
#> mean(mpg, na.rm = TRUE)
```

### Symbol and Expression Constructors

```r
# String to symbol
rlang::sym("column_name")  #> column_name (symbol)

# Multiple strings to symbol list
rlang::syms(c("col_a", "col_b"))  #> list(col_a, col_b)

# Use in injection
cols <- rlang::syms(c("cyl", "gear"))
mtcars |> dplyr::group_by(!!!cols) |> dplyr::tally()
```

### Building Calls Programmatically

```r
# call2() constructs function calls
rlang::call2("mean", rlang::sym("x"), na.rm = TRUE)
#> mean(x, na.rm = TRUE)

# With namespace
rlang::call2("filter", .ns = "dplyr", rlang::sym("data"), rlang::expr(x > 0))
#> dplyr::filter(data, x > 0)
```

## `inject()` Patterns

### Multiple Dynamic Arguments

```r
dynamic_mutate <- function(data, transformations) {
  # transformations: named list of expressions
  # e.g., list(x_sq = expr(x^2), x_log = expr(log(x)))
  rlang::inject(dplyr::mutate(data, !!!transformations))
}

# Usage
transforms <- list(
  mpg_sq = rlang::expr(mpg^2),
  mpg_log = rlang::expr(log(mpg))
)
mtcars |> dynamic_mutate(transforms)
```

### Conditional Argument Injection

```r
flex_plot <- function(data, x, y, color = NULL, facet = NULL) {
  # Build aes() dynamically
  mapping_args <- list(
    x = rlang::enquo(x),
    y = rlang::enquo(y)
  )

  if (!is.null(rlang::enexpr(color))) {
    mapping_args$colour <- rlang::enquo(color)
  }

  p <- rlang::inject(
    ggplot2::ggplot(data, ggplot2::aes(!!!mapping_args))
  ) +
    ggplot2::geom_point()

  if (!is.null(rlang::enexpr(facet))) {
    p <- p + ggplot2::facet_wrap(rlang::enquo(facet))
  }

  p
}
```

### Inject with `!!!` for Named Lists

```r
named_summary <- function(data, col, probs = c(0.25, 0.5, 0.75)) {
  fns <- purrr::set_names(probs, paste0("q", probs * 100)) |>
    purrr::map(function(p) {
      rlang::expr(quantile({{ col }}, probs = !!p, na.rm = TRUE))
    })

  rlang::inject(dplyr::summarise(data, !!!fns))
}

# Result columns: q25, q50, q75
mtcars |> named_summary(mpg)
```

## Bridging String and Symbol Interfaces

### The `all_of()` / `any_of()` Bridge

When your function receives string column names but needs tidy evaluation:

```r
# GOOD: Use .data[[]] for single string columns
filter_string <- function(data, col_name, value) {
  data |> dplyr::filter(.data[[col_name]] == value)
}

# GOOD: Use all_of() for selecting string columns
select_strings <- function(data, col_names) {
  data |> dplyr::select(dplyr::all_of(col_names))
}

# GOOD: Use across(all_of()) for mutating string columns
scale_strings <- function(data, col_names) {
  data |>
    dplyr::mutate(
      dplyr::across(dplyr::all_of(col_names), scale)
    )
}
```

### Converting Strings to Symbols for Injection

When you must convert strings to inject into expressions:

```r
group_by_strings <- function(data, group_cols) {
  group_syms <- rlang::syms(group_cols)
  data |> dplyr::group_by(!!!group_syms) |> dplyr::tally()
}

# More robust: use .data[[]] instead
group_by_strings2 <- function(data, group_cols) {
  data |> dplyr::group_by(dplyr::across(dplyr::all_of(group_cols))) |>
    dplyr::tally()
}
```

## Data Mask Patterns

### The Double Evaluation Trap

```r
# WRONG: col evaluated twice with different meanings
bad_fun <- function(data, col) {
  data |>
    dplyr::mutate(
      new = {{ col }} - mean({{ col }})  # OK here, but fragile
    )
}

# SAFER for complex expressions: compute intermediate
safe_fun <- function(data, col) {
  data |>
    dplyr::mutate(
      .col_val = {{ col }},
      new = .col_val - mean(.col_val, na.rm = TRUE),
      .col_val = NULL  # remove temp column
    )
}
```

### Forwarding the Data Mask

When calling one tidy-eval function from another:

```r
outer_fun <- function(data, col) {
  # {{ col }} correctly forwards the user's column reference
  inner_fun(data, {{ col }})
}

inner_fun <- function(data, col) {
  data |> dplyr::summarise(result = mean({{ col }}, na.rm = TRUE))
}
```

### Escape Hatch: Evaluating in Data Context

```r
eval_in_data <- function(data, expr) {
  rlang::eval_tidy(rlang::enquo(expr), data = data)
}

# Usage
eval_in_data(mtcars, mean(mpg))  #> 20.09
```

## Condition Handling with `try_fetch()`

### Rethrowing with Context

```r
with_context <- function(expr, context_msg) {
  rlang::try_fetch(
    expr,
    error = function(cnd) {
      cli::cli_abort(context_msg, parent = cnd)
    }
  )
}

# Usage
with_context(
  log("not a number"),
  "Failed during log transformation."
)
```

### Downgrading Errors to Warnings

```r
warn_on_error <- function(expr, default = NULL) {
  rlang::try_fetch(
    expr,
    error = function(cnd) {
      cli::cli_warn(
        "Operation failed: {conditionMessage(cnd)}"
      )
      default
    }
  )
}
```

### Custom Condition Classes

```r
# Signal a custom condition
signal_validation_error <- function(msg, data = NULL) {
  rlang::abort(
    msg,
    class = "pkg_validation_error",
    data = data
  )
}

# Catch by class
handle_validation <- function(expr) {
  rlang::try_fetch(
    expr,
    pkg_validation_error = function(cnd) {
      cli::cli_warn("Validation failed: {conditionMessage(cnd)}")
      cnd$data  # access custom field
    },
    error = function(cnd) {
      cli::cli_abort("Unexpected error.", parent = cnd)
    }
  )
}
```

## Testing Tidy-Eval Functions

### Snapshot Tests for Error Messages

```r
test_that("grouped_stats validates input", {
  expect_snapshot(error = TRUE, {
    grouped_stats(mtcars)  # missing required args
  })
})
```

### Testing Column Name Forwarding

```r
test_that("my_summary works with different columns", {
  result <- my_summary(mtcars, cyl, mpg)

  expect_s3_class(result, "tbl_df")
  expect_true("mpg_mean" %in% names(result))
  expect_equal(nrow(result), length(unique(mtcars$cyl)))
})
```

### Testing Programmatic Interfaces

```r
test_that("string column interface works", {
  result <- summarise_col(mtcars, "mpg")

  expect_named(result, c("mean", "sd"))
  expect_equal(result$mean, mean(mtcars$mpg), tolerance = 1e-10)
})
```

## Anti-Patterns to Avoid

### 1. Using `enquo()` + `!!` Where `{{ }}` Suffices

```r
# AVOID
my_fn <- function(data, col) {
  col_quo <- enquo(col)
  data |> dplyr::select(!!col_quo)
}

# PREFER
my_fn <- function(data, col) {
  data |> dplyr::select({{ col }})
}
```

### 2. Using `eval(parse())` Instead of Tidy Eval

```r
# NEVER
bad_filter <- function(data, expr_string) {
  eval(parse(text = paste0("dplyr::filter(data, ", expr_string, ")")))
}

# INSTEAD: Accept expressions via tidy eval
good_filter <- function(data, ...) {
  data |> dplyr::filter(...)
}
```

### 3. Forgetting `.env` When Names Collide

```r
# BUG: If data has a "threshold" column, this filters by it
bad_fn <- function(data, threshold) {
  data |> dplyr::filter(value > threshold)
}

# CORRECT: Explicit disambiguation
good_fn <- function(data, threshold) {
  data |> dplyr::filter(.data$value > .env$threshold)
}
```

### 4. Using `!!` Outside Injection-Aware Functions

```r
# WRONG: !! does nothing in base R functions
x <- 5
list(!!x, !!x + 1)  # Does NOT inject

# RIGHT: Use !! only inside rlang/tidyverse data-masked or inject() contexts
rlang::inject(list(!!x, !!x + 1))  #> list(5, 6)
```

## Quick Reference Table

| I want to... | Use |
|---|---|
| Forward a column arg | `{{ col }}` |
| Forward multiple args | `...` or `enquos()` + `!!!` |
| Hard-code a column name | `.data$col_name` |
| Use an env variable safely | `.env$var_name` |
| String to column reference | `.data[[string]]` or `all_of(string)` |
| String to symbol | `rlang::sym(string)` |
| Create dynamic col name | `"{{ col }}_suffix" := expr` |
| Build a call | `rlang::call2()` or `rlang::expr()` |
| Evaluate with injection | `rlang::inject(expr)` |
| Defuse without evaluating | `rlang::enquo()` / `rlang::enexpr()` |
| Get expression label | `rlang::as_label(quo)` |
| Get expression as string name | `rlang::as_name(quo)` (symbols only) |
| Handle errors by class | `rlang::try_fetch()` |
| Signal typed error | `rlang::abort(class = "my_class")` |
| Validate required arg | `rlang::check_required(arg)` |
| Validate exclusive args | `rlang::check_exclusive(a, b)` |
