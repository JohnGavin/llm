# WebR Multi-Page Vignettes

## Purpose
Create interactive, multi-page vignettes with WebR for browser-based R execution without requiring local R installation.

## When to Use
- Building package documentation with interactive examples
- Creating educational materials with live code
- Deploying R tutorials that run entirely in the browser
- Converting long vignettes into dashboard-style multi-page documents

## Core Requirements

### 1. Package Compilation (MANDATORY)
**NEVER manually define functions in WebR vignettes.** Always compile packages to WebAssembly.

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

- [ ] Set up GitHub Actions for WebR compilation
- [ ] Configure vignette YAML with WebR repos
- [ ] Split content into logical pages (max 300 lines per page)
- [ ] Add navigation between pages
- [ ] Use `library()` not manual function definitions
- [ ] Test in browser with WebR extension
- [ ] Deploy to GitHub Pages

## Common Pitfalls

### ❌ WRONG: Manual Function Definitions
```r
# Since package not on CRAN, define functions
mills_ratio <- function(x) { ... }
```

### ✅ CORRECT: Load from WebR Repository
```r
library(millsratio)
# All functions available from compiled package
```

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

## Related Skills
- `pkgdown-deployment` - For static documentation
- `shinylive-quarto` - For Shiny apps in browser
- `ci-workflows-github-actions` - For automation
- `r-package-workflow` - For package development