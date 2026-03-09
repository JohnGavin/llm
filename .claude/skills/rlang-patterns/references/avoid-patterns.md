# Anti-Patterns in Tidy Evaluation

Patterns to avoid and their correct alternatives.

## 1. `eval(parse(text = ...))` — Security Risk

```r
# BAD: string-based evaluation — injection risk, hard to debug
col <- "mpg"
eval(parse(text = paste0("mtcars$", col)))

# GOOD: .data pronoun
mtcars |> dplyr::pull(.data[[col]])
```

## 2. `get()` in Data Mask — Name Collision Prone

```r
# BAD: get() in data-masked context
col <- "mpg"
mtcars |> dplyr::mutate(x = get(col))

# GOOD: .data[[]] or !!sym()
mtcars |> dplyr::mutate(x = .data[[col]])
```

## 3. Using `{{ }}` on Non-Arguments

```r
# BAD: {{ }} on a local variable (not a function argument)
my_fn <- function(data) {
  col <- sym("mpg")
  data |> dplyr::select({{ col }})  # WRONG — col is not a param
}

# GOOD: use !! for local symbols
my_fn <- function(data) {
  col <- sym("mpg")
  data |> dplyr::select(!!col)
}
```

## 4. Mixing Injection Styles

```r
# BAD: enquo() + {{ }} (redundant)
my_fn <- function(data, col) {
  col_quo <- rlang::enquo(col)
  data |> dplyr::select({{ col_quo }})  # {{ }} already defuses
}

# GOOD: pick one style
# Option A: {{ }} only (preferred)
my_fn <- function(data, col) {
  data |> dplyr::select({{ col }})
}

# Option B: enquo() + !! (when you need the quosure for other purposes)
my_fn <- function(data, col) {
  col_quo <- rlang::enquo(col)
  cli::cli_inform("Column: {rlang::as_label(col_quo)}")
  data |> dplyr::select(!!col_quo)
}
```

## 5. Bare `enquo()` + `!!` Where `{{ }}` Suffices

```r
# VERBOSE: unnecessary defuse-inject cycle
my_fn <- function(data, col) {
  col_quo <- rlang::enquo(col)
  data |> dplyr::filter(!!col_quo > 0)
}

# BETTER: {{ }} is cleaner
my_fn <- function(data, col) {
  data |> dplyr::filter({{ col }} > 0)
}
```

## 6. `!!!` for a Single Value

```r
# BAD: splice operator on a single item
val <- rlang::quo(mpg)
data |> dplyr::select(!!!val)

# GOOD: use !! for single injection
data |> dplyr::select(!!val)
```

## 7. Forgetting `.data`/`.env` in Package Code

```r
# BAD: ambiguous — column or environment variable?
threshold <- 10
data |> dplyr::filter(score > threshold)

# GOOD: explicit disambiguation
data |> dplyr::filter(.data$score > .env$threshold)
```

## Summary: When to Use What

| I have... | I want to... | Use |
|-----------|-------------|-----|
| Function argument (column) | Pass to dplyr verb | `{{ arg }}` |
| Function argument (need quosure) | Inspect + inject | `enquo()` + `!!` |
| String column name | Use in dplyr | `.data[[name]]` |
| String column name | Create symbol | `rlang::sym(name)` + `!!` |
| Character vector of names | Pass to dplyr | `all_of(names)` |
| List of quosures | Splice into verb | `!!!quos` |
| Local computed value | Inject into expression | `.env$var` or `!!val` |
