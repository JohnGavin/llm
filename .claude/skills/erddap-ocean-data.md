# ERDDAP Ocean Data — Irish Weather Buoy Network

Spec-bundled skill for generating correct ERDDAP queries, pointblank
validation rules, and column mappings for the Irish Weather Buoy Network.

**When to consult:** Any task involving ERDDAP URLs, buoy variable names,
column renaming, QC flags, pointblank validation ranges, or adding new
variables to the irishbuoys package.

---

## Section 1: ERDDAP Tabledap Query Syntax

**Base URL:** `https://erddap.marine.ie/erddap/tabledap/IWBNetwork`

**URL pattern:** `{base}.{format}?{variables}&{constraints}`

### Formats

| Extension | Notes |
|-----------|-------|
| `.csv` | 2-row header: row 1 = names, row 2 = units (must skip row 2 when parsing) |
| `.json` | Nested `table.columnNames` + `table.rows` structure |
| `.tsv` | Tab-separated |
| `.nc` | NetCDF binary |
| `.html` | Human-readable table |

### Constraint Operators (URL-encoded)

| Operator | Encoded | Example |
|----------|---------|---------|
| `=` | `=` | `station_id=%22M3%22` |
| `!=` | `!=` | `station_id!=%22M1%22` |
| `=~` | `=~` | `station_id=~%22(M2\|M3)%22` (regex) |
| `>=` | `%3E%3D` | `time%3E%3D2024-01-01T00:00:00Z` |
| `<=` | `%3C%3D` | `time%3C%3D2024-12-31T23:59:59Z` |
| `>` | `%3E` | `wave_height%3E5` |
| `<` | `%3C` | `wind_speed%3C10` |

### Time Format

- ISO 8601: `YYYY-MM-DDTHH:MM:SSZ` (UTC)
- Relative: `now-7days`, `now-1month`

### String Values

- Must be double-quoted: `%22M3%22` (URL-encoded `"M3"`)
- Regex patterns: `=~%22(M2|M3|M5)%22`

### Server-Side Functions

| Function | Purpose | Example |
|----------|---------|---------|
| `distinct()` | Deduplicate rows | `...csv?station_id,longitude,latitude&distinct()` |
| `orderBy("var")` | Sort ascending | `&orderBy(%22time%22)` |
| `orderByMax("var")` | Get max per group | `&orderByMax(%22time%22)` |
| `orderByClosest("var,interval")` | Nearest to intervals | `&orderByClosest(%22time,1day%22)` |

### Parsing Quirks

- **CSV row 2 is units** — skip when reading (see `erddap_client.R:87-90`)
- **NaN** — ERDDAP returns `"NaN"` for missing values; convert to `NA`
- **Fill values** — `-999.0` (most vars), `99999.0` (coordinates)

---

## Section 2: IWB Variable Dictionary (22 Variables)

Source: `R/erddap_client.R:47-53` (ERDDAP names), `R/database.R:187-199`
(renaming), `R/data_dictionary.R:22-152` (metadata)

### Column Mapping: ERDDAP Name -> DB Column

The `load_to_duckdb()` function (`R/database.R:187-199`) lowercases all
names then applies these `gsub()` renames:

| ERDDAP Name | DB Column (snake_case) |
|-------------|------------------------|
| station_id | station_id |
| CallSign | call_sign |
| longitude | longitude |
| latitude | latitude |
| time | time |
| AtmosphericPressure | atmospheric_pressure |
| AirTemperature | air_temperature |
| DewPoint | dew_point |
| WindDirection | wind_direction |
| WindSpeed | wind_speed |
| Gust | gust |
| RelativeHumidity | relative_humidity |
| SeaTemperature | sea_temperature |
| salinity | salinity |
| WaveHeight | wave_height |
| WavePeriod | wave_period |
| MeanWaveDirection | mean_wave_direction |
| Hmax | hmax |
| Tp | tp |
| ThTp | thtp |
| SprTp | sprtp |
| QC_Flag | qc_flag |

**Renaming mechanism:** `tolower()` then `gsub("callsign", "call_sign", ...)`,
etc. The gsub operates on already-lowercased names (e.g. `"callsign"` not
`"CallSign"`).

### Full Variable Reference

| ERDDAP Name | DB Column | Type | Units | Valid Range | Description |
|-------------|-----------|------|-------|-------------|-------------|
| station_id | station_id | String | - | M1-M6, FS1, Belmullet-AMETS | Station identifier |
| CallSign | call_sign | String | - | 62023-62095 | International radio call sign |
| longitude | longitude | Float64 | degrees_east | -15.88 to -5.43 | Geographic longitude |
| latitude | latitude | Float64 | degrees_north | 51.22 to 55.00 | Geographic latitude |
| time | time | POSIXct | seconds since 1970-01-01 | 2002-present | UTC timestamp |
| AtmosphericPressure | atmospheric_pressure | Float64 | millibars | 900-1100 (typical: 970-1030) | Sea-level pressure |
| AirTemperature | air_temperature | Float64 | degrees_C | -10 to 30 | 3-4m above sea surface |
| DewPoint | dew_point | Float64 | degrees_C | -15 to 25 | Saturation temperature |
| WindDirection | wind_direction | Float64 | degrees_true | 0-360 | Direction FROM which wind blows |
| WindSpeed | wind_speed | Float64 | **knots** | 0-60 | 10-minute average |
| Gust | gust | Float64 | **knots** | 0-80 | 3-second maximum |
| RelativeHumidity | relative_humidity | Float64 | percent | 0-100 | Atmospheric RH |
| SeaTemperature | sea_temperature | Float64 | degrees_C | 0-25 | Sea surface temperature |
| salinity | salinity | Float64 | PSU | 30-36 | Practical salinity |
| WaveHeight | wave_height | Float64 | meters | 0-15 (validation: 0-30) | Hs (significant wave height) |
| WavePeriod | wave_period | Float64 | seconds | 0-20 | Mean wave period |
| MeanWaveDirection | mean_wave_direction | Float64 | degrees_true | 0-360 | Direction FROM which waves come |
| Hmax | hmax | Float64 | meters | 0-30 (validation: 0-40) | Maximum individual wave height |
| Tp | tp | Float64 | seconds | 0-25 | Peak spectral period |
| ThTp | thtp | Float64 | degrees_true | 0-360 | Peak spectral direction |
| SprTp | sprtp | Float64 | degrees | 0-180 | Directional spread at peak |
| QC_Flag | qc_flag | Integer | - | 0, 1, 9 | Quality control flag |

**Key unit traps:**
- WindSpeed and Gust are in **knots**, NOT m/s. Conversion: 1 knot = 0.514 m/s
- WaveHeight typical max is ~15m but validation allows 0-30m
- Hmax can exceed 2x WaveHeight (rogue waves); validation allows 0-40m
- Beaufort 8 (Gale) = 34 knots, Beaufort 12 (Hurricane) = 64 knots

---

## Section 3: QC Flag Semantics

Source: `R/data_dictionary.R:147` and `R/email_summary.R:30-33`

| QC_Flag | Meaning | Usage |
|---------|---------|-------|
| 0 | Unknown / not quality controlled | Include in raw counts |
| 1 | Good data (passed all QC tests) | **Use for analysis** |
| 9 | Missing value (no data available) | Exclude always |

### Filtering Rules

| Task | Filter |
|------|--------|
| Scientific analysis | `qc_flag == 1` (good only) |
| Coverage statistics | `qc_flag != 9` (exclude missing) |
| Raw record counts | No filter (include all) |
| ERDDAP default | Returns all flags -- always filter client-side |

### Code Reference

`query_buoy_data()` in `R/database.R:328` applies `qc_flag == 1L` when
`qc_filter = TRUE` (default). `generate_weekly_summary()` in
`R/email_summary.R:30-33` uses `qc_flag != 9` for weekly stats.

---

## Section 4: Domain Knowledge for Generation Tasks

### Generating ERDDAP Query URLs

```
# Pattern: base.format?vars&constraints
https://erddap.marine.ie/erddap/tabledap/IWBNetwork.csv?time,station_id,WaveHeight,Hmax,QC_Flag&time%3E%3D2024-01-01T00:00:00Z&time%3C%3D2024-01-31T23:59:59Z&station_id=~%22(M2|M3)%22
```

Checklist:
1. Use ERDDAP CamelCase names in URL (e.g. `WaveHeight`, not `wave_height`)
2. URL-encode operators: `>=` -> `%3E%3D`, `<=` -> `%3C%3D`
3. Wrap string values in `%22` (double quotes): `station_id=%22M3%22`
4. Use regex for multiple stations: `station_id=~%22(M2|M3|M5)%22`
5. Time in ISO 8601 UTC: `2024-01-01T00:00:00Z`
6. Always include `QC_Flag` in variable list

### Generating pointblank Validation Rules

Use **DB column names** (snake_case), not ERDDAP names. Reference ranges
from `R/validation.R:94-145`:

| Column | pointblank Check | Left | Right | Notes |
|--------|-----------------|------|-------|-------|
| wave_height | `col_vals_between` | 0 | 30 | `na_pass = TRUE` |
| hmax | `col_vals_between` | 0 | 40 | `na_pass = TRUE` |
| wind_speed | `col_vals_between` | 0 | 100 | Units: knots |
| gust | `col_vals_between` | 0 | 150 | Units: knots |
| atmospheric_pressure | `col_vals_between` | 900 | 1100 | Units: millibars |
| sea_temperature | `col_vals_between` | 0 | 25 | Units: degrees_C |
| air_temperature | `col_vals_between` | -10 | 30 | Units: degrees_C |
| relative_humidity | `col_vals_between` | 0 | 100 | Units: percent |

Rogue wave detection rule:
```r
pointblank::col_vals_expr(expr = ~ hmax > wave_height, label = "hmax > wave_height")
# Rogue wave threshold: hmax > 2 * wave_height AND wave_height > 2
```

### Adding a New Variable to the Package

All 6 files that need updating:

| Step | File | Location | Action |
|------|------|----------|--------|
| 1 | `R/erddap_client.R` | Line ~47 (variables vector) | Add ERDDAP CamelCase name |
| 2 | `R/erddap_client.R` | Line ~117 (numeric_cols vector) | Add to numeric conversion if numeric |
| 3 | `R/database.R` | Line ~187 (gsub renames) | Add CamelCase -> snake_case gsub |
| 4 | `R/database.R` | Line ~91 (CREATE TABLE) | Add column to schema DDL |
| 5 | `R/data_dictionary.R` | Line ~22 (get_data_dictionary) | Add row with units/range/description |
| 6 | `R/validation.R` | Line ~94 (validate_buoy_data) | Add pointblank range check |

### Station Coverage

**In `get_station_info()` (hardcoded):** M2, M3, M4, M5, M6

**Available on ERDDAP but NOT in `get_station_info()`:**
M1, FS1, Belmullet-AMETS, M4-Archive

**Valid station IDs for validation:** M1, M2, M3, M4, M5, M6, FS1
(defined in `R/validation.R:102`)

### Physical Relationships (for sanity checks)

- `hmax >= wave_height` (always; hmax is the largest single wave)
- `gust >= wind_speed` (gust is 3-sec max, wind_speed is 10-min avg)
- `gust / wind_speed` typically 1.3-2.0 (gust factor)
- `dew_point <= air_temperature` (physically required)
- `hmax > 2 * wave_height` with `wave_height > 2` indicates rogue wave
- Fog risk: `dew_point` approaches `air_temperature`

### Wind Speed Reference (Beaufort Scale)

| Beaufort | Description | Knots | m/s |
|----------|-------------|-------|-----|
| 0 | Calm | <1 | <0.5 |
| 4 | Moderate breeze | 11-16 | 5.5-8.0 |
| 8 | Gale | 34-40 | 17.2-20.7 |
| 10 | Storm | 48-55 | 24.5-28.4 |
| 12 | Hurricane | 64+ | 32.7+ |

Conversion: **1 knot = 0.514 m/s = 1.852 km/h**

Warning thresholds (from `R/data_dictionary.R:224-225`):
- Gust > 48 knots: gale warning
- Gust > 63 knots: storm warning

### Embedded Definition Links (MANDATORY)

When generating captions, emails, or documentation that mention domain
terms, always link to their definitions:

| Term | Link |
|------|------|
| knots | `https://en.wikipedia.org/wiki/Knot_(unit)` |
| Beaufort scale | `https://en.wikipedia.org/wiki/Beaufort_scale` |
| significant wave height (Hs) | `https://en.wikipedia.org/wiki/Significant_wave_height` |
| rogue wave | `https://en.wikipedia.org/wiki/Rogue_wave` |
| PSU (salinity) | `https://en.wikipedia.org/wiki/Practical_salinity_unit` |
| Open-Meteo | `https://open-meteo.com/` |
| ERDDAP | `https://erddap.marine.ie/erddap/` |
| Irish Weather Buoy Network | `https://www.marine.ie/site-area/data-services/real-time-observations/irish-weather-buoy-network` |
| Met Eireann warnings | `https://www.met.ie/warnings` |

### Workflow Schedules

| Workflow | Cron | Human |
|----------|------|-------|
| Storm alert | `0 8 * * *` | Daily at 08:00 UTC |
| Data update | `0 2 * * 0` | Sundays at 02:00 UTC |
