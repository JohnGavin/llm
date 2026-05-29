---
name: data-transformation-stack
description: "Use when building data pipelines with DuckDB, Arrow, or dbt, reading JSON/CSV/Parquet without loading into R memory, or orchestrating SQL transformations. Triggers: DuckDB, Arrow, dbt, Parquet, data pipeline, SQL transformation, data wrangling."
---
# Data Transformation Stack: DuckDB, Arrow, and dbt

## Description

Use DuckDB + Arrow as the primary data wrangling stack, with optional dbt for SQL transformation orchestration. DuckDB reads JSON, CSV, Parquet directly and processes with SQL — all without loading into R memory.

## Purpose

Use this skill when:
- Processing JSON from APIs (RSS feeds, curl output)
- Querying log files or CSV exports
- Joining data across formats (CSV + Parquet + JSON)
- Analyzing data larger than memory
- Replacing shell pipelines with SQL
- Orchestrating SQL transformations with dbt

## The Stack

```
┌─────────────────────────────────────────────────────────────┐
│  duckplyr   - dplyr backend using DuckDB (PREFERRED)       │
│  duckdb     - SQL engine, reads any format directly         │
│  arrow      - Large data I/O, Parquet/Feather, zero-copy    │
│  dbplyr     - dplyr verbs → SQL translation                 │
│  dplyr      - Tidy data manipulation                        │
│  dbt-duckdb - SQL transformation orchestration (optional)   │
└─────────────────────────────────────────────────────────────┘
```

## duckplyr - The Recommended Approach

**duckplyr** is a drop-in replacement for dplyr that uses DuckDB as its backend.

```r
library(duckplyr)

# dplyr verbs now execute on DuckDB automatically
mtcars |>
  filter(mpg > 20) |>
  group_by(cyl) |>
  summarise(mean_hp = mean(hp))

# Read files directly
read_csv_duckdb("large_file.csv") |>
  filter(value > 100) |>
  summarise(total = sum(amount))

# Enable globally
duckplyr::methods_overwrite()  # dplyr verbs now use DuckDB
```

## Core Patterns

### Query Files Directly (No Loading!)

```r
con <- dbConnect(duckdb())

# JSON, CSV, Parquet - all direct
tbl(con, sql("SELECT * FROM read_json_auto('data.json')"))
tbl(con, sql("SELECT * FROM read_csv_auto('data.csv')"))
tbl(con, sql("SELECT * FROM 'logs/*.parquet'"))

# Cross-format joins
tbl(con, sql("
  SELECT a.*, b.value
  FROM read_json_auto('api.json') a
  JOIN read_csv_auto('lookup.csv') b ON a.id = b.id
"))
```

### Arrow Integration

```r
library(arrow)
dataset <- open_dataset("large_data/", format = "parquet")
duckdb_register_arrow(con, "arrow_data", dataset)
tbl(con, "arrow_data") |>
  filter(date >= "2024-01-01") |>
  summarise(total = sum(value))
```

### targets Integration

```r
tar_target(raw_data, {
  con <- dbConnect(duckdb())
  result <- tbl(con, sql("SELECT * FROM read_json_auto('api.json')")) |> collect()
  dbDisconnect(con)
  result
})
```

## dbt Integration (Optional)

For projects needing SQL transformation orchestration, use dbt with the duckdb adapter.

See [dbt-integration.md](references/dbt-integration.md) for setup, configuration, models, and targets orchestration.

## Fuzzy Matching with fuzzyjoin

For entity resolution and categorisation pipelines (merchant names, team names, medication names), use `{fuzzyjoin}` when exact string equality fails:

```r
library(fuzzyjoin)

# Match raw transaction descriptions to category lookup
# jw = Jaro-Winkler distance (good for OCR/typo errors)
int_categorised <- stg_transactions |>
  stringdist_left_join(
    category_lookup,
    by = c("description" = "pattern"),
    method = "jw",
    max_dist = 0.2        # 0 = exact, 1 = totally different
  )

# Regex matching (for pattern-based categorisation)
int_categorised <- stg_transactions |>
  fuzzy_left_join(
    category_lookup,
    by = c("description" = "pattern"),
    match_fun = stringr::str_detect
  )
```

### Method selection

| Method | Use when | R equivalent |
|--------|----------|--------------|
| `jw` | Short strings, name matching, OCR noise | Jaro-Winkler |
| `lv` | Longer strings, edit distance | Levenshtein |
| `cosine` | Bag-of-words similarity | Token overlap |
| `regex` | Pattern-based (known structures) | `str_detect` |

### dbt equivalent

The dbt equivalent uses SQL `ILIKE` with `qualify row_number()`:
```sql
select t.*, c.category
from transactions t
left join categories c
  on t.description ilike '%' || c.pattern || '%'
qualify row_number() over (partition by t.id order by c.priority) = 1
```

Use `{fuzzyjoin}` for R-side pipelines; use the SQL pattern in dbt/DuckDB when the dataset is too large for in-memory matching.

### In a targets pipeline

```r
tar_target(int_transactions_categorised, {
  stg_transactions |>
    fuzzyjoin::stringdist_left_join(
      tar_read(stg_category_lookup),  # categories also a target
      by = c("description" = "pattern"),
      method = "jw",
      max_dist = 0.15
    ) |>
    dplyr::mutate(category = dplyr::coalesce(category, "uncategorised"))
})
```

## Decision Matrix

| Use Case | Approach |
|----------|----------|
| Standard dplyr workflows | `duckplyr` (drop-in replacement) |
| Complex SQL, window functions | `duckdb` + `tbl()` + SQL |
| Remote file queries (httpfs) | `duckdb` with extensions |
| Larger than memory | `arrow::open_dataset()` + register with DuckDB |
| SQL transformation pipelines | `dbt-duckdb` adapter |
| API response processing | `read_json_auto()` on URL or curl output |

## Anti-Patterns

```r
# BAD: Loading everything into R first
data <- jsonlite::read_json("large.json")

# GOOD: Let DuckDB handle it
result <- tbl(con, sql("SELECT * FROM read_json_auto('large.json')")) |>
  filter(...) |> summarise(...) |> collect()

# BAD: Multiple file reads in a loop
for (f in files) data <- rbind(data, read_csv(f))

# GOOD: Glob pattern
tbl(con, sql("SELECT * FROM 'data/*.csv'"))
```

## Resources

- [DuckDB R API](https://duckdb.org/docs/api/r)
- [DuckDB + dplyr](https://duckdb.org/docs/guides/sql_editors/dplyr)
- [Arrow + DuckDB](https://arrow.apache.org/docs/r/articles/arrow.html#duckdb)
- [dbt-duckdb adapter](https://github.com/jwills/dbt-duckdb)
- [DuckPlyr](https://duckdb.org/2024/04/02/duckplyr)
