---
paths:
  - "R/**"
  - "vignettes/**"
---
# Rule: Namespace Discipline

## When This Applies
Any R function in a package (`R/`) or analysis code in vignettes/scripts.

## CRITICAL: No library() in Function Bodies

`library()` inside a function modifies the search path (side effect), hides dependencies from NAMESPACE, and causes unpredictable masking. Use `pkg::func()` or `@importFrom`.

```r
# WRONG: library() in function body
my_analysis <- function(df) {
  library(dplyr)
  df |> filter(x > 0)
}

# RIGHT: explicit qualification
my_analysis <- function(df) {
  dplyr::filter(df, x > 0)
}
```

## Vignettes: Resolve Conflicts at Top

```r
library(dplyr)
library(stats)
conflicted::conflict_prefer("filter", "dplyr")
conflicted::conflict_prefer("lag", "dplyr")
```

## Forbidden Patterns

| Pattern | Why wrong | Fix |
|---------|-----------|-----|
| `library()` inside `R/` function body | Side effect, hides dependency | `pkg::func()` or `@importFrom` |
| `require()` anywhere | Fails silently if missing | `library()` (fails loudly) or `::` |
| Unqualified `filter()` without conflicted | Ambiguous: dplyr or stats? | `dplyr::filter()` or `conflict_prefer()` |
| `library()` mid-vignette | Hard to track what's loaded | All `library()` in first chunk |
