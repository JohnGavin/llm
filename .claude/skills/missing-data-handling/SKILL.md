---
name: missing-data-handling
description: Use when handling NA values in R, implementing missing data patterns across base R and tidyverse, ensuring database interoperability with NULLs, or writing defensive code for missing values. Triggers: NA, missing data, NULL, na.rm, complete.cases, missing values.
---
# Missing Data Handling in R

Guide to handling missing values (NA) in R, covering base R semantics, tidyverse conventions, database interoperability, and defensive programming patterns.

## When to Use This Skill

- Writing data ingestion/parsing functions
- Designing data validation pipelines
- Reviewing code for NA handling robustness
- Debugging unexpected NA propagation

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
as.Date(NA_character_)  # or lubridate::NA_Date_
```

**Why types matter:** Using untyped `NA` in `tibble()` can cause coercion surprises. Always use typed NAs (`NA_integer_`, `NA_real_`, `NA_character_`).

### NA Propagation Rules

```r
NA + 1           # NA
NA & TRUE        # NA (logical AND)
NA | TRUE        # TRUE (logical OR - special case!)
NA == NA         # NA (not TRUE!)
is.na(NA)        # TRUE (the ONLY way to test for NA)
```

### Common NA String Representations

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
df <- read.csv("data.csv")  # Only recognizes "NA" by default
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

**Anti-Pattern:** `suppressWarnings(as.integer(x))` silently hides truncation and failures.

**Correct:** Use readr column specs with `readr::problems()` to track failures:
```r
col_types <- readr::cols(count = readr::col_integer(), amount = readr::col_double())
df <- readr::read_csv("data.csv", col_types = col_types)
problems <- readr::problems(df)
if (nrow(problems) > 0L) cli::cli_warn("{nrow(problems)} parse problems detected")
```

### Column Extraction with Missing Columns

Accessing missing columns returns NULL, causing tibble size mismatch errors. Use type-safe extraction helpers (`extract_int_col`, `extract_char_col`, `extract_num_col`) that return typed NA vectors for missing columns.

See [analysis-patterns.md](references/analysis-patterns.md) for full helper implementations.

### Date NA Handling

R lacks `NA_Date_`. Use `as.Date(NA_character_)` or `lubridate::NA_Date_`. For date parsing, `suppressWarnings()` is acceptable ONLY if failures are tracked:

```r
parsed <- suppressWarnings(lubridate::ymd(dates))
n_failed <- sum(is.na(parsed)) - sum(is.na(dates))
if (n_failed > 0L) cli::cli_warn("{n_failed} dates failed to parse")
```

## Database NULL vs R NA

Key mappings: SQL `NULL` = R `NA`. Use `COALESCE()` in SQL, `dplyr::coalesce()` in R. Arrow/Parquet preserves typed NAs via null bitmask. SQLite loses typed NA distinction.

See [analysis-patterns.md](references/analysis-patterns.md) for DuckDB, Arrow/Parquet, and SQLite code examples and extended semantics.

## Validation Patterns

Three validation approaches: **pointblank** (declarative agent-based checks), **readr problems()** (parse failure tracking), and **NA rate checking** (per-column threshold monitoring).

See [analysis-patterns.md](references/analysis-patterns.md) for full implementations of `validate_parse_problems()` and `check_na_rates()`.

## Testing Patterns

Test NA handling across four dimensions: type (integer/real/character/Date), position (first/last/middle/all/none), density (0%/50%/100%), and mixed types after coercion. Include NA string variant tests for parsers, property-based testing with `hedgehog`, and reproducible fuzz testing.

See [testing-patterns.md](references/testing-patterns.md) for complete test examples.

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
c(1L, NA, 3L)
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
mean(c(1, 2, NA))
# GOOD: Explicit na.rm
mean(c(1, 2, NA), na.rm = TRUE)
```

## Checklist for Code Review

- [ ] `readr::read_csv()` used (not `read.csv()`)
- [ ] Explicit `na = c(...)` parameter in read_csv
- [ ] Explicit `col_types` specification (no guessing)
- [ ] `readr::problems()` checked after parsing
- [ ] No `suppressWarnings(as.integer())` pattern
- [ ] Column extraction uses safe helpers or checks
- [ ] Typed NAs used (`NA_integer_`, not `NA`)
- [ ] Aggregations have explicit `na.rm = TRUE` or documented NA behavior
- [ ] Tests cover all NA types and edge cases
- [ ] Date parsing NA failures tracked

## Research Notes

Detailed findings from issue #37 on NA semantics, reader comparison, and database interop are in the reference files:
- [analysis-patterns.md](references/analysis-patterns.md) -- Base R vs tidyverse auto-coercion, readr/vroom/data.table defaults, database NULL semantics
- [testing-patterns.md](references/testing-patterns.md) -- Property-based and fuzz testing patterns

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
