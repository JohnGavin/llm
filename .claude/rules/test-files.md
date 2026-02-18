# Test File Rules

**Applies to**: `tests/testthat/test-*.R`

## Test-Driven Development (TDD)

Follow RED-GREEN-REFACTOR:

1. **RED**: Write a failing test first
2. **GREEN**: Write minimal code to pass
3. **REFACTOR**: Clean up while tests stay green

## Test Structure: Arrange-Act-Assert

```r
test_that("analyze_extremes returns correct structure", {
  # Arrange - Set up test data
  test_data <- tibble::tibble(
    time = as.POSIXct("2024-01-01") + 1:10,
    wave_height = c(3, 4, 6, 2, 8, 5, 7, 3, 4, 5),
    station_id = "M3"
  )

  # Act - Call the function
  result <- analyze_extremes(test_data, threshold = 5)

  # Assert - Verify expectations
  expect_s3_class(result, "tbl_df")
  expect_named(result, c("time", "wave_height", "exceedance"))
  expect_equal(nrow(result), 3)  # 3 values > 5
})
```

## One Behavior Per Test

```r
# WRONG - Multiple behaviors in one test
test_that("analyze_extremes works", {
  result <- analyze_extremes(data, 5)
  expect_s3_class(result, "tbl_df")
  expect_equal(nrow(result), 3)
  expect_error(analyze_extremes(NULL))  # Different behavior!
})

# CORRECT - Separate tests
test_that("analyze_extremes returns tibble", {
  result <- analyze_extremes(test_data, threshold = 5)
  expect_s3_class(result, "tbl_df")
})

test_that("analyze_extremes filters by threshold", {
  result <- analyze_extremes(test_data, threshold = 5)
  expect_equal(nrow(result), 3)
})

test_that("analyze_extremes errors on NULL input", {
  expect_error(analyze_extremes(NULL), class = "rlang_error")
})
```

## Descriptive Test Names

Test names should describe the behavior being tested:

```r
# WRONG - Vague
test_that("it works", { ... })
test_that("test 1", { ... })

# CORRECT - Descriptive
test_that("analyze_extremes returns empty tibble when no values exceed threshold", { ... })
test_that("query_buoy_data filters by station_id when provided", { ... })
test_that("calculate_metrics handles NA values gracefully", { ... })
```

## Test Fixtures

Use `testthat::test_path()` for test data:

```r
# In tests/testthat/helper.R or within test file
load_test_fixture <- function(name) {
  path <- testthat::test_path("fixtures", paste0(name, ".rds"))
  readRDS(path)
}

test_that("process_buoy_data handles real data structure", {
  buoy_data <- load_test_fixture("buoy_sample")
  result <- process_buoy_data(buoy_data)
  expect_s3_class(result, "tbl_df")
})
```

## Snapshot Testing (PREFERRED FOR COMPLEX OUTPUT)

**Use snapshots liberally** - they capture exact output and make test maintenance easier.

### When to Use Snapshots

| Use Case | Snapshot Function | Example |
|----------|-------------------|---------|
| Complex return values | `expect_snapshot()` | Data frames, lists, summaries |
| Printed output | `expect_snapshot()` | cli messages, formatted tables |
| Error messages | `expect_snapshot_error()` | Defensive programming errors |
| Warning messages | `expect_snapshot_warning()` | Deprecation warnings |
| Plot output | `expect_snapshot_file()` | ggplot2/plotly plots |
| File output | `expect_snapshot_file()` | Generated CSV, JSON |

### Examples

```r
# Complex object structure
test_that("analyze_extremes returns expected structure", {
  result <- analyze_extremes(test_data, threshold = 5)
  expect_snapshot(result)
})

# Error messages (critical for defensive programming)
test_that("analyze_extremes error message is informative", {
  expect_snapshot_error(analyze_extremes(NULL))
  expect_snapshot_error(analyze_extremes(data.frame()))
  expect_snapshot_error(analyze_extremes("not a data frame"))
})

# CLI output
test_that("summary prints correctly", {
  expect_snapshot(print_buoy_summary(test_data))
})

# Multiple related values
test_that("metrics calculation is correct", {
  result <- calculate_metrics(test_data)
  expect_snapshot({
    result$mean
    result$sd
    result$extremes
  })
})
```

### Snapshot Best Practices

1. **Commit snapshot files** - They're in `tests/testthat/_snaps/`
2. **Review diffs carefully** - Snapshots show exact changes
3. **Update intentionally** - Run `testthat::snapshot_accept()` after reviewing
4. **Group related snapshots** - Use compound snapshots with `{}`
5. **Use for error messages** - Ensures defensive programming messages are tested

### Updating Snapshots

```r
# Review all snapshot changes
testthat::snapshot_review()

# Accept all changes (after reviewing!)
testthat::snapshot_accept()
```

## Testing Defensive Code

Every exported function should have tests for:

1. **Valid inputs**: Normal operation
2. **NULL inputs**: Should error with clear message
3. **Empty inputs**: Should handle gracefully
4. **Wrong types**: Should error with type info
5. **Edge cases**: 0, -1, Inf, NaN, single row

```r
describe("analyze_extremes input validation", {
  it("errors on NULL data with informative message", {
    expect_error(
      analyze_extremes(NULL),
      class = "rlang_error"
    )
    expect_error(
      analyze_extremes(NULL),
      regexp = "data.*required|NULL"
    )
  })

  it("errors on wrong type with class info", {
    err <- expect_error(analyze_extremes("not a dataframe"))
    expect_match(conditionMessage(err), "data frame|character")
  })

  it("handles empty data frame", {
    empty_df <- tibble::tibble(time = as.POSIXct(character()), wave_height = numeric())
    result <- analyze_extremes(empty_df, threshold = 5)
    expect_equal(nrow(result), 0)
  })

  it("handles single row", {
    single_row <- tibble::tibble(time = Sys.time(), wave_height = 10, station_id = "M3")
    result <- analyze_extremes(single_row, threshold = 5)
    expect_equal(nrow(result), 1)
  })
})
```

## Coverage Requirements

- **Minimum**: 80% line coverage for Bronze gate
- **Target**: 90% for Silver gate
- **Ideal**: 95% for Gold gate

Check coverage locally:
```r
covr::package_coverage()
covr::report()  # Interactive HTML report
```

## Test Performance

- Tests should complete in < 1 second each
- Use `skip_on_cran()` for slow tests
- Mock external services (database, API calls)

```r
test_that("fetch_buoy_data handles API response", {
  # Mock the API call
  local_mocked_bindings(
    fetch_from_api = function(...) test_fixture("api_response.json")
  )

  result <- fetch_buoy_data("M3")
  expect_s3_class(result, "tbl_df")
})
```
