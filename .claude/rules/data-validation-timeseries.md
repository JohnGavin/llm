---
paths:
  - "R/**"
  - "inst/extdata/**"
  - "_targets.R"
  - "R/tar_plans/**"
---
# Time-Series Data Validation

## Core Requirements (MANDATORY for any project with time-series data)

### 1. Temporal Coverage Target

Every project that ingests time-series data MUST have a target that computes
`expected_observations / actual_observations` per entity (station, sensor, patient, etc.).

- The expected frequency MUST be documented as a constant:
  ```r
  EXPECTED_FREQUENCY_HOURS <- 1L  # hourly
  EXPECTED_OBS_PER_DAY <- 24
  ```
- Coverage below 30% MUST abort the pipeline (`cli::cli_abort()`)
- Coverage below 80% MUST warn (`cli::cli_warn()`)

### 2. Temporal Gap Target

Every time-series project MUST detect contiguous gaps exceeding 2x the expected
frequency (e.g., for hourly data, flag gaps >= 2 hours).

### 3. Duplicate Detection Target

Every time-series project MUST verify no duplicate (timestamp, entity_id) pairs exist.

### 4. Freshness Target

Latest observation MUST be within the configured lookback window. If data is staler
than expected, the pipeline MUST warn.

### 5. Sampling Frequency Validation

Median interval between consecutive observations per entity MUST be within 2x the
expected frequency.

### 6. Time-Based vs Count-Based Windows (MANDATORY for irregular sampling)

Use `values[dates >= (max(dates) - 90)]` (time-based), NOT `tail(values, 30)` (count-based). Count-based windows on irregular data silently mix timeframes — "last 30" may span 6 months for one entity and 3 weeks for another. Count-based is fine for truly regular sampling (document the assumption).

### 7. Minimum Observations Gate (MANDATORY)

Rolling statistics MUST return `NA` below a minimum-observations threshold: median/MAD ≥ 4, mean/SD ≥ 5, regression ≥ 6, percentile ≥ `10/(1-p)`. Downstream code MUST handle `NA` explicitly (fallback to simpler signal).

### 8. All Validation as Targets

Validation MUST be encapsulated in `plan_data_validation.R` targets, NOT in ad-hoc
scripts or tests only. This ensures validation runs on every `tar_make()`, not just
when someone remembers to run tests.

### 9. Type Consistency on Join Keys (MANDATORY for cross-series joins)

`dplyr::full_join(by = "date")` between a tibble with `Date` and one with `POSIXct`
produces **zero matching rows with no warning** — values are never equal across
types. `lubridate::ceiling_date()`, `floor_date()`, `as_date()`, and most date-math
functions PRESERVE the input type, so a single POSIXct column propagates unchanged
through the whole pipeline.

**The bug looks like a frequency or alignment problem** (0 complete cases after
join, "incorrect number of dimensions" matrix errors downstream) but the root
cause is type-storage mismatch, not date-value mismatch.

**Required:**

1. **Defensively coerce date-like join keys at every cross-series boundary:**
   ```r
   x |> dplyr::mutate(date = as.Date(date)) |>
     dplyr::full_join(y |> dplyr::mutate(date = as.Date(date)), by = "date")
   ```
   This is cheap (no-op if already `Date`) and converts the silent-failure case
   into a no-op success.

2. **Add a `dv_join_key_types` validation target** when the project has ≥ 2
   independently-sourced time series that will eventually be joined:
   ```r
   targets::tar_target(dv_join_key_types, {
     series_targets <- c("series_a", "series_b", "series_c")  # populate per project
     types <- purrr::map_chr(series_targets, function(nm) {
       df <- targets::tar_read_raw(nm)
       paste(class(df$date), collapse = "/")
     })
     if (length(unique(types)) > 1L) {
       cli::cli_abort(c(
         "x" = "Inconsistent date-key types across {length(series_targets)} series.",
         "i" = "{paste(paste(series_targets, types, sep = ': '), collapse = '; ')}",
         "i" = "Coerce to a common type ({.code as.Date()}) at the producing target."
       ))
     }
     tibble::tibble(target = series_targets, date_class = types)
   })
   ```

3. **Diagnostic when a join produces 0 complete cases**, ALWAYS check types FIRST:
   ```r
   cat("Left date class:",  paste(class(left$date),  collapse = "/"), "\n")
   cat("Right date class:", paste(class(right$date), collapse = "/"), "\n")
   ```

**Common upstream sources of POSIXct contamination:**

| Source | Returns POSIXct |
|--------|-----------------|
| `arrow::read_parquet()` on TIMESTAMP columns | Yes (sometimes; depends on schema) |
| HuggingFace parquet via DuckDB | TIMESTAMP loads as POSIXct |
| `lubridate::ymd_hms()` and friends | Always |
| FRED / yfinance helpers that don't coerce | Often (check the package) |
| `as.POSIXct(...)` anywhere upstream | Always |

**Generalisation:** the same trap exists for any join key where storage type can
silently differ between sources — integer/double, character/factor, character/UUID,
Date/POSIXct. Date/POSIXct is the most common because date-math functions preserve
input type and the failure mode (0 matches, no error) is identical to "no overlap".

---

## Configuration Constants

Every `plan_data_validation.R` MUST define at the top: `EXPECTED_FREQUENCY_HOURS`, `ENTITY_ID_COLUMN`, `TIMESTAMP_COLUMN`, `MIN_COVERAGE_ABORT` (30%), `MIN_COVERAGE_WARN` (80%), `MAX_GAP_HOURS`, `MAX_STALE_HOURS`, `LOOKBACK_DAYS_VALIDATION`.

---

## Required Targets

| Target | What it validates | Fails pipeline? |
|--------|-------------------|-----------------|
| `dv_temporal_coverage` | Expected vs actual hourly obs per entity | Yes if < 30% |
| `dv_temporal_gaps` | Contiguous gaps >= threshold | No (informational) |
| `dv_sampling_frequency` | Median interval between obs | Yes if > 2x expected |
| `dv_station_completeness` | All expected entities present | Yes if entity missing |
| `dv_duplicate_check` | No duplicate primary keys | Yes if duplicates |
| `dv_freshness` | Latest observation within window | Yes if stale |
| `dv_value_ranges` | Physical bounds on numeric variables | Yes if > 5% fail |
| `dv_join_key_types` | Date/POSIXct/etc. consistency across series that will be joined | Yes if mixed |
| `dv_report` | Combines all above | No (summary) |

All targets MUST use `cue = tar_cue(mode = "always")`.

---

## Data Provenance (MANDATORY)

Every dataset MUST have lineage metadata answering: where, when, how.

Record as a `data_provenance` target with fields: source name, URL/path, acquisition timestamp, query/filter parameters, row count, date range, content hash (`digest::digest()`).

**Why:** Without provenance, you cannot tell if a result changed because code changed or data changed.

## External Data Source Validation (MANDATORY)

When fetching from external APIs (ERDDAP, GDC, Solana RPC, football APIs), validate the response before processing:

| Check | Fails? |
|-------|--------|
| Schema stability (column names/types match expected) | Yes — `cli::cli_abort()` |
| Response size (0 rows or <50% of expected) | Yes / Warn |
| Date continuity (unexpected gaps) | Warn |
| Value ranges (numeric within physical bounds) | Warn if >5% |

Validate with `setdiff(expected_cols, names(df))` immediately after fetch. **Anti-pattern:** piping API response directly into analysis without schema check.

## Anti-Patterns This Rule Prevents

- Assuming row counts are "probably fine" without computing expected counts
- Detecting outliers (quality control) but not temporal gaps
- Having pointblank value-range checks but no temporal completeness checks
- Validation only in tests (runs on `devtools::test()`) but not in pipeline
- The "69 vs 168 records" blind spot: pipeline succeeds silently with 41% coverage
- The "0 complete cases after join" blind spot: type mismatch (Date vs POSIXct) on the join key produces 0 matches with no warning, indistinguishable from a frequency/range mismatch (Section 9)

---

## Reference Implementation

- `irishbuoys/R/tar_plans/plan_data_validation.R` (8 targets, all dplyr, no raw SQL)

---

## Checklist Before Commit

- [ ] `plan_data_validation.R` exists with all 9 targets
- [ ] Expected frequency documented as constant (e.g., `EXPECTED_OBS_PER_DAY <- 24`)
- [ ] Coverage < 30% aborts pipeline, < 80% warns
- [ ] Contiguous gaps detected and reported
- [ ] No duplicate (timestamp, entity_id) pairs
- [ ] Data freshness checked against lookback window
- [ ] Physical value ranges checked
- [ ] **Join-key types consistent across cross-joinable series (`dv_join_key_types`)**
- [ ] Registered in `_targets.R` after `plan_data_acquisition`
