# profile_step.R — Call 1 of 2
# Purpose: profile a toy slow function and save the profvis object to disk.
# Run with: timeout 60 Rscript profile_step.R
# This mimics the per-call Rscript model (btw-timeouts rule).

library(profvis)

# Toy slow function: builds a cumsum iteratively (avoidable with cumsum() but
# deliberately slow so profvis captures meaningful samples).
slow_cumsum <- function(x) {
  result <- numeric(length(x))
  for (i in seq_along(x)) {
    result[i] <- if (i == 1) x[1] else result[i - 1] + x[i]
  }
  result
}

# Toy matrix operation: row-wise means via a loop (vectorisable but slow).
slow_row_means <- function(mat) {
  vapply(seq_len(nrow(mat)), function(i) mean(mat[i, ]), numeric(1))
}

cat("Running profvis profiling...\n")

p <- profvis({
  set.seed(42)
  # Large enough for profvis to capture samples (>10ms per call)
  x <- rnorm(500000)
  y <- slow_cumsum(x)
  m <- matrix(rnorm(100000), nrow = 1000)
  z <- slow_row_means(m)
  cat("cumsum result length:", length(y), "\n")
  cat("row means result length:", length(z), "\n")
}, interval = 0.01)

out_path <- file.path(getwd(), "profile.rds")
saveRDS(p, out_path)
cat("Saved profvis object to:", out_path, "\n")
cat("Class:", class(p), "\n")
cat("Names:", paste(names(p), collapse = ", "), "\n")
cat("profile_step.R DONE\n")
