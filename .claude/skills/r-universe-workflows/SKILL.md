# Skill: R-universe Build & Test Workflows

Enable an R package repository to test against the exact same build and check process used by R-universe.

## Rationale
The R-universe CI workflows have been refactored (as of January 2026) to allow users to run the R-universe build process directly within their own GitHub repository. This ensures that packages will build and check successfully on R-universe before they are actually deployed, mirroring CRAN-like strictness across Linux, Windows, and macOS.

## Implementation

Create a file at `.github/workflows/r-universe-test.yml` with the following configuration:

```yaml
name: Test R-universe
on:
  push:
  pull_request:
jobs:
  build:
    name: R-universe testing
    uses: r-universe-org/workflows/.github/workflows/build.yml@v3
    with:
      universe: ${{ github.repository_owner }}
```

## Key Features
- **Strict Environment:** The workflow is not customizable, mirroring the R-universe and CRAN build environments.
- **Cross-Platform:** Automatically builds and checks on Linux, Windows, and macOS.
- **R Version Coverage:** Tests against multiple R versions.
- **Pre-deployment Verification:** Catch issues that might occur during R-universe ingestion early.

## Usage
Add this workflow to any R package repo that is intended for distribution via R-universe to ensure consistent build results.
