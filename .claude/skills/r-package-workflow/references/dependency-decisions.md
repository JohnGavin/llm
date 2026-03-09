# Dependency Decision Framework

When to add a package dependency vs use base R.

## Decision Matrix

| Scenario | Add Dependency | Use Base R |
|----------|---------------|-----------|
| Complex string operations | `stringr` | Simple `paste0()`, `nchar()` |
| Date manipulation | `lubridate` | Simple `as.Date()`, `Sys.Date()` |
| HTTP requests | `httr2` | — (base is painful) |
| JSON parsing | `jsonlite` | — (no base equivalent) |
| Data manipulation | `dplyr` | Simple `subset()`, `merge()` |
| File I/O | `readr`/`arrow` | `read.csv()` (small files) |

## Tidyverse Dependency Tiers

### Core (Usually Safe to Depend On)
- `dplyr`, `tidyr`, `purrr`, `stringr`, `readr`
- Already common in most R projects
- Stable APIs, well-maintained

### Specialized (Add When Needed)
- `lubridate`, `forcats`, `glue`, `rlang`, `cli`
- Add when the task genuinely needs them

### Heavy (Avoid as Dependencies)
- `tidyverse` meta-package — **never** import in a package
- `ggplot2` — only in Suggests unless core to package purpose
- `shiny` — only for Shiny-specific packages

## DESCRIPTION Placement

```
Imports:    # Used in R/ code
    dplyr (>= 1.1.0),
    rlang
Suggests:   # Used in tests/vignettes only
    testthat,
    ggplot2,
    knitr
```

**Rule:** If a function in `R/` calls `pkg::fn()`, the package goes in `Imports`.
If it's only used in `tests/` or `vignettes/`, it goes in `Suggests`.

## When Base R Is Better

```r
# Don't import stringr just for this
nchar(x)           # not stringr::str_length(x)
paste0(a, b)       # not stringr::str_c(a, b)
grepl("^a", x)     # not stringr::str_detect(x, "^a") (simple pattern)

# Don't import dplyr just for this
subset(df, x > 5)  # not dplyr::filter(df, x > 5) (one-off)

# Don't import purrr just for this
lapply(x, f)       # not purrr::map(x, f) (simple apply)
vapply(x, f, 0.0)  # not purrr::map_dbl(x, f) (simple typed apply)
```

## When Tidyverse Is Better

```r
# Complex string operations — stringr is clearer
stringr::str_extract_all(text, "\\b\\w+@\\w+\\.\\w+\\b")
# vs: regmatches(text, gregexpr(...)) — hard to read

# Multiple joins — dplyr is clearer
dplyr::left_join(a, b, by = "id") |>
  dplyr::inner_join(c, by = join_by(date >= start, date <= end))
# vs: merge(merge(a, b, by = "id"), c, ...) — painful

# Complex reshaping — tidyr is essential
tidyr::pivot_longer(data, cols = -id, names_to = "metric")
# vs: reshape(...) — almost nobody can remember the args
```
