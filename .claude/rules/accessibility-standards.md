---
name: accessibility-standards
description: Enforce WCAG 2.1 AA accessibility standards for public-facing outputs including Shiny apps, Quarto reports, and HTML deliverables
type: rule
---

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

## Mandatory Automated Checks

Rules without enforcement are decoration. Every project MUST have the following:

| Check | Where it runs | What it catches |
|---|---|---|
| `scripts/check_dark_contrast.sh` | post-render hook + pre-commit + CI | Inline `style="background:#…"` light bgs without dark-mode override. See `dark-mode-completeness` rule for full spec |
| `axe: true` in `_quarto.yml` `format: html:` | every Quarto render | WCAG mechanical violations (contrast ratio, heading order, missing labels) |
| Headless browser screenshot in both modes | CI job (Playwright/Chromium) | Runtime/JS-injected DOM that static checks miss |
| Manual visual walk in dark mode after deploy | post-deploy step | Whatever the automation missed; tabs and JS states |

**Hard gate:** any of these returning a violation BLOCKS the commit/PR. Treat equivalent in severity to `parse(_targets.R)` failing.

## Mandatory Vignette Toolbar (every vignette, every project)

Every vignette MUST include a top-of-page toolbar with three controls. This is non-negotiable: without a toggle on every page, neither developer nor user can reach dark mode to verify it, so contrast bugs ship invisibly.

| Control | Required behaviour |
|---|---|
| Dark / light toggle | **Default = ON (dark)** for first-time visitors. Persists to `localStorage` thereafter. Respects `prefers-color-scheme` only if no preference saved |
| Font A− / A+ | 2px steps. Min 8px, max effectively unbounded (96px). Persists to `localStorage`. Drives `--upload-font-size` (or a project-wide CSS var with the same role) |
| Language switch | Required only if the vignette has bilingual content (`[data-lang="…"]` blocks). Persists |

**Implementation:** ONE shared partial per project (e.g. `_includes/toolbar.html` or a child chunk) included by every `.qmd`. NEVER copy-paste the toolbar JS into multiple vignettes — that produces drift, missed dark-mode bugs in vignettes the developer forgot to update, and inconsistent UX.

**Reference implementation:** `acd_area_climate_design/vignettes/articles/upload.qmd` toolbar block.

**Verification:** post-render check that every `.qmd` either includes the shared partial, or contains the three required controls (`#dark-btn`, `#font-up-btn`, `#font-down-btn`). Missing toolbar = quality-gate −5 deduction (see `quality-gates` skill).

## Forbidden Patterns

| Pattern | Why wrong | Fix |
|---------|-----------|-----|
| `scale_fill_manual(values = c("red", "green"))` | Red-green indistinguishable for 8% of men | Use viridis or ColorBrewer |
| Figure without `fig-alt` | Invisible to screen readers | Add descriptive `fig-alt` |
| Table with merged header cells | Screen readers lose context | Flatten headers, use `gt` |
| `axe: false` or omitting axe | No automated checking | `axe: true` in all HTML outputs |
| Pie chart with >4 slices using only color | Slices indistinguishable | Use bar chart or direct labels |
| Project missing `scripts/check_dark_contrast.sh` | No regression detection | Copy canonical implementation; wire to hook/CI |
| Vignette missing dark/light toggle | User cannot reach dark mode to verify | Include shared toolbar partial |
| Per-element contrast PR (fixes only reported instance) | Leaves sibling bugs for next session | One sweep PR per audit. See `dark-mode-completeness` rule |
| Substituting `var(--card-bg)` when user said "black" | Dark-blue ≠ black | Use literal `#000000` |

## Related

- `quarto-alt-text` skill — automated alt text generation
- `visualization-standards` rule — chart type selection
- `quarto-vignette-format` rule — vignette structure
