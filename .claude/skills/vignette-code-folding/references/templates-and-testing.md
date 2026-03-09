# Vignette Templates, Troubleshooting, and Testing

Extracted from SKILL.md. Contains complete templates, integration workflow, and testing guidance.

## Complete Vignette Template

### Quarto Template (.qmd)

```yaml
---
title: "Package Feature: Your Feature Name"
description: "Describes what users will learn"
format:
  html:
    code-fold: true
    code-summary: "Show code"
    code-tools:
      source: https://github.com/your-repo/blob/main/vignettes/feature-name.qmd
    toc: true
    toc-depth: 2
    theme: default
---

# Introduction

Start with narrative explanation of the feature.

## Setup

```{r setup}
#| code-fold: false
#| message: false

library(yourpackage)
library(ggplot2)
library(dplyr)
```

## Key Concept

Explain what users will learn.

```{r demonstration}
# Code for demonstration
result <- your_function(data)

# Visualization or output
plot(result)
```

## Real-World Example

```{r real-example}
# Full working example
# Code hidden by default
# Output always visible

data <- your_package::sample_data
summary <- analyze_data(data)
visualize_summary(summary)
```

## Further Reading

- [Package Reference](reference.html)
- [Other Vignettes](articles.html)
```

### R Markdown Template (.Rmd)

```r
---
title: "Package Feature: Your Feature Name"
output: rmarkdown::html_vignette
vignette: >
  %\VignetteIndexEntry{Your Feature Name}
  %\VignetteEngine{knitr::rmarkdown}
  %\VignetteEncoding{UTF-8}
---

```{r setup, include=FALSE}
knitr::opts_chunk$set(
  code_folding = "hide",
  echo = TRUE,
  message = FALSE,
  warning = FALSE,
  collapse = TRUE,
  comment = "#>",
  fig.width = 7,
  fig.height = 5,
  fig.align = "center"
)
```

# Introduction

Start with narrative explanation.

## Example

```{r example}
library(yourpackage)
result <- your_function(data)
plot(result)
```

## More Examples

```{r more}
# More demonstration code
```
```

## Troubleshooting

### Code Folding Not Working

**Problem:** "Show code" button doesn't appear

**Solutions:**
1. Verify YAML format (check for indentation)
2. Ensure `code-fold: true` is set in format section
3. Clear cache: `rm -rf .quarto/ _quarto_cache/`
4. Re-render: `quarto render vignette.qmd`

### Outputs Hidden

**Problem:** Plots or tables don't display

**Solutions:**
1. Check for `echo=FALSE` without output specification
2. Verify `results='hide'` not accidentally set
3. For plots: ensure `print()` is called for ggplot objects
4. For tables: use `knitr::kable()` or similar

### Inconsistent Display Across Platforms

**Problem:** Code folding works in browser but not on GitHub

**Solutions:**
1. Render HTML locally and check display
2. Ensure Quarto version is current
3. Use `quarto check` to verify setup
4. For GitHub display: Use raw HTML in README

## Integration with Package Workflow

### Step 1: Create Vignette with Code Folding

Use the templates above.

### Step 2: Build and Test Locally

```bash
# In Nix shell
Rscript -e "devtools::build_vignettes()"
# OR
quarto render vignettes/your-vignette.qmd
```

### Step 3: Verify Display

```bash
# Open in browser
open doc/your-vignette.html
# or
open vignettes/your-vignette.html
```

### Step 4: Include in pkgdown

Update `_pkgdown.yml`:

```yaml
articles:
  - title: "Guides"
    contents:
      - your-vignette
```

### Step 5: Build Website

```bash
pkgdown::build_site()
```

## Testing Code Folding

### Automated Test

Create `tests/test-vignettes.R`:

```r
test_that("vignette html contains code-fold", {
  # Build vignette
  devtools::build_vignettes()

  # Read generated HTML
  html <- readLines("doc/your-vignette.html")
  html_text <- paste(html, collapse = "\n")

  # Check for folding indicators
  expect_true(grepl("code-fold", html_text) ||
              grepl("Show code", html_text))
})
```

### Manual Verification Checklist

For each vignette:

- [ ] "Show code" button visible
- [ ] Code hidden by default
- [ ] All plots/tables display correctly
- [ ] Click button expands code
- [ ] Click again collapses code
- [ ] No JavaScript errors in console
- [ ] Works in latest Chrome/Firefox
- [ ] pkgdown site displays correctly
- [ ] GitHub renders HTML properly
