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

## MANDATORY: Captions on ALL Plots, Tables, and Diagrams

**Minimum 3 sentences. A 1-sentence caption is a VIOLATION.**

Every caption MUST include ALL of the following:
1. **Description**: What the plot/table/diagram shows (1 sentence)
2. **Key variables and units**: Name EVERY axis, column, or node variable with units (e.g., "X-axis: age in years. Y-axis: patient count.")
3. **Label definitions**: ALL legend labels, axis categories, color meanings, shape meanings, and abbreviations MUST be defined (e.g., "DESeq2: negative binomial GLM with apeglm shrinkage. edgeR: quasi-likelihood F-test. Red = upregulated, blue = downregulated.")
4. **Top 2-3 conclusions**: Key findings or interpretation (e.g., "Male patients outnumber female ~60:40, consistent with MM epidemiology.")
5. **Source/reference**: Data source and methodology (e.g., "Data: GDC STAR-Counts pipeline.")
6. **Cross-references**: At least ONE link to a related plot, table, section, or vignette (e.g., "See also: [Survival Analysis](survival-analysis.html) for KM curves by gender.")
7. **Glossary links**: Domain terms MUST link to [Glossary](glossary.html) definitions where applicable

### Caption Completeness Checklist (per item)

A caption is **INCOMPLETE** and blocks merge if ANY of these are missing:
- [ ] Description sentence (what it shows)
- [ ] ALL axis/column variables named with units
- [ ] ALL legend/color/shape labels defined
- [ ] 2-3 interpretation sentences (key findings)
- [ ] Data source cited
- [ ] At least 1 cross-reference link to related content
- [ ] Domain terms linked to glossary where applicable

### MANDATORY: Captions Are Pre-Computed Targets

**Captions MUST be dynamically generated from the data they describe.**
A hardcoded caption that says "N=200" when the data has 1,143 rows is a LIE.

**Required pattern:** Compute the caption text INSIDE the target that produces
the plot/table, using actual data values (row counts, p-values, medians, etc.):

```r
tar_target(vig_gender_table, {
  result <- # ... compute data ...
  DT::datatable(result, rownames = FALSE, filter = "top",
    options = list(pageLength = 15, scrollX = TRUE),
    caption = htmltools::tags$caption(
      style = "caption-side: top; text-align: left;",
      paste0(
        "Gender distribution of CoMMpass patients (N = ", nrow(result), "). ",
        "Columns: Gender, Count, Percentage. ",
        "Male patients outnumber female (~60:40). ",
        "Data: GDC clinical endpoint. ",
        "See also: survival-analysis.html for gender as Cox covariate."
      )
    )
  )
}, packages = c("DT", "htmltools"))
```

For ggplot2 plots, use `labs(caption = paste0(...))` with dynamic values.

**FORBIDDEN**: Static/hardcoded captions that don't reflect current data.
**FORBIDDEN**: Adding captions in vignette chunks (violates zero-computation rule).
**FORBIDDEN**: Relying on `safe_tar_read()` auto-wrapper for captions (it adds NONE).

### Lessons Learned (2026-03-14)

**Root cause of 40 uncaptioned tables:** Table targets returned plain `data.frame`
objects. `safe_tar_read()` auto-wrapped them in `DT::datatable(obj, rownames = FALSE)`
with NO `caption=` parameter. The rule "Every DT::datatable() MUST have caption="
was satisfied in the target code but lost during the auto-wrap fallback.

**Fix:** All table targets MUST return `DT::datatable(...)` with `caption=` baked in,
NOT plain `data.frame`. The `safe_tar_read()` auto-wrapper is a fallback for
data display only — it does NOT add captions, cross-refs, or column formatting.

**Root cause of 15 minimal plot captions:** Dynamic captions like
`paste0(gene, " expression distribution")` satisfied the "has a caption" check
but failed the 7-point completeness checklist (missing variables, units,
conclusions, cross-refs, glossary links).

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

### DT::datatable Pattern (MANDATORY for all table targets)

**ALL table targets MUST return `DT::datatable()` with `caption=`, NOT plain `data.frame`.**
The `safe_tar_read()` auto-wrapper does NOT add captions.

```r
# CORRECT: Caption baked into DT object inside the target
DT::datatable(
  data, rownames = FALSE, filter = "top",
  options = list(pageLength = 15, scrollX = TRUE),
  caption = htmltools::tags$caption(
    style = "caption-side: top; text-align: left;",
    paste0(
      "Station coverage summary (N = ", nrow(data), " stations). ",
      "Columns: Station, Start Date, End Date, Records, Completeness (%). ",
      "M2 has longest record (", max_years, " years). ",
      "Source: Marine Institute API. ",
      "See also: coverage-timeline.html for temporal view."
    )
  )
)

# WRONG: Returns data.frame — safe_tar_read wraps it WITHOUT caption
data  # DO NOT RETURN BARE DATA FRAMES
```

## Color Accessibility (MANDATORY)

- Use colorblind-safe palettes: `viridis`, `RColorBrewer::brewer.pal(n, "Set2")`, `scale_color_brewer(palette = "Dark2")`
- **NEVER** rely on red/green distinction alone
- For 2 groups: blue (#2c3e50) and orange (#e67e22)

## Caption Alignment (MANDATORY)

**ALL captions MUST be left-justified. NEVER center. No exceptions.**

This applies to:
- Plot captions (`labs(caption = ...)`)
- Table captions (`DT::datatable(..., caption = htmltools::tags$caption(style = "caption-side: top; text-align: left;", ...))`)
- Figure captions in Quarto (`fig-cap:`)
- Diagram captions (Mermaid, flowcharts)
- `htmltools::tags$caption()` — MUST include `style = "caption-side: top; text-align: left;"`
- `htmltools::tags$figcaption()` — MUST include `style = "text-align: left;"`

**CSS (pkgdown/extra.css):**
```css
caption, figcaption, .figure-caption {
  text-align: left !important;
  caption-side: top !important;
}
```

**Rationale:** Left-aligned captions are easier to scan and match academic standards. Centered captions look unprofessional in technical documents. Top placement (not bottom) ensures the caption is read before the data.

## Checklist

- [ ] Every plot has `labs(title=, subtitle=, caption=, x=, y=)` or equivalent
- [ ] Caption includes ALL 7 items: description, variables+units, label definitions, 2-3 conclusions, source, cross-refs, glossary links
- [ ] **Caption is minimum 3 sentences** (1-sentence captions are VIOLATIONS)
- [ ] **Caption is dynamically generated** from data (N=, p=, median=) inside the target — NOT hardcoded
- [ ] **Captions are left-justified (never centered)** — `text-align: left`
- [ ] **Table targets return DT::datatable with caption=** (NOT bare data.frame)
- [ ] Each graph makes an explicit comparison
- [ ] Small multiples for 4+ groups
- [ ] `theme_minimal()` or `theme_light()` base
- [ ] Y-axis starts at 0 for bar charts
- [ ] No pie charts, no dual y-axes
- [ ] Colorblind-safe palette
- [ ] Data points shown alongside summaries

See also: `visualization-diagrams` rule for Mermaid/flowchart diagram standards.
