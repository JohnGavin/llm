# Missing Data Handling in R

Comprehensive guide to handling missing values (NA) in R, covering base R semantics, tidyverse conventions, database interoperability, and defensive programming patterns.

## When to Use This Skill

- Writing data ingestion/parsing functions
- Designing data validation pipelines
- Reviewing code for NA handling robustness
- Debugging unexpected NA propagation
- Converting between base R and tidyverse patterns

## Core Concepts

### R's NA Types

R has **typed NA values** that preserve type information:

```r
NA              # Logical NA (default)
NA_integer_     # Integer NA
NA_real_        # Double/numeric NA
NA_character_   # Character NA
NA_complex_     # Complex NA

# No NA_Date_ exists! Use:
as.Date(NA_character_)  # or
lubridate::NA_Date_
```

**Why types matter:**

```r
# Type-safe column creation
tibble::tibble(
  int_col = c(1L, NA_integer_, 3L),      # Stays integer
  num_col = c(1.0, NA_real_, 3.0),       # Stays double
  chr_col = c("a", NA_character_, "c")   # Stays character
)

# vs type coercion surprise
tibble::tibble(
  bad_col = c(1L, NA, 3L)  # NA is logical, coerces to integer
)
```

### NA Propagation Rules

Most R operations propagate NA:

```r
NA + 1           # NA
NA & TRUE        # NA (logical AND)
NA | TRUE        # TRUE (logical OR - special case!)
NA == NA         # NA (not TRUE!)
is.na(NA)        # TRUE (the ONLY way to test for NA)
```

### Common NA String Representations

External data sources use many representations:

| Source | Common Strings |
|--------|----------------|
| CSV | `""`, `"NA"`, `"N/A"`, `"n/a"` |
| Excel | `"#N/A"`, `"-"`, `"NULL"` |
| Databases | `NULL` (different from R's NA) |
| APIs | `"null"`, `"None"`, `"undefined"` |
| Scientific | `"."`, `"*"`, `"missing"` |

## Base R vs Tidyverse Patterns

### Reading CSV Files

**Base R (problematic):**
```r
# Only recognizes "NA" by default
df <- read.csv("data.csv")  # "" becomes ""
df <- read.csv("data.csv", na.strings = c("", "NA", "N/A"))  # Better
```

**Tidyverse (preferred):**
```r
df <- readr::read_csv(
  "data.csv",
  na = c("", "NA", "N/A", "n/a", "-", "NULL", "#N/A"),
  col_types = readr::cols(.default = readr::col_character())
)
```

### Type Coercion

**Base R Anti-Pattern:**
```r
# NEVER DO THIS - silently hides coercion failures
safe_int <- function(x) suppressWarnings(as.integer(x))

# "2.5" silently becomes 2L (truncation)
# "abc" silently becomes NA
```

**Tidyverse Pattern:**
```r
# Use explicit column types - failures are tracked
col_types <- readr::cols(
  count = readr::col_integer(),
  amount = readr::col_double(),
  name = readr::col_character()
)

df <- readr::read_csv("data.csv", col_types = col_types)

# Inspect what failed
problems <- readr::problems(df)
if (nrow(problems) > 0L) {
  cli::cli_warn("{nrow(problems)} parse problems detected")
}
```

### Column Extraction with Missing Columns

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

### Date NA Handling

R lacks `NA_Date_`, requiring special patterns:

```r
# Creating NA dates
na_date <- as.Date(NA_character_)
na_date <- lubridate::NA_Date_  # If lubridate available

# Date parsing with NAs
dates <- c("2024-01-15", "not-a-date", "2024-03-20")
lubridate::ymd(dates)  # Returns NA for invalid, with warning

# Suppress expected warnings (ONLY for date parsing)
parsed <- suppressWarnings(lubridate::ymd(dates))
n_failed <- sum(is.na(parsed)) - sum(is.na(dates))
if (n_failed > 0L) {
  cli::cli_warn("{n_failed} dates failed to parse")
}
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

## Testing Patterns

### Comprehensive NA Tests

```r
test_that("function handles all NA types", {
  # Typed NAs

  expect_no_error(my_func(NA_integer_))
  expect_no_error(my_func(NA_real_))
  expect_no_error(my_func(NA_character_))

  # Embedded NAs
  expect_no_error(my_func(c(1, NA, 3)))
  expect_no_error(my_func(c("a", NA, "c")))

  # All-NA vectors
  expect_no_error(my_func(rep(NA_integer_, 10)))

  # NA in data frames
  df <- tibble::tibble(
    a = c(1, NA, 3),
    b = c(NA, "x", NA)
  )
  expect_no_error(my_func(df))
})

test_that("function preserves NA types", {
  result <- my_func(c(1L, NA_integer_, 3L))
  expect_true(is.integer(result))
})

test_that("function handles NA propagation correctly", {
  # Document expected NA propagation
  result <- my_func(c(1, NA, 3))
  expect_equal(sum(is.na(result)), 1L)  # Or whatever is expected
})
```

### NA String Variant Tests

```r
test_that("parser handles all NA string variants", {
  tmp <- withr::local_tempfile(fileext = ".csv")
  writeLines(c(
    "col",
    "",        # Empty string
    "NA",      # R default
    "N/A",     # Common variant
    "n/a",     # Lowercase
    "-",       # Dash
    "NULL",    # SQL-style
    "#N/A"     # Excel-style
  ), tmp)

  result <- parse_data(tmp)
  expect_true(all(is.na(result$col)))
})
```

## Anti-Patterns to Avoid

### 1. suppressWarnings(as.*)

```r
# BAD: Silently hides data quality issues
safe_int <- function(x) suppressWarnings(as.integer(x))

# GOOD: Use readr col_types or explicit validation
```

### 2. Unchecked Column Access

```r
# BAD: Returns NULL if column missing
value <- df[["missing_col"]]

# GOOD: Check existence or use extraction helper
value <- extract_int_col(df, "col", nrow(df))
```

### 3. Implicit NA Coercion

```r
# BAD: NA coerces to logical, then to integer
c(1L, NA, 3L)  # Works but NA is logical

# GOOD: Explicit typed NA
c(1L, NA_integer_, 3L)
```

### 4. == for NA Comparison

```r
# BAD: Always returns NA
x == NA

# GOOD: Use is.na()
is.na(x)
```

### 5. Ignoring NA in Aggregations

```r
# BAD: Returns NA if any NA present
mean(c(1, 2, NA))  # NA

# GOOD: Explicit na.rm
mean(c(1, 2, NA), na.rm = TRUE)  # 1.5

# OR: Document that NA propagates (if intentional)
```

## Checklist for Code Review

- [ ] All `read.csv()` replaced with `readr::read_csv()`
- [ ] Explicit `na = c(...)` parameter in read_csv
- [ ] Explicit `col_types` specification (no guessing)
- [ ] `readr::problems()` checked after parsing
- [ ] No `suppressWarnings(as.integer())` pattern
- [ ] Column extraction uses safe helpers or checks
- [ ] Typed NAs used (`NA_integer_`, not `NA`)
- [ ] Aggregations have explicit `na.rm = TRUE` or documented NA behavior
- [ ] Tests cover all NA types and edge cases
- [ ] Date parsing NA failures tracked

## Related Skills

- **adversarial-qa**: NA attack patterns (Category 2)
- **data-validation-pointblank**: NA validation rules
- **tidyverse-style**: NA handling conventions
- **data-wrangling-duckdb**: NULL handling in SQL

## References

- [R for Data Science: Missing Values](https://r4ds.hadley.nz/missing-values.html)
- [readr Column Specification](https://readr.tidyverse.org/reference/cols.html)
- [Tidyverse Design Principles: NA](https://design.tidyverse.org/cs-na.html)
- [pointblank Documentation](https://rstudio.github.io/pointblank/)

## Research Notes

Answers to research questions from issue #37.

### Base R vs Tidyverse NA Semantics

**`is.na()` behavior:**
- `is.na()` works identically for all NA types (`NA`, `NA_integer_`, `NA_real_`, `NA_character_`, `NA_complex_`)
- Returns `TRUE` for any NA regardless of type — no difference in detection

**Auto-coercion rules:**
- `NA` is logical by default; R coerces it to match the vector type:
  - `c(1L, NA)` → `NA` becomes `NA_integer_`
  - `c(1.0, NA)` → `NA` becomes `NA_real_`
  - `c("a", NA)` → `NA` becomes `NA_character_`
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

### Database NULL vs R NA

**DuckDB:**
- `NULL` in SQL ↔ `NA` in R (round-trip safe)
- `NULL` propagates in SQL like `NA` in R (e.g., `NULL + 1 = NULL`)
- `COALESCE(x, default)` is the SQL equivalent of `dplyr::coalesce()`
- JOINs: `NULL != NULL` in SQL (unlike R where `NA == NA` returns `NA`)
- Use `IS NOT DISTINCT FROM` for NULL-safe equality in DuckDB

**Arrow/Parquet:**
- Uses a null bitmask separate from values — preserves typed NAs perfectly
- `NA_integer_` stays integer, `NA_real_` stays double through Parquet round-trip
- Arrow's `is_null()` compute function ≈ R's `is.na()`

**SQLite:**
- `NULL` → `NA` conversion works, but typed NA distinction is lost
- SQLite is typeless, so `NA_integer_` vs `NA_real_` may not survive round-trip

### Testing Patterns for NA Handling

**Property-based testing:**
- `hedgehog` package: generate arbitrary vectors with random NA positions
- Pattern: define a property (e.g., "output length equals input length") and test with generated data

```r
test_that("function preserves length with random NAs", {
  hedgehog::forall(
    hedgehog::gen.c(hedgehog::gen.element(c(1:10, NA_integer_))),
    function(x) {
      result <- my_func(x)
      expect_equal(length(result), length(x))
    }
  )
})
```

**Reproducible fuzz testing:**
```r
test_that("function handles random NA patterns", {
  withr::local_seed(42)
  for (i in seq_len(100)) {
    x <- sample(c(1:5, NA_integer_), size = 20, replace = TRUE)
    expect_no_error(my_func(x))
  }
})
```

**Systematic NA position tests:**
```r
test_that("function handles NA at every position", {
  base_vec <- 1:5
  for (pos in seq_along(base_vec)) {
    test_vec <- base_vec
    test_vec[pos] <- NA_integer_
    expect_no_error(my_func(test_vec))
  }
})
```

**Key test dimensions:**
1. NA type (integer, real, character, complex, Date)
2. NA position (first, last, middle, all, none)
3. NA density (0%, 50%, 100%)
4. Mixed types with NA (after coercion)
