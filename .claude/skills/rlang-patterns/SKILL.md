---
name: rlang-patterns
description: >
  Comprehensive guide to rlang metaprogramming patterns for R package
  development. Use this skill when: (1) Writing functions that accept column
  names as arguments (tidy evaluation), (2) Using embrace {{}} or injection
  !!/!!! operators, (3) Creating dynamic column names or expressions
  programmatically, (4) Defusing arguments with enquo()/enquos(),
  (5) Disambiguating data columns from environment variables with .data/.env,
  (6) Improving error messages with caller_env()/caller_arg(),
  (7) Validating function inputs with check_*() helpers,
  (8) Handling conditions with try_fetch().
metadata:
  author: johngavin
  version: "1.0"
  github-issue: 41
---

# rlang Patterns for R Packages

Practical patterns for tidy evaluation, injection, and dynamic programming with rlang.

## When to Use What

task: Write a function that wraps a single dplyr verb argument
use: `{{ }}` embrace operator

task: Write a function that wraps multiple column arguments
use: `{{ }}` with `...` passthrough or `enquos()` + `!!!`

task: Inject a stored quosure or value into an expression
use: `!!` (single) or `!!!` (splice list)

task: Build an expression programmatically from pieces
use: `inject()` with `!!`/`!!!` inside

task: Reference a column name unambiguously in data-masked code
use: `.data$col` pronoun

task: Reference an environment variable in data-masked code
use: `.env$var` pronoun

task: Create columns with dynamic names
use: `:=` with `{{ }}` or glue-style `"{name}" :=`

task: Give better error messages pointing to user's call
use: `caller_env()` and `caller_arg()`

task: Validate required arguments
use: `check_required()`, `check_exclusive()`

task: Handle errors/warnings with class-based dispatch
use: `try_fetch()`

## The Embrace Operator `{{}}`

The embrace operator is the primary tool for writing functions that accept
column names. It combines `enquo()` + `!!` into a single step.

### Basic Column Argument

```r
my_summary <- function(data, group_col, value_col) {
  data |>
    dplyr::group_by({{ group_col }}) |>
    dplyr::summarise(
      mean = mean({{ value_col }}, na.rm = TRUE),
      n = dplyr::n(),
      .groups = "drop"
    )
}

# Usage
mtcars |> my_summary(cyl, mpg)
```

### Passing `...` Through

When your function should accept arbitrary columns (like `select()` or
`group_by()`), pass `...` directly:

```r
my_group_summary <- function(data, ..., .value) {
  data |>
    dplyr::group_by(...) |>
    dplyr::summarise(
      mean_val = mean({{ .value }}, na.rm = TRUE),
      .groups = "drop"
    )
}

# Usage
mtcars |> my_group_summary(cyl, gear, .value = mpg)
```

### Dynamic Column Names with `:=`

Use the walrus operator `:=` to create columns with names derived from inputs:

```r
my_center <- function(data, col) {
  data |>
    dplyr::mutate(
      "{{ col }}_centered" := {{ col }} - mean({{ col }}, na.rm = TRUE)
    )
}

# Usage: creates column "mpg_centered"
mtcars |> my_center(mpg)
```

### Multiple Column Results

```r
my_stats <- function(data, col) {
  data |>
    dplyr::summarise(
      "{{ col }}_mean" := mean({{ col }}, na.rm = TRUE),
      "{{ col }}_sd" := sd({{ col }}, na.rm = TRUE),
      "{{ col }}_n" := sum(!is.na({{ col }}))
    )
}
```

## `.data` and `.env` Pronouns

These pronouns disambiguate column references from environment variables.

### `.data$col` -- Column from the Data Frame

Use `.data` in package code when column names are known strings:

```r
#' @importFrom rlang .data
process_data <- function(data) {
  data |>
    dplyr::filter(.data$status == "active") |>
    dplyr::mutate(score = .data$points / .data$total)
}
```

### `.env$var` -- Variable from the Environment

Use `.env` to avoid column-name collisions:

```r
filter_threshold <- function(data, threshold) {
  # Without .env, if data has a column named "threshold", this breaks
  data |>
    dplyr::filter(.data$value > .env$threshold)
}
```

### When to Use Which

| Context | Pattern | Example |
|---------|---------|---------|
| Known column name in package code | `.data$col` | `.data$age > 18` |
| User-supplied column name | `{{ col }}` | `{{ user_col }} > 18` |
| Env variable at risk of collision | `.env$var` | `.env$threshold` |
| User column + env value | Both | `{{ col }} > .env$min_val` |

**Package code rule:** Always use `.data$col` for hard-coded column names.
Add `@importFrom rlang .data .env` to your package documentation.

## Injection Operators `!!` and `!!!`

For programmatic scenarios beyond `{{ }}`, use explicit injection.

### `!!` -- Inject a Single Value or Quosure

```r
filter_by <- function(data, col, val) {
  col_quo <- rlang::enquo(col)
  data |>
    dplyr::filter(!!col_quo == val)
}
```

### `!!!` -- Splice a List of Quosures

```r
group_and_count <- function(data, ...) {
  group_vars <- rlang::enquos(...)
  data |>
    dplyr::group_by(!!!group_vars) |>
    dplyr::summarise(n = dplyr::n(), .groups = "drop")
}
```

### String Column Names with `.data[[]]`

When column names are strings (not symbols), use `.data[[name]]`:

```r
summarise_col <- function(data, col_name) {
  # col_name is a string like "mpg"
  data |>
    dplyr::summarise(
      mean = mean(.data[[col_name]], na.rm = TRUE),
      sd = sd(.data[[col_name]], na.rm = TRUE)
    )
}
```

**For advanced injection patterns:** See
[references/injection-patterns.md](references/injection-patterns.md).

## `enquo()` and `enquos()` for Defusing

Defusing captures an expression without evaluating it. Use `enquo()` for a
single argument, `enquos()` for `...`. Inject back with `!!` or `!!!`.

```r
# enquo() + !! for single arg (prefer {{ }} when possible)
debug_column <- function(data, col) {
  col_quo <- rlang::enquo(col)
  cli::cli_inform("Column: {.code {rlang::as_label(col_quo)}}")
  data |> dplyr::select(!!col_quo)
}

# enquos() + !!! for multiple args
multi_select <- function(data, ...) {
  cols <- rlang::enquos(...)
  cli::cli_inform("Selecting {length(cols)} column{?s}")
  data |> dplyr::select(!!!cols)
}

# Named enquos for column creation
my_mutate <- function(data, ...) {
  dots <- rlang::enquos(...)  # named list of quosures
  data |> dplyr::mutate(!!!dots)
}
# Usage: mtcars |> my_mutate(mpg2 = mpg * 2, wt_kg = wt * 453.6)
```

## `inject()` for Programmatic Code

`inject()` evaluates an expression with `!!`/`!!!` support inside:

```r
build_summary <- function(data, col, fns = list(mean = mean, sd = sd)) {
  args <- purrr::imap(fns, \(fn, name) {
    rlang::expr((!!fn)({{ col }}, na.rm = TRUE))
  })
  rlang::inject(dplyr::summarise(data, !!!args, .groups = "drop"))
}

# Conditional expression building
optional_filter <- function(data, col, min_val = NULL, max_val = NULL) {
  out <- data
  if (!is.null(min_val)) {
    out <- rlang::inject(dplyr::filter(out, {{ col }} >= !!min_val))
  }
  if (!is.null(max_val)) {
    out <- rlang::inject(dplyr::filter(out, {{ col }} <= !!max_val))
  }
  out
}
```

## Error Context: `caller_env()` and `caller_arg()`

These functions help error messages point to the user's code, not internal
implementation details.

### `caller_arg()` -- Argument Name in Errors

```r
check_positive <- function(x, arg = rlang::caller_arg(x),
                           call = rlang::caller_env()) {
  if (!is.numeric(x) || any(x <= 0, na.rm = TRUE)) {
    cli::cli_abort(
      "{.arg {arg}} must contain only positive numbers.",
      call = call
    )
  }
  invisible(x)
}

# In user code:
my_fun <- function(threshold) {
  check_positive(threshold)
  # Error: `threshold` must contain only positive numbers.
  # (points to my_fun(), not check_positive())
}
```

### `caller_env()` -- Error Call Environment

Always pass `call = caller_env()` to `cli_abort()` in internal helpers:

```r
validate_data <- function(data, required_cols, call = rlang::caller_env()) {
  missing <- setdiff(required_cols, names(data))
  if (length(missing) > 0L) {
    cli::cli_abort(
      c("Missing required column{?s}: {.field {missing}}",
        "i" = "Data has columns: {.field {names(data)}}"),
      call = call
    )
  }
}
```

## Input Validators: `check_*()` Functions

rlang provides input validation helpers that produce consistent error messages.

### `check_required()` -- Ensure Argument Was Supplied

```r
my_plot <- function(data, x, y) {
  rlang::check_required(x)
  rlang::check_required(y)
  # Errors: `x` is absent but must be supplied.
  ggplot2::ggplot(data, ggplot2::aes({{ x }}, {{ y }}))
}
```

### `check_exclusive()` -- Mutually Exclusive Arguments

```r
my_read <- function(file = NULL, url = NULL) {
  action <- rlang::check_exclusive(file, url)  # Errors if both or neither
  switch(action, file = readr::read_csv(file), url = readr::read_csv(url))
}
```

### `check_dots_empty()` and `check_dots_used()`

```r
strict_fun <- function(x, ..., na.rm = TRUE) {
  rlang::check_dots_empty()   # Error if ... has unexpected args
  mean(x, na.rm = na.rm)
}

flexible_fun <- function(x, ...) {
  rlang::check_dots_used()    # Warn if ... args went unused
  plot(x, ...)
}
```

## `try_fetch()` for Condition Handling

`try_fetch()` is rlang's structured condition handler, matching conditions by
class. Use `parent = cnd` in `cli_abort()` to chain errors.

```r
safe_read <- function(path) {
  rlang::try_fetch(
    readr::read_csv(path, show_col_types = FALSE),
    error = function(cnd) {
      cli::cli_abort(
        "Failed to read {.file {path}}.",
        parent = cnd  # chains: "Failed to read..." -> "Caused by..."
      )
    }
  )
}
```

### Class-Based Dispatch

Match specific condition classes for different handling:

```r
robust_parse <- function(x) {
  rlang::try_fetch(
    jsonlite::fromJSON(x),
    simpleError = function(cnd) {
      cli::cli_warn("JSON parse failed: {conditionMessage(cnd)}")
      NULL
    },
    simpleWarning = function(cnd) {
      cli::cli_inform("JSON parse warning: {conditionMessage(cnd)}")
      rlang::zap()  # Continue with result despite warning
    }
  )
}
```

## Common Patterns

### Pattern 1: Column-Accepting Function (Complete)

Combines embrace, dynamic names, input validation, and grouping:

```r
#' @export
grouped_stats <- function(data, group_col, value_col, na.rm = TRUE) {
  rlang::check_required(group_col)
  rlang::check_required(value_col)

  data |>
    dplyr::group_by({{ group_col }}) |>
    dplyr::summarise(
      "{{ value_col }}_mean" := mean({{ value_col }}, na.rm = na.rm),
      "{{ value_col }}_n" := sum(!is.na({{ value_col }})),
      .groups = "drop"
    )
}
```

### Pattern 2: String Column Names (Programmatic)

Uses `.data[[]]`, `inject()`, and `!!!` for string-based column access:

```r
#' @export
summarise_by_name <- function(data, col_name,
                              fns = list(mean = mean, sd = sd)) {
  if (!col_name %in% names(data)) {
    cli::cli_abort("Column {.field {col_name}} not found in data.",
                   call = rlang::caller_env())
  }

  args <- purrr::imap(fns, \(fn, name) {
    rlang::expr((!!fn)(.data[[!!col_name]], na.rm = TRUE))
  }) |>
    rlang::set_names(paste0(col_name, "_", names(fns)))

  rlang::inject(dplyr::summarise(data, !!!args))
}
```

### Pattern 3: Wrapper with Error Forwarding

```r
#' @export
safe_read_csv <- function(path, ...) {
  rlang::check_required(path)
  rlang::check_dots_used()
  if (!file.exists(path)) {
    cli::cli_abort(c("File does not exist.", "x" = "Path: {.file {path}}"))
  }
  rlang::try_fetch(
    readr::read_csv(path, show_col_types = FALSE, ...),
    error = function(cnd) {
      cli::cli_abort("Failed to parse {.file {path}}.", parent = cnd)
    }
  )
}
```

### Pattern 4: Multiple Column Transformer via `across()`

```r
#' @export
standardise_cols <- function(data, ...) {
  data |>
    dplyr::mutate(dplyr::across(
      c(...),
      ~ (. - mean(., na.rm = TRUE)) / sd(., na.rm = TRUE),
      .names = "{.col}_z"
    ))
}
```

## Review Checklist

- [ ] Uses `{{ }}` for user-supplied column names (not bare `!!enquo()`)
- [ ] Uses `.data$col` for hard-coded column names in package code
- [ ] Uses `.env$var` where data-column collision is possible
- [ ] Uses `:=` with `"{{ col }}_suffix"` for dynamic column names
- [ ] Passes `call = caller_env()` in internal validation helpers
- [ ] Uses `check_required()` for mandatory tidy-eval arguments
- [ ] Uses `try_fetch()` instead of `tryCatch()` for rlang integration
- [ ] Has `@importFrom rlang .data .env` if using pronouns
- [ ] No bare `enquo()` + `!!` where `{{ }}` suffices
- [ ] `!!!` used only to splice a list; not for single values

## Resources & Advanced Topics

### Reference Files

- **[references/injection-patterns.md](references/injection-patterns.md)** --
  Advanced injection and defusing patterns: dynamic tidyselect, expression
  surgery, quosure manipulation, metaprogramming recipes.
- **[references/bridge-patterns.md](references/bridge-patterns.md)** -- `across()` as tidy-select↔data-mask bridge
- **[references/dots-forwarding.md](references/dots-forwarding.md)** -- `...` forwarding, `check_dots_*()`, dynamic dots
- **[references/name-injection.md](references/name-injection.md)** -- `:=`, `englue()`, `.names` in `across()`
- **[references/testing-tidyeval.md](references/testing-tidyeval.md)** -- Testing `{{ }}`, `!!`, `.data` with testthat
- **[references/transformation-patterns.md](references/transformation-patterns.md)** -- Wrapping and augmenting tidy-eval args
- **[references/avoid-patterns.md](references/avoid-patterns.md)** -- Anti-patterns: `eval(parse())`, `get()`, mixing styles

### Related Skills

- **cli-package** -- Error formatting with `cli_abort()` (used with `caller_env()`)
- **tidyverse-style** -- Mandates `.data$col` and `{{ }}` in package code
- **lifecycle-management** -- Deprecation patterns that use rlang internals
- **testthat-patterns** -- Testing tidy-eval functions with snapshots

### External Resources

- [Programming with dplyr](https://dplyr.tidyverse.org/articles/programming.html)
- [rlang: Data masking](https://rlang.r-lib.org/reference/topic-data-mask.html)
- [rlang: Injection](https://rlang.r-lib.org/reference/topic-inject.html)
- [rlang: Defusing](https://rlang.r-lib.org/reference/topic-defuse.html)
- [rlang: Data mask ambiguity](https://rlang.r-lib.org/reference/topic-data-mask-ambiguity.html)
