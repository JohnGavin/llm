# WebR Multi-Page Vignettes

## Purpose
Create interactive, multi-page vignettes with WebR for browser-based R execution without requiring local R installation.

## When to Use
- Building package documentation with interactive examples
- Creating educational materials with live code
- Deploying R tutorials that run entirely in the browser
- Converting long vignettes into dashboard-style multi-page documents

## Core Requirements

### 1. Package Compilation (MANDATORY - NO EXCEPTIONS)

**CRITICAL: UNIVERSAL WEBR REQUIREMENTS**

These rules apply to ALL WebR implementations, NO EXCEPTIONS:

1. **Packages MUST be compiled to WebAssembly** using r-wasm/actions
2. **NEVER use manual function definitions as a workaround**
3. **NEVER copy/paste function code into vignettes**
4. **ALWAYS use proper package loading with `library()`**

**Why This Matters:**
- Manual definitions break when functions change
- No access to internal package functions
- S3/S4 methods won't work
- Dependencies won't load correctly
- Creates maintenance nightmare

**The ONLY Correct Approach:**
Compile your package to WebAssembly using r-wasm/actions GitHub workflow.

```yaml
# .github/workflows/webr-build.yml
jobs:
  deploy-cran-repo:
    uses: r-wasm/actions/.github/workflows/deploy-cran-repo.yml@v2
    with:
      packages: |
        .
```

This workflow:
- Compiles your R package to WebAssembly
- Creates a CRAN-like repository
- Deploys to GitHub Pages under `/webr-packages`

### 2. Vignette Configuration

```yaml
---
title: "Interactive Tutorial"
format:
  html:
    code-fold: true
    code-tools: true
    toc: true
    page-layout: custom
filters:
  - quarto-webr
webr:
  packages: ['your-package']
  autoload-packages: true
  repos:
    - https://username.github.io/repo/webr-packages
    - https://repo.r-wasm.org
---
```

### 3. Multi-Page Structure

Split long vignettes into logical sections:

```yaml
# _quarto.yml for multi-page vignettes
project:
  type: website

website:
  title: "Package Tutorial"
  navbar:
    left:
      - text: "Overview"
        href: index.qmd
      - text: "Getting Started"
        href: getting-started.qmd
      - text: "Examples"
        menu:
          - text: "Basic Usage"
            href: examples-basic.qmd
          - text: "Advanced Topics"
            href: examples-advanced.qmd
      - text: "Reference"
        href: reference.qmd
```

### 4. Page Content Structure

Each page should be focused and concise:

```markdown
# getting-started.qmd
---
title: "Getting Started"
---

## Installation {.unnumbered}

The package is automatically loaded in this WebR environment:

\`\`\`{webr-r}
library(your-package)
packageVersion("your-package")
\`\`\`

## First Steps

[Interactive example here...]

:::{.callout-tip}
## Next Steps
Continue to [Basic Examples](examples-basic.qmd)
:::
```

## Implementation Checklist

**MANDATORY Steps (NO shortcuts allowed):**

- [ ] **Set up r-wasm/actions GitHub workflow** (REQUIRED - no manual compilation)
- [ ] **Verify package compiles to WebAssembly** (Check workflow succeeds)
- [ ] **Configure vignette YAML with WebR repos** (Point to your GitHub Pages)
- [ ] Split content into logical pages (max 300 lines per page)
- [ ] Add navigation between pages
- [ ] **Use `library()` ONLY - NEVER manual function definitions** (FORBIDDEN)
- [ ] Test in browser with WebR extension
- [ ] Deploy to GitHub Pages
- [ ] **Verify package loads with `library()` in browser** (Must work or deployment fails)

**CRITICAL:** Steps marked in bold are non-negotiable. Manual function definitions are FORBIDDEN.

## Common Pitfalls

### ❌ WRONG: Manual Function Definitions (FORBIDDEN)

**NEVER DO THIS:**
```r
# Since package not on CRAN, define functions manually
mills_ratio <- function(x) {
  # Function body copied from source
}

# WRONG! This approach is:
# - Unmaintainable (functions change)
# - Incomplete (missing internals)
# - Broken (no methods, no dependencies)
# - FORBIDDEN in all WebR projects
```

**Why manual definitions fail:**
- No access to package internals (non-exported functions)
- S3/S4 methods won't register correctly
- Package dependencies won't load
- Data objects unavailable
- Namespace collisions
- Breaks when package updates

### ✅ CORRECT: Load from WebR Repository

**ALWAYS DO THIS:**
```r
library(millsratio)
# All functions available from properly compiled package
# - Full API access
# - All methods registered
# - Dependencies loaded
# - Data objects available
# - Updates automatically with package
```

### ❌ WRONG: Skipping r-wasm/actions

**NEVER skip the compilation step:**
- "I'll just manually define the functions for now" ← NO
- "Let me test without the WebR build first" ← NO
- "Can I use shinylive without compiling?" ← NO

**ALWAYS use r-wasm/actions workflow:**
- Proper WebAssembly compilation
- CRAN-like repository structure
- GitHub Pages deployment
- Automatic dependency resolution

## Critical: The munsell/ggplot2 Issue (MANDATORY FIX)

### ⚠️ Known WebR Issue: ggplot2 Fails Due to Missing munsell

**THE PROBLEM:** As of Jan 2025, ggplot2 in WebR fails with:
```
preload error: there is no package called 'munsell'
preload error: Error: package 'ggplot2' could not be loaded
```

**THE FIX:** Explicitly install munsell BEFORE ggplot2:

### ✅ CORRECT Pattern (from irishbuoys project):
```r
# In WebR/Shinylive setup:
webr::install("munsell", repos = "https://repo.r-wasm.org")
webr::install("ggplot2", repos = "https://repo.r-wasm.org")
library(ggplot2)  # NOW it works!
```

### Alternative: Use Base R or Other Packages
```r
# Instead of ggplot2, use:
plot()      # Base R plotting
plotly::plot_ly()  # Interactive plots (works without munsell)
```

### ❌ WRONG Assumptions:
- "WebR automatically bundles dependencies" ← FALSE
- "Shinylive 0.8.0+ fixes this" ← FALSE
- "Just library(ggplot2) works" ← FALSE

**ALWAYS TEST IN BROWSER:** Deploy and check F12 console for munsell errors

### ❌ WRONG: Single Long Page
- 1000+ line vignettes are hard to navigate
- Slow to render and interact with
- Poor mobile experience

### ✅ CORRECT: Multi-Page Dashboard
- Each topic on separate page
- Clear navigation structure
- Fast loading and interaction
- Mobile-friendly

## Cachix Integration

Include in your 9-step workflow:

```bash
# Step 5: Push to Cachix
../push_to_cachix.sh

# Creates reproducible environment
# Speeds up CI builds
# Ensures consistency across machines
```

## Testing WebR Vignettes

1. **Local Testing**
   ```bash
   quarto preview vignettes/
   # Opens browser with live reload
   ```

2. **WebR Console Testing**
   - F12 to open browser console
   - Check for package loading errors
   - Verify all functions available

3. **GitHub Pages Testing**
   - Push to gh-pages branch
   - Check https://username.github.io/repo/
   - Test on mobile devices

## Advanced Features

### Auto-Running Setup Code
```yaml
\`\`\`{webr-r}
#| autorun: true
# This runs automatically when page loads
library(required-packages)
\`\`\`
```

### Progress Indicators
```yaml
webr:
  show-startup-message: true
  show-header-message: true
```

### Custom Repository Priority
```yaml
webr:
  repos:
    - https://custom-repo.com  # Checked first
    - https://repo.r-wasm.org  # Fallback
```

## References
- [WebR Documentation](https://docs.r-wasm.org/webr/latest/)
- [quarto-webr Extension](https://quarto-webr.thecoatlessprofessor.com/)
- [r-wasm/actions](https://github.com/r-wasm/actions)
- [Building R Packages for WebR](https://docs.r-wasm.org/webr/latest/building.html)

## Standards Summary

| Aspect | Requirement | NEVER Do | ALWAYS Do |
|--------|-------------|----------|-----------|
| Package Loading | WebAssembly compilation | Manual function definitions | r-wasm/actions workflow |
| Function Access | library() call | Copy/paste code | Proper package import |
| Dependencies | Automatic via WASM | Skip compilation step | Full package build |
| Maintenance | Package updates | Hardcoded functions | Repository references |
| Testing | Browser verification | Assume it works | Test library() loads |

**REMINDER:** Manual function definitions are FORBIDDEN in WebR. NO exceptions. NO shortcuts. NO workarounds.

## Related Skills
- `pkgdown-deployment` - For static documentation
- `shinylive-quarto` - For Shiny apps in browser
- `ci-workflows-github-actions` - For automation
- `r-package-workflow` - For package development
- `vignette-code-folding` - For code display standards (MANDATORY: code-fold: true)