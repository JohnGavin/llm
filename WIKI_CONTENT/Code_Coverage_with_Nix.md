# Code Coverage with Nix: Pre-computed Coverage Workflow

This guide explains how to generate and cache code coverage for R packages when using Nix environments, where `covr` encounters compatibility issues.

## The Problem

The `covr::package_coverage()` function fails in Nix environments with:
```
Error: error reading from connection
```

This is a known R/Nix compatibility issue affecting the connection between covr's instrumented code and the coverage collector.

## The Solution: Pre-computed Coverage

Generate coverage **outside of Nix** and cache the results for use in vignettes and CI.

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Local R/RStudio (NOT Nix)                                  │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  source("R/dev/coverage/generate_coverage.R")       │   │
│  │  ├── covr::package_coverage()                       │   │
│  │  ├── Calculate overall % and per-file stats        │   │
│  │  └── saveRDS() → inst/extdata/coverage.rds         │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│  Git Repository                                             │
│  └── inst/extdata/coverage.rds (committed)                 │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│  CI/Nix Environment                                         │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  Vignette (telemetry.qmd)                           │   │
│  │  └── readRDS("inst/extdata/coverage.rds")          │   │
│  │      └── Display cached coverage data              │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

## Implementation Steps

### Step 1: Create the Coverage Generator Script

Create `R/dev/coverage/generate_coverage.R`:

```r
# generate_coverage.R
# Run this script OUTSIDE of Nix to generate code coverage
#
# Usage:
#   1. Open R/RStudio (NOT in Nix shell)
#   2. setwd() to the package directory
#   3. source("R/dev/coverage/generate_coverage.R")

library(covr)

cat("=== Generating Code Coverage ===\n")

# Check we're in the right directory
if (!file.exists("DESCRIPTION")) {
  stop("Please run this script from the package root directory")
}

# Check we're NOT in Nix
if (Sys.getenv("IN_NIX_SHELL") != "") {
  warning("You appear to be in a Nix shell. covr may fail.")
}

# Generate coverage
coverage <- package_coverage()

# Calculate summary statistics
overall_pct <- percent_coverage(coverage)
cat(sprintf("Overall coverage: %.1f%%\n", overall_pct))

# Get file-level summary
file_coverage <- tally_coverage(coverage, by = "file")
file_summary <- data.frame(
  filename = basename(file_coverage$filename),
  total_lines = file_coverage$relevant,
  covered_lines = file_coverage$covered,
  coverage_pct = round(file_coverage$coverage, 1)
)

# Prepare data for saving
coverage_data <- list(
  overall_pct = overall_pct,
  file_summary = file_summary,
  generated_at = Sys.time(),
  r_version = R.version.string,
  covr_version = as.character(packageVersion("covr"))
)

# Save to inst/extdata
output_path <- "inst/extdata/coverage.rds"
dir.create(dirname(output_path), recursive = TRUE, showWarnings = FALSE)
saveRDS(coverage_data, output_path)

cat("\nCoverage saved to:", output_path, "\n")
```

### Step 2: Update Vignette to Load Cached Coverage

In your telemetry or coverage vignette:

```r
# Try to load pre-computed coverage from cached file
cov_data <- tryCatch({
  cached_path <- system.file("extdata", "coverage.rds", package = "yourpackage")
  if (cached_path == "") {
    cached_path <- "../../inst/extdata/coverage.rds"  # Relative fallback
  }
  if (file.exists(cached_path)) {
    readRDS(cached_path)
  } else {
    NULL
  }
}, error = function(e) NULL)

if (!is.null(cov_data)) {
  cat(sprintf("Overall Test Coverage: %.1f%%\n", cov_data$overall_pct))
  cat(sprintf("Generated: %s\n", format(cov_data$generated_at)))
} else {
  cat("Coverage data not found. Run R/dev/coverage/generate_coverage.R\n")
}
```

### Step 3: Generate and Commit Coverage

```bash
# 1. Open R/RStudio (NOT in Nix shell)
# 2. Navigate to package directory
setwd("/path/to/your/package")

# 3. Run the coverage script
source("R/dev/coverage/generate_coverage.R")

# 4. Commit the cached coverage
git add inst/extdata/coverage.rds
git commit -m "UPDATE: Pre-computed code coverage"
git push
```

## Data Structure

The cached `coverage.rds` contains:

| Field | Type | Description |
|-------|------|-------------|
| `overall_pct` | numeric | Overall coverage percentage |
| `file_summary` | data.frame | Per-file coverage breakdown |
| `generated_at` | POSIXct | Timestamp of generation |
| `r_version` | character | R version used |
| `covr_version` | character | covr package version |

### file_summary columns:
- `filename`: Base filename
- `total_lines`: Total relevant lines
- `covered_lines`: Lines covered by tests
- `coverage_pct`: Coverage percentage

## When to Regenerate

Regenerate coverage when:
- Adding new functions or files
- Adding or modifying tests
- Before major releases
- When coverage metrics seem stale

## Best Practices

1. **Commit coverage.rds to git** - Ensures CI can display coverage
2. **Include generation timestamp** - Shows how fresh the data is
3. **Document the process** - Add comments in vignette explaining the approach
4. **Consider automation** - Could add a GitHub Action that runs on a non-Nix runner

## Alternative Approaches

### GitHub Actions with Standard R

Create a separate workflow using `r-lib/actions/setup-r` instead of Nix:

```yaml
name: Code Coverage

on:
  push:
    paths:
      - 'R/**'
      - 'tests/**'

jobs:
  coverage:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: r-lib/actions/setup-r@v2
      - uses: r-lib/actions/setup-r-dependencies@v2

      - name: Generate coverage
        run: |
          Rscript -e "
            coverage <- covr::package_coverage()
            covr::to_cobertura(coverage, 'coverage.xml')
          "

      - name: Upload to Codecov
        uses: codecov/codecov-action@v3
```

### Codecov Integration

For public repos, consider using [Codecov](https://codecov.io) which provides:
- Coverage badges
- PR coverage diffs
- Historical trends

## Troubleshooting

### "Error reading from connection"
- **Cause**: Running in Nix environment
- **Fix**: Run in standard R/RStudio outside Nix

### Coverage seems incomplete
- **Cause**: Tests not loading all code paths
- **Fix**: Review file_summary for low-coverage files

### Old coverage data displayed
- **Cause**: Stale coverage.rds file
- **Fix**: Regenerate with `source("R/dev/coverage/generate_coverage.R")`

## Related Documentation

- [covr package documentation](https://covr.r-lib.org/)
- [Nix Environment Guide](./Nix_Environment_Guide.md)
- [Workflows and Best Practices](./Workflows_and_Best_Practices.md)
