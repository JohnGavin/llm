# Test-Driven Development for R Packages

## Description

Write the test first. Watch it fail. Write minimal code to pass. This skill enforces the RED-GREEN-REFACTOR cycle for R package development using testthat.

## Purpose

Use this skill when:
- Implementing new functions
- Fixing bugs (write test that reproduces bug first)
- Adding features to existing functions
- Refactoring (tests protect against regressions)

## The Iron Law

```
NO PRODUCTION CODE WITHOUT A FAILING TEST FIRST
```

Wrote code before the test? **Delete it.** Start over.

## The RED-GREEN-REFACTOR Cycle

```
┌─────────────────────────────────────────────────────────────┐
│  RED: Write a failing test                                  │
│       └─→ devtools::test_active_file()                      │
│       └─→ VERIFY: Test fails for the RIGHT reason           │
│                                                             │
│  GREEN: Write MINIMAL code to pass                          │
│       └─→ Just enough to make the test pass                 │
│       └─→ devtools::test_active_file()                      │
│       └─→ VERIFY: Test passes                               │
│                                                             │
│  REFACTOR: Clean up (tests still pass)                      │
│       └─→ Improve code quality                              │
│       └─→ devtools::test()                                  │
│       └─→ VERIFY: All tests still pass                      │
│                                                             │
│  COMMIT: gert::git_commit()                                 │
└─────────────────────────────────────────────────────────────┘
```

## R Package TDD Workflow

### Step 1: Create Test File First
```r
# Create test file for new function
usethis::use_test("my_new_function")
# Creates: tests/testthat/test-my_new_function.R
```

### Step 2: Write Failing Test (RED)
```r
# In tests/testthat/test-my_new_function.R
test_that("my_new_function returns expected output", {


# Arrange
input <- c(1, 2, 3)

# Act
result <- my_new_function(input)

# Assert
expect_equal(result, 6)
})
```

### Step 3: Run Test - MUST FAIL
```r
devtools::test_active_file()
# Expected output: Error: could not find function "my_new_function"
# OR: Test failed: result != expected

# ✅ GOOD: Test fails because function doesn't exist
# ❌ BAD: Test passes (you wrote code first - DELETE IT)
```

### Step 4: Write MINIMAL Code (GREEN)
```r
# In R/my_new_function.R
usethis::use_r("my_new_function")

#' Sum values
#' @param x Numeric vector
#' @return Sum of x
#' @export
my_new_function <- function(x) {
  sum(x)  # MINIMAL implementation
}
```

### Step 5: Run Test - MUST PASS
```r
devtools::load_all()
devtools::test_active_file()
# Expected: "[ FAIL 0 | WARN 0 | SKIP 0 | PASS 1 ]"
```

### Step 6: Refactor (Optional)
```r
# Improve code quality, add edge case handling
my_new_function <- function(x) {
  if (!is.numeric(x)) {
    cli::cli_abort("{.arg x} must be numeric, not {.cls {class(x)}}")
}
  sum(x, na.rm = TRUE)
}

# Run ALL tests to check for regressions
devtools::test()
```

### Step 7: Commit
```r
gert::git_add(c("R/my_new_function.R", "tests/testthat/test-my_new_function.R"))
gert::git_commit("Add my_new_function with tests")
```

## Bug Fix TDD Pattern

**ALWAYS reproduce the bug in a test first:**

```r
# Step 1: Write test that exposes the bug
test_that("process_data handles NA values correctly", {
  # This was failing in issue #123
  input <- c(1, NA, 3)
  result <- process_data(input)
  expect_equal(result, 4)  # Should sum non-NA values
})

# Step 2: Run test - MUST FAIL (reproduces bug)
devtools::test_active_file()
# Fails: result is NA, not 4

# Step 3: Fix the bug
process_data <- function(x) {
  sum(x, na.rm = TRUE)  # Add na.rm = TRUE
}

# Step 4: Run test - MUST PASS
devtools::test_active_file()
# Passes: bug is fixed AND we have regression protection
```

## testthat Best Practices

### Test Structure: Arrange-Act-Assert
```r
test_that("function does something specific", {
  # Arrange: Set up test data
  input <- create_test_input()

  # Act: Call the function
  result <- my_function(input)

  # Assert: Check expectations
  expect_equal(result$value, expected_value)
  expect_s3_class(result, "my_class
)
})
```

### Use Fixtures for Complex Data
```r
# tests/testthat/fixtures/sample_data.rds
# Create once:
saveRDS(complex_test_data, testthat::test_path("fixtures", "sample_data.rds"))

# Use in tests:
test_that("function handles complex data", {
  data <- readRDS(testthat::test_path("fixtures", "sample_data.rds"))
  result <- my_function(data)
  expect_snapshot(result)
})
```

### Use withr for Temporary State
```r
test_that("function respects options", {
  withr::local_options(my_option = TRUE)
  result <- my_function()
  expect_true(result$used_option)
})

test_that("function writes to temp file", {
  temp_file <- withr::local_tempfile()
  my_write_function(data, temp_file)
  expect_true(file.exists(temp_file))
})
```

### Snapshot Tests for Complex Output
```r
test_that("summary output is correct", {
  result <- summarize_data(test_data)
  expect_snapshot(result)
})

# Update snapshots when output intentionally changes:
# testthat::snapshot_accept("test-summary")
```

## MANDATORY: Snapshot Testing with Real Data

**As soon as a project generates real data, snapshot tests MUST be added.**

This requirement exists because:
1. Mock data often doesn't capture edge cases (e.g., mixed types in JSON)
2. Real data evolves - snapshots catch regressions
3. The telemetry.qmd failure (2026-01-20) was caused by untested real data patterns

### When to Add Real Data Snapshots

| Trigger | Action Required |
|---------|-----------------|
| First API response received | Save as fixture, add snapshot test |
| First JSON data cached | Add `expect_snapshot()` for parsing |
| First database query works | Snapshot the result structure |
| CI generates artifacts | Test artifact parsing with snapshots |

### Required Pattern: Real Data Fixtures

```r
# Step 1: Save real data as fixture (ONCE, when first available)
# Run interactively:
real_data <- fetch_actual_data()
saveRDS(real_data, testthat::test_path("fixtures", "real_api_response.rds"))

# Step 2: Create snapshot test
test_that("parse_data handles real API response structure", {
  # Load real data fixture
  real_data <- readRDS(testthat::test_path("fixtures", "real_api_response.rds"))

  # Parse it
  result <- parse_data(real_data)

  # Snapshot the structure (catches type changes, new fields, etc.)
  expect_snapshot(str(result))
  expect_snapshot(sapply(result, class))
})
```

### Example: ccusage JSON Parsing (Lesson Learned)

The `modelsUsed` field had three types in real data:
- String: `"claude-opus-4-5-20251101"`
- Array: `["claude-haiku", "claude-opus"]`
- Empty: `[]`

**A snapshot test would have caught this:**
```r
test_that("parse_ccusage_json handles real data types", {
  json_data <- jsonlite::fromJSON(
    testthat::test_path("fixtures", "ccusage_daily_real.json")
  )

  result <- parse_ccusage_json(json_data)

  # Snapshot column types - catches character vs list mismatch
  expect_snapshot(sapply(result, class))

  # Snapshot a sample of modelsUsed values
  expect_snapshot(head(result$modelsUsed, 5))
})
```

### Fixture Update Policy

```r
# When real data format changes intentionally:
# 1. Update the fixture
saveRDS(new_real_data, testthat::test_path("fixtures", "real_data.rds"))

# 2. Review and accept new snapshots
testthat::snapshot_accept("test-parse_data")

# 3. Commit both fixture and snapshot changes together
gert::git_add(c(
 "tests/testthat/fixtures/real_data.rds",
  "tests/testthat/_snaps/test-parse_data.md"
))
```

### CI Integration

```yaml
# In .github/workflows/test.yaml
- name: Run tests with snapshots
  run: |
    Rscript -e "testthat::test_local(reporter = 'check')"

- name: Fail if snapshots differ
  run: |
    # Snapshots should be committed - differences indicate regression
    git diff --exit-code tests/testthat/_snaps/
```

## Common TDD Violations (DELETE and Restart)

| Violation | Why It's Wrong | Fix |
|-----------|---------------|-----|
| Wrote function first | Don't know if test tests the right thing | Delete function, write test first |
| Test passes immediately | Either test is wrong or code existed | Delete both, start over |
| Skipped RED phase | Can't verify test catches failures | Run test, watch it fail |
| Wrote multiple functions | Too much code without verification | One function, one test cycle |
| "I'll add tests later" | You won't, and bugs will ship | Stop. Write test now. |

## Integration with 9-Step Workflow

TDD fits into **Step 3: Make Changes**:

```
Step 3a: Write failing test
Step 3b: Run test, verify RED
Step 3c: Write minimal code
Step 3d: Run test, verify GREEN
Step 3e: Refactor if needed
Step 3f: Run all tests
Step 3g: Commit (include test file!)
```

## Tidyverse Alignment

From [tidyverse design principles](https://design.tidyverse.org/):
- **Composable**: Tests verify small, composable units
- **Consistent**: Same testing patterns across all functions
- **Human-centered**: Tests document expected behavior

From [R Packages book](https://r-pkgs.org/testing-basics.html):
> "Tests are a way to encode your knowledge about how the code should work"

## Testing Anti-Patterns

### ❌ Testing Implementation, Not Behavior
```r
# BAD: Tests internal implementation
test_that("function uses dplyr", {
  expect_true("dplyr" %in% loadedNamespaces())
})

# GOOD: Tests observable behavior
test_that("function returns summarized data", {
  result <- summarize_data(input)
  expect_equal(nrow(result), 1)
})
```

### ❌ Overly Specific Tests
```r
# BAD: Brittle test
test_that("error message is exact", {
  expect_error(fn(), "Error at line 42: unexpected NULL")
})

# GOOD: Flexible test
test_that("function errors on NULL input", {
  expect_error(fn(NULL), class = "my_null_error")
})
```

### ❌ Testing Too Much at Once
```r
# BAD: Tests multiple behaviors
test_that("function works", {
  expect_equal(fn(1), 1)
  expect_error(fn(NULL))
  expect_warning(fn(-1))
  expect_s3_class(fn(list()), "result")
})

# GOOD: One behavior per test
test_that("function returns input for positive numbers", {...})
test_that("function errors on NULL", {...})
test_that("function warns on negative numbers", {...})
```
