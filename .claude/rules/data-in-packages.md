---
paths:
  - "inst/extdata/**"
  - "data/**"
  - "vignettes/data/**"
  - "tests/testthat/**"
---
# Data in R Packages

## R-exts 1.1.6 Compliance (MANDATORY)

Reference: https://cran.r-project.org/doc/manuals/R-exts.html#Data-in-packages-1

### Directory Purpose

| Directory | Purpose | Installed? | User-facing? |
|-----------|---------|------------|--------------|
| `data/` | Datasets for `data()` / lazy-loading | Yes | Yes |
| `inst/extdata/` | Package-internal data files | Yes | No (use `system.file()`) |
| `vignettes/data/` | Vignette source data (exclude via .Rbuildignore) | No | No |
| `docs/` | Generated site (GitHub Pages) | No | No |

### Size Rules

- **CRAN limit:** Package tarball < 5 MB (soft), installed < 5 MB (warning)
- **Non-CRAN packages:** No hard limit, but `inst/extdata/` bloats installs
- **LazyData compression:** If `data/` > 5 MB, set `LazyDataCompression: xz` in DESCRIPTION
- **Large files:** Use `.Rbuildignore` to exclude, provide download functions instead

### What Goes Where

**`data/` (user-facing datasets):**
- Small reference datasets users access via `data("dataset_name")`
- Must be `.rda` or `.RData` (or `.csv`/`.tab` with `data()` loader)
- Requires `LazyData: true` in DESCRIPTION for lazy-loading

**`inst/extdata/` (package-internal):**
- Files the package reads at runtime via `system.file("extdata", "file", package = "pkg")`
- Database files, config, templates
- NEVER store large volatile data here (it installs with the package)

**`.Rbuildignore` exclusions (development-only):**
- `vignettes/data/` — vignette source data not needed at install time
- Pipeline outputs, CI artifacts, docs/

### Anti-Patterns

```r
# BAD: 60 MB DuckDB in inst/extdata/ ships with every install
inst/extdata/irish_buoys.duckdb  # 58.75 MB

# BETTER: Download on first use, cache locally
connect_duckdb <- function(db_path = rappdirs::user_cache_dir("irishbuoys")) {
  if (!file.exists(db_path)) download_database(db_path)
  DBI::dbConnect(duckdb::duckdb(), dbdir = db_path)
}

# BAD: LLM context files in inst/extdata/ctx/ ship with package
inst/extdata/ctx/dplyr.ctx.yaml  # Development tool, not runtime data

# GOOD: Exclude from build + centralise in llmcontent
# In .Rbuildignore:
#   ^inst/extdata/ctx$
# plan_pkgctx.R can still write here for local dev, but files
# never ship. Dependency contexts live in llmcontent central repo.
```

---

## Snapshot Tests for Live Data (MANDATORY)

### The Rule

**NEVER `expect_snapshot()` on growing/changing data properties.**

### Classification

| Property | Stable? | Test Strategy |
|----------|---------|---------------|
| Column names / schema | Yes | `expect_snapshot()` |
| Earliest dates (historical) | Yes | `expect_snapshot()` + `expect_lte()` |
| Row counts | No (grows) | `expect_gte(actual, REFERENCE_MIN)` |
| Date range / span | No (grows) | `expect_gte(span, REFERENCE_MIN_DAYS)` |
| QC percentages | No (shifts) | `expect_gte(pct, 50)` bounds check |
| Exact values | No | Never snapshot |

### Required Pattern: Fixed Reference Baseline

Every test file with data assertions MUST define reference constants:

```r
# ============================================================================
# FIXED REFERENCE BASELINE (established YYYY-MM-DD)
# These are minimum thresholds. Actual values must be >= these.
# Update ONLY when data source genuinely changes.
# ============================================================================
REFERENCE_STATIONS <- c("M2", "M3", "M4", "M5", "M6")
REFERENCE_MIN_RECORDS <- list(M2 = 1500L, M3 = 2100L)
REFERENCE_MIN_DAYS_SPAN <- 90
```

### Tests Must Pass After Every Data Update

If a test fails after `incremental_update()` or `tar_make()`, the test
is wrong (snapshots exact values of growing data). Fix the test, not the
data.

---

## Data Versioning (MANDATORY for DuckDB/Parquet)

Datasets that change over time MUST be versioned so past analyses can be reproduced.

| Strategy | When | How |
|----------|------|-----|
| **Date-partitioned parquet** | Time-series data (irishbuoys, solwatch) | `data/raw/YYYY-MM-DD/` partitions |
| **DuckDB snapshots** | Analytical databases (coMMpass) | `EXPORT DATABASE 'snapshots/YYYY-MM-DD'` |
| **Content-hashed RDS** | Small derived datasets | `saveRDS(df, paste0("data/", digest::digest(df), ".rds"))` |
| **Git tags** | Release datasets | `git tag data-v1.0` on the commit that produced the dataset |

**MANDATORY:** Every project with mutable data MUST record in `data_provenance` target (see `data-validation-timeseries` rule):
- Content hash of the dataset (`digest::digest()`)
- Acquisition timestamp
- Row count and date range

**Anti-pattern:** Overwriting `inst/extdata/data.parquet` with no way to recover the previous version.

## Checklist

- [ ] No files > 5 MB in `inst/extdata/` without justification
- [ ] No dependency `.ctx.yaml` files in `inst/extdata/ctx/` (use llmcontent)
- [ ] Self-context `.ctx.yaml` in `inst/extdata/ctx/` excluded via `.Rbuildignore`
- [ ] `plan_pkgctx.R` generates self-context ONLY (no dependency targets)
- [ ] `vignettes/data/` excluded in `.Rbuildignore`
- [ ] No `expect_snapshot()` on row counts, date ranges, or totals
- [ ] Fixed reference baseline defined for monotonic assertions
- [ ] `LazyData` only set if `data/` directory exists
- [ ] Large data accessed via download functions, not shipped
- [ ] Time-series data has `plan_data_validation.R` with temporal coverage targets
- [ ] Expected observation frequency documented as constant (e.g., `EXPECTED_OBS_PER_DAY <- 24`)
- [ ] Coverage < 30% aborts pipeline, < 80% warns
- [ ] Contiguous gaps detected and reported
- [ ] No duplicate (timestamp, entity_id) pairs
