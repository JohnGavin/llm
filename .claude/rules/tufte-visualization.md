---
paths:
  - "R/**"
  - "vignettes/**"
  - "*.qmd"
  - "*.Rmd"
  - "inst/shiny/**"
  - "shiny/**"
---
# Tufte/Gelman Visualization Principles

## 1. Every Graph Must Make a Comparison

- **NEVER** plot a single metric in isolation
- Always show: a baseline/benchmark, multiple groups, before/after
- If you cannot identify what comparison the graph makes, **do not create it**

```r
# BAD: One number over time
ggplot(data, aes(x = date, y = cost)) + geom_line()

# GOOD: Multiple providers + reference line
ggplot(data, aes(x = date, y = cost, color = provider)) +
  geom_line() +
  geom_hline(yintercept = budget_limit, linetype = "dashed", alpha = 0.5)
```

## 2. Use Small Multiples for Multi-Group Comparisons

- Prefer `facet_wrap()` / `facet_grid()` over overloaded single plots
- Same scales across panels unless explicitly justified
- Small multiples > legends with 5+ categories
- plotly: use `subplot()` with `shareY = TRUE`

## 3. Maximize Data-Ink Ratio

- **Remove**: Heavy gridlines, background fills, redundant legends, 3D effects
- **Keep**: Data points, axis labels with units, reference lines
- Use `theme_minimal()` or `theme_light()` as base
- **NEVER** use `theme_gray()` (ggplot2 default)

## 4. Show the Data, Not Just Summaries

- Prefer `geom_point()` + `geom_smooth()` over `geom_smooth()` alone
- For bar charts of means: add `geom_jitter()` or `geom_boxplot()`
- Never show a mean without a spread indicator (CI, SD, IQR)

## 5. NEVER Use Pie Charts

- **FORBIDDEN** in all projects, no exceptions
- Use instead: horizontal bar chart, stacked/grouped bar, line chart, small multiples
- Reference: Cleveland & McGill (1984) — position along common scale is most accurate

## 6. Maintain Graphical Integrity (Lie Factor 0.95-1.05)

- **ALWAYS** start y-axis at 0 for bar charts
- **NEVER** truncate axes to exaggerate differences without annotation
- **NEVER** use dual y-axes (create two separate plots instead)
- Area/size encodings must be proportional to data values

## 7. Label Directly, Not Via Legends

- For <= 3 groups: direct annotation with `ggrepel::geom_text_repel()` or `annotate()`
- For > 3 groups: legend acceptable, but consider small multiples first

## 8. Revise and Edit

- First-draft plots are never final
- After creating a plot, ask: "What comparison does this enable?"
- Every plot in a PR should be reviewed for clarity

## Checklist

- [ ] Every plot has `labs(title=, subtitle=, caption=, x=, y=)` or equivalent
- [ ] Every table has `caption=` argument
- [ ] Caption includes: description, variables+units, 2-3 conclusions, source
- [ ] Domain terms link to definitions
- [ ] Each graph makes an explicit comparison
- [ ] Small multiples for 4+ groups
- [ ] `theme_minimal()` or `theme_light()` base
- [ ] Y-axis starts at 0 for bar charts
- [ ] No pie charts, no dual y-axes
- [ ] Colorblind-safe palette
- [ ] Axes labeled with units
- [ ] Data points shown alongside summaries
