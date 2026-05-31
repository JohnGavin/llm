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

## Legend Position (MANDATORY — added 2026-05-31)

**ALL plots with a legend MUST place the legend at the bottom.** Reasons:
- Top-anchored legends compete with the title/caption for attention
- Right-anchored legends waste horizontal space (especially on mobile / narrow panels)
- Bottom-anchored legends read like a footnote and scale with column count

### Required pattern by library

| Library | Configuration |
|---|---|
| **ggplot2** | `theme(legend.position = "bottom")` on every plot, OR set globally via `theme_set(theme_minimal() + theme(legend.position = "bottom"))` at project start |
| **plotly** | `layout(legend = list(orientation = "h", x = 0.5, xanchor = "center", y = -0.2, yanchor = "top"))` |
| **echarts4r / e_charts** | `e_legend(orient = "horizontal", left = "center", bottom = 0)` |
| **Observable JS / ojs (Plot.plot)** | `Plot.plot({color: {legend: true, /* legend rendered above */ }, ...})` — wrap chart + legend in a `div` with custom CSS to place legend at bottom; OR use `Plot.legend({...})` separately below the chart |
| **base R** | `legend(x = "bottom", inset = c(0, -0.15), xpd = TRUE)` plus `par(mar = c(7, 4, 4, 2))` for room |
| **Vega-Lite / Altair** | `legend = {"orient": "bottom"}` |

### Allowed exception

When a chart has **only one legend entry** (single series), suppress the legend
entirely via `theme(legend.position = "none")` (ggplot) or equivalent — the
legend adds no information.

### Forbidden

| Pattern | Why wrong |
|---|---|
| `theme(legend.position = "right")` or default right-anchored | Wastes horizontal space; not consistent |
| `theme(legend.position = "top")` | Competes with title |
| Legend inside the plot area | Overlaps data |
| Different positions across plots in the same dashboard | Inconsistent reader experience |

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
- `mermaid-click-anchors` — every clickable node URL into project source must include `#L<n>`
