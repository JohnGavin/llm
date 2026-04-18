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
