# Intentionally WEAK test suite for classify_score().
#
# DESIGN: Only the mid-range "pass" band [50, 70) is covered.
# Mutations that shift boundary constants (50, 70, 85) or negate/swap
# the < comparisons should SURVIVE — these tests cannot detect them.
#
# NOTE: Do NOT source R/classify.R here. muttest loads and mutates the
# source file itself before each test run; an explicit source() call
# would reload the original (unmutated) version, hiding all mutations.
#
# Expected surviving mutants (muttest should flag these):
#   - < 50  ->  <= 50  (boundary shift: fail/pass — score 50 still "pass")
#   - < 50  ->  >  50  (operator swap — score 60 still in pass band)
#   - < 70  ->  <= 70  (boundary shift: pass/merit)
#   - < 85  ->  <= 85  (boundary shift: merit/distinction)
#   - numeric_decrement on 50: 50 -> 49 (score 55 still returns "pass")
#   - negate_condition on < 50 block (for score 60 the fail branch is not taken)
#
# Expected killed mutants:
#   - < 70  ->  > 70  (score 60 would return "fail" -> kills the test)
#   - < 70  ->  !=    (score 60 -> wrong path -> kills the test)
#   - numeric_decrement on 70: 69 (score 60 now < 69 -> "pass" still, survives)

library(testthat)

test_that("classify_score returns pass for mid-range scores", {
  expect_equal(classify_score(60), "pass")
  expect_equal(classify_score(55), "pass")
})
