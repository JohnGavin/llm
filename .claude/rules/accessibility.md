---
description: WCAG 2.1 AA accessibility + dark mode completeness for all public-facing outputs
paths:
  - "**/*.qmd"
  - "vignettes/**"
  - "dashboard/**"
  - "docs/**"
  - "**/*.css"
  - "**/*.scss"
---

# Rule: Accessibility Standards

Consolidated from: `accessibility-standards`, `dark-mode-completeness`.

Source: DSTT Ch5 (Turner). WCAG 2.2, Section 508.

---

## Part 1: WCAG 2.1 AA Requirements

### Four Pillars (POUR)

All outputs must be Perceivable, Operable, Understandable, and Robust.

### Color and Contrast

| Requirement | Standard |
|-------------|----------|
| Text contrast ratio | 4.5:1 minimum (normal), 3:1 (large: 18pt or 14pt bold) |
| Color as sole differentiator | FORBIDDEN — combine with shape, line type, or labels |
| Mandatory palettes | Viridis or ColorBrewer (`"Dark2"`, `"Set2"`) |

### Alt Text

| Context | Requirement |
|---------|-------------|
| Quarto figures | `fig-alt` on EVERY figure (separate from `fig-cap`) |
| Content | Describe data: "Peak at 2,400 in week 5" NOT "Bar chart showing cases" |

### Accessible Tables

- Every table has caption
- No merged cells (screen reader issue)
- Use `gt` or `DT::datatable()`

### HTML Accessibility

```yaml
format:
  html:
    axe: true  # MANDATORY
```

### Shiny Apps

- Keyboard navigation via Tab/Enter
- ARIA labels on dynamic content
- Visible focus rings
- Labels on all inputs

---

## Part 2: Dark Mode Completeness

### Clause 0: `color-scheme: dark` is mandatory (supersedes all other clauses)

Every dark-mode dashboard/vignette MUST include BOTH:

```html
<meta name="color-scheme" content="dark" />
```

```css
:root, html, body { color-scheme: dark; }
```

Without this, **Chrome's "Auto Dark Mode for Web Contents" (default-on
since v96, late 2021)** mis-classifies intentionally-dark pages as light
and silently inverts the page's lightness — black backgrounds → white,
deep palettes → pastels, in plots, tables AND diagrams. Safari/Edge/Brave
are unaffected, so the breakage is Chrome-only and easy to miss.

Worked example (premortem issue 0027): **5 merged iterations** fixed the
wrong layer (mermaid theme override, CSS catch-all, vendored mermaid 10,
per-diagram `%%{init}%%`, http-server workaround) before the meta tag was
identified as the root cause. Check this clause FIRST, before any other
dark-mode debugging.

Verification: `~/.claude/scripts/check_dashboard_color_scheme.sh <dir>`
(greps every rendered HTML for both signals; exit 1 on any miss). Wire it
into the project's Quarto `post-render` alongside `check_dark_contrast.sh`.
See llm#584.

### CRITICAL: Black = `#000000`. White = `#ffffff`.

`var(--card-bg)`, `#16213e`, `#1a1a2e` are NOT black. They are dark blue.

### Clause 1: Inline `style=` requires `!important`

```css
/* RIGHT */
body.dark-mode #element {
  background: #000000 !important;
  color: #ffffff !important;
}
```

### Clause 2: Audit, don't patch

When ONE contrast bug is reported:
1. Run `check_dark_contrast.sh`
2. Fix ALL uncovered elements in same commit

Per-element commits are a process violation.

### Clause 3: Catch-all selector required

```css
body.dark-mode [style*="background:#fff"],
body.dark-mode [style*="background:#f8"]
{ background: #000000 !important; color: #ffffff !important; }
```

### Clause 4: Verification gate

No CSS/qmd commit without `check_dark_contrast.sh` exit 0.

### Clause 5: Single global script

Script at `~/docs_gh/llm/.claude/scripts/check_dark_contrast.sh`. Projects reference by absolute path — NEVER copy per-project.

### Dark-Mode Replacement Palette

| Light hex | Dark pair (≥4.5:1 on `#000`) |
|---|---|
| `#198754` (success) | `#69d4a0` |
| `#dc3545` (danger) | `#f08080` |
| `#0dcaf0` (cyan) | `#5edaff` |
| `#0d6efd` (primary) | `#4ea8de` |

---

## Part 3: Mandatory Vignette Toolbar

Every vignette MUST have toolbar with:

| Control | Behavior |
|---------|----------|
| Dark/light toggle | Default dark, persists to localStorage |
| Font A−/A+ | 2px steps, persists |
| Language switch | Only if bilingual |

ONE shared partial per project.

---

## Forbidden Patterns

| Pattern | Fix |
|---------|-----|
| `scale_fill_manual(c("red", "green"))` | Use viridis |
| Figure without `fig-alt` | Add descriptive alt text |
| `var(--card-bg)` when user said "black" | Use `#000000` |
| Per-element contrast fix | Sweep PR with full audit |
| Vignette missing dark toggle | Include shared toolbar |

---

## Related

- `visualization` — chart contrast, captions
- `quarto-vignettes` — vignette structure
