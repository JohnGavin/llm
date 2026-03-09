# Workflow YAML Templates

Full YAML templates for each CI workflow. See SKILL.md for summaries and the decision matrix.

## 1. R-CMD-check (Nix-based)

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

## 2. R-Universe Test Workflow

**File:** `.github/workflows/r-universe-test.yml`

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

## 3. Code Coverage (Non-Nix)

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

## 4. WASM Build (WebAssembly)

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

## 5. Deploy to GitHub Pages (Hybrid)

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

## 6. Nix Environment Builder

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

## Trigger Patterns Reference

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
