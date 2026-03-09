# Best Practices, Integration, and Debugging

## Best Practices

### 1. Keep Functions Pure

```r
# Good: Pure function that returns an object
create_plot <- function(data) {
  ggplot(data, aes(x, y)) + geom_point()
}

# Bad: Function with side effects
create_plot <- function(data) {
  p <- ggplot(data, aes(x, y)) + geom_point()
  ggsave("plot.png", p)  # Side effect!
  print(p)               # Side effect!
}
```

### 2. Use Meaningful Target Names

```r
# Good
tar_target(summary_statistics_by_group, ...)
tar_target(plot_temporal_trends, ...)

# Bad
tar_target(x, ...)
tar_target(plot1, ...)
```

### 3. Document Expected Outputs

```r
#' Create summary table
#'
#' @param data Cleaned data frame with columns x, y, group
#' @return A data frame with columns: group, mean_x, sd_x, n
#' @export
create_summary_table <- function(data) {
  # ...
}
```

### 4. Version Your Pipeline

Use git to track changes to _targets.R:

```r
# R/log/git_gh.R
library(gert)

gert::git_add("_targets.R")
gert::git_commit("Update pipeline: add new visualization targets")
```

### 5. Invalidate Strategically

Use `tar_invalidate()` when you need to force re-computation:

```r
# Force re-run of specific target
targets::tar_invalidate(plot_distribution)

# Re-run downstream targets
targets::tar_make()
```

## Integration with pkgdown

### Pre-build Vignettes

```r
# _pkgdown.yml
articles:
  - title: Analysis
    contents:
      - analysis
      - results
  - title: Project Info
    contents:
      - telemetry

# Build vignettes first
# targets::tar_make()
# Then build site
# pkgdown::build_site()
```

### Automate in GitHub Actions

```yaml
# .github/workflows/pkgdown.yaml
- name: Build targets
  run: nix-shell default.nix --run "Rscript -e 'targets::tar_make()'"

- name: Build pkgdown site
  run: nix-shell default.nix --run "Rscript -e 'pkgdown::build_site()'"
```

## Debugging Targets

### Check Target Status

```r
# See what needs to run
targets::tar_outdated()

# Visualize the pipeline
targets::tar_visnetwork()

# See detailed metadata
targets::tar_meta()
```

### Debug Individual Targets

```r
# Load target dependencies
targets::tar_load_globals()

# Interactively run target code
targets::tar_load(clean_data)
# Now manually run the code for the next target

# Debug mode
targets::tar_option_set(debug = "plot_distribution")
targets::tar_make()
```

## Common Issues

### Vignette can't find targets

**Solution**: Run `targets::tar_make()` before building vignettes

```r
targets::tar_make()
devtools::build_vignettes()
```

### Targets out of date

**Solution**: Check what changed

```r
targets::tar_outdated()
targets::tar_make()
```

### Missing dependencies

**Solution**: Ensure all packages are in DESCRIPTION

```r
usethis::use_package("targets")
usethis::use_package("tarchetypes")
```
