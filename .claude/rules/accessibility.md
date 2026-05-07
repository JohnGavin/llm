---
description: WCAG 2.1 AA accessibility + dark mode completeness for all public-facing outputs
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
