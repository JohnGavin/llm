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
