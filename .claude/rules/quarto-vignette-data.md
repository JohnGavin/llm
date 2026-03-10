---
paths:
  - "*.qmd"
  - "vignettes/**"
---
# Quarto Vignette Data Rules

All vignettes use `.qmd` format exclusively. See `quarto-vignette-format.md` Rule 0.

## 1. NO SAMPLED DATA WITHOUT EXPLICIT APPROVAL

**CRITICAL**: Never use sampled, subsetted, or filtered data in vignettes without:
1. **Explicit prior approval** from the user for EACH instance
2. **Documented justification** in the vignette itself
3. **Clear indication** to readers that data is sampled

**Violations include:**
- Using `head()`, `sample_n()`, `slice()` to reduce data
- Filtering date ranges without full historical coverage
- Limiting to subset of stations/categories
- Using "example" or "demo" datasets instead of production data

**Correct approach:**
- Always use full production data
- Pre-compute in targets pipeline for performance
- If data is truly too large, ASK user for explicit approval first

## 2. PRE-COMPUTED DATA ONLY

**MANDATORY**: Vignettes perform NO computation.

**All data must come from:**
- `targets::tar_load()` for targets
- `targets::tar_read()` for inline use
- Pre-saved RDS/parquet files in `inst/extdata/`

**Forbidden in vignettes:**
- Database queries (`DBI::dbGetQuery()`, `dplyr::collect()`)
- API calls (`httr2::req_perform()`)
- Heavy computation (`lm()`, `glm()`, aggregations)
- File I/O that computes (`read_csv()` then summarise)

**Exception: targets introspection functions**

| Function | Purpose | Why allowed |
|----------|---------|-------------|
| `tar_visnetwork()` | Interactive DAG visualization | htmlwidget can't be serialized |
| `tar_network()` | Network data structure | Metadata only |
| `tar_meta()` | Pipeline metadata (timing, errors) | Metadata changes between builds |
| `tar_manifest()` | Target listing | Metadata only |
| `tar_progress()` | Build progress | Live status |
| `tar_outdated()` | What needs rebuilding | Live status |

For Shinylive dashboards: Pre-compute with `tar_network()` in
`R/dev/save_dag_network.R` and embed the JSON data.

## 3. ZERO INLINE COMPUTATION OR ASSIGNMENTS

**MANDATORY**: Vignettes contain ZERO computation and ZERO assignments.

Every `{r}` chunk is exactly ONE expression:
```r
safe_tar_read("vig_target_name")
```

**Forbidden** (in any non-setup chunk):
`<-`, `=`, `print()`, `cat()`, `ggplot()`, `data.frame()`, `sprintf()`,
`table()`, `colSums()`, `apply()`, `if`/`else`, `for`, `DBI::dbGetQuery()`

The **ONLY** exception is the setup chunk which contains:
- `knitr::opts_chunk$set(...)`
- `library(targets)`
- Target store discovery
- `safe_tar_read` definition

**library() in executed chunks:**
- ALLOWED: `library(targets)` in setup chunk (for tar_read/tar_load)
- ALLOWED: `library(DT)` (display-only rendering)
- FORBIDDEN: `library(<own-package>)` or any DESCRIPTION dependency
- Enforced by: `~/.claude/hooks/vignette_check.sh`

## 4. PKGDOWN/CI RENDERING GUARDS

**MANDATORY**: Vignettes using `targets` store data MUST guard against missing store in CI.

**Setup chunk pattern:**
```r
in_pkgdown <- nzchar(Sys.getenv("IN_PKGDOWN"))
knitr::opts_chunk$set(
  eval = !in_pkgdown,
  echo = FALSE,
  # ...
)
if (!in_pkgdown) library(targets)
```

**Callout banner** (eval ONLY in pkgdown):
```r
#| results: asis
#| eval: !expr in_pkgdown
#| echo: false
cat("::: {.callout-note}\n## Online documentation\nRun `targets::tar_make()` locally to see full output.\n:::\n")
```

**Post-deploy verification** (CI step):
- Grep all rendered HTML for `#> NULL`, `#> Error`, `not available`, `could not find`
- FAIL the build if any error patterns are found
- This catches regressions where vignettes accidentally evaluate in CI

## 5. FULL DATE RANGE REQUIREMENT

**MANDATORY**: Targets querying time-series data MUST use full date range.

```r
# FORBIDDEN: Arbitrary date filter
filter(time >= Sys.Date() - 30)

# REQUIRED: Full historical range
filter(time >= as.Date("2019-01-01"))  # Or earliest available
```
