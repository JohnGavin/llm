# Testing Patterns for Missing Data

Comprehensive test patterns for NA handling, including type tests, string variant tests, property-based testing, and fuzz testing.

## Comprehensive NA Tests

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

## NA String Variant Tests

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

## Property-Based Testing

Use `hedgehog` to generate arbitrary vectors with random NA positions:

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

## Reproducible Fuzz Testing

```r
test_that("function handles random NA patterns", {
  withr::local_seed(42)
  for (i in seq_len(100)) {
    x <- sample(c(1:5, NA_integer_), size = 20, replace = TRUE)
    expect_no_error(my_func(x))
  }
})
```

## Systematic NA Position Tests

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

## Key Test Dimensions

1. NA type (integer, real, character, complex, Date)
2. NA position (first, last, middle, all, none)
3. NA density (0%, 50%, 100%)
4. Mixed types with NA (after coercion)
