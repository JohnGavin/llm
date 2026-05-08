---
description: Core visualization standards — chart types, palettes, caption minimums
paths:
  - "R/**"
  - "vignettes/**"
  - "*.qmd"
---

# Rule: Visualization Standards (Core)

For detailed guidance (captions, Mermaid, plotly theming), invoke `visualization-detailed` skill.

## Core Principles (Tufte/Gelman)

1. **Every graph makes a comparison** — never single metric
2. **Small multiples** — `facet_wrap()` for 5+ categories
3. **Maximize data-ink** — `theme_minimal()`, no 3D
4. **Show data, not just summaries** — points + smooth
5. **NEVER pie charts. NEVER bar charts.** — Use dot plots (Cleveland)

## Color Accessibility (MANDATORY)

- **Palettes:** `viridis`, `brewer.pal(n, "Dark2")`
- **NEVER** red/green alone. For 2 groups: blue `#2c3e50` + orange `#e67e22`

## Caption Minimum

**Every figure needs 3+ sentence caption** with: what it shows, units, key findings.

1-sentence caption = VIOLATION. Use `visualization-detailed` skill for full 7-item spec.

## Number Formatting

| Type | Format |
|------|--------|
| Counts | `round(x, 0)` |
| Scores | `signif(x, 4)` |
| Percentages | `round(x, 1)` |

**15+ decimal places is FORBIDDEN.**

## Dynamic Values

**NEVER hardcode numbers in prose or captions.** Use inline R or `paste0()`.

## Related

- `accessibility` rule — contrast, alt text
- `visualization-detailed` skill — full caption spec, plotly, Mermaid
