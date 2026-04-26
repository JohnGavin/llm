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

## Start with ggauto for Standard Charts

For standard chart types (bar, line, scatter, distribution, heatmap), start with [`ggauto`](https://github.com/nrennie/ggauto) — it auto-selects chart type from data types and applies accessible defaults:

```r
library(ggauto)
df |> ggauto(x_var)              # 1 var: raincloud plot
df |> ggauto(x_var, y_var)       # 2 vars: scatter/line/bar (auto-detected)
df |> ggauto(date, value, group) # 3 vars: coloured lines (≤6) or faceted (>6)
```

**What ggauto does automatically:** Paul Tol accessible palettes, direct labels for ≤6 categories, auto-faceting for >6, magnitude ordering (not alphabetical), symmetric axes about 0, text wrapping, sentence-case titles. Returns standard ggplot2 — add `+ labs(caption = ...)` for our mandatory captions.

**When NOT to use:** Complex custom designs, Shiny dashboards (use plotly), interactive pkgdown (use ggiraph), or when you need precise control over every visual element.

## Core Principles (Tufte/Gelman)

1. **Every graph makes a comparison** — never plot a single metric in isolation
2. **Small multiples** — prefer `facet_wrap()`/`facet_grid()` over 5+ category legends; ggauto auto-facets at >6
3. **Maximize data-ink ratio** — remove gridlines, background fills, 3D effects; use `theme_minimal()` or ggauto defaults
4. **Show data, not just summaries** — `geom_point()` + `geom_smooth()`, never mean without spread
5. **No pie charts** — use horizontal bar, stacked bar, small multiples (Cleveland & McGill, 1984)
6. **Graphical integrity** — y-axis at 0 for bars, no truncated axes, no dual y-axes
7. **Direct labels** — ggauto auto-labels ≤6 groups; for manual ggplot2, use `ggrepel` for ≤3 groups, legend for >3

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

## Interactive Plot Library Choice

| Library | Best For | Size | Syntax |
|---------|----------|------|--------|
| **plotly** | Shiny dashboards, range sliders, 3D | ~3MB | `plot_ly()` / `ggplotly()` |
| **ggiraph** | pkgdown, closeread, static sites | ~200KB | ggplot2 + `_interactive()` geoms |
| **DT** | Tables with search/filter/sort | ~500KB | `datatable()` |

Use **ggiraph** for pkgdown/closeread (smaller, CSS-styleable, hover/click built-in). Use **plotly** for Shiny (range sliders, linked brushing). See `quarto-dynamic-content` skill for closeread scrollytelling.

## Color Accessibility (MANDATORY)

- Colorblind-safe: `viridis`, `brewer.pal(n, "Set2")`, `scale_color_brewer(palette = "Dark2")`
- **NEVER** red/green distinction alone. For 2 groups: blue (#2c3e50) + orange (#e67e22)

## Caption Alignment (MANDATORY)

**ALL captions left-justified. NEVER center.** `caption-side: top; text-align: left;`

CSS: `caption, figcaption, .figure-caption { text-align: left !important; caption-side: top !important; }`

## Caption↔Table Label Consistency (MANDATORY)

Every label, acronym, or term used in a caption MUST appear verbatim in the adjacent table, plot, or diagram. Conversely, do not introduce abbreviations in captions that the reader cannot find in the visual.

| Violation | Fix |
|-----------|-----|
| Caption says "FF5+Mom" but table header says "FF Alpha" | Use the same label in both: "FF5+Mom Alpha" |
| Caption says "2 of 5 strategies" without naming them | Name them: "DRIF and Factor MAX show genuine alpha" |
| Caption uses "HAC Sharpe" but table column says "HAC t" | Match: use "HAC t-statistic" in both |

## Percentage Column Formatting (MANDATORY)

Columns containing percentages MUST:

1. **Column name includes units**: append `(%)` to the header — e.g., `Alpha (%)`, `R² (%)`
2. **Values are bare numbers**: `1.57` not `1.57%` — the unit is in the header
3. **Precision**: whole-number `round(x, 0)` for values > 10%; one decimal `round(x, 1)` for values 0.1–10%; two decimals for values < 0.1%
4. **Right-aligned**: numeric columns auto-align right in DT when values are numeric (not character with `%` suffix)

| Wrong | Right |
|-------|-------|
| `FF Alpha (ann)` with value `"166.23%"` (character) | `Alpha (%)` with value `166` (numeric) |
| `R²` with value `"5.2%"` | `R² (%)` with value `5.2` |

This prevents left-alignment bugs (character columns align left) and spurious precision.

## Column and Row Ordering (MANDATORY)

- **Columns**: Most important column on the left. For strategy comparison tables, the verdict/conclusion column comes first, then key metrics, then detail.
- **Rows**: Sort by the primary column. For verdict tables, use an ordered factor: genuine alpha → borderline → no alpha (beta). For metric tables, sort descending by the key metric.

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
