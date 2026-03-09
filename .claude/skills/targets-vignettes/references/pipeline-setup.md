# Pipeline Setup: Step-by-Step

## 1. Define Your Pipeline in _targets.R

```r
# _targets.R
library(targets)
library(tarchetypes)

# Source your package functions
tar_source()

# Define the pipeline
tar_plan(
  # Data loading
  tar_target(raw_data, read_raw_data("data-raw/input.csv")),

  # Data processing
  tar_target(clean_data, clean_dataset(raw_data)),
  tar_target(summary_stats, summarize_data(clean_data)),

  # Visualizations (return ggplot objects)
  tar_target(plot_distribution, plot_dist(clean_data)),
  tar_target(plot_trends, plot_time_series(clean_data)),
  tar_target(plot_comparison, plot_compare_groups(clean_data)),

  # Tables (return data frames or gt/kable objects)
  tar_target(table_summary, create_summary_table(summary_stats)),
  tar_target(table_detailed, create_detailed_table(clean_data)),

  # Save outputs for vignette use
  tar_target(
    vignette_objects,
    save_for_vignette(
      plot_distribution,
      plot_trends,
      table_summary
    ),
    format = "file"
  )
)
```

## 2. Create Package Functions That Return Objects

```r
# R/plotting.R

#' Create distribution plot
#'
#' @param data Cleaned data frame
#' @return A ggplot object
#' @export
plot_dist <- function(data) {
  library(ggplot2)

  ggplot(data, aes(x = value)) +
    geom_histogram(bins = 30, fill = "steelblue") +
    theme_minimal() +
    labs(
      title = "Distribution of Values",
      x = "Value",
      y = "Count"
    )
}
```

Key points:
- Functions return plot objects (ggplot), not plot to screen
- Functions return data frames or table objects, not print them
- All logic is in package functions, not in _targets.R
- Functions are documented and tested

## 3. Run the Pipeline Locally

```r
# Run the entire pipeline
targets::tar_make()

# Check what's available
targets::tar_manifest()

# Inspect a specific target
targets::tar_read(plot_distribution)

# Load multiple targets
targets::tar_load(c(plot_distribution, table_summary))
```

## 4. Create Vignettes That Load Results

```r
# vignettes/analysis.Rmd
---
title: "Analysis Results"
output: rmarkdown::html_vignette
vignette: >
  %\VignetteIndexEntry{Analysis Results}
  %\VignetteEngine{knitr::rmarkdown}
  %\VignetteEncoding{UTF-8}
---

```{r setup, include = FALSE}
knitr::opts_chunk$set(
  collapse = TRUE,
  comment = "#>",
  echo = FALSE,  # Hide code by default
  message = FALSE,
  warning = FALSE
)

library(targets)
```

## Introduction

Brief narrative explaining the analysis...

## Data Summary

```{r load-summary}
# Load pre-calculated table
tar_load(table_summary)
```

Here's a summary of the dataset:

```{r display-summary}
knitr::kable(table_summary)
```

## Distribution Analysis

```{r load-plot-dist}
# Load pre-calculated plot
tar_load(plot_distribution)
```

The distribution shows...

```{r display-plot-dist}
print(plot_distribution)
```

## Trends Over Time

```{r}
tar_load(plot_trends)
print(plot_trends)
```

```
