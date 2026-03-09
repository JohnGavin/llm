# Testing vctrs Classes

Four areas to test: type stability, coercion, casting, and vector operations.

## 1. Construction and Validation

```r
test_that("constructor creates valid objects", {
  pct <- percent(0.5)
  expect_s3_class(pct, "my_percent")
  expect_equal(vec_data(pct), 0.5)
})

test_that("constructor validates input", {
  expect_error(percent(1.5), "between 0 and 1")
  expect_error(percent("a"))
})

test_that("zero-length prototype works", {
  pct <- percent()
  expect_length(pct, 0)
  expect_s3_class(pct, "my_percent")
})

test_that("NA handling works", {
  pct <- percent(NA_real_)
  expect_true(is.na(pct))
  expect_s3_class(pct, "my_percent")
})
```

## 2. Type Stability

```r
test_that("output type is stable regardless of input", {
  # Type should be the same whether input is length 0, 1, or n
  expect_equal(vec_ptype(percent()), vec_ptype(percent(0.5)))
  expect_equal(vec_ptype(percent(0.5)), vec_ptype(percent(c(0.1, 0.2))))
})

test_that("function returns consistent type", {
  expect_equal(
    vec_ptype(my_function(1:3)),
    vec_ptype(my_function(integer()))
  )
})
```

## 3. Coercion (vec_ptype2)

```r
test_that("same-type coercion works", {
  expect_equal(
    vec_ptype_common(percent(0.1), percent(0.2)),
    percent()
  )
})

test_that("percent + double = double", {
  expect_equal(vec_ptype_common(percent(0.5), 1.0), double())
})

test_that("incompatible types error", {
  expect_error(vec_ptype_common(percent(0.5), "a"))
})
```

## 4. Casting (vec_cast)

```r
test_that("round-trip casting works", {
  pct <- percent(0.5)
  # percent → double → percent should round-trip
  expect_equal(
    vec_cast(vec_cast(pct, double()), percent()),
    pct
  )
})

test_that("casting from double works", {
  expect_equal(vec_data(vec_cast(0.5, percent())), 0.5)
})

test_that("lossy cast warns or errors", {
  expect_error(vec_cast(percent(0.5), integer()))
})
```

## 5. Vector Operations

```r
test_that("vec_c combines correctly", {
  p1 <- percent(0.1)
  p2 <- percent(0.2)
  combined <- vec_c(p1, p2)
  expect_s3_class(combined, "my_percent")
  expect_equal(vec_size(combined), 2L)
})

test_that("arithmetic works", {
  p1 <- percent(0.3)
  p2 <- percent(0.2)
  expect_equal(vec_data(p1 + p2), 0.5)
  expect_equal(vec_data(p1 * 2), 0.6)
  expect_error(p1 * p2)  # percent × percent is undefined
})

test_that("comparison works", {
  expect_true(percent(0.5) > percent(0.3))
  expect_equal(sort(percent(c(0.3, 0.1, 0.2))), percent(c(0.1, 0.2, 0.3)))
})
```

## 6. Display

```r
test_that("format produces correct output", {
  expect_equal(format(percent(0.156)), "15.6%")
  expect_equal(format(percent(NA_real_)), NA_character_)
  expect_equal(format(percent(0)), "0.0%")
})

test_that("tibble display works", {
  df <- tibble::tibble(x = percent(c(0.1, 0.2)))
  output <- capture.output(print(df))
  expect_true(any(grepl("pct", output)))  # type_sum shows
})
```
