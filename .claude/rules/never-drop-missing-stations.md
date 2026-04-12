# Rule: Never Silently Drop Missing Stations (CRITICAL)

## When This Applies
Any report, dashboard, email, API, or validation output that summarises
per-entity (station, patient, sensor, device) metrics.

## CRITICAL: Missing Data MUST Be Reported, NEVER Omitted

When an entity has no recent data, the report MUST show a row for that entity
with explicit "no data" / "offline" / 0 values. Silently dropping it makes
coverage look 100% when it is not. This is a **data integrity violation**.

## The Bug Pattern

```r
# BAD: group_by() only includes entities with at least one row.
# Entities with zero rows in the time window are silently dropped.
data |>
  filter(time >= start, time < end) |>
  group_by(station_id) |>
  summarise(coverage = n() / expected)
# Result: stations with no data don't appear AT ALL.

# GOOD: Start from the canonical entity list, then left-join data.
all_stations <- get_station_info()  # authoritative list
coverage <- data |>
  filter(time >= start, time < end) |>
  group_by(station_id) |>
  summarise(actual = n(), .groups = "drop")

all_stations |>
  left_join(coverage, by = "station_id") |>
  mutate(
    actual = replace_na(actual, 0L),
    coverage_pct = round(100 * actual / expected, 1),
    status = if_else(actual == 0, "offline", "reporting")
  )
# Result: ALL stations appear. Offline stations show 0 / "offline".
```

## Required Pattern: "canonical list first, left-join data"

Every summary that groups by entity MUST:

1. **Start from the canonical entity list** (e.g., `get_station_info()`,
   patient roster, sensor registry) — NOT from the data itself.
2. **Left-join** the data summary onto the canonical list.
3. **Replace NA with explicit zero/offline** values.
4. **Assert the output has the expected entity count** before returning.

```r
stopifnot(
  "Output must include all stations" =
    nrow(result) == nrow(get_station_info())
)
```

## Where This Has Bitten Us (irishbuoys, 2026-04)

M4 buoy went offline 2026-03-29. For 13 days, every report silently showed
4 stations at 100% coverage instead of 5 stations at 80% coverage:

| Component | Silent drop mechanism |
|---|---|
| Email weekly summary | `group_by(station_id)` on filtered data |
| `dv_temporal_coverage` | Time-range filter then `group_by()` |
| Dashboard coverage table | `summarise()` only includes stations with data |
| API stats/trends/seasonal | Derived from `analysis_data` which uses `filter(!is.na(wave_height))` |

Every downstream consumer inherited the gap because the upstream
`analysis_data` target dropped M4 via `filter(!is.na(wave_height))`.

## Enforcement

- Code review: any `group_by(entity_id) |> summarise()` that produces
  per-entity output MUST be preceded by a left-join from the canonical list
  OR followed by a row-count assertion.
- The `dv_station_completeness` target detects missing stations and warns.
  But warning alone is insufficient — downstream reports must still INCLUDE
  the missing station with explicit "no data" status.

## Related Rules

- `data-validation-timeseries` — temporal coverage checks
- `medical-etl-quality` — "NEVER discard data"
- `missing-data-handling` — NA handling patterns
