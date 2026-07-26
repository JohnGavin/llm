---
description: Core visualization standards — chart types, palettes, caption minimums
paths:
  - "R/**"
  - "vignettes/**"
  - "*.qmd"
  - "app*.R"
  - "ui.R"
  - "server.R"
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

## Plotly Dark Theming (MANDATORY for any dark-themed app)

Every `plotly::layout(...)` call in an app/vignette using a dark theme (bslib
`bootswatch = "darkly"`, dark mode toggles, etc.) MUST set
`paper_bgcolor = "#000000", plot_bgcolor = "#000000", font = list(color = "#ffffff")`
(plus `plotly::config(scrollZoom = TRUE)`). Plotly defaults to a **white**
canvas regardless of the page theme — an unthemed plot inside a dark page
renders a bright white rectangle, and any marker colour picked to be visible
against black (e.g. medium grey `#6c757d`) instead reads as near-invisible
against that unthemed white background.

**Recognise this defect from its symptom, not just by reading code:** a
chart, or occasionally a whole tab, that "looks blank/wrong in one browser
but fine in another" is the pattern this produces — check for missing
`paper_bgcolor`/`plot_bgcolor`/`font` on every `renderPlotly`/`plot_ly()`
call BEFORE chasing a browser-specific JS theory. See `visualization-detailed`
skill's "Plotly Theming" section for the audit grep pattern and full writeup
(origin: mycare dashboard incident, 2026-07-26 — reported as Chrome-only
blank tabs; confirmed defect was missing theming on every plot in the app,
found while investigating, though the causal link to the Chrome symptom was
never proven via a captured console error).

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
