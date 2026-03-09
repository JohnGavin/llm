---
paths:
  - "R/**"
  - "vignettes/**"
  - "*.qmd"
  - "*.Rmd"
  - "inst/shiny/**"
  - "shiny/**"
---
# Plot & Table Caption Standards

## Core Principle: Graphs Are Comparisons

Every graph must answer: **"Compared to what?"**
(Gelman, via Tufte: "Numbers are meaningful only in relation to other numbers.")

## MANDATORY: Captions on ALL Plots and Tables

Every caption MUST include:
1. **Description**: What the plot/table shows (1 sentence)
2. **Key variables and units**: Name each axis variable and unit
3. **Top 2-3 conclusions**: Main takeaways
4. **Source/reference links**: Data source, methodology
5. **Embedded definition links**: Domain terms MUST link to definitions

### ggplot2 Pattern

```r
ggplot(data, aes(x = date, y = cost)) +
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
    "Station coverage summary. Rows = monitoring stations. ",
    "Key: M2 has longest continuous record (2003-present). ",
    "Source: Marine Institute API."
  )
)
```

### knitr Chunk Headers

````
```{r fig-daily-cost, fig.cap="Daily LLM cost (USD) by provider. Claude ~$2/day vs Gemini ~$0.01/day. Source: ccusage logs."}
```
````

## Color Accessibility (MANDATORY)

- Use colorblind-safe palettes: `viridis`, `RColorBrewer::brewer.pal(n, "Set2")`, or `scale_color_brewer(palette = "Dark2")`
- **NEVER** rely on red/green distinction alone
- For 2 groups: blue (#2c3e50) and orange (#e67e22)
