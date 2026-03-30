# Closeread — Scrollytelling for Quarto

[closeread.dev](https://closeread.dev/) | [GitHub: qmd-lab/closeread](https://github.com/qmd-lab/closeread)

Quarto extension for scroll-driven narratives. Visual elements stay pinned while narrative text scrolls alongside. Install: `quarto add qmd-lab/closeread`.

## When to Use

| Use Case | Example |
|----------|---------|
| Storm event passing over buoys in sequence | irishbuoys |
| Patient journey through treatment phases | coMMpass |
| Risk comparison walkthroughs | micromort |
| Match analysis with progressive stats | football |
| Simulation parameter exploration | randomwalk |

**NOT for:** Standard reference documentation, API docs, dashboards with user input.

## Core Pattern

```yaml
---
title: Storm Event Narrative
format: closeread-html
---
```

Three building blocks:

```markdown
:::{.cr-section layout="sidebar-left"}

<!-- Sticky: pinned visual that responds to scroll -->
:::{#cr-wave-plot}
```{r}
safe_tar_read("vig_storm_wave_plot")
```
:::

<!-- Trigger: narrative that activates the sticky -->
As the storm approaches M6, wave heights begin to rise. @cr-wave-plot

The peak hits at 14:00 UTC with significant wave height of
`r round(peak_hmax, 1)` metres. [@cr-wave-plot]{highlight="3-5"}

:::
```

## Focus Effects

| Effect | Syntax | Use For |
|--------|--------|---------|
| Zoom | `[@cr-plot]{scale-by="2"}` | Zoom into a region of a plot |
| Pan | `[@cr-map]{pan-to="50%,-30%"}` | Move map to next buoy |
| Highlight | `[@cr-code]{highlight="3-5"}` | Highlight specific code lines |
| Highlight + Zoom | `[@cr-code]{hlz="cr-span1"}` | Zoom to highlighted span |
| Fill viewport | `:::{#cr-img .scale-to-fill}` | Full-bleed images |

Effects persist until the next trigger overrides them.

## OJS Scroll Variables

Closeread exposes reactive OJS variables that update on scroll:

```{ojs}
// Current trigger index (0-based)
crTriggerIndex

// Progress through current trigger (0.0 to 1.0)
crTriggerProgress

// Scroll direction
crDirection  // "up" or "down"

// Currently visible sticky
crActiveSticky  // e.g., "cr-wave-plot"
```

Use `crTriggerProgress` to smoothly animate a time cursor across a plot as the reader scrolls through a narrative section.

### Progress Blocks (smooth animation)

Group triggers so progress spans across them:

```markdown
:::{.progress-block}
First paragraph — progress 0.0 to 0.33. @cr-animated-plot
Second paragraph — progress 0.33 to 0.67. @cr-animated-plot
Third paragraph — progress 0.67 to 1.0. @cr-animated-plot
:::
```

## Layouts

| Layout | Narrative | Sticky |
|--------|-----------|--------|
| `sidebar-left` (default) | Left column | Right column |
| `sidebar-right` | Right column | Left column |
| `overlay-center` | Overlaid center | Full screen |
| `overlay-left` / `overlay-right` | Overlaid left/right | Full screen |

All layouts become `overlay-center` on mobile. Set per-section or globally:

```yaml
format:
  closeread-html:
    cr-section:
      layout: "overlay-center"
```

## Keyboard Navigation

Press **P** for presentation mode: transparent narrative, arrow-key navigation between triggers. Add to any scrollytelling document for accessibility.

## Progressive Plot Construction

Build up a plot layer-by-layer as the reader scrolls. Each trigger reveals the next geom:

```markdown
:::{#cr-penguins}
```{r}
safe_tar_read("vig_penguins_progressive")
```
:::

We start with the raw data points. @cr-penguins

Adding a smooth trend line reveals the relationship. [@cr-penguins]{highlight="geom_smooth"}

Faceting by species shows the pattern holds within each group. [@cr-penguins]{highlight="facet_wrap"}
```

Pre-compute each stage as a separate target: `vig_plot_stage1`, `vig_plot_stage2`, etc.

## ggiraph for Interactive SVG

[ggiraph](https://davidgohel.github.io/ggiraph/) produces interactive SVG plots — lighter than plotly, better for pkgdown/closeread:

```r
library(ggiraph)
p <- ggplot(data, aes(x, y, tooltip = label, data_id = id)) +
  geom_point_interactive() +
  theme_minimal()
girafe(ggobj = p)
```

**Advantages over plotly:** Smaller file size, native ggplot2 syntax, CSS-styleable, hover/click/zoom built-in. **Use for:** Static sites, closeread stickies, pkgdown articles. **Use plotly for:** Shiny dashboards, range sliders, 3D plots.

## Integration with Targets Pipeline

All stickies MUST be pre-computed targets (per `reproducible-visualization` rule):

```r
tar_target(vig_storm_map, generate_storm_map(storm_data)),
tar_target(vig_storm_wave_plot, generate_wave_timeseries(storm_data)),
tar_target(vig_storm_summary, generate_storm_summary_table(storm_data)),
```

Zero inline computation in closeread documents — same rule as all vignettes.
