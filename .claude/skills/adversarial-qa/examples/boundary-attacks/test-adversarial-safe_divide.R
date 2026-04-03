# Adversarial tests for safe_divide()
# Demonstrates all 7 core attack categories from the adversarial-qa skill
#
# Run: Rscript examples/boundary-attacks/run_tests.R
# Expected: output/test_results.txt (8 PASS, 0 FAIL)

source("safe_divide.R")
library(testthat)

# Category 1: Boundary Attacks
test_that("safe_divide handles boundary values", {
  expect_equal(safe_divide(0, 1), 0)
  expect_equal(safe_divide(1e308, 1), 1e308)
  expect_equal(safe_divide(-1e308, 1), -1e308)
  expect_equal(safe_divide(1, Inf), 0)
  expect_equal(safe_divide(Inf, 1), Inf)
})

# Category 2: NA Attacks
test_that("safe_divide rejects NA inputs", {
  expect_error(safe_divide(1, NA), "must not be 0 or NA")
  expect_error(safe_divide(1, NA_real_), "must not be 0 or NA")
  # NA in x propagates (expected R behavior)
  expect_true(is.na(safe_divide(NA, 1)))
})

# Category 3: Type Attacks
test_that("safe_divide rejects wrong types", {
  expect_error(safe_divide("10", 2), "must be numeric")
  expect_error(safe_divide(1, "2"), "must be numeric")
  expect_error(safe_divide(TRUE, 2), "must be numeric")
  expect_error(safe_divide(1, list(2)), "must be numeric")
})

# Category 4: Structure Attacks
test_that("safe_divide handles vector x, scalar y", {
  expect_equal(safe_divide(c(10, 20, 30), 10), c(1, 2, 3))
  expect_error(safe_divide(1, c(2, 3)), "must be length 1")
  expect_error(safe_divide(1, numeric(0)), "must be length 1")
})

# Category 5: Zero Division
test_that("safe_divide rejects division by zero", {
  expect_error(safe_divide(1, 0), "must not be 0 or NA")
  expect_error(safe_divide(0, 0), "must not be 0 or NA")
})

# Category 6: Idempotency
test_that("safe_divide is idempotent on identity", {
  expect_equal(safe_divide(safe_divide(100, 10), 1), 10)
})

# Category 7: Determinism
test_that("safe_divide is deterministic", {
  result1 <- safe_divide(22, 7)
  result2 <- safe_divide(22, 7)
  expect_identical(result1, result2)
})

# Category 11: Numerical Stability
test_that("safe_divide handles floating-point edge cases", {
  expect_true(all.equal(safe_divide(1, 3) * 3, 1))
  expect_true(all.equal(safe_divide(0.1 + 0.2, 1), 0.3))
})
