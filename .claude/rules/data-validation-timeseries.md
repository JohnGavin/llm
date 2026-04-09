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

When computing rolling statistics (median, MAD, z-score, moving average) over irregularly sampled time series, use a **time-based window**, not a count-based window.

| Pattern | Correct for irregular sampling? |
|---|---|
| `tail(values, 30)` — last 30 readings | **NO** — silently mixes timeframes |
| `values[dates >= (max(dates) - 90)]` — last 90 days | **YES** |

**Why:** Lab results, sensor data during gaps, and any human-initiated measurement stream have non-uniform inter-arrival times. A count-based window of "last 30" might span 6 months in one patient and 3 weeks in another — the resulting statistics are incomparable.

```r
# RIGHT: time-based
rolling_window <- function(values, dates, window_days = 90) {
  cutoff <- max(dates, na.rm = TRUE) - window_days
  values[dates >= cutoff]
}

# WRONG: count-based on irregular data
tail(values, 30)
```

For truly regular sampling (e.g. 1Hz sensor, daily cron job), count-based is fine and simpler. Document the assumption. If sampling regularity ever changes, the count-based code fails silently.

### 7. Minimum Observations Gate (MANDATORY)

Any rolling statistic MUST have a minimum-observations gate below which it returns `NA` (or a simpler fallback), not a noisy partial result:

```r
if (length(window_vals) < min_obs) {
  return(list(score = NA_real_, baseline = NA_real_, mad = NA_real_))
}
```

Recommended minimums:
- Median / MAD / quantiles: `≥ 4` (median of fewer is unstable)
- Mean / SD (if you insist): `≥ 5` (SD of 2 is meaningless)
- Regression slope: `≥ 6`
- Percentile ≥ 0.9: `≥ 10 / (1 - p)`

Downstream code MUST handle the `NA` case explicitly — usually by falling back to a simpler signal (e.g. distance from target, last-known value).

### 8. All Validation as Targets

Validation MUST be encapsulated in `plan_data_validation.R` targets, NOT in ad-hoc
scripts or tests only. This ensures validation runs on every `tar_make()`, not just
when someone remembers to run tests.

---

## Configuration Constants

Every `plan_data_validation.R` MUST define these constants at the top:

```r
EXPECTED_FREQUENCY_HOURS <- 1L        # Adjust per project
ENTITY_ID_COLUMN <- "station_id"      # Primary entity identifier
TIMESTAMP_COLUMN <- "time"            # Timestamp column name
MIN_COVERAGE_ABORT <- 30              # % below which pipeline aborts
MIN_COVERAGE_WARN <- 80               # % below which pipeline warns
MAX_GAP_HOURS <- 6                    # Flag gaps >= this many hours
MAX_STALE_HOURS <- 72                 # Maximum data staleness
LOOKBACK_DAYS_VALIDATION <- 7L        # Validation window
```

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

---

## Reference Implementation

- `irishbuoys/R/tar_plans/plan_data_validation.R` (8 targets, all dplyr, no raw SQL)

---

## Checklist Before Commit

- [ ] `plan_data_validation.R` exists with all 8 targets
- [ ] Expected frequency documented as constant (e.g., `EXPECTED_OBS_PER_DAY <- 24`)
- [ ] Coverage < 30% aborts pipeline, < 80% warns
- [ ] Contiguous gaps detected and reported
- [ ] No duplicate (timestamp, entity_id) pairs
- [ ] Data freshness checked against lookback window
- [ ] Physical value ranges checked
- [ ] Registered in `_targets.R` after `plan_data_acquisition`
