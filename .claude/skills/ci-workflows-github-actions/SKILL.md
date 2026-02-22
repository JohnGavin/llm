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

**File:** `.github/workflows/R-CMD-check.yml`

```yaml
name: R-CMD-check

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  workflow_dispatch:

jobs:
  R-CMD-check:
    runs-on: ubuntu-latest
    timeout-minutes: 20
    env:
      GITHUB_PAT: ${{ secrets.GITHUB_TOKEN }}

    steps:
      - uses: actions/checkout@v6

      - name: Install Nix
        uses: DeterminateSystems/nix-installer-action@main
        with:
          logger: pretty
          log-directives: nix_installer=trace
          backtrace: full

      - name: Setup magic Nix cache
        uses: DeterminateSystems/magic-nix-cache-action@main

      - name: Setup Cachix (rstats-on-nix + johngavin)
        uses: cachix/cachix-action@v15
        with:
          name: rstats-on-nix
          extraPullNames: johngavin

      - name: Build development environment
        run: nix-build default.nix -A shell --no-out-link

      - name: Run R CMD check
        run: |
          nix-shell default.nix -A shell --run "Rscript -e 'devtools::document(); devtools::check(error_on = \"error\", check_dir = \"check\")'"

      - name: Validate targets pipeline
        if: hashFiles('_targets.R') != ''
        run: |
          nix-shell default.nix -A shell --run "Rscript -e '
            targets::tar_validate()
            cat(\"Pipeline valid:\", length(targets::tar_manifest()\$name), \"targets\\n\")
          '"

      - name: Upload check results on failure
        if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: R-CMD-check-results
          path: check/
          retention-days: 7
```

**Key points:**
- `GITHUB_PAT` at job level prevents GitHub API rate limits
- `actions/checkout@v6` (latest)
- Verbose Nix installer logging (`logger: pretty`, `log-directives`, `backtrace`)
- `magic-nix-cache-action` for free automatic Nix binary caching (no quota)
- Cachix `rstats-on-nix` + `johngavin` for R package binaries
- Explicit `nix-build` step separates env build errors from check errors
- `tar_validate()` runs when `_targets.R` exists (catches pipeline definition errors)
- Failure artifact upload for post-mortem debugging

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
      - uses: actions/checkout@v6

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
      - uses: actions/checkout@v6

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
      - uses: actions/checkout@v6

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
      - 'package.nix'
  workflow_dispatch:

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6

      - name: Install Nix
        uses: DeterminateSystems/nix-installer-action@main

      - name: Setup magic Nix cache
        uses: DeterminateSystems/magic-nix-cache-action@main

      - uses: cachix/cachix-action@v15
        with:
          name: johngavin
          authToken: '${{ secrets.CACHIX_AUTH_TOKEN }}'

      - name: Build and push project package to cachix
        run: |
          cachix watch-exec johngavin --watch-mode auto -- nix-build package.nix --no-out-link
```

## Nix Caching Integration

### Three-Tier Caching Strategy (MANDATORY)

```yaml
# 1. Magic Nix cache (free, automatic, CI-only — no auth token)
- uses: DeterminateSystems/magic-nix-cache-action@main

# 2. Public R packages cache (contains pre-built R packages)
- uses: cachix/cachix-action@v15
  with:
    name: rstats-on-nix

# 3. Project cache (your custom builds — pulled via extraPullNames)
#    Only needs authToken when PUSHING (in nix-builder workflow)
```

**Why three tiers:**
- `magic-nix-cache` is free with no quota — caches all Nix build artifacts
- `rstats-on-nix` has pre-built R packages — avoids 30+ minute source builds
- `johngavin` has project-specific packages — for downstream consumers

### Local Push to Cachix (Step 5 of 9-Step Workflow)

**⚠️ IMPORTANT: Only push PROJECT-SPECIFIC packages to johngavin cache!**

- Standard R packages (dplyr, ggplot2, targets, etc.) are ALL in `rstats-on-nix`
- Only push custom packages NOT available in rstats-on-nix
- For development packages loaded via `load_all()`, there's nothing to push
- Pushing standard R packages wastes limited Cachix quota

```bash
# Push ONLY if you have custom packages in default-ci.nix/package.nix
# that are NOT available from rstats-on-nix
nix-store -qR $(nix-build default-ci.nix) | cachix push johngavin

# Or use helper script (should be project-aware)
./push_to_cachix.sh
```

**When to push to johngavin:**
- Custom R packages built from GitHub (not in rstats-on-nix)
- Modified/patched versions of packages
- Project-specific Nix derivations

**When NOT to push:**
- Standard CRAN packages (already in rstats-on-nix)
- Development packages loaded via `load_all()`
- Shell environments with only standard packages

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
      - uses: actions/checkout@v6
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
      - uses: actions/checkout@v6

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
      - uses: actions/checkout@v6

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
      - uses: actions/checkout@v6

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

### 10. Incremental Pipeline with `targets-runs` Branch (b-rodrigues Pattern)

**Source:** [nix_targets_pipeline](https://github.com/b-rodrigues/nix_targets_pipeline)

An alternative to committing `_targets/` to main. Stores pipeline outputs on a separate
orphan branch (`targets-runs`), restoring them before each CI run for incremental builds.

```yaml
name: Run Pipeline

on:
  push:
    branches: [main]

jobs:
  targets:
    runs-on: ubuntu-latest
    env:
      GITHUB_PAT: ${{ secrets.GITHUB_TOKEN }}
    steps:
      - uses: actions/checkout@v6

      - uses: DeterminateSystems/nix-installer-action@main
        with:
          logger: pretty
          log-directives: nix_installer=trace
          backtrace: full

      - uses: DeterminateSystems/magic-nix-cache-action@main

      - name: Build development environment
        run: nix-build

      - name: Check if previous runs exist
        id: runs-exist
        run: git ls-remote --exit-code --heads origin targets-runs
        continue-on-error: true

      - name: Checkout previous run
        if: steps.runs-exist.outcome == 'success'
        uses: actions/checkout@v6
        with:
          ref: targets-runs
          fetch-depth: 1
          path: .targets-runs

      - name: Restore output files from the previous run
        if: steps.runs-exist.outcome == 'success'
        run: |
          nix-shell default.nix --run "Rscript -e 'for (dest in scan(\".targets-runs/.targets-files\", what = character())) {
            source <- file.path(\".targets-runs\", dest)
            if (!file.exists(dirname(dest))) dir.create(dirname(dest), recursive = TRUE)
            if (file.exists(source)) file.rename(source, dest)
          }'"

      - name: Run pipeline
        run: nix-shell default.nix --run "Rscript -e 'targets::tar_make()'"

      - name: Identify pipeline output files
        run: git ls-files -mo --exclude='*.duckdb' > .targets-files

      - name: Create runs branch if needed
        if: steps.runs-exist.outcome != 'success'
        run: git checkout --orphan targets-runs

      - name: Switch to runs branch if it exists
        if: steps.runs-exist.outcome == 'success'
        run: |
          rm -r .git
          mv .targets-runs/.git .
          rm -r .targets-runs

      - name: Upload latest run
        run: |
          git config --local user.name "GitHub Actions"
          git config --local user.email "actions@github.com"
          rm -rf .gitignore .github/workflows
          git add --all -- ':!*.duckdb'
          for file in $(cat .targets-files); do
            git add --force $file
          done
          git commit -am "Run pipeline"
          git push origin targets-runs

      - name: Post failure artifact
        if: failure()
        uses: actions/upload-artifact@main
        with:
          name: pipeline-failure
          path: .
```

**Trade-offs vs committing `_targets/` to main (LFS approach):**

| Aspect | `targets-runs` branch | `_targets/` on main (LFS) |
|--------|----------------------|---------------------------|
| Main branch cleanliness | Clean — no pipeline artifacts | Polluted with binary objects |
| Incremental CI builds | Yes — restores previous outputs | Yes — already in checkout |
| Local development | Must pull `targets-runs` branch separately | Available immediately |
| LFS dependency | None | Required for large objects |
| Workflow complexity | Higher (orphan branch management) | Lower (just commit + restore .gitignore) |
| Repo size | main stays small | main grows with each update |

**When to use which:**
- **`targets-runs` branch**: Large pipelines, many binary artifacts, want clean main
- **`_targets/` on main (LFS)**: Small stores (< 50 MB), vignettes need targets data, simpler workflow

### DeterminateSystems/magic-nix-cache-action

**Free** Nix binary cache from Determinate Systems. No auth token needed.
Can replace or supplement cachix for CI-only caching.

```yaml
# Instead of (or in addition to) cachix:
- uses: DeterminateSystems/magic-nix-cache-action@main
```

**Key differences from cachix:**
- Free, no quota limits
- Automatic — caches everything Nix builds
- No auth token needed
- Only works in CI (not for sharing with local devs)
- Cannot replace johngavin cachix for publishing project packages

**Recommendation:** Use `magic-nix-cache-action` for CI speed. Keep `cachix`
for publishing project packages to johngavin cache for downstream consumers.

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

## Mandatory CI Environment (ALL Nix Workflows)

Every Nix-based workflow MUST include these three features:

### 1. `GITHUB_PAT` at job level

Prevents GitHub API rate limits (affects `remotes::`, `pak::`, `rix::` calls):

```yaml
jobs:
  my-job:
    env:
      GITHUB_PAT: ${{ secrets.GITHUB_TOKEN }}
```

### 2. Verbose Nix installer logging

Better debugging when Nix install fails in CI:

```yaml
      - uses: DeterminateSystems/nix-installer-action@main
        with:
          logger: pretty
          log-directives: nix_installer=trace
          backtrace: full
```

### 3. `actions/checkout@v6`

Always use latest major version:

```yaml
      - uses: actions/checkout@v6
```

### 4. Pipeline validation (if `_targets.R` exists)

Add after R CMD check step. Fast (< 5s), catches definition errors:

```yaml
      - name: Validate targets pipeline
        if: hashFiles('_targets.R') != ''
        run: |
          nix-shell default.nix -A shell --run "Rscript -e '
            targets::tar_validate()
            cat(\"Pipeline valid:\", length(targets::tar_manifest()\$name), \"targets\\n\")
          '"
```

See `targets-ci-pipeline` skill for full pipeline CI workflows.

## Best Practices

1. **Use path filters** - Don't run CI on unrelated changes
2. **Three-tier Nix caching** - magic-nix-cache + rstats-on-nix + project cache
3. **DeterminateSystems installer** - Better logging and diagnostics
4. **Explicit nix-build step** - Separates env build errors from command errors
5. **Failure artifact upload** - Upload check results/workdir on failure
6. **Skip CI commits** - Use `[skip ci]` for automated commits
7. **Native R for web tools** - bslib/pkgdown don't work in Nix
8. **Test r-universe locally** - Catch issues before deployment
9. **targets-runs branch** - Store pipeline state on orphan branch, not main
10. **GITHUB_PAT** - Always set at job level to avoid rate limits
11. **Verbose Nix logging** - Always use `logger: pretty` + `log-directives`
12. **Pipeline validation** - Add `tar_validate()` when `_targets.R` exists

## Related Skills

- `targets-ci-pipeline` - Full targets pipeline CI (targets-runs branch, bootstrapping)
- `nix-rix-r-environment` - Core Nix/rix setup, `available_dates()`
- `pkgdown-deployment` - Hybrid deployment details
- `verification-before-completion` - CI verification patterns
- `r-package-workflow` - 9-step workflow with CI integration
- `llm-package-context` - pkgctx usage, API drift detection
- `targets-vignettes` - Pre-computed vignette pattern

## Resources

- [r-universe workflows](https://github.com/r-universe-org/workflows)
- [r-lib/actions](https://github.com/r-lib/actions)
- [r-wasm/actions](https://github.com/r-wasm/actions)
- [Cachix documentation](https://docs.cachix.org/)
- [GitHub Actions docs](https://docs.github.com/en/actions)
- [pkgctx](https://github.com/b-rodrigues/pkgctx) - LLM package context generator
