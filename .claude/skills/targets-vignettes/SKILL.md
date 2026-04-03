---
name: targets-vignettes
description: Use when pre-calculating objects for package vignettes using targets, keeping vignettes focused on narrative while computation runs through the pipeline. Triggers: targets vignettes, pre-compute, vignette data, tar_read in vignettes.
---
# Targets Pipeline for Vignette Pre-calculation

## Description

This skill implements the pattern of using the targets package to pre-calculate all objects displayed in package vignettes. Vignettes focus on narrative and visualization while all computation happens through the targets pipeline.

## Purpose

Use this skill when:
- Creating R package vignettes that require heavy computation
- Building data analysis pipelines for reproducible research
- Need to separate computation from presentation
- Want vignettes to build quickly without re-running expensive calculations
- Creating telemetry and project statistics vignettes

## Key Principles

### Vignettes Load, Don't Compute

Vignettes should:
- Contain primarily text, explanations, and narrative
- Use `targets::tar_load()` or `targets::tar_read()` to load pre-calculated objects
- Display tables and plots that were computed via targets
- Build quickly since computation already happened

Vignettes should NOT:
- Run expensive computations directly
- Process raw data
- Generate complex visualizations from scratch
- Take a long time to build

## How It Works

The workflow follows four steps:

1. **Define pipeline** in `_targets.R` using `tar_plan()` with targets for data loading, processing, visualizations, and tables
2. **Create package functions** that return objects (ggplot objects, data frames) -- no side effects, no printing
3. **Run the pipeline** locally with `targets::tar_make()`
4. **Create vignettes** that use `tar_load()` / `tar_read()` to display pre-calculated results

See [pipeline-setup.md](references/pipeline-setup.md) for complete code examples of each step.

### Key Rules for Functions

- Functions return plot objects (ggplot), not plot to screen
- Functions return data frames or table objects, not print them
- All logic is in package functions, not in `_targets.R`
- Functions are documented and tested

### Key Rules for Vignettes

- Use `echo = FALSE` in chunk options to hide code by default
- Load `library(targets)` in setup chunk
- Separate load chunks from display chunks for clarity

## File Structure

```
package/
├── _targets.R              # Pipeline definition
├── _targets/               # Targets cache (gitignored)
│   ├── meta/
│   ├── objects/
│   └── user/
├── R/
│   ├── data_processing.R   # Data cleaning functions
│   ├── plotting.R          # Plotting functions
│   ├── tables.R            # Table generation functions
│   └── utils.R             # Helper functions
├── vignettes/
│   ├── analysis.Rmd        # Vignette loading targets
│   ├── results.Rmd         # Another vignette
│   └── telemetry.Rmd       # Project stats vignette
├── data-raw/
│   ├── input.csv           # Raw data
│   └── prepare_data.R      # Data preparation script
└── inst/
    └── logs/               # Logger output
```

## Common Patterns

Four key patterns for organizing targets in vignette pipelines:

| Pattern | Use Case | Key Technique |
|---------|----------|---------------|
| Multiple related plots | Group comparisons | Return named list of ggplots |
| Conditional targets | Cache-or-fetch | `if/else` in target expression |
| File targets | Rendered reports | `format = "file"`, return path |
| Dynamic branching | Process many files | `pattern = map(input_files)` |

A **telemetry vignette** pattern is also available for showing project statistics (git history, test coverage, pipeline metadata).

See [common-patterns.md](references/common-patterns.md) for complete code examples.

## Best Practices Summary

1. **Keep functions pure** -- return objects, no side effects (`ggsave`, `print`)
2. **Use meaningful target names** -- `plot_temporal_trends`, not `plot1`
3. **Document expected outputs** -- roxygen `@return` for every function
4. **Version your pipeline** -- commit `_targets.R` changes with `gert`
5. **Invalidate strategically** -- `tar_invalidate()` to force re-computation

## Integration with pkgdown

- Configure `_pkgdown.yml` to organize vignettes into article groups
- Build order: `tar_make()` first, then `pkgdown::build_site()`
- In CI (GitHub Actions): run targets build step before pkgdown build step

## Debugging Quick Reference

| Task | Command |
|------|---------|
| See what needs to run | `targets::tar_outdated()` |
| Visualize pipeline | `targets::tar_visnetwork()` |
| Inspect metadata | `targets::tar_meta()` |
| Load dependencies for debugging | `targets::tar_load_globals()` |
| Enter debug mode | `tar_option_set(debug = "target_name")` then `tar_make()` |

## Common Issues

| Problem | Solution |
|---------|----------|
| Vignette can't find targets | Run `tar_make()` before `devtools::build_vignettes()` |
| Targets out of date | `tar_outdated()` then `tar_make()` |
| Missing dependencies | `usethis::use_package("targets")` in DESCRIPTION |

See [best-practices-and-debugging.md](references/best-practices-and-debugging.md) for detailed code examples.

## Resources

- **targets manual**: https://books.ropensci.org/targets/
- **targets package**: https://docs.ropensci.org/targets/
- **Example pipelines**: https://github.com/ropensci/targets/tree/main/inst/examples
- **Best practices**: https://books.ropensci.org/targets/practice.html
