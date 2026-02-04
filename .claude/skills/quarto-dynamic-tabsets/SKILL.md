# Dynamic Quarto Tabsets from Factor Variables

## Description

This skill covers creating dynamic tabsets in Quarto documents based on factor variables in your data. Instead of hardcoding tabs, you can programmatically generate tabs for each level of a categorical variable (e.g., stations, categories, groups).

## Purpose

Use this skill when:
- Displaying the same visualization/analysis for multiple groups (e.g., stations, categories, regions)
- The number of groups may change with the data
- You want to avoid repetitive code for each group
- Building dashboards with tabbed navigation by factor levels
- Creating an "All [Groups]" aggregate view alongside individual tabs

## Key Principles

### When to Use Tabsets vs Dropdowns

**Use Tabsets When:**
- Number of factor levels is small (2-10 tabs)
- Users need to quickly switch between views
- All options should be visible at once
- Content is pre-rendered (no server-side reactivity needed)

**Use Dropdowns/Select Inputs When:**
- Large number of options (>10)
- Options need search/filter capability
- Server-side reactivity is required (Shiny)
- Memory constraints (tabsets pre-render all content)

### Static vs Dynamic Approach

**Static (Hardcoded) Tabsets:**
```qmd
::: {.panel-tabset}
### Tab 1
Content for tab 1

### Tab 2
Content for tab 2
:::
```

**Dynamic (Data-Driven) Tabsets:**
Generated programmatically from factor levels using `results: asis`.

## Two Approaches for Dynamic Tabsets

### Approach 1: results: asis with cat() (Recommended)

Use `#| results: asis` to output raw Quarto markdown syntax.

```{r}
#| results: asis

# Get unique levels
stations <- c("All Buoys", sort(unique(data$station_id)))

# Start tabset
cat("::: {.panel-tabset}\n\n")

for (station in stations) {
  cat("### ", station, "\n\n", sep = "")

  # Filter data
  if (station == "All Buoys") {
    stn_data <- data
  } else {
    stn_data <- data |> filter(station_id == station)
  }

  # Output content (text, stats, etc.)
  cat("**Records:** ", nrow(stn_data), "\n\n")

  # For plots, you need sub-chunks or save/include pattern
}

cat(":::\n")
```

**Limitation:** You cannot directly render plots inside `results: asis` chunks. Plots need special handling.

### Approach 2: Pre-compute and Include Pattern

Pre-render all content for each tab, then assemble with `results: asis`.

**Step 1: Pre-compute plots and save to files**
```{r setup}
library(ggplot2)

stations <- c("All Buoys", sort(unique(data$station_id)))

# Pre-compute and save plots
for (station in stations) {
  stn_data <- if (station == "All Buoys") data else filter(data, station_id == station)

  p <- ggplot(stn_data, aes(x = time, y = wave_height)) +
    geom_line() +
    labs(title = paste("Wave Height -", station))

  ggsave(
    filename = paste0("plots/wave_", gsub(" ", "_", station), ".png"),
    plot = p, width = 8, height = 4
  )
}
```

**Step 2: Generate tabset with image includes**
```{r}
#| results: asis

cat("::: {.panel-tabset}\n\n")

for (station in stations) {
  cat("### ", station, "\n\n", sep = "")

  # Include saved plot
  img_file <- paste0("plots/wave_", gsub(" ", "_", station), ".png")
  cat("![](", img_file, ")\n\n", sep = "")

  # Add summary stats
  stn_data <- if (station == "All Buoys") data else filter(data, station_id == station)
  cat("Records: ", nrow(stn_data), "\n\n")
}

cat(":::\n")
```

### Approach 3: Explicit Tabs (Most Reliable)

For guaranteed rendering, explicitly write each tab with R code chunks:

```qmd
## Wave Height by Station

::: {.panel-tabset}

### All Buoys

```{r}
stn_data <- data
create_plot(stn_data, "wave_height", " - All Buoys")
```

### M2

```{r}
stn_data <- filter(data, station_id == "M2")
create_plot(stn_data, "wave_height", " - M2")
```

### M3

```{r}
stn_data <- filter(data, station_id == "M3")
create_plot(stn_data, "wave_height", " - M3")
```

:::
```

**Advantages:**
- Most reliable rendering
- Full control over each tab
- Works with any content type

**Disadvantages:**
- Repetitive code
- Must manually update when factors change

## Complete Example: Multi-Variable Dashboard

This pattern creates tabsets for multiple variables, each with tabs per station.

```qmd
---
title: "Weather Buoy Explorer"
format:
  html:
    page-layout: full
    toc: true
---

```{r setup}
library(dplyr)
library(ggplot2)

# Load data
data <- jsonlite::fromJSON("data/buoy_data.json")
data$time <- as.POSIXct(data$time, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")

# Define groups
stations <- c("All Buoys", sort(unique(data$station_id)))

# Helper functions
get_station_data <- function(data, station, days = 30) {
  cutoff <- max(data$time) - (days * 24 * 3600)
  if (station == "All Buoys") {
    data |> filter(time >= cutoff)
  } else {
    data |> filter(station_id == station, time >= cutoff)
  }
}

create_time_series_plot <- function(data, variable, title_suffix = "") {
  ggplot(data, aes(x = time, y = .data[[variable]], color = station_id)) +
    geom_line(alpha = 0.7) +
    geom_point(size = 0.5, alpha = 0.5) +
    labs(title = paste(variable, title_suffix), x = "Time", y = variable) +
    theme_minimal() +
    theme(legend.position = "bottom")
}
```

## Wave Height by Station

::: {.panel-tabset}

### All Buoys

```{r}
#| fig-height: 5
stn_data <- get_station_data(data, "All Buoys", 30)
create_time_series_plot(stn_data, "wave_height", " - Last 30 Days")
```

### M2

```{r}
#| fig-height: 4
stn_data <- get_station_data(data, "M2", 30)
create_time_series_plot(stn_data, "wave_height", " - M2")
```

<!-- Add more station tabs as needed -->

:::

## Wind Speed by Station

::: {.panel-tabset}

### All Buoys

```{r}
#| fig-height: 5
stn_data <- get_station_data(data, "All Buoys", 30)
create_time_series_plot(stn_data, "wind_speed", " - Last 30 Days")
```

<!-- Add more station tabs as needed -->

:::
```

## Adding an "All Groups" Aggregate Tab

Always include an aggregate view as the first tab:

```{r}
# Define stations with "All" first
stations <- c("All Buoys", sort(unique(data$station_id)))

# In helper function, handle "All" specially
get_station_data <- function(data, station) {
  if (station == "All Buoys") {
    return(data)  # Return all data
  }
  filter(data, station_id == station)
}
```

## When Shinylive Fails: Use Static Tabsets

Shinylive/WebR has limitations that can cause data loading issues. When this happens:

1. **Use static Quarto dashboards** with pre-rendered tabsets
2. **Load data at render time** (R runs on your machine during `quarto render`)
3. **Pre-compute all visualizations** (no server-side reactivity)

**Advantages of Static over Shinylive:**
- Guaranteed data loading (no WebAssembly complexity)
- Faster page load (no WebR initialization)
- Works offline
- No CORS or network issues

**Disadvantages:**
- No user interactivity (can't change parameters)
- Must re-render to update data
- All tabs pre-rendered (larger HTML output)

## Reference Implementation

See the irishbuoys package for a complete example:
- `vignettes/dashboard_static.qmd` - Static dashboard with tabsets
- Uses `::: {.panel-tabset}` fenced divs
- Tabs for each station (M2, M3, M4, M5, M6) plus "All Buoys"
- Multiple variable sections (Wave Height, Wind Speed, Scatter plots)

## Best Practices

1. **Keep tab count reasonable** - 2-10 tabs work well, >10 consider dropdowns
2. **Include "All" aggregate first** - Users often want the overview
3. **Use consistent naming** - Match factor levels exactly
4. **Pre-compute when possible** - Avoid expensive calculations in tabs
5. **Document data requirements** - Factor variable must have clean levels
6. **Test all tabs** - Each must render without errors
7. **Use helper functions** - DRY principle for repeated visualizations

## Troubleshooting

### Plots not rendering in results: asis
- Use explicit code chunks per tab instead
- Or use save/include pattern with ggsave()

### Empty tabs
- Check factor levels match data
- Verify filter conditions
- Add defensive checks: `if (nrow(stn_data) > 0)`

### Tabset syntax not recognized
- Ensure proper spacing around `:::`
- Check for missing closing `:::`
- Use `\n\n` between elements in cat()

## Related Skills

- `shinylive-quarto` - For interactive WebAssembly dashboards
- `quarto-dynamic-content` - Other dynamic Quarto patterns
- `eda-workflow` - Exploratory data analysis patterns

## Resources

- [Quarto Tabsets](https://quarto.org/docs/output-formats/html-basics.html#tabsets)
- [Quarto Raw Output](https://quarto.org/docs/computations/execution-options.html#raw-output)
- [Danielle Navarro Blog: Quarto Syntax from R](https://blog.djnavarro.net/posts/2025-07-05_quarto-syntax-from-r/)
