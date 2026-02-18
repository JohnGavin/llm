# GitHub Workflows Rules

**Applies to**: `.github/workflows/*.yml`

## Critical: Nix-Based CI Only

**We use Nix-based CI, NOT standard r-lib/actions.**

### What We DON'T Use

```yaml
# FORBIDDEN - These attempt package installation
- uses: r-lib/actions/setup-r@v2
- uses: r-lib/actions/setup-r-dependencies@v2
- run: Rscript -e 'install.packages("pak")'
```

### What We DO Use

```yaml
# CORRECT - Nix-based testing
- uses: cachix/install-nix-action@v22
- uses: cachix/cachix-action@v12
  with:
    name: rstats-on-nix
    extraPullNames: johngavin
- run: nix-shell default.nix --run "Rscript -e 'devtools::test()'"
```

## Standard Workflow Template

```yaml
name: R-CMD-check

on:
  push:
    branches: [main, master]
  pull_request:
    branches: [main, master]

jobs:
  check:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4

      - name: Install Nix
        uses: cachix/install-nix-action@v22
        with:
          nix_path: nixpkgs=channel:nixos-unstable

      - name: Setup Cachix
        uses: cachix/cachix-action@v12
        with:
          name: rstats-on-nix
          extraPullNames: johngavin
          authToken: '${{ secrets.CACHIX_AUTH_TOKEN }}'

      - name: Run tests
        run: |
          nix-shell default.nix --run "Rscript -e 'devtools::test()'"

      - name: Run R CMD check
        run: |
          nix-shell default.nix --run "Rscript -e 'devtools::check(args = \"--as-cran\")'"
```

## Workflow Triggers

```yaml
on:
  push:
    branches: [main, master]
    paths:
      - 'R/**'
      - 'tests/**'
      - 'DESCRIPTION'
      - 'default.nix'
  pull_request:
    branches: [main, master]
  workflow_dispatch:  # Manual trigger
```

**Path filtering**: Only trigger on relevant file changes.

## Secrets Management

**NEVER commit secrets to workflows.**

```yaml
# WRONG
env:
  API_KEY: "sk-12345..."

# CORRECT
env:
  API_KEY: ${{ secrets.API_KEY }}
```

Required secrets for Nix CI:
- `CACHIX_AUTH_TOKEN`: For pushing to personal cachix cache

## Documented Exceptions

### 1. pkgdown Website Deployment

pkgdown attempts to install packages, breaking Nix. Build locally instead:

```yaml
name: pkgdown

on:
  push:
    branches: [main, master]
    paths:
      - 'R/**'
      - 'man/**'
      - 'vignettes/**'
      - '_pkgdown.yml'

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      # Only deploy pre-built site from gh-pages branch
      - name: Deploy to GitHub Pages
        uses: peaceiris/actions-gh-pages@v3
        with:
          github_token: ${{ secrets.GITHUB_TOKEN }}
          publish_dir: ./docs
```

**Local build process**:
```bash
./default.sh
R -e "pkgdown::build_site()"
# Commit docs/ to gh-pages branch
```

### 2. GitHub Pages with nix-shell-root

**CRITICAL**: Remove `nix-shell-root` from gh-pages branch.

```bash
# Before pushing to gh-pages
rm -f nix-shell-root  # Symlinks break GitHub Pages
```

## Caching Strategies

### Nix Store Caching

```yaml
- name: Cache Nix store
  uses: actions/cache@v3
  with:
    path: /nix/store
    key: ${{ runner.os }}-nix-${{ hashFiles('default.nix') }}
    restore-keys: |
      ${{ runner.os }}-nix-
```

### Cachix for R Packages

```yaml
- uses: cachix/cachix-action@v12
  with:
    name: rstats-on-nix
    extraPullNames: johngavin  # Personal cache as fallback
```

## Matrix Builds (When Needed)

For testing across Nix configurations:

```yaml
strategy:
  matrix:
    nix-channel: [nixos-unstable, nixos-23.11]

steps:
  - uses: cachix/install-nix-action@v22
    with:
      nix_path: nixpkgs=channel:${{ matrix.nix-channel }}
```

**Note**: We avoid multi-OS matrices (Windows/Mac/Linux) in favor of reproducible Nix builds.

## Job Dependencies

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - run: nix-shell default.nix --run "Rscript -e 'devtools::test()'"

  check:
    needs: test  # Only run if tests pass
    runs-on: ubuntu-latest
    steps:
      - run: nix-shell default.nix --run "Rscript -e 'devtools::check()'"

  deploy:
    needs: [test, check]  # Only deploy if both pass
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    steps:
      - run: echo "Deploying..."
```

## Debugging Workflows

```yaml
- name: Debug info
  run: |
    echo "Event: ${{ github.event_name }}"
    echo "Ref: ${{ github.ref }}"
    echo "SHA: ${{ github.sha }}"
    nix-shell default.nix --run "R --version"
```

## Scheduled Workflows

For regular checks:

```yaml
on:
  schedule:
    - cron: '0 6 * * 1'  # Every Monday at 6 AM UTC

jobs:
  weekly-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Full check
        run: nix-shell default.nix --run "Rscript -e 'devtools::check()'"
```
