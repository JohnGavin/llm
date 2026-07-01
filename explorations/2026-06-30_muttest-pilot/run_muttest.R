# run_muttest.R — Run mutation testing against classify_score()
#
# Run from the pilot directory:
#   nix-shell default.nix --run "timeout 300 Rscript run_muttest.R 2>&1"
#
# muttest plan:
#   - comparison_operators(): <, >, <=, >= swaps
#   - numeric_literals(): increment/decrement the threshold constants (50, 70, 85)
#   - negate_condition(): negate if-blocks
#
# Expected weak-suite result:
#   Many mutants SURVIVE because the test only covers score 55 and 60 ("pass" band).
#   Mutants in the fail/merit/distinction bands are invisible to these tests.

cat("=== muttest pilot: classify_score() ===\n")
cat("Source:  R/classify.R\n")
cat("Tests:   tests/testthat/test-classify.R\n")
cat("Mutators: comparison_operators, numeric_literals, negate_condition\n\n")

library(muttest)

plan <- muttest_plan(
  mutators = c(
    comparison_operators(),
    numeric_literals(),
    negate_condition()
  )
)

result <- muttest(plan)

cat("\n=== Summary ===\n")
print(result)
