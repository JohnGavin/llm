# LLM Package Context with pkgctx

## Description

This skill covers generating structured, compact API specifications from R and Python packages for use in LLMs. The `pkgctx` tool minimizes token usage (~67% reduction) while maximizing useful context about function signatures, arguments, and documentation.

## Purpose

Use this skill when:
- Providing Claude/GPT with package API context
- Documenting project dependencies for LLM consumption
- Detecting API drift/breaking changes in CI
- Creating reproducible package documentation
- Reducing token usage for package context in prompts

## Key Concepts

### What pkgctx Does

`pkgctx` extracts from packages:
- Function signatures and exported APIs
- Argument names and descriptions
- Brief purpose summaries
- Class definitions (Python)

**Output format:** YAML or JSON with `kind` field discriminators:
- `context_header` - LLM instructions
- `package` - Package metadata
- `function` - Function documentation
- `class` - Class definitions (Python)

### Token Efficiency

| Mode | Reduction | Use Case |
|------|-----------|----------|
| Default | Baseline | Full documentation |
| `--compact` | ~67% | Most LLM contexts |
| `--compact --hoist-common-args` | ~75% | Packages with shared args |

## Running pkgctx (No Installation)

**Requires only Nix installed.** Run directly from GitHub:

```bash
# Basic syntax
nix run github:b-rodrigues/pkgctx -- <language> <source> [options] > output.ctx.yaml
```

### R Package Sources

```bash
# CRAN package
nix run github:b-rodrigues/pkgctx -- r dplyr --compact > dplyr.ctx.yaml

# Bioconductor package
nix run github:b-rodrigues/pkgctx -- r bioc:TCGAbiolinks --compact > tcgabiolinks.ctx.yaml

# GitHub package
nix run github:b-rodrigues/pkgctx -- r github:ropensci/rix --compact > rix.ctx.yaml

# Local package (current directory)
nix run github:b-rodrigues/pkgctx -- r . --compact > mypackage.ctx.yaml

# Local package (specific path)
nix run github:b-rodrigues/pkgctx -- r ./path/to/package --compact > pkg.ctx.yaml
```

### Python Package Sources

```bash
# PyPI package
nix run github:b-rodrigues/pkgctx -- python pandas --compact > pandas.ctx.yaml

# GitHub Python package
nix run github:b-rodrigues/pkgctx -- python github:psf/requests --compact > requests.ctx.yaml

# Local Python package
nix run github:b-rodrigues/pkgctx -- python ./mypackage --compact > mypackage.ctx.yaml
```

### Command Line Options

| Option | Description |
|--------|-------------|
| `--format yaml\|json` | Output format (default: YAML) |
| `--compact` | Reduce output by ~67% |
| `--hoist-common-args` | Extract shared arguments to package level |
| `--include-internal` | Include non-exported functions |
| `--emit-classes` | Add class specs for Python |
| `--no-header` | Remove LLM instruction header |

### Recommended Flags for LLM Use

```bash
# Maximum compression for LLM context
nix run github:b-rodrigues/pkgctx -- r targets --compact --hoist-common-args > targets.ctx.yaml

# Python with class information
nix run github:b-rodrigues/pkgctx -- python numpy --compact --emit-classes > numpy.ctx.yaml
```

## Project Integration

### Core Packages for llm Project

Generate context for frequently used packages:

```bash
# Core tidyverse/data manipulation
nix run github:b-rodrigues/pkgctx -- r dplyr --compact > .claude/context/dplyr.ctx.yaml
nix run github:b-rodrigues/pkgctx -- r tidyr --compact > .claude/context/tidyr.ctx.yaml
nix run github:b-rodrigues/pkgctx -- r purrr --compact > .claude/context/purrr.ctx.yaml
nix run github:b-rodrigues/pkgctx -- r tibble --compact > .claude/context/tibble.ctx.yaml

# Pipeline and workflow
nix run github:b-rodrigues/pkgctx -- r targets --compact > .claude/context/targets.ctx.yaml
nix run github:b-rodrigues/pkgctx -- r tarchetypes --compact > .claude/context/tarchetypes.ctx.yaml

# Git/GitHub operations
nix run github:b-rodrigues/pkgctx -- r gert --compact > .claude/context/gert.ctx.yaml
nix run github:b-rodrigues/pkgctx -- r gh --compact > .claude/context/gh.ctx.yaml
nix run github:b-rodrigues/pkgctx -- r usethis --compact > .claude/context/usethis.ctx.yaml

# Package development
nix run github:b-rodrigues/pkgctx -- r devtools --compact > .claude/context/devtools.ctx.yaml
nix run github:b-rodrigues/pkgctx -- r testthat --compact > .claude/context/testthat.ctx.yaml
nix run github:b-rodrigues/pkgctx -- r pkgdown --compact > .claude/context/pkgdown.ctx.yaml

# Nix/reproducibility
nix run github:b-rodrigues/pkgctx -- r github:ropensci/rix --compact > .claude/context/rix.ctx.yaml

# Utilities
nix run github:b-rodrigues/pkgctx -- r logger --compact > .claude/context/logger.ctx.yaml
nix run github:b-rodrigues/pkgctx -- r fs --compact > .claude/context/fs.ctx.yaml
nix run github:b-rodrigues/pkgctx -- r here --compact > .claude/context/here.ctx.yaml
nix run github:b-rodrigues/pkgctx -- r glue --compact > .claude/context/glue.ctx.yaml
```

### Project-Specific Packages (coMMpass Example)

```bash
# Bioconductor data access
nix run github:b-rodrigues/pkgctx -- r bioc:TCGAbiolinks --compact > .claude/context/TCGAbiolinks.ctx.yaml
nix run github:b-rodrigues/pkgctx -- r bioc:GenomicDataCommons --compact > .claude/context/GenomicDataCommons.ctx.yaml
nix run github:b-rodrigues/pkgctx -- r bioc:SummarizedExperiment --compact > .claude/context/SummarizedExperiment.ctx.yaml

# AWS access
nix run github:b-rodrigues/pkgctx -- r aws.s3 --compact > .claude/context/aws.s3.ctx.yaml

# Parallel processing
nix run github:b-rodrigues/pkgctx -- r mirai --compact > .claude/context/mirai.ctx.yaml
nix run github:b-rodrigues/pkgctx -- r nanonext --compact > .claude/context/nanonext.ctx.yaml
```

### Generate Context for Current Project

```bash
# Generate context for your own package
nix run github:b-rodrigues/pkgctx -- r . --compact > package.ctx.yaml

# Commit to version control
git add package.ctx.yaml
git commit -m "Add package API context for LLM use"
```

## Version Compatibility with rix

### The Version Availability Problem

Using `rix::available_dates()` returns snapshot dates from rstats-on-nix, but:
- **Newer ≠ better** - Latest dates may have packages still building
- **Version pinning** - A package may exist but not at the version you need
- **Stability** - Older, well-tested snapshots are more reliable

### Finding Compatible Dates

```r
library(rix)

# List all available snapshot dates
dates <- available_dates()
cat("Total dates:", length(dates), "\n")
cat("Range:", min(dates), "to", max(dates), "\n")

# Check package availability for a specific date
# Note: This doesn't guarantee VERSION compatibility
# You must verify the actual versions work together

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

## File Organization

```
project/
├── package.ctx.yaml           # Context for THIS package (auto-generated)
├── .claude/
│   └── context/               # Context for DEPENDENCIES
│       ├── dplyr.ctx.yaml
│       ├── targets.ctx.yaml
│       ├── gert.ctx.yaml
│       └── ...
└── .github/
    └── workflows/
        ├── update-pkg-context.yaml
        ├── api-drift-check.yaml
        └── update-dep-context.yaml
```

## Using Context in Prompts

### Including in Claude Code

Reference `.ctx.yaml` files in your prompts:

```
Based on the targets package API in .claude/context/targets.ctx.yaml,
help me create a pipeline that...
```

### Concatenating Multiple Contexts

```bash
# Combine relevant package contexts for a task
cat .claude/context/targets.ctx.yaml \
    .claude/context/tarchetypes.ctx.yaml \
    .claude/context/dplyr.ctx.yaml > combined.ctx.yaml
```

## Troubleshooting

### Package Not Found

```bash
# Error: Package 'xyz' not found on CRAN
# Solution: Check if it's on Bioconductor or GitHub
nix run github:b-rodrigues/pkgctx -- r bioc:xyz --compact
nix run github:b-rodrigues/pkgctx -- r github:user/xyz --compact
```

### Nix Build Fails

```bash
# First time may need to build pkgctx itself
# This is normal - subsequent runs use cache
nix run github:b-rodrigues/pkgctx -- r dplyr --compact
```

### Context Too Large

```bash
# Use maximum compression
nix run github:b-rodrigues/pkgctx -- r largepackage \
  --compact \
  --hoist-common-args \
  --no-header > pkg.ctx.yaml

# Or exclude internal functions
nix run github:b-rodrigues/pkgctx -- r . --compact > pkg.ctx.yaml
# (--include-internal is opt-in, not default)
```

## Related Skills

- `nix-rix-r-environment` - Nix environment management, `available_dates()`
- `ci-workflows-github-actions` - CI workflow patterns
- `r-package-workflow` - R package development workflow
- `context-control` - Managing Claude Code context

## Resources

- **pkgctx repository**: https://github.com/b-rodrigues/pkgctx
- **rix package**: https://docs.ropensci.org/rix/
- **rstats-on-nix**: https://github.com/rstats-on-nix/nixpkgs
