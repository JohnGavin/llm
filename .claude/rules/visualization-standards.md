---
paths:
  - "R/**"
  - "vignettes/**"
  - "*.qmd"
  - "*.Rmd"
  - "inst/shiny/**"
  - "shiny/**"
---
# Visualization Standards

## Core Principles (Tufte/Gelman)

1. **Every graph makes a comparison** — never plot a single metric in isolation
2. **Small multiples** — prefer `facet_wrap()`/`facet_grid()` over 5+ category legends
3. **Maximize data-ink ratio** — remove gridlines, background fills, 3D effects; use `theme_minimal()`
4. **Show data, not just summaries** — `geom_point()` + `geom_smooth()`, never mean without spread
5. **No pie charts** — use horizontal bar, stacked bar, small multiples (Cleveland & McGill, 1984)
6. **Graphical integrity** — y-axis at 0 for bars, no truncated axes, no dual y-axes
7. **Direct labels** — `ggrepel::geom_text_repel()` for <=3 groups; legend OK for >3

## MANDATORY: Captions on ALL Plots, Tables, and Diagrams

**Minimum 3 sentences. A 1-sentence caption is a VIOLATION.**

Every caption MUST include ALL 7 items:
1. **Description**: What it shows (1 sentence)
2. **Variables and units**: Every axis/column named with units
3. **Label definitions**: All legend labels, colors, shapes, abbreviations defined
4. **2-3 conclusions**: Key findings or interpretation
5. **Source**: Data source and methodology
6. **Cross-references**: At least 1 link to related content
7. **Glossary links**: Domain terms linked to glossary where applicable

### Captions Are Pre-Computed Targets

Captions MUST be dynamically generated from data inside the target (use `nrow()`, `ncol()`, p-values). **FORBIDDEN**: hardcoded captions, captions added in vignette chunks, relying on `safe_tar_read()` auto-wrapper (adds NO caption).

**Table targets MUST return `DT::datatable()` with `caption=` baked in** — NOT bare `data.frame`. The `safe_tar_read()` auto-wrapper is a display fallback only.

### Code Patterns

**ggplot2:** `labs(caption = paste("Cost in USD.", "Source: file.json"))` with dynamic values.

**plotly:** `layout(title = list(text = paste0("Title", "<br><sup>subtitle</sup>")))`.

**DT::datatable:**
```r
DT::datatable(data, rownames = FALSE, filter = "top",
  options = list(pageLength = 15, scrollX = TRUE),
  caption = htmltools::tags$caption(
    style = "caption-side: top; text-align: left;",
    paste0("Summary (N = ", nrow(data), "). ", "Key finding. ", "Source: API.")
  ))
```

## Color Accessibility (MANDATORY)

- Colorblind-safe: `viridis`, `brewer.pal(n, "Set2")`, `scale_color_brewer(palette = "Dark2")`
- **NEVER** red/green distinction alone. For 2 groups: blue (#2c3e50) + orange (#e67e22)

## Caption Alignment (MANDATORY)

**ALL captions left-justified. NEVER center.** `caption-side: top; text-align: left;`

CSS: `caption, figcaption, .figure-caption { text-align: left !important; caption-side: top !important; }`

## Plotly Number Formatting (MANDATORY)

**ALL numbers in plotly hovertemplates MUST be rounded.** No spurious precision.

| Data type | Format | Example |
|-----------|--------|---------|
| Integer counts | `%{x:.0f}` or `%{customdata}` | 306, 1500 |
| Percentages | `%{x:.1f}%` or `%{x:.1%}` | 99.7%, 45.2% |
| Goals/rates | `%{y:.2f}` | 2.65, 1.48 |
| Elo ratings | `%{x:.0f}` | 1523, 1487 |
| Probabilities | `%{x:.1%}` | 45.2% |

**NEVER use `%{marker.size}` for N** — it shows the scaled marker size (float), not the actual count. Use `customdata = ~as.integer(n)` and `%{customdata}`.

## Checklist

- [ ] Caption has all 7 items (description, variables, labels, conclusions, source, cross-refs, glossary)
- [ ] Caption is 3+ sentences, dynamically generated, left-justified
- [ ] Table targets return data.frame (NOT DT::datatable — nix path serialization issue)
- [ ] Each graph makes a comparison; small multiples for 4+ groups
- [ ] `theme_minimal()` base; y-axis at 0 for bars; no pie charts
- [ ] Colorblind-safe palette; data points shown alongside summaries
- [ ] ALL plotly hovertemplates use rounded format specifiers (no spurious precision)
- [ ] Text labels in dotcharts use size >= 13 with jitter to avoid overlap

See also: `visualization-diagrams` for Mermaid/Plotly diagram standards.
