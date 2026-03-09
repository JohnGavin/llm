# Adversarial QA - Detailed Attack Examples

Full code examples for each attack category. See [SKILL.md](../SKILL.md) for the summary and decision criteria.

## 1. Boundary Attacks

Test extreme numeric values that commonly cause silent failures.

```r
test_that("function handles extreme values", {
  expect_no_error(my_func(Inf))
  expect_no_error(my_func(-Inf))
  expect_no_error(my_func(NaN))
  expect_no_error(my_func(1e10))
  expect_no_error(my_func(-1e10))
  expect_no_error(my_func(0))
  expect_no_error(my_func(.Machine$double.xmin))
  expect_no_error(my_func(.Machine$double.xmax))
})
```

## 2. NA Attacks

Test NA handling at every input position. R has **typed NAs** that must be tested separately.

```r
test_that("function handles all NA types", {
  # Typed NAs - each may behave differently
  expect_no_error(my_func(NA))            # Logical NA (default)
  expect_no_error(my_func(NA_integer_))   # Integer NA
  expect_no_error(my_func(NA_real_))      # Numeric/double NA
  expect_no_error(my_func(NA_character_)) # Character NA
  expect_no_error(my_func(NA_complex_))   # Complex NA

  # Date NA (R has no NA_Date_!)
  expect_no_error(my_func(as.Date(NA_character_)))
})

test_that("function handles embedded NAs", {
  # NA at different positions
  expect_no_error(my_func(c(NA, 2, 3)))   # First
  expect_no_error(my_func(c(1, NA, 3)))   # Middle
  expect_no_error(my_func(c(1, 2, NA)))   # Last

  # Multiple NAs
  expect_no_error(my_func(c(1, NA, NA, 4)))
})

test_that("function handles all-NA input", {
  expect_no_error(my_func(rep(NA_integer_, 10)))
  expect_no_error(my_func(rep(NA_real_, 10)))
  expect_no_error(my_func(rep(NA_character_, 10)))
})

test_that("function handles NA in data frames", {
  # Single NA column
  df <- tibble::tibble(x = c(1, NA, 3), y = c("a", "b", "c"))
  expect_no_error(my_func(df))

  # All-NA column
  df_na_col <- tibble::tibble(x = rep(NA_real_, 3), y = 1:3)
  expect_no_error(my_func(df_na_col))

  # NA in every column
  df_na_all <- tibble::tibble(x = c(1, NA), y = c(NA, "b"))
  expect_no_error(my_func(df_na_all))
})

test_that("function preserves NA type in output", {
  # Verify output maintains input type
  result <- my_func(c(1L, NA_integer_, 3L))
  expect_true(is.integer(result))

  result <- my_func(c(1.0, NA_real_, 3.0))
  expect_true(is.double(result))
})

test_that("function documents NA propagation behavior", {
  # Test expected NA propagation
  result <- my_func(c(1, NA, 3))
  # Document: does NA propagate? Is it removed? Replaced?
  # expect_equal(sum(is.na(result)), 1L)  # Propagates
  # expect_equal(length(result), 2L)       # Removed
  # expect_false(any(is.na(result)))       # Replaced
})
```

**NA Attack Reference Table:**

| Attack | What it tests | Example |
|--------|---------------|---------|
| Typed NAs | Each NA type handled | `NA_integer_` vs `NA_real_` |
| Position NAs | First/middle/last element | `c(NA, 2, 3)` |
| Multiple NAs | Several missing values | `c(1, NA, NA, 4)` |
| All-NA vector | Entirely missing input | `rep(NA_real_, 10)` |
| NA column | Column with NAs | `tibble(x = c(1, NA))` |
| All-NA column | Entirely missing column | `tibble(x = rep(NA, 3))` |
| Date NA | No NA_Date_ in R | `as.Date(NA_character_)` |
| NA propagation | Does NA spread? | `sum(c(1, NA, 3))` -> `NA` |
| Type preservation | Output type matches input | Integer in -> Integer out |

## 3. Type Attacks

Wrong types that R might silently coerce.

```r
test_that("function rejects wrong types gracefully", {
  # Character where numeric expected
  expect_error(my_func("not_a_number"), class = "simpleError")

  # Numeric where logical expected
  expect_error(my_func(42), class = "simpleError")

  # List where vector expected
  expect_error(my_func(list(1, 2, 3)))

  # Factor (common surprise coercion)
  expect_error(my_func(factor("a")))
})
```

## 4. Structure Attacks

Test data frame structure variations.

```r
test_that("function handles structure variations", {
  # tibble vs data.frame
  expect_equal(my_func(tibble::tibble(x = 1)), my_func(data.frame(x = 1)))


  # Single-row input
  expect_no_error(my_func(data.frame(x = 1)))

  # Empty data frame (0 rows)
  expect_no_error(my_func(data.frame(x = numeric(0))))

  # Minimal columns (only required ones)
  expect_no_error(my_func(data.frame(x = 1)))

  # Extra columns (should be ignored)
  expect_no_error(my_func(data.frame(x = 1, extra = "foo")))

  # Wrong column names
  expect_error(my_func(data.frame(wrong_name = 1)))
})
```

## 5. Injection Attacks

For functions that interact with databases or produce HTML.

```r
test_that("function defends against injection", {
  # SQL injection on DB parameters
  expect_error(my_func(station = "M2'; DROP TABLE data;--"))

  # XSS on HTML-producing functions
  result <- my_func(title = "<script>alert('xss')</script>")
  expect_false(grepl("<script>", result, fixed = TRUE))

  # Path traversal

  expect_error(my_func(file = "../../../etc/passwd"))
})
```

## 6. Idempotency

Double-application should return the same result.

```r
test_that("function is idempotent", {
  input <- data.frame(x = c(1, 2, 3))
  result1 <- my_func(input)
  result2 <- my_func(result1)
  expect_equal(result1, result2)
})
```

## 7. Determinism

Same inputs produce same outputs (for non-random functions).

```r
test_that("function is deterministic", {
  input <- data.frame(x = c(1, 2, 3))
  result1 <- my_func(input)
  result2 <- my_func(input)
  expect_identical(result1, result2)
})
```

## 8. Domain Hallucination Guards

Source code assertions that domain-specific outputs are correct. Especially important for data pipelines where wrong mappings can silently produce plausible-but-wrong results.

```r
test_that("domain mapping is correct", {
  # Verify known correct mappings (ground truth)
  result <- my_func(code = "BM")
  expect_equal(result$description, "Bone Marrow")  # NOT "Brain Metastasis"

  # Verify known categories are complete
  all_categories <- sort(unique(my_func(get_all = TRUE)$category))
  expect_true("expected_category" %in% all_categories)

  # Verify no hallucinated categories
  expect_true(all(all_categories %in% VALID_CATEGORIES))
})
```

## 9. Data Sanity Attacks

For functions that ingest, transform, or query time-series data. These test whether
the pipeline catches basic arithmetic and temporal inconsistencies.

**Applies to any function that:**
- Ingests data from external sources (APIs, files, databases)
- Returns time-series or panel data
- Produces aggregated summaries (counts, means, totals)

```r
test_that("temporal coverage matches expected frequency", {
  # Hourly data for 7 days = 168 expected observations
  result <- get_weekly_data(station = "M3", days = 7)
  expected <- 24 * 7
  coverage_pct <- nrow(result) / expected * 100
  expect_gte(coverage_pct, 30,
    label = paste0("Coverage ", round(coverage_pct, 1), "% is below 30% minimum"))
})

test_that("no duplicate timestamps per station", {
  result <- get_data(station = "M3")
  n_unique <- nrow(dplyr::distinct(result, time))
  expect_equal(nrow(result), n_unique)
})

test_that("timestamps are monotonically increasing", {
  result <- get_data(station = "M3") |> dplyr::arrange(time)
  expect_true(all(diff(result$time) > 0))
})

test_that("data freshness within expected window", {
  result <- get_latest_data()
  hours_old <- as.numeric(difftime(Sys.time(), max(result$time), units = "hours"))
  expect_lte(hours_old, 72, label = "Data is more than 72 hours old")
})

test_that("entity completeness: all expected stations present", {
  result <- get_data()
  stations <- unique(result$station_id)
  expect_true("M3" %in% stations)
})

test_that("aggregation arithmetic: parts sum to total", {
  per_station <- get_summary_by_station()
  total <- get_total_summary()
  expect_equal(sum(per_station$n_records), total$n_records)
})

test_that("schema stability: column names unchanged", {
  result <- get_data(station = "M3")
  expect_snapshot(sort(names(result)))
})
```

| Attack | What it tests | Example |
|--------|--------------|---------|
| Frequency audit | `n_obs / expected_obs` per entity | 69/168 = 41% |
| Duplicate detection | No duplicate primary keys | `distinct(time, station_id)` |
| Monotonicity | Timestamps strictly increasing per entity | `all(diff(time) > 0)` |
| Freshness | Latest obs within expected window | `max(time) > Sys.time() - 72h` |
| Entity completeness | All expected entities present | `"M3" %in% stations` |
| Schema stability | Column names/types unchanged | `expect_snapshot(names(result))` |
| Aggregation arithmetic | `sum(parts) == total` | `sum(per_station_records) == total_records` |

## 10. Data Ingestion Attacks

For functions that read external data files (CSV, JSON, Excel, etc.). Test robustness
against malformed, corrupted, or adversarial input files.

**Applies to any function that:**
- Reads CSV/TSV files (`read_csv`, `read.csv`, etc.)
- Parses external data sources
- Transforms raw data into structured formats

```r
test_that("parse_X: handles BOM prefix", {
  tmp <- withr::local_tempfile(fileext = ".csv")
  bom <- as.raw(c(0xEF, 0xBB, 0xBF))
  content <- "col1,col2\nval1,val2"
  writeBin(c(bom, charToRaw(content)), tmp)
  result <- parse_X(tmp)
  expect_equal(nrow(result), 1L)
})

test_that("parse_X: handles all NA string variants", {
  # Test "", "NA", "N/A", "n/a", "-", "NULL"
  tmp <- withr::local_tempfile(fileext = ".csv")
  writeLines(c("col", "", "NA", "N/A", "n/a", "-", "NULL"), tmp)
  result <- parse_X(tmp)
  expect_true(all(is.na(result$col)))
})

test_that("parse_X: handles whitespace in values", {
  tmp <- withr::local_tempfile(fileext = ".csv")
  writeLines(c("col", "  value  "), tmp)
  result <- parse_X(tmp)
  expect_equal(result$col, "value")  # Trimmed
})

test_that("parse_X: handles quoted fields with embedded commas", {
  tmp <- withr::local_tempfile(fileext = ".csv")
  writeLines(c('col1,col2', '"value, with comma",other'), tmp)
  result <- parse_X(tmp)
  expect_equal(result$col1, "value, with comma")
})

test_that("parse_X: handles encoding (latin1)", {
  tmp <- withr::local_tempfile(fileext = ".csv")
  # Write latin1 encoded content
  con <- file(tmp, "wb")
  writeBin(charToRaw("col\ncaf\xe9"), con)  # cafe in latin1
  close(con)
  result <- parse_X(tmp)
  expect_true(grepl("caf", result$col))
})

test_that("parse_X: type coercion warnings for floats in integer columns", {
  tmp <- withr::local_tempfile(fileext = ".csv")
  writeLines(c("int_col", "2.5"), tmp)
  expect_message(result <- parse_X(tmp), "parse")
})

test_that("parse_X: handles missing required columns", {
  tmp <- withr::local_tempfile(fileext = ".csv")
  writeLines(c("wrong_col", "value"), tmp)
  expect_error(parse_X(tmp))  # Or expect graceful NA handling
})

test_that("parse_X: handles extra unknown columns", {
  tmp <- withr::local_tempfile(fileext = ".csv")
  writeLines(c("required_col,unknown_col", "value,extra"), tmp)
  result <- parse_X(tmp)  # Should not error
  expect_equal(nrow(result), 1L)
})

test_that("parse_X: handles empty file", {
  tmp <- withr::local_tempfile(fileext = ".csv")
  file.create(tmp)
  result <- parse_X(tmp)
  expect_equal(nrow(result), 0L)  # Or expect specific error
})

test_that("parse_X: handles ambiguous date formats", {
  # 01/02/2024 could be Jan 2 or Feb 1
  tmp <- withr::local_tempfile(fileext = ".csv")
  writeLines(c("date_col", "01/02/2024"), tmp)
  result <- parse_X(tmp)
  # Verify the expected interpretation (e.g., DD/MM/YYYY)
  expect_equal(lubridate::month(result$date_col), 2L)  # February
})
```

| Attack | What it tests | Example |
|--------|---------------|---------|
| Encoding attacks | Non-UTF8 characters | `"Atl\xe9tico Madrid"` |
| BOM attacks | Byte order mark at file start | `\xEF\xBB\xBF` prefix |
| Delimiter attacks | Wrong/mixed delimiters | `;` instead of `,` |
| Quoted field attacks | Embedded commas, quotes, newlines | `"Team, FC"` |
| NA string variants | All common NA representations | `""`, `"NA"`, `"n/a"`, `"-"`, `"NULL"` |
| Numeric format attacks | Locale-specific formats | `"1,000"`, `"1.5e3"`, `"50%"` |
| Whitespace attacks | Leading/trailing whitespace | `"  Arsenal  "` |
| Column order attacks | Columns in different order | Header permutations |
| Missing column attacks | Required column absent | No `col1` column |
| Extra column attacks | Unexpected columns | New `VAR` column added |
| Type coercion attacks | Values that coerce unexpectedly | `"1.5"` -> `1L` (truncation) |
| Empty file attacks | 0 bytes, header only, 1 row | Edge cases |
| Large file attacks | Memory limits | 1M+ rows |
| Date format attacks | Ambiguous dates | `"01/02/2024"` (DD/MM or MM/DD?) |
