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

### 1. Every Graph Must Make a Comparison
- **NEVER** plot a single metric in isolation
- Always show: a baseline/benchmark, multiple groups, before/after
- If you cannot identify the comparison, **do not create the graph**

### 2. Use Small Multiples for Multi-Group Comparisons
- Prefer `facet_wrap()` / `facet_grid()` over overloaded single plots
- Same scales across panels unless explicitly justified
- Small multiples > legends with 5+ categories

### 3. Maximize Data-Ink Ratio
- **Remove**: Heavy gridlines, background fills, redundant legends, 3D effects
- **Keep**: Data points, axis labels with units, reference lines
- Use `theme_minimal()` or `theme_light()` (NEVER `theme_gray()`)

### 4. Show the Data, Not Just Summaries
- Prefer `geom_point()` + `geom_smooth()` over `geom_smooth()` alone
- Never show a mean without a spread indicator (CI, SD, IQR)

### 5. NEVER Use Pie Charts
- **FORBIDDEN**, no exceptions (Cleveland & McGill, 1984)
- Use: horizontal bar chart, stacked bar, small multiples

### 6. Graphical Integrity (Lie Factor 0.95-1.05)
- Start y-axis at 0 for bar charts
- Never truncate axes without annotation
- Never use dual y-axes (create two plots)

### 7. Label Directly When Possible
- For <= 3 groups: `ggrepel::geom_text_repel()` or `annotate()`
- For > 3 groups: legend acceptable, but consider small multiples

## MANDATORY: Captions on ALL Plots and Tables

Every caption MUST include:
1. **Description**: What the plot/table shows (1 sentence)
2. **Key variables and units**: Name each axis variable and unit
3. **Top 2-3 conclusions**: Main takeaways
4. **Source/reference links**: Data source, methodology
5. **Embedded definition links**: Domain terms MUST link to definitions

### ggplot2 Pattern

```r
ggplot(data, aes(x = date, y = cost, color = provider)) +
  geom_line() +
  labs(
    title = "Daily LLM Cost by Provider",
    subtitle = "Claude dominates spend; Gemini negligible after Feb 2026",
    caption = paste(
      "Cost in USD. Tokens from ccusage + Gemini API logs.",
      "Key: Claude ~$2/day avg vs Gemini ~$0.01/day.",
      "Source: inst/extdata/ccusage_daily.json"
    ),
    x = "Date", y = "Cost (USD)"
  )
```

### plotly Pattern

```r
plot_ly(data, x = ~date, y = ~cost, type = "scatter", mode = "lines") |>
  layout(
    title = list(text = paste0(
      "Daily LLM Cost by Provider",
      "<br><sup>Claude ~$2/day avg; cost in USD. Source: ccusage_daily.json</sup>"
    )),
    xaxis = list(title = "Date"),
    yaxis = list(title = "Cost (USD)")
  )
```

### DT::datatable Pattern

```r
DT::datatable(
  data,
  caption = htmltools::tags$caption(
    style = "caption-side: bottom; text-align: left;",
    "Station coverage summary. Key: M2 has longest record. Source: Marine Institute API."
  )
)
```

## Plotly Legend and Theme Contrast (MANDATORY)

Every `plotly::layout()` call MUST include explicit background and font colors for readable legends:

```r
plotly::layout(
  ...,
  paper_bgcolor = "white",
  plot_bgcolor = "white",
  font = list(color = "#1a1a1a"),
  legend = list(..., font = list(color = "#1a1a1a"),
                bgcolor = "rgba(255,255,255,0.9)")
) |>
plotly::config(scrollZoom = TRUE)
```

Rules:
- Legend text MUST have high contrast against the plot background
- Always set `paper_bgcolor` and `plot_bgcolor` explicitly
- Always set `font = list(color = "#1a1a1a")` for dark text on light backgrounds
- Always add `plotly::config(scrollZoom = TRUE)` for interactive zoom

## Color Accessibility (MANDATORY)

- Use colorblind-safe palettes: `viridis`, `RColorBrewer::brewer.pal(n, "Set2")`, `scale_color_brewer(palette = "Dark2")`
- **NEVER** rely on red/green distinction alone
- For 2 groups: blue (#2c3e50) and orange (#e67e22)

## Checklist

- [ ] Every plot has `labs(title=, subtitle=, caption=, x=, y=)` or equivalent
- [ ] Caption includes: description, variables+units, 2-3 conclusions, source
- [ ] Each graph makes an explicit comparison
- [ ] Small multiples for 4+ groups
- [ ] `theme_minimal()` or `theme_light()` base
- [ ] Y-axis starts at 0 for bar charts
- [ ] No pie charts, no dual y-axes
- [ ] Colorblind-safe palette
- [ ] Data points shown alongside summaries
- [ ] Plotly: explicit `paper_bgcolor`, `plot_bgcolor`, `font` color set
- [ ] Plotly: legend has contrasting `font` and `bgcolor`
- [ ] Plotly: `config(scrollZoom = TRUE)` added
