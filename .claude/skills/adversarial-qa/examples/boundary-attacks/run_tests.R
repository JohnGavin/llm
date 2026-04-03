#' Run adversarial tests and save results
#' Usage: Rscript examples/boundary-attacks/run_tests.R
#' Expected output: output/test_results.txt

cat("=== Adversarial QA: Boundary Attacks Example ===\n\n")

# Run tests
results <- testthat::test_file(
  "test-adversarial-safe_divide.R",
  reporter = testthat::SummaryReporter$new()
)

# Summary
df <- as.data.frame(results)
n_pass <- sum(df$passed)
n_fail <- sum(df$failed)
n_warn <- sum(df$warning)
n_skip <- sum(df$skipped)

summary_line <- sprintf("[ FAIL %d | WARN %d | SKIP %d | PASS %d ]", n_fail, n_warn, n_skip, n_pass)
cat("\n", summary_line, "\n")

# Save
out_dir <- "output"
if (!dir.exists(out_dir)) dir.create(out_dir)
writeLines(summary_line, file.path(out_dir, "test_results.txt"))
cat("Saved to:", file.path(out_dir, "test_results.txt"), "\n")
