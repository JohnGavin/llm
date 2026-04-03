---
name: quarto-dashboards
description: >
  Build Quarto dashboards with bslib, plotly, and optional Shiny/Shinylive
  interactivity. Use when creating dashboard-format Quarto documents,
  converting Shiny dashboards to static/Shinylive, or adding interactive
  components to Quarto pages.
---

# Quarto Dashboards

## Purpose

Guide for creating Quarto dashboards (`format: dashboard`) with R and Python.
Covers layout, components, interactivity tiers, theming, and deployment.

## When to Use

- Creating `format: dashboard` Quarto documents
- Adding interactive plots, tables, or inputs to dashboards
- Converting Shiny apps to static or Shinylive dashboards
- Choosing between Observable JS, Shiny, and Shinylive interactivity

## Quick Start

```yaml
---
title: "My Dashboard"
format: dashboard
---
```

```markdown
# Page 1

## Row

### Column

\```{r}
plotly::plot_ly(data, x = ~x, y = ~y, type = "scatter")
\```
```

## Layout Model

Dashboards use a **pages > rows > columns > cards** hierarchy:

| Level | Markdown | Purpose |
|-------|----------|---------|
| Page | `#` | Top-level navigation tabs |
| Row | `##` | Horizontal sections |
| Column | `###` | Vertical subdivisions |
| Card | Code chunk or `:::{.card}` | Content container |

Key options: `{height=}` on rows, `{width=}` on columns, `{.tabset}` for tabs.

See [layout-patterns.md](references/layout-patterns.md) for navigation, multi-page, and sidebar patterns.

## Components

| Component | Package | Best For |
|-----------|---------|----------|
| Interactive plots | `plotly` | Hover, zoom, pan |
| Static plots | `ggplot2` | Publication quality |
| Tables | `DT::datatable()` | Sorting, filtering, search |
| Value boxes | `bslib::value_box()` | KPI summaries |
| Maps | `leaflet` | Geographic data |

See [components.md](references/components.md) for code patterns and examples.

## Interactivity Tiers

| Tier | Technology | Server? | Complexity |
|------|-----------|---------|------------|
| Static | plotly, DT, leaflet | No | Low |
| Client-side | Observable JS | No | Medium |
| Shinylive | Shiny + WebR/Pyodide | No | Medium-High |
| Full Shiny | Shiny server | Yes | High |

**Decision rule:** Start static. Add Observable JS for cross-widget filtering.
Use Shinylive for R/Python reactivity without a server. Full Shiny only when needed.

See [interactivity.md](references/interactivity.md) for Observable JS, Shiny, and Shinylive patterns.

## Theming

Use `theme:` in YAML or `_brand.yml` for consistent styling.
See [theming.md](references/theming.md) for built-in themes and custom SCSS.

## Deployment

Static and Shinylive dashboards deploy without a server (GitHub Pages, Netlify).
Full Shiny dashboards need shinyapps.io, Posit Connect, or similar.

See [deployment.md](references/deployment.md) for GitHub Actions workflows and hosting options.

## Best Practices

1. Use `plotly` over `ggplot2` for dashboard interactivity
2. Set explicit `height=` and `width=` on layout sections
3. Use `bslib::value_box()` for KPI summary cards
4. Test fill behavior — cards expand to fill available space
5. Use `{.tabset}` to organize dense content
6. Pre-compute data in targets pipeline (zero computation in dashboard)

See [best-practices.md](references/best-practices.md) for performance, fill behavior, and debugging.

## Related Skills

- `shiny-bslib` — bslib components for Shiny apps
- `brand-yml` — Brand styling
- `shinylive-quarto` — Shinylive in Quarto vignettes
- `quarto-websites` — Full Quarto website structure

## Resources

- [Quarto Dashboards](https://quarto.org/docs/dashboards/)
- [bslib](https://rstudio.github.io/bslib/)
