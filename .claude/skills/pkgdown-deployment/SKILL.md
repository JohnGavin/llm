# Pkgdown Deployment with Hybrid Nix + Native R

## Description

This skill covers deploying R package documentation using pkgdown and GitHub Pages with a hybrid workflow that uses Nix for core development and Native R for deployment. This approach bypasses fundamental incompatibilities between the Nix store and modern R web tooling (bslib/Bootstrap 5).

## Purpose

Use this skill when:
- Deploying pkgdown sites from Nix-based R projects
- Encountering `Permission denied` errors with bslib in Nix CI
- Building vignettes that depend on targets pipeline data
- Setting up GitHub Actions for documentation deployment
- Need to separate "logic verification" (Nix) from "presentation" (Native R)

## The Problem: Nix vs Modern R Web Tools

The Nix store (`/nix/store/...`) is **read-only**, which conflicts with how `bslib` operates:

1. **Immutability:** Nix store is read-only
2. **Runtime Copying:** `bslib` attempts to copy JS/CSS assets from its installation directory to a temporary cache during execution
3. **The Crash:** In strict Nix environments, `bslib` fails with `Permission denied`
4. **Quarto Complexity:** Quarto binary dependencies can desynchronize from Nix shell context, causing "Quarto not found" errors

## The Solution: Hybrid Workflow

### Workflow Split

| Task | Environment | Why |
|------|-------------|-----|
| Core logic, tests, `devtools::check()` | **Nix** | Reproducibility |
| `pkgdown::build_site()` | **Native R** | Web tooling compatibility |
| Vignette computation | **Nix** (via targets) | Reproducible results |
| Vignette rendering | **Native R** | Uses pre-computed data |

### Why This Is Acceptable

- **Logic is Verified in Nix:** `devtools::check()` and targets pipeline run in Nix
- **Documentation is Presentation:** Website is a view of the package, not core logic
- **Pre-built Vignettes:** Use targets to pre-compute results in Nix, commit outputs, CI just wraps them

## Implementation

### 1. GitHub Actions Configuration (`deploy-docs.yml`)

**DO:**
```yaml
- uses: r-lib/actions/setup-r@v2
- uses: r-lib/actions/setup-pandoc@v2
- uses: quarto-dev/quarto-actions/setup@v2
- run: |
    Rscript -e "remotes::install_deps(dependencies = TRUE)"
    Rscript -e "pkgdown::build_site(new_process = FALSE)"
```

**DON'T:**
- Don't use `nix-shell` for the pkgdown build step
- Don't forget `setup-pandoc` (needed for README/manual conversion)

### 2. Vignette Data Strategy ("Data Snapshot" Pattern)

**Problem:** pkgdown builds vignettes in a temporary directory where relative paths to `_targets` store are invalid.

**Solution:**

1. **Snapshot Data:** After `targets::tar_make()`, extract required data:
   ```r
   # In CI workflow
   targets::tar_load(c(universe, history))
   saveRDS(list(universe = universe, history = history),
           "inst/extdata/vignette_data.rds")
   ```

2. **Install with Data:** Run `devtools::install()` after creating snapshot

3. **Robust Access in Vignette:**
   ```r
   data_path <- system.file("extdata", "vignette_data.rds", package = "mypkg")
   if (file.exists(data_path)) {
     data <- readRDS(data_path)
   } else {
     # Placeholder message for missing data
   }
   ```

4. **Fail-Safe Coding:** Wrap data loading in `tryCatch`, use `requireNamespace` for libraries

5. **Dependencies:** List all vignette packages in `Suggests` in DESCRIPTION

### 3. Complete Workflow Example

```yaml
# .github/workflows/deploy-docs.yml
name: Deploy to GitHub Pages

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: r-lib/actions/setup-r@v2
      - uses: r-lib/actions/setup-pandoc@v2
      - uses: quarto-dev/quarto-actions/setup@v2

      - name: Install dependencies
        run: |
          Rscript -e "install.packages('remotes')"
          Rscript -e "remotes::install_deps(dependencies = TRUE)"

      - name: Build pkgdown site
        run: Rscript -e "pkgdown::build_site(new_process = FALSE)"

      - name: Deploy to GitHub Pages
        uses: peaceiris/actions-gh-pages@v3
        with:
          github_token: ${{ secrets.GITHUB_TOKEN }}
          publish_dir: ./docs
```

## Key References

- **R Packages (2nd Ed):** "If you want to include raw data... put it in `inst/extdata`" and use `system.file()` to access it
- **Reliability:** `system.file()` resolves absolute path to installed package location, works in CI, local, and isolated pkgdown builds
- **Decoupling:** Separates data generation (complex deps/credentials) from vignette rendering (just reads files)

## Common Errors and Fixes

| Error | Cause | Fix |
|-------|-------|-----|
| `Permission denied` in bslib | Nix read-only store | Use Native R for pkgdown |
| `Quarto not found` | PATH issues in Nix CI | Use `quarto-dev/quarto-actions/setup` |
| Vignette can't find targets data | Relative path invalid in temp dir | Use `system.file()` with `inst/extdata` |
| `library(ggplot2)` fails in vignette | Missing from Suggests | Add all vignette deps to Suggests |

## Artifact vs. Branch Deployment (Important)

**Modern GitHub Actions Deployment:**
- **Mechanism:** Deploys directly from build artifacts (`actions/upload-pages-artifact`) to the GitHub Pages environment.
- **Branch:** The `gh-pages` branch is **NOT** updated with new commits for every deployment. It may become stale or disappear entirely.
- **Verification:** DO NOT check `git log origin/gh-pages`. Check the **Actions** tab or the live website's "Last Updated" timestamp.

**To verify deployment:**
```bash
# Check the latest workflow run status
gh run list --workflow "Deploy to GitHub Pages" --limit 1

# Check the live site
curl -I https://username.github.io/repo/
```

## Related Skills

- `nix-rix-r-environment` - Core Nix/rix workflow
- `r-package-workflow` - 9-step development workflow
- `targets-vignettes` - Pre-computing vignette objects
- `shinylive-quarto` - Browser-based Shiny deployment