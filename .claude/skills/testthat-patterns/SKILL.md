---
name: testthat-patterns
description: >
  Best practices for writing R package tests using testthat version 3+. Use when
  writing, organizing, or improving tests for R packages. Covers test structure,
  expectations, fixtures, snapshots, mocking, and modern testthat 3 patterns
  including self-sufficient tests, proper cleanup with withr, and snapshot testing.
metadata:
  author: Garrick Aden-Buie (@gadenbuie)
  adapted-by: johngavin
  version: "1.0"
  source: posit-dev/skills (MIT)
---

# Testing R Packages with testthat

Modern best practices for R package testing using testthat 3+.

## Initial Setup

```r
usethis::use_testthat(3)
```

Creates `tests/testthat/`, adds testthat to DESCRIPTION Suggests with `Config/testthat/edition: 3`.

## File Organization

**Mirror package structure:**
- Code in `R/foofy.R` -> tests in `tests/testthat/test-foofy.R`
- Use `usethis::use_r("foofy")` and `usethis::use_test("foofy")` to create paired files

**Special files:**
- `helper-*.R` - Helper functions and custom expectations, sourced before tests
- `setup-*.R` - Run during `R CMD check` only, not during `load_all()`
- `fixtures/` - Static test data files accessed via `test_path()`

## Test Structure

### Standard Syntax

```r
test_that("descriptive behavior", {
  result <- my_function(input)
  expect_equal(result, expected_value)
})
```

### BDD Syntax (describe/it)

```r
describe("matrix()", {
  it("can be multiplied by a scalar", {
    m1 <- matrix(1:4, 2, 2)
    m2 <- m1 * 2
    expect_equal(matrix(1:4 * 2, 2, 2), m2)
  })

  it("can be transposed", {
    m <- matrix(1:4, 2, 2)
    expect_equal(t(m), matrix(c(1, 3, 2, 4), 2, 2))
  })
})
```

Use `describe()` to verify you implement the right things, use `test_that()` to ensure you do things right.

See [references/bdd.md](references/bdd.md) for comprehensive BDD patterns.

## Core Expectations

### Equality
```r
expect_equal(10, 10 + 1e-7)      # Allows numeric tolerance
expect_identical(10L, 10L)       # Exact match required
expect_all_equal(x, expected)    # Every element matches (v3.3.0+)
```

### Errors, Warnings, Messages
```r
expect_error(1 / "a")
expect_error(bad_call(), class = "specific_error_class")
expect_no_error(valid_call())
expect_warning(deprecated_func())
expect_no_warning(safe_func())
expect_message(informative_func())
```

### Structure and Type
```r
expect_length(vector, 10)
expect_type(obj, "list")
expect_s3_class(model, "lm")
expect_shape(matrix, c(10, 5))         # v3.3.0+
```

### Sets and Collections
```r
expect_setequal(x, y)           # Same elements, any order
expect_contains(fruits, "apple") # Subset check (v3.2.0+)
expect_in("apple", fruits)       # Element in set (v3.2.0+)
```

## Design Principles

### 1. Self-Sufficient Tests

Each test contains all setup, execution, and teardown:

```r
# Good: self-contained
test_that("foofy() works", {
  data <- data.frame(x = 1:3, y = letters[1:3])
  result <- foofy(data)
  expect_equal(result$x, 1:3)
})
```

### 2. Self-Contained Tests (Cleanup with withr)

```r
test_that("function respects options", {
  withr::local_options(my_option = "test_value")
  withr::local_envvar(MY_VAR = "test")
  withr::local_package("jsonlite")
  result <- my_function()
  expect_equal(result$setting, "test_value")
})
```

**Common withr functions:**
- `local_options()` - Temporarily set options
- `local_envvar()` - Temporarily set environment variables
- `local_tempfile()` - Create temp file with automatic cleanup
- `local_tempdir()` - Create temp directory with automatic cleanup
- `local_package()` - Temporarily attach package

### 3. Repetition is Acceptable

Repeat setup code in tests rather than factoring it out. Test clarity > DRY.

## Snapshot Testing

For complex output difficult to verify programmatically:

```r
test_that("error message is helpful", {
  expect_snapshot(
    error = TRUE,
    validate_input(NULL)
  )
})
```

Snapshots stored in `tests/testthat/_snaps/`.

**Workflow:**
```r
devtools::test()                    # Creates new snapshots
testthat::snapshot_review('name')   # Review changes
testthat::snapshot_accept('name')   # Accept changes
```

See [references/snapshots.md](references/snapshots.md) for transforms, variants, and advanced patterns.

## Test Fixtures

**Constructor functions** - Create data on-demand:
```r
new_sample_data <- function(n = 10) {
  data.frame(id = seq_len(n), value = rnorm(n))
}
```

**Local functions with cleanup** - Handle side effects:
```r
local_temp_csv <- function(data, env = parent.frame()) {
  path <- withr::local_tempfile(fileext = ".csv", .local_envir = env)
  write.csv(data, path, row.names = FALSE)
  path
}
```

**Static fixture files** - Store in `fixtures/`:
```r
data <- readRDS(test_path("fixtures", "sample_data.rds"))
```

See [references/fixtures.md](references/fixtures.md) for detailed fixture patterns.

## Mocking

Replace external dependencies with `local_mocked_bindings()`:

```r
test_that("function works with mocked dependency", {
  local_mocked_bindings(
    external_api = function(...) list(status = "success", data = "mocked")
  )
  result <- my_function_that_calls_api()
  expect_equal(result$status, "success")
})
```

See [references/mocking.md](references/mocking.md) for comprehensive mocking strategies.

## File System Discipline

```r
# Good: write to temp directory
output <- withr::local_tempfile(fileext = ".csv")
write.csv(data, output)

# Good: access fixtures with test_path()
data <- readRDS(test_path("fixtures", "data.rds"))
```

## testthat 3 Modernizations

**Deprecated -> Modern:**
- `context()` -> Remove (duplicates filename)
- `expect_equivalent()` -> `expect_equal(ignore_attr = TRUE)`
- `with_mock()` -> `local_mocked_bindings()`
- `is_null()` -> `expect_null()`

**Prefer snapshot for errors/warnings** (posit convention):
```r
# Prefer this (captures full message text)
expect_snapshot(error = TRUE, bad_call())
# Over this (only checks class)
expect_error(bad_call(), class = "my_error")
```

## Advanced Topics

- **[references/bdd.md](references/bdd.md)** - BDD-style testing with describe/it
- **[references/snapshots.md](references/snapshots.md)** - Snapshot testing, transforms, variants
- **[references/mocking.md](references/mocking.md)** - Mocking strategies, webfakes, httptest2
- **[references/fixtures.md](references/fixtures.md)** - Fixture patterns, database fixtures
- **[references/advanced.md](references/advanced.md)** - Skipping, secrets, CRAN requirements, parallel testing

## Related Skills

- **test-driven-development** - TDD workflow (RED-GREEN-REFACTOR)
- **adversarial-qa** - Attack-based testing patterns
- **quality-gates** - Coverage requirements and quality scoring
