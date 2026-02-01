# Vignette Code Folding Requirements

## Description

MANDATORY standards for code display and user experience in R package vignettes. This skill ensures consistent, professional presentation of vignette content while allowing users to explore code when needed.

## Purpose

Use this skill when:
- Creating or updating R package vignettes (Quarto, R Markdown, HTML)
- Building package documentation websites with pkgdown
- Writing educational materials with code examples
- Designing interactive tutorials
- Ensuring compliance with package documentation standards

## MANDATORY Code Folding Rules

**CRITICAL: UNIVERSAL REQUIREMENTS FOR ALL R PACKAGE VIGNETTES**

These rules apply to EVERY R package project, NO EXCEPTIONS:

1. **ALL vignettes MUST have `code-fold: true`** in YAML header
2. **ALL vignettes MUST have `code-summary: "Show code"`** in YAML header
3. These settings are NON-NEGOTIABLE across all projects

### RULE 1: Code Folding Enabled (REQUIRED)

**All code chunks in ALL vignettes must support code folding.**

#### For Quarto Vignettes (.qmd)

```yaml
---
title: "Your Vignette Title"
format:
  html:
    code-fold: true              # MANDATORY: Hide code by default (EVERY vignette, EVERY project)
    code-summary: "Show code"    # MANDATORY: Standard button text (EVERY vignette, EVERY project)
    code-tools: true             # Optional: Add copy/view buttons
---
```

**NO EXCEPTIONS:** Every vignette in every R package project must include both `code-fold: true` and `code-summary: "Show code"`.

#### For R Markdown Vignettes (.Rmd)

Add to your vignette YAML header:

```yaml
---
title: "Your Vignette Title"
output:
  html_document:
    code_folding: hide   # MANDATORY: Hide code by default
---
```

And in your first code chunk:

```{r setup, include=FALSE}
knitr::opts_chunk$set(
  code_folding = "hide",  # Hide code by default
  echo = TRUE,            # Show code when expanded
  message = FALSE,
  warning = FALSE,
  collapse = TRUE,
  comment = "#>"
)
```

### RULE 2: All Outputs Must Display (REQUIRED)

**Every code chunk that produces output (graphs, tables, text) must show the output.**

#### Correct: Show Output

```{r load-data}
# This code loads data
data <- read.csv("data.csv")
# Output will be shown
head(data)
```

```{r plot-example}
# Code is hidden by default, but plot ALWAYS shows
library(ggplot2)
ggplot(data, aes(x = var1, y = var2)) +
  geom_point() +
  theme_minimal()
# Plot is ALWAYS visible to users
```

#### Correct: Table Output Always Visible

```{r summary-table}
library(knitr)
summary_stats <- data.frame(
  Variable = names(data),
  Mean = colMeans(data),
  SD = apply(data, 2, sd)
)
kable(summary_table, digits = 2)
# Table is ALWAYS visible to users
```

#### INCORRECT: Hiding Outputs

```{r hidden-plot, echo=FALSE, results='hide'}
# WRONG! Plot won't display
plot(data)
```

```{r silent-compute, include=FALSE}
# WRONG! Results are hidden
x <- mean(data$var1)
```

### RULE 3: Default Code Hidden (REQUIRED)

**Code must be hidden by default. Users click "Show code" to see implementation.**

#### Correct Implementation

```yaml
---
format:
  html:
    code-fold: true  # Code hidden by default
---
```

Result: Users see narrative and outputs first. Code is accessible via collapsible section.

#### INCORRECT Implementation

```yaml
---
format:
  html:
    code-fold: false  # WRONG! Code always visible
---
```

Result: Code clutters the reading experience.

### RULE 4: Selective Code Display (OPTIONAL)

**In specific cases, you may show code by default for a chunk:**

```{r key-function, code-fold=false}
# This is essential code users MUST see
# Use only for critical examples
library(package)
essential_function()
```

**When to use `code-fold=false`:**
- Core tutorial examples where understanding implementation is the goal
- Step-by-step walkthroughs with minimal code
- API usage demonstrations

**Default behavior:** All chunks should use document-level `code-fold: true` setting

### RULE 5: Output Display Control (REQUIRED)

**Always display outputs using correct options:**

#### For Graphs/Plots (ALWAYS SHOW)

```{r plot-name}
# Code: hidden by default
# Output: ALWAYS shows

library(ggplot2)
ggplot(mtcars, aes(x = wt, y = mpg)) +
  geom_point() +
  labs(title = "Weight vs MPG")
# Plot displays automatically
```

#### For Tables (ALWAYS SHOW)

```{r table-name}
# Code: hidden by default
# Output: ALWAYS shows

library(knitr)
summary_table <- data.frame(
  Metric = c("Mean", "SD", "N"),
  Value = c(23.5, 6.0, 32)
)
kable(summary_table)
# Table displays automatically
```

#### For Console Output (Show/Hide as Needed)

```{r analysis-results}
# Show console results
mean_value <- mean(data$x)
print(paste("Mean:", round(mean_value, 2)))
# Output: Shows with results
```

```{r silent-calc, results='hide'}
# Hide intermediate calculations
temp <- complex_calculation()
# No console output shown
```

### RULE 6: Code Folding in GitHub/pkgdown Display (REQUIRED)

**Code folding works consistently across:**

- GitHub README (if vignette is rendered as HTML)
- pkgdown website articles
- Local HTML builds
- Quarto Dashboards

#### Verification Checklist

After adding code folding to a vignette:

1. Render locally: `quarto render` or `devtools::build_vignettes()`
2. Open in browser: Look for "Show code" button
3. Click button: Code should expand/collapse smoothly
4. Check outputs: All graphs, tables, and results display
5. Test in pkgdown: `pkgdown::build_site()`
6. Verify on GitHub: Rendered vignette displays correctly

## Best Practices

### 1. Structure Narrative First

```yaml
---
format:
  html:
    code-fold: true
---

# Users see this first
## Introduction

This vignette demonstrates...

## Key Concepts

Explanation of what you'll learn.

## Analysis

[Visible outputs]

Click "Show code" to see the implementation.
```

### 2. Label Chunks Meaningfully

```{r bad-name}
# Unclear what this does
x <- mean(data)
```

```{r calculate-average-height}
# Clear, descriptive name
avg_height <- mean(data$height)
```

### 3. Use Code Descriptions

Quarto supports code block titles:

```{r}
#| code-fold: true
#| code-summary: "Load and explore data"

library(readr)
data <- read_csv("dataset.csv")
str(data)
```

### 4. Group Related Code

```{r setup-libraries}
library(ggplot2)
library(dplyr)
library(tidyr)
```

```{r prepare-data}
clean_data <- data %>%
  filter(!is.na(value)) %>%
  mutate(group = factor(group))
```

### 5. Separate Computation from Display

```{r compute-summary}
# Computation code (hidden)
summary_stats <- data %>%
  group_by(group) %>%
  summarise(mean = mean(value))
```

```{r display-summary}
# Display code (hidden)
knitr::kable(summary_stats)
```

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

## Standards Summary

| Aspect | Requirement | Default | Applies To |
|--------|-------------|---------|------------|
| Code Display | All code must support folding | Hidden | EVERY vignette |
| Code Folding | MANDATORY in document YAML | `code-fold: true` | EVERY project |
| Code Summary | MANDATORY button text | `code-summary: "Show code"` | EVERY project |
| Outputs | ALWAYS show | Visible by default | All vignettes |
| User Experience | Hide implementation details | Click to reveal | Universal |
| Platform Support | Works everywhere | Quarto + Rmd | All platforms |
| Accessibility | Semantic HTML | Browser controls | All browsers |

**REMINDER:** The code-fold and code-summary settings are UNIVERSAL requirements. NO package is exempt.

## Resources

- [Quarto Code Folding](https://quarto.org/docs/output-formats/html-code.html#code-folding)
- [R Markdown Code Folding](https://bookdown.org/yihui/rmarkdown/html-document.html#code-folding)
- [pkgdown Articles](https://pkgdown.r-lib.org/articles/articles.html)
- [Vignette Best Practices](https://cran.r-project.org/web/packages/knitr/vignettes/knit_print.html)
