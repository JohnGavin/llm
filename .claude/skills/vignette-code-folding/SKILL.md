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

Every code chunk that produces output (graphs, tables, text) must show the output. Never use `echo=FALSE` with `results='hide'` or `include=FALSE` on output-producing chunks.

See [code-examples-and-rules.md](references/code-examples-and-rules.md) for correct and incorrect examples.

### RULE 3: Default Code Hidden (REQUIRED)

Code must be hidden by default. Users click "Show code" to see implementation. Use `code-fold: true` in YAML; never `code-fold: false`.

See [code-examples-and-rules.md](references/code-examples-and-rules.md) for correct and incorrect YAML examples.

### RULE 4: Selective Code Display (OPTIONAL)

Use `code-fold=false` on individual chunks only for:
- Core tutorial examples where understanding implementation is the goal
- Step-by-step walkthroughs with minimal code
- API usage demonstrations

All other chunks use the document-level `code-fold: true` setting.

See [code-examples-and-rules.md](references/code-examples-and-rules.md) for examples.

### RULE 5: Output Display Control (REQUIRED)

- **Graphs/Plots:** ALWAYS show (no `results='hide'`)
- **Tables:** ALWAYS show (use `knitr::kable()` or similar)
- **Console output:** Show for results, hide for intermediate calculations with `results='hide'`

See [code-examples-and-rules.md](references/code-examples-and-rules.md) for detailed examples.

### RULE 6: Cross-Platform Consistency (REQUIRED)

Code folding must work across GitHub README, pkgdown articles, local HTML builds, and Quarto Dashboards.

**Verification steps:** render locally, check "Show code" button, verify outputs display, test in pkgdown, verify on GitHub.

See [code-examples-and-rules.md](references/code-examples-and-rules.md) for the full verification checklist.

## Best Practices

1. **Structure narrative first** -- users see explanations and outputs before code
2. **Label chunks meaningfully** -- use descriptive names like `calculate-average-height`, not `chunk1`
3. **Use code descriptions** -- Quarto `#| code-summary: "Load and explore data"` for per-chunk labels
4. **Group related code** -- separate setup, data prep, analysis, and display into logical chunks
5. **Separate computation from display** -- one chunk computes, next chunk renders output

See [code-examples-and-rules.md](references/code-examples-and-rules.md) for detailed examples of each practice.

## Complete Vignette Templates

Full Quarto (.qmd) and R Markdown (.Rmd) templates are available in [templates-and-testing.md](references/templates-and-testing.md).

## Troubleshooting

Common issues and solutions for code folding not working, hidden outputs, and inconsistent cross-platform display.

See [templates-and-testing.md](references/templates-and-testing.md) for detailed troubleshooting guidance.

## Integration with Package Workflow

Steps: (1) Create vignette with code folding using templates, (2) Build and test locally, (3) Verify display in browser, (4) Include in `_pkgdown.yml`, (5) Build website with `pkgdown::build_site()`.

See [templates-and-testing.md](references/templates-and-testing.md) for commands and configuration details.

## Testing Code Folding

Automated tests and manual verification checklists for ensuring code folding works correctly.

See [templates-and-testing.md](references/templates-and-testing.md) for the test code and checklist.

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
