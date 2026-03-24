---
name: dynamic-prose-values
description: All specific values in prose/captions must be dynamic R expressions, never hardcoded
globs: ["**/*.qmd", "**/*.Rmd", "**/R/*.R"]
---

# Rule: Dynamic Prose Values (Mandatory, No Exceptions)

## When This Applies
Any prose text in vignettes, email templates, captions, or README that contains specific values — numbers, dates, station names, counts, percentages, or any derived quantity.

## CRITICAL: Never Hardcode Values That Can Become Stale

Every specific value in prose MUST be an embedded R expression evaluated by the targets pipeline or at render time.

### In Quarto vignettes (.qmd)
Use inline R: `` `r variable_name` `` or `` `r round(max_hmax, 1)` ``

### In targets-built captions (R code)
Use `paste0()` or `sprintf()` with pipeline variables:
```r
caption = paste0("Max Wave: ", round(max_hmax, 1), " m at ", max_station, " on ", format(max_date, "%Y-%m-%d"))
```

### In email templates (R functions)
Use dynamic values from the summary/forecast objects passed to the function:
```r
paste0(n_stations, " stations affected | Max Beaufort ", max_beaufort)
```

## Violations

| Pattern | Problem | Fix |
|---------|---------|-----|
| `"29.9 m"` in prose | Hardcoded value | `paste0(round(max_hmax, 1), " m")` |
| `"2026-03-01"` in prose | Hardcoded date | `format(max_date, "%Y-%m-%d")` |
| `"5 stations"` in prose | Hardcoded count | `paste0(n_stations, " stations")` |
| `"M6"` in prose (when referring to max station) | Hardcoded station | `max_station` variable |

## Exception
Static reference text is allowed when it describes a fixed property:
- "Beaufort 9 = 41 knots" (definition, never changes)
- "M6 is 320km offshore" (geographic fact)
- "Data source: Marine Institute ERDDAP" (attribution)
