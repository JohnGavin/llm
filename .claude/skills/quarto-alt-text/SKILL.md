---
name: quarto-alt-text
description: >
  Generate accessible alt text for data visualizations in Quarto documents. Use
  when the user wants to add, improve, or review alt text for figures in .qmd
  files. Triggers for requests about accessibility, figure descriptions, fig-alt,
  screen reader support, or making Quarto documents more accessible.
metadata:
  author: Emil Hvitfeldt (@emilhvitfeldt)
  adapted-by: johngavin
  version: "1.0"
  source: posit-dev/skills (MIT)
---

# Write Chart Alt Text

Generate accessible alt text for data visualizations in Quarto documents.

## Key Advantage: Source Code Access

Unlike typical alt text scenarios, **we have access to the code that generates each chart**:

**From plotting code:**
- Variable mappings -> exact variable names for axes
- Color/fill mappings -> what color encodes
- Plot type functions -> scatter, histogram, line chart, etc.
- Faceting/subplots -> number of panels and what varies

**From surrounding prose:**
- Text before/after the chunk explains the **purpose** and **key insight**
- This is often the best source for the "key insight" part of alt text

## Three-Part Structure (Amy Cesal's Formula)

1. **Chart type** - First words identify the format
2. **Data description** - Axes, variables, what's shown
3. **Key insight** - The pattern or takeaway

## ggplot2 Code → Alt Text Mapping

Read the plotting code to extract structured descriptions:

| ggplot2 Code | Alt Text Description |
|-------------|---------------------|
| `geom_point()` | "Scatter chart" |
| `geom_histogram()` / `geom_bar()` | "Histogram" / "Bar chart" |
| `geom_line()` | "Line chart" |
| `geom_tile()` / `geom_raster()` | "Heatmap" / "Tile chart" |
| `geom_boxplot()` / `geom_violin()` | "Box plot" / "Violin plot" |
| `geom_smooth()` | "with overlaid fitted [method] curve" |
| `aes(x = var1, y = var2)` | "[var1] along the x-axis, [var2] along the y-axis" |
| `aes(color = group)` / `aes(fill = group)` | "colored by [group]" / "filled by [group]" |
| `facet_wrap(~var, nrow = N)` | "Faceted into [N] panels, one per [var]" |
| `facet_grid(row ~ col)` | "[N×M] grid of panels, rows by [row], columns by [col]" |
| `scale_x_log10()` | "x-axis on log scale" |
| `labs(x = "Label")` | Use the label text, not the variable name |
| `coord_flip()` | Swap x/y descriptions |

## Data Generation Code → Distribution Clues

Read the code that creates the data to describe expected shapes:

| Code Pattern | Alt Text Clue |
|-------------|---------------|
| `rnorm()`, `dnorm()` | "approximately bell-shaped" |
| `rbeta(a, b)` where a < b | "right-skewed" |
| `runif()` | "approximately uniform" |
| `rpois()`, `rbinom()` | "discrete, right-skewed" |
| `log()` transform | "after log transformation" |
| `scale()` / z-score | "after standardization" |
| `filter(x > threshold)` | "subset where [condition]" |

## fig-cap / fig-alt Complementarity (MANDATORY)

fig-cap and fig-alt MUST work together, not duplicate each other:

| If fig-cap... | Then fig-alt should... |
|--------------|----------------------|
| States the key insight ("Males outnumber females 60:40") | Focus on **visual structure** (chart type, axes, encoding) |
| Is generic ("Gender distribution") | Include the **key insight** from surrounding prose |
| Includes data source | Skip source, focus on pattern |

Together they should give a complete understanding to any reader.

## Content Rules

**Include:** Chart type as first words, axis labels, specific values/ranges, number of panels, what color/size encodes, key pattern.

**Exclude:** "Image of..." or "Chart showing..." (screen readers announce this), decorative color descriptions, information already in fig-cap, implementation details.

## Length Guidelines

| Complexity | Sentences | When to use                                 |
|------------|-----------|---------------------------------------------|
| Simple     | 2-3       | Single geom, no facets, obvious pattern     |
| Standard   | 3-4       | Multiple geoms or color encoding            |
| Complex    | 4-5       | Faceted, multiple overlays, nuanced insight |

## Template Patterns

**Scatter chart:**
```
Scatter chart. [X var] along the x-axis, [Y var] along the y-axis.
[Shape: linear/curved/clustered]. [Specific pattern].
```

**Histogram:**
```
Histogram of [variable]. [Shape: right-skewed/bimodal/normal/uniform].
[Notable features: outliers, gaps, multiple modes].
```

**Bar chart:**
```
Bar chart. [Categories] along the x-axis, [measure] along the y-axis.
[Key comparison: which is highest/lowest, relative differences].
```

**Faceted chart:**
```
Faceted [chart type] with [N] panels, one per [faceting variable].
[What's constant across panels]. [What changes/varies].
```

**Line chart with overlays:**
```
[Line/Scatter] chart with overlaid [fits/curves]. [Axes].
[Number] of [lines/fits] shown: [list what each represents].
```

**Tile / heatmap:**
```
Heatmap with [rows var] along the y-axis, [cols var] along the x-axis.
Color intensity represents [measure]. [Pattern: diagonal, clustered, gradient].
```

**Correlation heatmap:**
```
Correlation heatmap of [N] variables. Color ranges from [low color] (negative)
to [high color] (positive). [Strongest correlations: X-Y at r=0.9]. [Clusters].
```

**Before/after comparison:**
```
Side-by-side [chart type]. Left panel shows [before condition], right panel
shows [after condition]. [Key difference between panels].
```

## Closeread Sticky Alt Text

Closeread stickies are pinned visuals that change with scroll. Alt text must describe **what the reader sees at each scroll state**, not just the static image.

**Pattern:** Describe the initial state, then note that focus effects change the view:

```
Map showing 6 buoy positions along the Irish Atlantic coast.
As the reader scrolls, the map zooms to each buoy in sequence,
highlighting wave height changes during the storm event.
Currently showing M6 with peak wave height of 14.2 metres.
```

For **progressive plots** (built up layer-by-layer), describe the final complete state in `fig-alt`, and note the progressive construction in the surrounding prose.

For **ggiraph** interactive SVGs, include hover/click information: "Hovering over a point shows the station name and peak wave height."

## Workflow

1. **Locate** - `grep -n "#| label: fig-" *.qmd`
2. **Read context** - Read ~50 lines around the chunk (prose + code + prose)
3. **Extract details** - Note fig-cap, plot code, data generation, surrounding explanation
4. **Draft alt text** - Apply three-part structure (type -> data -> insight)
5. **Verify** - Check against quality checklist

## Quality Checklist

- [ ] Starts with chart type (Scatter chart, Histogram, etc.)
- [ ] Names the axis variables
- [ ] Includes specific values/ranges from code when informative
- [ ] States the key insight from surrounding prose
- [ ] Complements (not duplicates) the fig-cap
- [ ] Would make sense to someone who cannot see the image
- [ ] Uses plain language (avoid jargon like "geom" or "aesthetic")

## Example

**Code context:**
```r
plotting_data |>
  ggplot(aes(value)) +
  geom_histogram(binwidth = 0.2) +
  facet_grid(name~., scales = "free_y") +
  geom_line(aes(x, y), data = norm_curve, color = "green4")
```

**Good alt text:**
```
#| fig-alt: |
#|   Faceted histogram with two panels stacked vertically. Top panel shows
#|   original data with a bimodal distribution. Bottom panel shows the same
#|   data after z-score normalization, retaining the bimodal shape. A green
#|   normal distribution curve overlaid on the bottom panel clearly does not
#|   match the data, demonstrating that normalization preserves distribution
#|   shape rather than creating normality.
```

## Related Skills

- **quarto-dynamic-content** - Quarto document authoring
- **reproducible-visualization** - ggplot2 visualization patterns
