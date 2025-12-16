# R-WASM Build Workflows for Interactive Vignettes

## Overview

This document describes the workflow for building R packages as WebAssembly (WASM) binaries for use in browser-based Shinylive vignettes. This enables fast development iteration compared to waiting for r-universe synchronization.

## Problem Statement

**Challenge**: R-universe syncs package repositories periodically (1-4 hours), creating slow feedback loops when developing interactive vignettes.

**Solution**: GitHub Actions builds R-WASM binaries on every push (~5-10 minutes), enabling rapid testing.

## Architecture

### Three-Tier Package Distribution

```
┌─────────────────────────────────────────────────────────────┐
│ 1. GitHub Pages (johngavin.github.io/PACKAGE/wasm/)        │
│    • Built on every push (5-10 min)                         │
│    • Fast development iteration                             │
│    • Latest commits immediately                             │
│    • Primary source for vignette testing                    │
└─────────────────────────────────────────────────────────────┘
                              ↓ fallback
┌─────────────────────────────────────────────────────────────┐
│ 2. R-Universe (johngavin.r-universe.dev)                   │
│    • Synced periodically (1-4 hours)                        │
│    • Stable, tested builds                                  │
│    • Multi-platform binaries                                │
│    • Secondary fallback for vignettes                       │
└─────────────────────────────────────────────────────────────┘
                              ↓ fallback
┌─────────────────────────────────────────────────────────────┐
│ 3. CRAN/Other R-Universe Repos                             │
│    • Standard package repositories                          │
│    • For dependencies (nanonext, mirai, crew, etc.)         │
│    • e.g., https://r-lib.r-universe.dev                     │
└─────────────────────────────────────────────────────────────┘
```

### Vignette Repository Configuration

Shinylive vignettes install packages from multiple sources with fallback:

```r
# In vignettes (dashboard.qmd, dashboard_async.qmd, etc.)
webr::install(
  "randomwalk",
  repos = c(
    "https://johngavin.github.io/randomwalk/wasm",  # ← PRIMARY (5-10 min)
    "https://johngavin.r-universe.dev",             # ← Fallback (1-4 hours)
    "https://r-lib.r-universe.dev"                  # ← Dependencies
  ),
  verbose = TRUE
)
```

## GitHub Actions Workflow

### File: `.github/workflows/build-wasm.yaml`

**Triggers:**
- Every push to `main` branch
- Manual workflow dispatch

**Steps:**

1. **Checkout & Setup**
   - Checkout repository
   - Setup R (version 4.4.1)
   - Install system dependencies

2. **Install rwasm**
   - `remotes::install_github("r-wasm/rwasm")`

3. **Extract Dependencies**
   - Read DESCRIPTION file
   - Extract Imports and Suggests
   - Clean package names (remove version constraints)

4. **Build WASM Repository**
   ```r
   rwasm::make_library(
     packages = c(
       "logger", "ggplot2",           # Core dependencies
       "nanonext", "mirai", "crew",   # Async backends
       "shiny",                        # For dashboards
       "."                             # Local package
     ),
     repos = c(
       "https://cran.r-project.org",
       "https://r-lib.r-universe.dev"  # For async packages
     ),
     lib_dir = "wasm-library",
     compress = TRUE
   )
   ```

5. **Create Repository Metadata**
   - Generate PACKAGES file
   - Include version, dependencies, build info

6. **Upload Artifact**
   - Store as GitHub Actions artifact
   - Retention: 30 days

7. **Deploy to GitHub Pages**
   - Deploy to `wasm/` subdirectory
   - Available at `https://johngavin.github.io/PACKAGE/wasm/`

### Timeline Comparison

| Stage | GitHub Pages WASM | R-Universe |
|-------|-------------------|------------|
| **Trigger** | Push to main | Periodic sync |
| **Build Time** | ~3-5 minutes | ~10-20 minutes |
| **Deploy Time** | ~2-3 minutes | N/A (sync delay) |
| **Total** | **5-10 minutes** | **1-4 hours** |
| **Update Frequency** | Every push | Hourly (typical) |

## Development Workflow

### Fast Iteration Loop

1. **Make changes** to R code, vignettes, etc.
2. **Local testing**:
   ```r
   devtools::document()
   devtools::test()
   devtools::check()
   pkgdown::build_site()
   ```
3. **Push to GitHub**:
   ```r
   gert::git_add(c("R/", "vignettes/", ...))
   gert::git_commit("Feature: description")
   gert::git_push()
   ```
4. **Wait ~5-10 minutes** for GitHub Actions
5. **Test vignettes** at:
   - https://johngavin.github.io/PACKAGE/articles/dashboard.html
   - https://johngavin.github.io/PACKAGE/articles/dashboard_async.html
   - etc.
6. **Iterate** if needed (repeat steps 1-5)

### Monitoring Build Status

**GitHub Actions:**
- https://github.com/USER/PACKAGE/actions
- Look for "Build R-WASM Binary" workflow
- Green ✓ = success, red ✗ = failure

**Check Deployed WASM:**
```bash
# Check if WASM binary exists
curl -I https://johngavin.github.io/randomwalk/wasm/PACKAGES

# Download and inspect
curl https://johngavin.github.io/randomwalk/wasm/PACKAGES
```

## Hybrid Approach: Development vs Production

### For Development & Testing

**Use GitHub Pages WASM:**
- ✅ Fast feedback (5-10 minutes)
- ✅ Every push triggers build
- ✅ Test immediately after push
- ✅ Latest commits
- ❌ Single platform (WASM only)
- ❌ Not suitable for non-browser use

### For Releases & Production

**Use R-Universe:**
- ✅ Multi-platform binaries (Linux, macOS, Windows)
- ✅ Stable, tested builds
- ✅ Standard R package installation
- ✅ Long-term availability
- ❌ Slower sync (1-4 hours)
- ❌ Not immediate after push

### For Local Development

**Use git_pkgs in Nix:**
```nix
# In default.R or default-dev.nix
git_pkgs = list(
  list(
    package_name = "randomwalk",
    repo_url = "https://github.com/JohnGavin/randomwalk",
    branch_name = "main"  # Or specific commit
  )
)
```

- ✅ Immediate access to latest commits
- ✅ No build delay
- ✅ Full control over version
- ❌ Builds from source (slower initial setup)
- ❌ Requires build tools

## Troubleshooting

### Build Fails with "Package XXX not found"

**Problem**: Dependency not available in specified repos

**Solution**: Add the repo to `repos` parameter in `make_library()`:
```r
repos = c(
  "https://cran.r-project.org",
  "https://r-lib.r-universe.dev",      # For nanonext, mirai
  "https://ropensci.r-universe.dev"    # For other packages
)
```

### Vignette Can't Load Package

**Problem**: `Error: there is no package called 'PACKAGE'`

**Check**:
1. GitHub Actions workflow completed successfully?
2. WASM binary deployed to GitHub Pages?
   ```bash
   curl -I https://USER.github.io/PACKAGE/wasm/PACKAGES
   ```
3. Vignette `webr::install()` includes correct repo URL?
4. Browser console shows any errors?

### WASM Binary Out of Date

**Problem**: Vignette loads old version after recent push

**Solution**:
1. Verify GitHub Actions completed: https://github.com/USER/PACKAGE/actions
2. Clear browser cache (Ctrl+Shift+R or Cmd+Shift+R)
3. Check GitHub Pages deployed: https://USER.github.io/PACKAGE/wasm/PACKAGES
4. Wait a few minutes for CDN propagation

### Large Package Build Timeout

**Problem**: Build fails with timeout

**Solution**:
```yaml
# In .github/workflows/build-wasm.yaml
jobs:
  build-wasm:
    runs-on: ubuntu-latest
    timeout-minutes: 60  # ← Increase from default 30
```

## References

### R-WASM Tools

- **rwasm package**: https://github.com/r-wasm/rwasm
- **WebR**: https://docs.r-wasm.org/webr/latest/
- **Shinylive for R**: https://posit-dev.github.io/r-shinylive/

### R-Universe

- **Documentation**: https://r-universe.dev/
- **Build System**: https://github.com/r-universe/
- **How It Works**: https://ropensci.org/r-universe/

### Related Documentation

- See `DEPLOYMENT_QUARTO_WEBSITE.md` for pkgdown deployment
- See `AGENTS.md` for full development workflow
- See project `AGENTS.md` for project-specific requirements

## Cross-References

### To randomwalk Repository (Example Implementation)

**AGENTS.md:**
- [GitHub Actions Workflows](https://github.com/JohnGavin/randomwalk/blob/main/AGENTS.md#github-actions-workflows) - Step 7 in 9-step workflow
- [Testing Vignettes After Push](https://github.com/JohnGavin/randomwalk/blob/main/AGENTS.md#testing-vignettes-after-push) - Fast feedback loop documentation

**GitHub Actions:**
- [build-wasm.yaml](https://github.com/JohnGavin/randomwalk/blob/main/.github/workflows/build-wasm.yaml) - Full workflow implementation with rwasm
- Deployment to `https://johngavin.github.io/randomwalk/wasm/`

**Vignettes (Usage Examples):**
- [dashboard.qmd](https://github.com/JohnGavin/randomwalk/blob/main/vignettes/dashboard.qmd) - Shinylive with randomwalk package
- [dashboard_async.qmd](https://github.com/JohnGavin/randomwalk/blob/main/vignettes/dashboard_async.qmd) - Async parallel with mirai
- [dynamic_broadcasting.qmd](https://github.com/JohnGavin/randomwalk/blob/main/vignettes/dynamic_broadcasting.qmd) - Dynamic broadcasting demo
- All vignettes use `webr::install()` with three-tier repos

### From randomwalk → This Guide

**randomwalk/AGENTS.md** links back to:
- This comprehensive R-WASM workflow guide
- General agent development guidelines
- Deployment documentation

See [randomwalk/AGENTS.md § Related Documentation](https://github.com/JohnGavin/randomwalk/blob/main/AGENTS.md#related-documentation)

---

**Last Updated**: 2025-12-16
**Maintainer**: JohnGavin
**Status**: Active - To be migrated to wiki ([llm#1](https://github.com/JohnGavin/llm/issues/1))
