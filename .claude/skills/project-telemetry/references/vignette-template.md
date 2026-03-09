# Telemetry Vignette Template

Full Rmd template for `vignettes/telemetry.Rmd`.

```r
# vignettes/telemetry.Rmd
---
title: "Project Telemetry and Statistics"
output: rmarkdown::html_vignette
vignette: >
  %\VignetteIndexEntry{Project Telemetry and Statistics}
  %\VignetteEngine{knitr::rmarkdown}
  %\VignetteEncoding{UTF-8}
---
```

````{verbatim}
```{r setup, include = FALSE}
knitr::opts_chunk$set(
  collapse = TRUE,
  comment = "#>",
  echo = FALSE,
  message = FALSE,
  warning = FALSE
)

library(targets)
library(knitr)
library(ggplot2)
```
````

## Overview

This vignette provides comprehensive statistics and telemetry for the package,
including git history, test coverage, pipeline performance, and project structure.

## Git History

### Contributors

````{verbatim}
```{r}
tar_load(git_contributors)
kable(git_contributors)
```
````

### Commit Activity

````{verbatim}
```{r}
tar_load(git_history)

# Plot commits over time
library(dplyr)
git_history |>
  count(date) |>
  ggplot(aes(x = date, y = n)) +
  geom_line() +
  geom_smooth(se = FALSE) +
  labs(title = "Commit Activity", x = "Date", y = "Commits") +
  theme_minimal()
```
````

## Test Coverage

````{verbatim}
```{r}
tar_load(coverage_data)
tar_load(coverage_plot)
```
````

Overall coverage: **`r round(coverage_data$percent, 1)`%**

````{verbatim}
```{r}
print(coverage_plot)
```
````

## Pipeline Performance

````{verbatim}
```{r}
tar_load(pipeline_timing)
tar_load(pipeline_plot)
```
````

Total targets: **`r nrow(pipeline_timing)`**

````{verbatim}
```{r}
kable(head(pipeline_timing, 10))
print(pipeline_plot)
```
````

## Package Structure

````{verbatim}
```{r}
tar_load(package_tree)
tar_load(file_counts)
```
````

### File Counts by Type

````{verbatim}
```{r}
kable(file_counts)
```
````

### Directory Tree

````{verbatim}
```{r, comment = ""}
cat(package_tree)
```
````

## Session Information

````{verbatim}
```{r}
tar_load(session_info)
```
````

R Version: **`r session_info$r_version`**

Platform: **`r session_info$platform`**

Operating System: **`r session_info$os`**

### Loaded Packages

````{verbatim}
```{r}
kable(session_info$packages)
```
````

## GitHub Statistics

````{verbatim}
```{r}
tar_load(github_stats)
tar_load(workflow_status)
```
````

- Stars: **`r github_stats$stars`**
- Forks: **`r github_stats$forks`**
- Open Issues: **`r github_stats$open_issues`**
- Watchers: **`r github_stats$watchers`**

### Recent Workflow Runs

````{verbatim}
```{r}
kable(workflow_status)
```
````

## Build Information

Built on: **`r Sys.time()`**

Package version: **`r packageVersion("yourpackage")`**
