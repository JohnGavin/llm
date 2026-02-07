# Advanced Nix/Rix Patterns

## Pattern 1: Using available_dates() for Version Compatibility

**CRITICAL**: The `r_ver` date in rix determines which package VERSIONS you get.

**Testing Version Compatibility:**

```r
# R/dev/nix/verify_date.R
library(rix)

# Your required packages
required_pkgs <- c("targets", "dplyr", "TCGAbiolinks")

# Test if a date works for all packages
test_date <- function(date, pkgs) {
  temp_dir <- tempdir()
  tryCatch({
    rix::rix(
      r_ver = date,
      r_pkgs = pkgs,
      project_path = temp_dir,
      overwrite = TRUE
    )
    # Try to parse the generated nix file
    nix_file <- file.path(temp_dir, "default.nix")
    result <- system2("nix-instantiate", c("--parse", nix_file),
                      stdout = TRUE, stderr = TRUE)
    return(length(attr(result, "status")) == 0)
  }, error = function(e) FALSE)
}

# Find the most recent working date
dates <- available_dates()
for (date in rev(tail(dates, 30))) {  # Check last 30 dates, newest first
  if (test_date(date, required_pkgs)) {
    cat("✓ Working date found:", date, "\n")
    break
  } else {
    cat("✗ Date", date, "missing packages\n")
  }
}
```

## Pattern 2: Project-Specific vs Global Environment

```r
# Global environment for all projects:
# /Users/johngavin/docs_gh/rix.setup/default.nix
# Contains common packages used across projects

# Project-specific environment:
# /Users/johngavin/docs_gh/claude_rix/random_walk/default.nix
# Contains packages specific to random_walk project
# Inherits from global or defines independently
```

## Pattern 3: Two-Tier Cachix Strategy

| Priority | Cache | Contains |
|----------|-------|----------|
| 1st | `rstats-on-nix` | ALL standard R packages (public, pre-built) |
| 2nd | `johngavin` | Project-specific custom packages ONLY |

**⚠️ IMPORTANT: Never push standard R packages to personal cache!**
- dplyr, ggplot2, targets, etc. are ALL in `rstats-on-nix`
- Only push custom packages NOT available in rstats-on-nix
- Pushing standard packages wastes limited Cachix quota

## Pattern 4: Verifying Environment Consistency

```r
# R/setup/verify_environment.R
library(logger)

log_info("Verifying nix environment")

# Check if in nix shell
in_nix <- Sys.getenv("IN_NIX_SHELL") != ""

if (!in_nix) {
  log_warn("NOT in nix shell - reproducibility not guaranteed")
} else {
  log_info("Running in nix shell ✓")
}

# Check R version
expected_r_version <- "4.4.1"  # Update to match your r_ver
actual_r_version <- paste(R.version$major, R.version$minor, sep = ".")

if (actual_r_version == expected_r_version) {
  log_info("R version matches: {actual_r_version}")
} else {
  log_warn("R version mismatch: expected {expected_r_version}, got {actual_r_version}")
}
```
