# pkgctx Advanced: CI Workflows, Version Compatibility, Output Schema

## CI Integration

### Workflow 1: Auto-Update Package Context

```yaml
# .github/workflows/update-pkg-context.yaml
name: Update Package Context

on:
  push:
    branches: [main]
    paths:
      - 'DESCRIPTION'
      - 'R/**'
      - 'NAMESPACE'
  workflow_dispatch:

permissions:
  contents: write

jobs:
  update-context:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: DeterminateSystems/nix-installer-action@main

      - uses: DeterminateSystems/magic-nix-cache-action@main

      - name: Generate package context
        run: |
          mkdir -p .claude/context
          nix run github:b-rodrigues/pkgctx -- r . --compact > package.ctx.yaml

      - name: Commit updated context
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add package.ctx.yaml .claude/context/
          git diff --staged --quiet || git commit -m "Update package API context [skip ci]"
          git push
```

### Workflow 2: API Drift Detection (Warning Only)

```yaml
# .github/workflows/api-drift-check.yaml
name: Check API Drift

on:
  pull_request:
    paths:
      - 'R/**'
      - 'NAMESPACE'
      - 'DESCRIPTION'

jobs:
  check-drift:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: DeterminateSystems/nix-installer-action@main

      - uses: DeterminateSystems/magic-nix-cache-action@main

      - name: Generate current context
        run: |
          nix run github:b-rodrigues/pkgctx -- r . --compact > current.ctx.yaml

      - name: Check for API drift
        run: |
          if [ -f package.ctx.yaml ]; then
            if ! diff -q package.ctx.yaml current.ctx.yaml > /dev/null 2>&1; then
              echo "::warning::API has changed! Review changes below:"
              echo "--- Existing API vs Current API ---"
              diff package.ctx.yaml current.ctx.yaml || true
              echo ""
              echo "If intentional, the context will be auto-updated on merge."
            else
              echo "No API drift detected."
            fi
          else
            echo "::notice::No existing package.ctx.yaml found. Will be created on merge."
          fi
```

### Workflow 3: Dependency Context Update (Scheduled)

```yaml
# .github/workflows/update-dep-context.yaml
name: Update Dependency Context

on:
  schedule:
    - cron: '0 3 * * 0'  # Weekly on Sunday at 3am
  workflow_dispatch:

permissions:
  contents: write

jobs:
  update-deps:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: DeterminateSystems/nix-installer-action@main

      - name: Generate context for core dependencies
        run: |
          mkdir -p .claude/context

          # Core packages (adjust list per project)
          for pkg in targets dplyr tidyr purrr gert gh usethis devtools; do
            echo "Generating context for $pkg..."
            nix run github:b-rodrigues/pkgctx -- r "$pkg" --compact > ".claude/context/${pkg}.ctx.yaml" || true
          done

      - name: Commit updated context
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add .claude/context/
          git diff --staged --quiet || git commit -m "Weekly update: dependency API context [skip ci]"
          git push
```

## Version Compatibility with rix

### The Version Availability Problem

Using `rix::available_dates()` returns snapshot dates from rstats-on-nix, but:
- **Newer is not better** - Latest dates may have packages still building
- **Version pinning** - A package may exist but not at the version you need
- **Stability** - Older, well-tested snapshots are more reliable

### Finding Compatible Dates

```r
library(rix)

# List all available snapshot dates
dates <- available_dates()
cat("Total dates:", length(dates), "\n")
cat("Range:", min(dates), "to", max(dates), "\n")

# Strategy: Start with a date ~2-4 weeks old for stability
stable_date <- dates[length(dates) - 14]  # 2 weeks before latest
cat("Recommended stable date:", stable_date, "\n")
```

### Testing Version Compatibility

```r
# R/dev/nix/verify_versions.R
library(rix)

# Target packages with specific version requirements
required_pkgs <- c(
  "targets",      # Need >= 1.0.0

  "dplyr",        # Need >= 1.1.0
  "TCGAbiolinks"  # Bioconductor, version varies
)

# Test different dates
test_dates <- c("2026-01-12", "2025-12-15", "2025-11-01")

for (date in test_dates) {
  cat("\n=== Testing date:", date, "===\n")

  # Generate temp nix expression
  temp_nix <- tempfile(fileext = ".nix")
  rix::rix(
    r_ver = date,
    r_pkgs = required_pkgs,
    project_path = dirname(temp_nix),
    overwrite = TRUE
  )

  # Try to evaluate (checks if packages exist for date)
  result <- system2("nix-instantiate",
                    c("--parse", temp_nix),
                    stdout = TRUE, stderr = TRUE)

  if (length(attr(result, "status")) == 0) {
    cat("  Date", date, "is VALID for these packages\n")
  } else {
    cat("  Date", date, "FAILED - package not available\n")
  }
}
```

### Best Practices for Date Selection

1. **Start conservative** - Use dates 2-4 weeks before latest
2. **Test locally** - Build the nix environment before committing
3. **Document the date** - Include comment explaining why date was chosen
4. **Don't chase latest** - Only update dates when you need new features

```r
# default.R
library(rix)

# Date chosen: 2026-01-12
# Rationale: All required packages (targets, dplyr, TCGAbiolinks)
# confirmed available and working together. More recent dates
# (2026-01-15+) have TCGAbiolinks still building.
rix::rix(
  r_ver = "2026-01-12",
  r_pkgs = c("targets", "dplyr", "TCGAbiolinks"),
  ...
)
```

## Output Schema (v1.1)

### Context Header

```yaml
kind: context_header
llm_instructions: >-
  This is an LLM-optimized API specification for the R package 'dplyr'.
  Use these function signatures and descriptions to understand available
  operations. Arguments marked with defaults show their default values.
```

### Package Metadata

```yaml
kind: package
schema_version: '1.1'
name: dplyr
version: 1.1.4
language: R
description: A Grammar of Data Manipulation
license: MIT
```

### Function Documentation

```yaml
kind: function
name: filter
exported: true
signature: filter(.data, ..., .by = NULL, .preserve = FALSE)
purpose: Keep rows that match a condition
arguments:
  .data: A data frame, tibble, or lazy data frame
  ...: Expressions that return logical vectors
  .by: Optionally, column(s) to group by for just this operation
  .preserve: Relevant for grouped data frames only
returns: An object of the same type as .data
```

### Python Class (with --emit-classes)

```yaml
kind: class
name: DataFrame
methods:
  __init__: Create a new DataFrame
  head: Return first n rows
  filter: Filter rows based on column values
```
