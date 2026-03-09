---
paths:
  - "R/**/*.R"
  - "tests/**/*.R"
---

# Anti-Pattern: suppressWarnings(as.*) for Type Coercion

## The Problem

Using `suppressWarnings()` to silence type coercion warnings is a dangerous anti-pattern that hides data quality issues:

```r
# ANTI-PATTERN - NEVER DO THIS
safe_int <- function(x) suppressWarnings(as.integer(x))
safe_num <- function(x) suppressWarnings(as.numeric(x))
```

### Why It's Dangerous

1. **Silent data corruption**: `"2.5"` silently becomes `2L` (truncation)
2. **Hidden failures**: `"abc"` silently becomes `NA` without tracking
3. **No audit trail**: You can't know how much data was corrupted
4. **Debugging nightmare**: Errors appear downstream, far from the source

### Real Example

```r
# Input data
scores <- c("100", "85.5", "N/A", "92")

# Anti-pattern result
suppressWarnings(as.integer(scores))
# [1] 100  85  NA  92
#      ^^^ 85.5 truncated to 85 - SILENTLY!

# What the user expected: error or warning about 85.5
```

## The Solution

### 1. Use readr Column Specifications

```r
# CORRECT: Explicit types, tracked problems
col_types <- readr::cols(
  score = readr::col_integer()
)
df <- readr::read_csv("data.csv", col_types = col_types)

# Check what failed
problems <- readr::problems(df)
if (nrow(problems) > 0L) {
  cli::cli_warn(c(
    "!" = "{nrow(problems)} values failed integer parsing",
    "i" = "Use readr::problems(df) to inspect"
  ))
}
```

### 2. Track Coercion Failures Explicitly

If you must coerce manually, track failures:

```r
#' Coerce to integer with failure tracking
#' @return List with result and failure info
coerce_integer_tracked <- function(x) {
  n_before <- sum(is.na(x))
  result <- suppressWarnings(as.integer(x))
  n_after <- sum(is.na(result))
  n_failures <- n_after - n_before

  if (n_failures > 0L) {
    cli::cli_warn(c(
      "!" = "{n_failures} values failed integer coercion",
      "i" = "These became NA"
    ))
  }

  list(result = result, n_failures = n_failures)
}
```

### 3. Use Type-Safe Extraction Helpers

For extracting columns that may be missing:

```r
extract_int_col <- function(df, col, n_rows) {
  if (col %in% colnames(df)) df[[col]] else rep(NA_integer_, n_rows)
}
```

## Detection in Code Review

Look for these patterns:

```r
# RED FLAGS - Always investigate
suppressWarnings(as.integer(...))
suppressWarnings(as.numeric(...))
suppressWarnings(as.double(...))
suppressWarnings(as.logical(...))

# Also watch for
tryCatch(as.integer(...), warning = function(w) ...)  # May hide issues
```

## Exceptions

The ONLY acceptable use is date parsing where failure is expected:

```r
# Acceptable: Date parsing where some failures are expected
dates <- c("2024-01-15", "not-a-date", "2024-03-20")
n_before <- sum(is.na(dates))
parsed <- suppressWarnings(lubridate::ymd(dates))
n_failed <- sum(is.na(parsed)) - n_before

if (n_failed > 0L) {
  cli::cli_warn("{n_failed} dates failed to parse")
}
```

Even here, failures MUST be tracked and reported.

## Related

- `missing-data-handling` skill
- `tidyverse-style` skill (Missing Data section)
- `adversarial-qa` skill (Type Attacks)
