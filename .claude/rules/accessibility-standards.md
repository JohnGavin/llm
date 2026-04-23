# Rule: Accessibility Standards (WCAG 2.1 AA)

## Source

DSTT Ch5 (Turner, dstt.stephenturner.us/accessibility.html). WCAG 2.2, Section 508, ADA Title II (2024 DOJ rule).

## When This Applies

Any public-facing output: Shiny apps, pkgdown sites, Quarto reports/dashboards, rendered HTML, PDF deliverables.

## CRITICAL: Four Pillars (POUR)

All outputs must be Perceivable, Operable, Understandable, and Robust.

## Required Checks

### 1. Color and Contrast

| Requirement | Standard |
|-------------|----------|
| Text contrast ratio | 4.5:1 minimum (normal text), 3:1 (large text: 18pt or 14pt bold) |
| Color as sole differentiator | FORBIDDEN — combine with shape, line type, or direct labels |
| Mandatory palettes | Viridis (built into ggplot2 3.0+) or ColorBrewer (`"Dark2"`, `"Set2"`, `"YlOrRd"`, `"Blues"`) |
| Grayscale test | Print/render in grayscale; all data series must remain distinguishable |

**Verification:**
```r
# Simulate color vision deficiency
colorblindr::cvd_grid(my_plot)
```

### 2. Alt Text for Figures

| Context | Requirement |
|---------|-------------|
| Quarto figures | `fig-alt` chunk option on EVERY figure (separate from `fig-cap`) |
| Decorative images | Empty string: `fig-alt: ""` |
| Content | Describe data and meaning, not chart type: "Weekly cases peak at 2,400 in week 5" not "Bar chart showing cases" |
| Captions with data | Reference underlying tables: "See @tbl-counts for data" |

### 3. Accessible Tables

| Requirement | Detail |
|-------------|--------|
| Captions | Every table must have a caption identifying contents |
| Column headers | Descriptive names, not abbreviations |
| Merged cells | FORBIDDEN — complicates screen reader navigation |
| Layout tables | FORBIDDEN — use CSS grid/flexbox instead |
| Preferred packages | `gt` (semantic HTML markup) or `knitr::kable()` + `kableExtra` |

### 4. HTML Accessibility (axe-core)

Quarto 1.8+ integrates axe-core for automated checking:

```yaml
format:
  html:
    axe: true
```

For development, use a debug profile:

```yaml
# _quarto-debug.yml
format:
  html:
    axe:
      output: document
```

**Limitation:** axe-core detects mechanical violations (missing alt text, contrast, heading hierarchy) but cannot evaluate alt text quality — human review required.

### 5. PDF Accessibility (PDF/UA)

For PDF deliverables, enable accessibility standards:

```yaml
# Typst (preferred — better practical accessibility)
format:
  typst:
    pdf-standard: ua-1

# LaTeX
format:
  pdf:
    pdf-standard: ua-2
```

**Requirements:** `title` in YAML, `fig-alt` on every figure.

**Validation:** `quarto install verapdf` — runs automatically when `pdf-standard` is set.

**Known limitation:** LaTeX margin content (`.column-margin`, `cap-location: margin`) prevents UA-2 compliance. Typst is recommended for new accessible PDF documents.

### 6. Shiny Apps

| Requirement | Detail |
|-------------|--------|
| Keyboard navigation | All interactive elements reachable via Tab/Enter |
| ARIA labels | Dynamic content and custom widgets need `aria-label` attributes |
| Focus indicators | Visible focus rings on all interactive elements |
| Form labels | Every input must have an associated `<label>` |

## Forbidden Patterns

| Pattern | Why wrong | Fix |
|---------|-----------|-----|
| `scale_fill_manual(values = c("red", "green"))` | Red-green indistinguishable for 8% of men | Use viridis or ColorBrewer |
| Figure without `fig-alt` | Invisible to screen readers | Add descriptive `fig-alt` |
| Table with merged header cells | Screen readers lose context | Flatten headers, use `gt` |
| `axe: false` or omitting axe | No automated checking | `axe: true` in all HTML outputs |
| Pie chart with >4 slices using only color | Slices indistinguishable | Use bar chart or direct labels |

## Related

- `quarto-alt-text` skill — automated alt text generation
- `visualization-standards` rule — chart type selection
- `quarto-vignette-format` rule — vignette structure
