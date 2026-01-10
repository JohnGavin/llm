# Data Wrangling with DuckDB and Arrow

## Description

Use DuckDB as the primary data wrangling tool, avoiding traditional ETL pipelines. DuckDB can read JSON, CSV, Parquet directly, process with SQL, and export in any format - all without loading data into R memory.

## Purpose

Use this skill when:
- Processing JSON from APIs (RSS feeds, curl output)
- Querying log files or CSV exports
- Joining data across formats (CSV + Parquet + JSON)
- Analyzing data larger than memory
- Replacing shell pipelines with SQL

## The Stack

```
┌─────────────────────────────────────────────────────────────┐
│  duckdb     - SQL engine, reads any format directly        │
│  arrow      - Large data I/O, Parquet/Feather, zero-copy   │
│  dbplyr     - dplyr verbs → SQL translation                │
│  dplyr      - Tidy data manipulation                        │
└─────────────────────────────────────────────────────────────┘
```

## Core Patterns

### 1. Basic Setup

```r
library(duckdb)
library(dplyr)
library(dbplyr)

# In-memory database (default)
con <- dbConnect(duckdb())

# Persistent database
con <- dbConnect(duckdb(), dbdir = "my_data.duckdb")

# Always disconnect when done
# dbDisconnect(con, shutdown = TRUE)
```

### 2. Query Files Directly (No Loading!)

```r
# JSON files
tbl(con, sql("SELECT * FROM read_json_auto('data.json')"))

# CSV files
tbl(con, sql("SELECT * FROM read_csv_auto('data.csv')"))

# Parquet files (with glob patterns)
tbl(con, sql("SELECT * FROM 'logs/*.parquet'"))

# Multiple formats in one query!
tbl(con, sql("
  SELECT a.*, b.value
  FROM read_json_auto('api.json') a
  JOIN read_csv_auto('lookup.csv') b ON a.id = b.id
"))
```

### 3. RSS Feed Processing

```r
# Fetch and process RSS feed
rss_data <- tbl(con, sql("
  SELECT
    unnest(channel.item) as item
  FROM read_json_auto('https://example.com/feed.rss')
")) |>
  mutate(
    title = item$title,
    link = item$link,
    pubDate = item$pubDate
  ) |>
  select(-item) |>
  collect()
```
### 4. Shell Command Output → SQL

```r
# Using httpfs extension for remote files
dbExecute(con, "INSTALL httpfs; LOAD httpfs;")

# Query remote JSON directly
tbl(con, sql("
  SELECT * FROM read_json_auto(
    'https://api.github.com/repos/JohnGavin/llm/commits'
  )
")) |>
  mutate(
    sha = commit$sha,
    message = commit$message,
    date = commit$author$date
  )
```

### 5. Export to Any Format

```r
# To Parquet
dbExecute(con, "COPY (SELECT * FROM my_table) TO 'output.parquet'")

# To CSV
dbExecute(con, "COPY (SELECT * FROM my_table) TO 'output.csv' (HEADER)")

# To JSON
dbExecute(con, "COPY (SELECT * FROM my_table) TO 'output.json'")
```

## Integration with Arrow

```r
library(arrow)

# Arrow for larger-than-memory data
dataset <- open_dataset("large_data/", format = "parquet")

# Register Arrow dataset with DuckDB
duckdb_register_arrow(con, "arrow_data", dataset)

# Now query with SQL
tbl(con, "arrow_data") |>
  filter(date >= "2024-01-01") |>
  summarise(total = sum(value))
```

## Integration with targets

```r
# _targets.R
library(targets)
library(crew)

tar_option_set(
  controller = crew_controller_local(workers = 4)
)

list(
  tar_target(raw_data, {
    con <- dbConnect(duckdb())
    result <- tbl(con, sql("SELECT * FROM read_json_auto('api.json')")) |>
      collect()
    dbDisconnect(con)
    result
  }),

  tar_target(processed, {
    raw_data |>
      filter(!is.na(value)) |>
      summarise(mean_val = mean(value))
  })
)
```

## Common DuckDB Extensions

```r
# Install and load extensions
dbExecute(con, "INSTALL httpfs; LOAD httpfs;")   # Remote file access
dbExecute(con, "INSTALL json; LOAD json;")       # JSON functions
dbExecute(con, "INSTALL parquet; LOAD parquet;") # Parquet support
dbExecute(con, "INSTALL excel; LOAD excel;")     # Excel files
```

## Decision Matrix

| Task | Use This |
|------|----------|
| Query JSON/CSV/Parquet | `duckdb::tbl(con, sql("SELECT * FROM read_*"))` |
| Join across formats | DuckDB SQL with multiple `read_*` |
| Larger than memory | `arrow::open_dataset()` + register with DuckDB |
| API response processing | `read_json_auto()` on URL or curl output |
| Log file analysis | `read_csv_auto()` with glob patterns |
| Export results | `COPY ... TO 'file.parquet'` |

## Anti-Patterns

```r
# ❌ AVOID: Loading everything into R first
data <- jsonlite::read_json("large.json")
result <- data |> filter(...) |> summarise(...)

# ✅ PREFER: Let DuckDB handle it
result <- tbl(con, sql("SELECT * FROM read_json_auto('large.json')")) |>
  filter(...) |>
  summarise(...) |>
  collect()  # Only collect final result

# ❌ AVOID: Multiple file reads in a loop
for (f in files) {
  data <- rbind(data, read_csv(f))
}

# ✅ PREFER: Glob pattern
tbl(con, sql("SELECT * FROM 'data/*.csv'"))

# ❌ AVOID: Shell pipeline for data processing
system("curl api | jq '.items[]' | grep pattern")

# ✅ PREFER: DuckDB SQL
tbl(con, sql("
  SELECT * FROM read_json_auto('https://api/endpoint')
  WHERE field LIKE '%pattern%'
"))
```

## Parallel Processing with mirai/crew

For CPU-intensive transforms after DuckDB query:

```r
library(mirai)

# Parallel processing of DuckDB results
data <- tbl(con, sql("SELECT * FROM large_table")) |> collect()

# Process in parallel with mirai
results <- mirai_map(
  split(data, data$group),
  \(chunk) expensive_computation(chunk)
)
```

## Resources

- [DuckDB R API](https://duckdb.org/docs/api/r)
- [DuckDB + dplyr](https://duckdb.org/docs/guides/sql_editors/dplyr)
- [Arrow + DuckDB](https://arrow.apache.org/docs/r/articles/arrow.html#duckdb)
- [Deep Dive into DuckDB](https://codecut.ai/deep-dive-into-duckdb-data-scientists/)
