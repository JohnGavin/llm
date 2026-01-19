# CI Workflows with GitHub Actions

## Description

Comprehensive GitHub Actions workflows for R package development, covering Nix-based builds, r-universe testing, WASM compilation, code coverage, and deployment patterns.

## Purpose

Use this skill when:
- Setting up CI/CD for R packages
- Testing against r-universe build process
- Building WebAssembly (WASM) versions of packages
- Configuring code coverage reporting
- Using Cachix for Nix store caching
- Implementing reusable workflow patterns

## Workflow Catalog

### 1. R-CMD-check (Nix-based)

**File:** `.github/workflows/r-cmd-check.yaml`

```yaml
name: R-CMD-check

on:
  push:
    branches: [main, master]
  pull_request:
    branches: [main, master]

permissions:
  contents: read

jobs:
  R-CMD-check:
    runs-on: ubuntu-latest
    env:
      GITHUB_PAT: ${{ secrets.GITHUB_TOKEN }}

    steps:
      - uses: actions/checkout@v4

      - name: Create nix folder to silence warning
        run: mkdir -p ~/.nix-defexpr/channels

      - uses: cachix/install-nix-action@v31
        with:
          nix_path: nixpkgs=https://github.com/rstats-on-nix/nixpkgs/archive/refs/heads/r-daily.tar.gz

      - uses: cachix/cachix-action@v15
        with:
          name: rstats-on-nix  # Public R packages cache

      - uses: cachix/cachix-action@v15
        with:
          name: johngavin  # Project-specific cache
          authToken: '${{ secrets.CACHIX_AUTH_TOKEN }}'
          skipPush: true

      - name: Build development environment
        run: nix-shell default-ci.nix --quiet --run "Rscript -e \"sessionInfo()\""

      - name: Run R CMD check
        run: nix-shell default-ci.nix --quiet --run "Rscript -e \"devtools::check(error_on = 'warning', check_dir = 'check')\""

      - name: Upload check results
        if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: check-results
          path: check/
```

**Key points:**
- Uses Nix for reproducible R environment
- Two-tier Cachix: public `rstats-on-nix` then project-specific
- `skipPush: true` on project cache to avoid pushing during checks

### 2. R-Universe Test Workflow

**File:** `.github/workflows/r-universe-test.yml`

Test the exact r-universe build process locally before deployment.

```yaml
name: Test R-universe

on:
  push:
    branches: [main, master]
  pull_request:
    branches: [main, master]
  workflow_dispatch:

jobs:
  build:
    name: R-universe testing
    uses: r-universe-org/workflows/.github/workflows/build.yml@v3
    with:
      universe: ${{ github.repository_owner }}
```

**Why use this:**
- Tests exact build process as r-universe.dev
- Builds/checks on Linux, Windows, MacOS
- Uses same R versions as CRAN submission checks
- Catches issues before actual r-universe deployment

**Reference:** [rOpenSci blog post](https://ropensci.org/blog/2026/01/03/r-universe-workflows/)

### 3. Code Coverage (Non-Nix)

**File:** `.github/workflows/coverage.yaml`

`covr::package_coverage()` fails in Nix due to "error reading from connection". Use Native R:

```yaml
name: Code Coverage

on:
  push:
    branches: [main]
    paths:
      - 'R/**'
      - 'tests/**'
      - 'src/**'
  workflow_dispatch:

permissions:
  contents: write

jobs:
  coverage:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: r-lib/actions/setup-r@v2
        with:
          use-public-rspm: true

      - uses: r-lib/actions/setup-r-dependencies@v2
        with:
          extra-packages: covr

      - name: Generate coverage
        run: |
          Rscript -e '
            cov <- covr::package_coverage()
            saveRDS(cov, "inst/extdata/coverage.rds")
          '

      - name: Commit coverage data
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add inst/extdata/coverage.rds
          git diff --staged --quiet || git commit -m "Update coverage data [skip ci]"
          git push
```

**Pattern:** Generate coverage in CI, commit to repo, read in telemetry vignette via `readRDS()`.

### 4. WASM Build (WebAssembly)

**File:** `.github/workflows/build-rwasm.yml`

```yaml
name: Build R WASM Package

on:
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: write

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Build WASM package
        uses: r-wasm/actions/build-rwasm@v2
        with:
          packages: |
            .
          compress: true
```

**For Shinylive:** Build WASM binaries for browser-based Shiny apps.

### 5. Deploy to GitHub Pages (Hybrid)

**File:** `.github/workflows/deploy-pages.yaml`

Uses Native R for pkgdown (bslib incompatibility with Nix):

```yaml
name: Deploy to GitHub Pages

on:
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: read
  pages: write
  id-token: write

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}

    steps:
      - uses: actions/checkout@v4

      - uses: r-lib/actions/setup-r@v2
      - uses: r-lib/actions/setup-pandoc@v2
      - uses: quarto-dev/quarto-actions/setup@v2

      - uses: r-lib/actions/setup-r-dependencies@v2
        with:
          extra-packages: pkgdown

      - name: Build pkgdown site
        run: Rscript -e "pkgdown::build_site(new_process = FALSE)"

      - uses: actions/upload-pages-artifact@v3
        with:
          path: docs

      - uses: actions/deploy-pages@v4
        id: deployment
```

### 6. Nix Environment Builder

**File:** `.github/workflows/nix-builder.yaml`

Pre-build Nix environment and push to Cachix:

```yaml
name: Build Nix Environment

on:
  push:
    paths:
      - 'default.nix'
      - 'default-ci.nix'
      - 'package.nix'
  workflow_dispatch:

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: cachix/install-nix-action@v31
        with:
          nix_path: nixpkgs=https://github.com/rstats-on-nix/nixpkgs/archive/refs/heads/r-daily.tar.gz

      - uses: cachix/cachix-action@v15
        with:
          name: johngavin
          authToken: '${{ secrets.CACHIX_AUTH_TOKEN }}'

      - name: Build and push to cachix
        run: |
          nix-build default-ci.nix
          nix-store -qR result | cachix push johngavin
```

## Cachix Integration

### Two-Tier Caching Strategy

```yaml
# 1. Public cache FIRST (contains pre-built R packages)
- uses: cachix/cachix-action@v15
  with:
    name: rstats-on-nix

# 2. Project cache SECOND (your custom builds)
- uses: cachix/cachix-action@v15
  with:
    name: johngavin
    authToken: '${{ secrets.CACHIX_AUTH_TOKEN }}'
```

### Local Push to Cachix (Step 5 of 9-Step Workflow)

```bash
# Push project derivation to cachix before GitHub Actions
nix-store -qR $(nix-build default-ci.nix) | cachix push johngavin

# Or use helper script
../push_to_cachix.sh
```

## Reusable Workflow Patterns

### Calling External Reusable Workflows

```yaml
jobs:
  build:
    uses: r-universe-org/workflows/.github/workflows/build.yml@v3
    with:
      universe: ${{ github.repository_owner }}
```

### Creating Your Own Reusable Workflow

```yaml
# .github/workflows/reusable-check.yml
name: Reusable R Check

on:
  workflow_call:
    inputs:
      r-version:
        description: 'R version to use'
        default: 'release'
        type: string

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: r-lib/actions/setup-r@v2
        with:
          r-version: ${{ inputs.r-version }}
      # ... rest of workflow
```

## Package Context Workflows (pkgctx)

Generate LLM-optimized API documentation and detect API drift. See `llm-package-context` skill for full details.

### 7. Auto-Update Package Context

**File:** `.github/workflows/update-pkg-context.yaml`

```yaml
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
          nix run github:b-rodrigues/pkgctx -- r . --compact > package.ctx.yaml

      - name: Commit updated context
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add package.ctx.yaml
          git diff --staged --quiet || git commit -m "Update package API context [skip ci]"
          git push
```

**Purpose:** Auto-generate structured API documentation for LLMs after code changes.

### 8. API Drift Detection (Warning Only)

**File:** `.github/workflows/api-drift-check.yaml`

```yaml
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
              diff package.ctx.yaml current.ctx.yaml || true
            else
              echo "No API drift detected."
            fi
          else
            echo "::notice::No existing package.ctx.yaml - will be created on merge."
          fi
```

**Purpose:** Warn (not fail) when function signatures change in PRs.

### 9. Weekly Dependency Context Update

**File:** `.github/workflows/update-dep-context.yaml`

```yaml
name: Update Dependency Context

on:
  schedule:
    - cron: '0 3 * * 0'  # Weekly on Sunday at 3am UTC
  workflow_dispatch:

permissions:
  contents: write

jobs:
  update-deps:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: DeterminateSystems/nix-installer-action@main

      - name: Generate context for dependencies
        run: |
          mkdir -p .claude/context
          # Adjust package list per project
          for pkg in targets dplyr tidyr purrr gert gh usethis devtools; do
            echo "Generating context for $pkg..."
            nix run github:b-rodrigues/pkgctx -- r "$pkg" --compact \
              > ".claude/context/${pkg}.ctx.yaml" || true
          done

      - name: Commit updated context
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add .claude/context/
          git diff --staged --quiet || git commit -m "Weekly: update dependency API context [skip ci]"
          git push
```

**Purpose:** Keep dependency API context fresh for LLM use.

## Decision Matrix

| Need | Workflow | Environment |
|------|----------|-------------|
| Standard R CMD check | r-cmd-check.yaml | Nix |
| r-universe compatibility | r-universe-test.yml | r-universe |
| Code coverage | coverage.yaml | Native R |
| WASM/Shinylive | build-rwasm.yml | r-wasm |
| Documentation site | deploy-pages.yaml | Native R (hybrid) |
| Pre-build Nix cache | nix-builder.yaml | Nix |
| LLM package context | update-pkg-context.yaml | Nix (pkgctx) |
| API drift detection | api-drift-check.yaml | Nix (pkgctx) |
| Dependency context | update-dep-context.yaml | Nix (pkgctx) |

## Trigger Patterns

```yaml
# Run on push to main only
on:
  push:
    branches: [main]

# Run on PR and push
on:
  push:
    branches: [main, master]
  pull_request:
    branches: [main, master]

# Run when specific files change
on:
  push:
    paths:
      - 'R/**'
      - 'tests/**'

# Manual trigger only
on:
  workflow_dispatch:

# Scheduled (daily at 2am UTC)
on:
  schedule:
    - cron: '0 2 * * *'
```

## Required Secrets

| Secret | Purpose | Where to get |
|--------|---------|--------------|
| `GITHUB_TOKEN` | Auto-provided | GitHub |
| `CACHIX_AUTH_TOKEN` | Push to Cachix | cachix.org |
| `CODECOV_TOKEN` | Coverage upload | codecov.io |

## Best Practices

1. **Use path filters** - Don't run CI on unrelated changes
2. **Two-tier Cachix** - Public cache first, project cache second
3. **Skip CI commits** - Use `[skip ci]` for automated commits
4. **Artifact upload on failure** - Debug failed checks easily
5. **Native R for web tools** - bslib/pkgdown don't work in Nix
6. **Test r-universe locally** - Catch issues before deployment

## Related Skills

- `nix-rix-r-environment` - Core Nix/rix setup, `available_dates()`
- `pkgdown-deployment` - Hybrid deployment details
- `verification-before-completion` - CI verification patterns
- `r-package-workflow` - 9-step workflow with CI integration
- `llm-package-context` - pkgctx usage, API drift detection

## Resources

- [r-universe workflows](https://github.com/r-universe-org/workflows)
- [r-lib/actions](https://github.com/r-lib/actions)
- [r-wasm/actions](https://github.com/r-wasm/actions)
- [Cachix documentation](https://docs.cachix.org/)
- [GitHub Actions docs](https://docs.github.com/en/actions)
- [pkgctx](https://github.com/b-rodrigues/pkgctx) - LLM package context generator
