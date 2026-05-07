---
paths:
  - "inst/extdata/**"
  - "data/**"
  - "vignettes/data/**"
---
# Data in R Packages

## Directory Purpose (R-exts 1.1.6)

| Directory | Purpose | Installed? | User-facing? |
|-----------|---------|------------|--------------|
| `data/` | Datasets for `data()` / lazy-loading | Yes | Yes |
| `inst/extdata/` | Package-internal runtime files | Yes | No (`system.file()`) |
| `vignettes/data/` | Vignette source (exclude via .Rbuildignore) | No | No |

## Size Rules

- **CRAN:** Tarball < 5 MB, installed < 5 MB (warning)
- **LazyData:** If `data/` > 5 MB, set `LazyDataCompression: xz`
- **Large files:** `.Rbuildignore` + download functions

## Anti-Patterns

| Bad | Good |
|-----|------|
| 60 MB DuckDB in `inst/extdata/` | Download on first use, cache with `rappdirs` |
| `.ctx.yaml` in `inst/extdata/ctx/` | Central cache in llmcontent |
| Overwriting data with no recovery | Date-partitioned parquet or snapshots |

## Snapshot Tests for Live Data (MANDATORY)

**NEVER `expect_snapshot()` on growing/changing data.**

| Property | Stable? | Test Strategy |
|----------|---------|---------------|
| Column names / schema | Yes | `expect_snapshot()` |
| Earliest dates | Yes | `expect_snapshot()` + `expect_lte()` |
| Row counts | No | `expect_gte(actual, REFERENCE_MIN)` |
| Date range / span | No | `expect_gte(span, MIN_DAYS)` |
| QC percentages | No | Bounds check |

### Required: Fixed Reference Baseline

```r
# FIXED REFERENCE BASELINE (established YYYY-MM-DD)
REFERENCE_STATIONS <- c("M2", "M3", "M4", "M5", "M6")
REFERENCE_MIN_RECORDS <- list(M2 = 1500L, M3 = 2100L)
REFERENCE_MIN_DAYS_SPAN <- 90
```

## Data Versioning (MANDATORY)

| Strategy | When | How |
|----------|------|-----|
| Date-partitioned parquet | Time-series | `data/raw/YYYY-MM-DD/` |
| DuckDB snapshots | Analytical DBs | `EXPORT DATABASE 'snapshots/YYYY-MM-DD'` |
| Content-hashed RDS | Small derived | `saveRDS(df, paste0(digest(df), ".rds"))` |
| Git tags | Release datasets | `git tag data-v1.0` |

**MANDATORY:** Record in `data_provenance` target: content hash, timestamp, row count, date range.

## Checklist

- [ ] No files > 5 MB in `inst/extdata/` without justification
- [ ] No `.ctx.yaml` in `inst/extdata/ctx/` (use llmcontent)
- [ ] `vignettes/data/` in `.Rbuildignore`
- [ ] No `expect_snapshot()` on row counts/date ranges
- [ ] Fixed reference baseline for monotonic assertions
- [ ] Large data via download functions, not shipped
- [ ] Time-series has temporal coverage targets
