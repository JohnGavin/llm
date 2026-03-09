# Data Backend Selection

Choose the right backend based on data size and operation complexity.

## Decision Matrix

| Data Size | Operation | Backend | Why |
|-----------|-----------|---------|-----|
| < 100 MB | Any | `dplyr` | Readable, fast enough |
| 100 MB - 1 GB | Aggregation, joins | `duckdb` | Zero-copy SQL engine |
| > 1 GB | Complex grouping | `data.table` | Reference semantics, fastest |
| > RAM | Any | `arrow` + `duckdb` | Out-of-core processing |
| No deps allowed | Simple ops | base R | Zero dependencies |

## dplyr (Default Choice)

```r
# Readable, pipe-friendly, good for < 100 MB
data |>
  dplyr::filter(year >= 2020) |>
  dplyr::group_by(category) |>
  dplyr::summarise(total = sum(amount, na.rm = TRUE))
```

## duckdb (Medium-Large Data)

```r
# SQL engine on files — no need to load into R memory
con <- DBI::dbConnect(duckdb::duckdb())
tbl <- dplyr::tbl(con, "read_parquet('data/*.parquet')")
result <- tbl |>
  dplyr::filter(year >= 2020) |>
  dplyr::summarise(total = sum(amount)) |>
  dplyr::collect()
DBI::dbDisconnect(con, shutdown = TRUE)
```

## data.table (Maximum Performance)

```r
# Reference semantics — modifies in place, minimal copies
library(data.table)
dt <- fread("big.csv")
dt[year >= 2020, .(total = sum(amount, na.rm = TRUE)), by = category]
```

Use data.table when:
- Data > 1 GB and duckdb isn't suitable
- Need reference semantics (in-place modification)
- Complex rolling joins or non-equi joins
- Maximum single-threaded performance

## arrow (Larger Than Memory)

```r
# Process parquet files without loading into memory
library(arrow)
ds <- open_dataset("data/", format = "parquet")
ds |>
  dplyr::filter(year >= 2020) |>
  dplyr::group_by(category) |>
  dplyr::summarise(total = sum(amount)) |>
  dplyr::collect()
```

## base R (Zero Dependencies)

```r
# Simple operations, teaching, packages with minimal deps
aggregate(amount ~ category, data = df, FUN = sum)
subset(df, year >= 2020)
```

## Hybrid Patterns

```r
# arrow for I/O + dplyr for manipulation
data <- arrow::read_parquet("file.parquet") |>
  dplyr::filter(status == "active") |>
  dplyr::mutate(ratio = x / y)

# duckdb for heavy aggregation + dplyr for light post-processing
con <- DBI::dbConnect(duckdb::duckdb())
heavy <- dplyr::tbl(con, "read_csv_auto('big.csv')") |>
  dplyr::group_by(key) |>
  dplyr::summarise(n = dplyr::n()) |>
  dplyr::collect()
# Light post-processing in dplyr
heavy |> dplyr::arrange(desc(n)) |> head(20)
```
