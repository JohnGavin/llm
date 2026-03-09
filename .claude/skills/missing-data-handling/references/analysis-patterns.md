# Analysis Patterns for Missing Data

Detailed code examples for column extraction, database interoperability, and validation.

## Column Extraction with Missing Columns

**Problem:** Accessing missing columns returns NULL, causing tibble errors.

```r
# FAILS: NULL causes size mismatch
raw <- readr::read_csv("minimal.csv")  # Only has col1, col2
tibble::tibble(
  col1 = raw[["col1"]],
  col2 = raw[["col2"]],
  col3 = raw[["col3"]]  # NULL! Tibble size mismatch error
)
```

**Solution: Type-safe extraction helpers:**

```r
#' Extract integer column safely
#' @noRd
extract_int_col <- function(df, col, n_rows) {
  if (col %in% colnames(df)) {
    df[[col]]
  } else {
    rep(NA_integer_, n_rows)
  }
}

#' Extract character column safely
#' @noRd
extract_char_col <- function(df, col, n_rows) {
  if (col %in% colnames(df)) {
    as.character(df[[col]])
  } else {
    rep(NA_character_, n_rows)
  }
}

#' Extract numeric column safely
#' @noRd
extract_num_col <- function(df, col, n_rows) {
  if (col %in% colnames(df)) {
    df[[col]]
  } else {
    rep(NA_real_, n_rows)
  }
}

# Usage
n_rows <- nrow(raw)
tibble::tibble(
  col1 = raw[["col1"]],
  col2 = raw[["col2"]],
  col3 = extract_int_col(raw, "col3", n_rows)  # Safe!
)
```

## Database NULL vs R NA

### DuckDB

```r
library(duckdb)
library(dplyr)

con <- dbConnect(duckdb())

# NULL in SQL = NA in R
dbExecute(con, "CREATE TABLE t (x INTEGER)")
dbExecute(con, "INSERT INTO t VALUES (1), (NULL), (3)")

tbl(con, "t") |> collect()
# x: 1, NA, 3

# COALESCE converts NULL to default
tbl(con, sql("SELECT COALESCE(x, 0) as x FROM t")) |> collect()
# x: 1, 0, 3
```

### Arrow/Parquet

```r
library(arrow)

# Arrow null = R NA
df <- tibble::tibble(x = c(1L, NA_integer_, 3L))
write_parquet(df, "data.parquet")

# Round-trip preserves NA
read_parquet("data.parquet")$x
# 1, NA, 3
```

## Validation Patterns

### With pointblank

```r
library(pointblank)

agent <- create_agent(data) |>
  # Check for unexpected NAs in required columns
  col_vals_not_null(columns = c(id, date)) |>

  # Allow NAs in optional columns, but validate non-NA values
  col_vals_gte(columns = matches("^n_"), value = 0, na_pass = TRUE) |>

  # Check NA rate threshold
  rows_distinct() |>
  interrogate()
```

### With readr problems()

```r
#' Validate readr parse problems
#' @param df Parsed tibble (may have problems attribute)
#' @param max_problems Maximum allowed before warning
validate_parse_problems <- function(df, max_problems = 10L) {
  probs <- readr::problems(df)

  if (nrow(probs) > max_problems) {
    cli::cli_warn(c(
      "!" = "{nrow(probs)} parse problems detected",
      "i" = "Threshold: {max_problems}",
      "i" = "Use readr::problems() to inspect"
    ))
  }

  list(
    passed = nrow(probs) <= max_problems,
    n_problems = nrow(probs),
    problems = probs
  )
}
```

### NA Rate Checking

```r
#' Check NA rates per column
#' @param df Data frame
#' @param critical_cols Columns that should have <1% NA
#' @param warn_threshold Threshold for warning (default 0.05)
check_na_rates <- function(df, critical_cols, warn_threshold = 0.05) {
  rates <- vapply(df, function(x) mean(is.na(x)), numeric(1))

  issues <- names(rates)[rates > warn_threshold & names(rates) %in% critical_cols]

  if (length(issues) > 0L) {
    cli::cli_warn(c(
      "!" = "High NA rates in critical columns",
      "x" = paste(sprintf("%s: %.1f%%", issues, rates[issues] * 100), collapse = ", ")
    ))
  }

  list(rates = rates, issues = issues)
}
```

## Research Notes: NA Semantics and Readers

### Base R vs Tidyverse NA Semantics

**`is.na()` behavior:**
- `is.na()` works identically for all NA types (`NA`, `NA_integer_`, `NA_real_`, `NA_character_`, `NA_complex_`)
- Returns `TRUE` for any NA regardless of type -- no difference in detection

**Auto-coercion rules:**
- `NA` is logical by default; R coerces it to match the vector type:
  - `c(1L, NA)` -> `NA` becomes `NA_integer_`
  - `c(1.0, NA)` -> `NA` becomes `NA_real_`
  - `c("a", NA)` -> `NA` becomes `NA_character_`
- This is safe for vectors but can cause surprises in `tibble()` column creation
- Best practice: always use typed NAs (`NA_integer_`, `NA_real_`, `NA_character_`)

**readr/vctrs type system:**
- readr uses `vctrs` internally (since readr 2.0), which is stricter about type coercion
- `vctrs::vec_c(1L, NA)` works, but `vctrs::vec_c(1L, "a")` errors (no implicit coercion)
- Column specs (`col_integer()`, etc.) enforce types at parse time, not after

### readr vs vroom vs data.table NA Handling

| Reader | Default NA strings | Notes |
|--------|-------------------|-------|
| `readr::read_csv()` | `c("", "NA")` | Shared backend with vroom since readr 2.0 |
| `vroom::vroom()` | `c("", "NA")` | Same as readr (shared implementation) |
| `data.table::fread()` | `"NA"` only | Does NOT treat `""` as NA by default |
| `base::read.csv()` | `"NA"` only | Does NOT treat `""` as NA by default |

**Recommendation:** Always specify `na` explicitly regardless of which reader you use:
```r
na_strings <- c("", "NA", "N/A", "n/a", "-", "NULL", "#N/A")
```

**Locale-specific missing values:**
- Some datasets use locale-specific strings (e.g., `"fehlend"` in German)
- Always document expected NA representations in data dictionaries
- Add domain-specific strings to your `na` parameter

### Database NULL vs R NA (Extended)

**DuckDB:**
- `NULL` in SQL <-> `NA` in R (round-trip safe)
- `NULL` propagates in SQL like `NA` in R (e.g., `NULL + 1 = NULL`)
- `COALESCE(x, default)` is the SQL equivalent of `dplyr::coalesce()`
- JOINs: `NULL != NULL` in SQL (unlike R where `NA == NA` returns `NA`)
- Use `IS NOT DISTINCT FROM` for NULL-safe equality in DuckDB

**Arrow/Parquet:**
- Uses a null bitmask separate from values -- preserves typed NAs perfectly
- `NA_integer_` stays integer, `NA_real_` stays double through Parquet round-trip
- Arrow's `is_null()` compute function ~ R's `is.na()`

**SQLite:**
- `NULL` -> `NA` conversion works, but typed NA distinction is lost
- SQLite is typeless, so `NA_integer_` vs `NA_real_` may not survive round-trip
