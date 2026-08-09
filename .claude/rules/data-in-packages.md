---
paths:
  - "inst/extdata/**"
  - "data/**"
  - "vignettes/data/**"
  # The migration-snapshot section below is decided while editing ETL and
  # pipeline code, not while editing the data directory it protects. A rule
  # that loads only after the damage is done is a rule that never fires.
  - "R/etl_*.R"
  - "R/tar_plans/**"
  - "_targets.R"
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

## Snapshot Before a Migration That Rewrites Existing Rows (MANDATORY)

The table above covers *periodic* versioning. This is the *event-triggered*
snapshot, and it is the one that gets skipped — because the run that needs it
looks like every other pipeline run right up until it isn't.

### Trigger

Before any pipeline run that will **change rows that already exist**, rather
than only appending new ones:

| Change | Why it rewrites |
|---|---|
| Entity/component rename or merge | rows change identity; duplicates may collapse |
| Parser fix affecting already-ingested values | stored values change under a stable key |
| Regenerating source files from their origin | the inputs the store rebuilds from change |
| Any run whose expected row-count delta is non-zero | by definition |

NOT needed for pure appends, or for a store fully regenerable from committed
inputs in minutes. **Say which of those applies** rather than skipping in
silence — "it's regenerable" is a claim, and the time to test it is not
after a bad run.

### Name the snapshot for the CHANGE, not just the date

```
<store>.bak_YYYYMMDD_pre_<issue-or-change>
mycare.duckdb.bak_20260806_pre_030_040
```

A date alone stops being enough at about the third one. The reader restoring
in six months needs to know which snapshot predates the thing they want to
undo — the filename is the rollback index, so put the change in it.

### Predict the delta, then verify it

A snapshot makes a run **recoverable**; it does not make it **correct**. State
the expected row-count change and its reason before running, then check:

```
predicted  12,334 -> 12,324   (-10, all same-value same-date duplicates)
actual     12,329             (-10 from the merge, +5 from a newly-routed source)
```

Both numbers were expected and each is attributable to a named change. An
unexplained delta is a defect until reconciled — **including a delta of zero
where one was expected**, which is the `zero-metric-evidence-or-defect` case:
a migration that changed nothing usually means it did not run.

### Prune

Snapshots are large and accumulate quietly — `du -ch <store>.bak*` reached
396 MB across 8 files in one project before anyone looked. Keep the ones that
bracket a schema or identity change; delete the rest once the following run is
verified.

## Checklist

- [ ] No files > 5 MB in `inst/extdata/` without justification
- [ ] No `.ctx.yaml` in `inst/extdata/ctx/` (use llmcontent)
- [ ] `vignettes/data/` in `.Rbuildignore`
- [ ] No `expect_snapshot()` on row counts/date ranges
- [ ] Fixed reference baseline for monotonic assertions
- [ ] Large data via download functions, not shipped
- [ ] Time-series has temporal coverage targets
- [ ] Row-rewriting migration: snapshot taken FIRST, named for the change
- [ ] Row-count delta predicted before the run and reconciled after
- [ ] Stale snapshots pruned once the following run is verified
