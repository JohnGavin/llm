# Testing Tidy Evaluation Functions

Patterns for testing functions that use `{{ }}`, `!!`, `.data`, and `...`.

## Testing `{{ }}` (Embrace)

```r
test_that("function supports data masking", {
  result <- my_summary(mtcars, cyl, mpg)
  expect_s3_class(result, "tbl_df")
  expect_true("mean" %in% names(result))
})

test_that("function supports expressions", {
  result <- my_summary(mtcars, cyl, mpg * 2)
  expect_equal(nrow(result), 3L)  # 3 cylinder groups
})
```

## Testing Dynamic Column Names

```r
test_that("dynamic names are correct", {
  result <- my_mean(mtcars, mpg)
  expect_true("mean_mpg" %in% names(result))

  result2 <- my_mean(mtcars, wt)
  expect_true("mean_wt" %in% names(result2))
})
```

## Testing `.data[[]]` (String Column Names)

```r
test_that("string column names work", {
  result <- summarise_col(mtcars, "mpg")
  expect_equal(nrow(result), 1L)
  expect_true("mean" %in% names(result))
})

test_that("missing column gives clear error", {
  expect_error(summarise_col(mtcars, "nonexistent"), "not found")
})
```

## Testing `!!` Injection

```r
test_that("injection works", {
  var <- rlang::sym("cyl")
  result <- mtcars |> dplyr::group_by(!!var) |> dplyr::tally()
  expect_equal(nrow(result), 3L)
})
```

## Testing Error Messages

```r
test_that("missing required arg gives clear error", {
  expect_error(my_plot(mtcars), "is absent")
})

test_that("error points to caller, not internal function", {
  expect_snapshot(my_fun(bad_input), error = TRUE)
  # Snapshot should show the user's call, not internal validate_*()
})
```

## Testing `...` Forwarding

```r
test_that("dots are forwarded correctly", {
  result <- my_group_summary(mtcars, cyl, gear, .value = mpg)
  expect_equal(nrow(result), 8L)  # 3 cyl × ~3 gear combos
})

test_that("unused dots trigger warning", {
  expect_warning(strict_fn(1:5, typo = TRUE))
})
```

## Snapshot Tests for Complex Output

```r
test_that("tidy eval function output is stable", {
  expect_snapshot({
    mtcars |> my_stats(mpg)
  })
})
```
