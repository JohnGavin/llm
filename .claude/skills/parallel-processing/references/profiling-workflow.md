# Profiling Workflow

**Rule: Profile BEFORE parallelizing.** Most performance issues are algorithmic, not parallelism problems.

## Tool Decision Matrix

| Tool | Use When | Output |
|------|----------|--------|
| `profvis::profvis()` | Visual flame graph of where time is spent | Interactive HTML |
| `bench::mark()` | Comparing alternative implementations | Tibble with stats |
| `system.time()` | Quick wall-clock timing | elapsed seconds |
| `Rprof()` | Low-level, no dependencies | Text summary |

## Step 1: Profile with profvis

```r
profvis::profvis({
  data <- readr::read_csv("big.csv", show_col_types = FALSE)
  result <- data |>
    dplyr::group_by(category) |>
    dplyr::summarise(mean_val = mean(value, na.rm = TRUE))
})
# Opens interactive flame graph — find the tallest bars
```

## Step 2: Focus on the Slowest Part (80/20 Rule)

Only optimize what profvis shows as the bottleneck. Common findings:
- I/O (reading files) → switch to `arrow::read_parquet()` or `duckdb`
- Grouping/aggregation → switch to `data.table` or `duckdb`
- Row-wise operations → vectorize or parallelize

## Step 3: Benchmark Alternatives

```r
bench::mark(
  base = mean(x),
  vectorized = sum(x) / length(x),
  check = FALSE,
  min_iterations = 10,
  max_iterations = 100
)
# Returns: expression, min, median, mem_alloc, n_itr, n_gc
```

**Best practices:**
- Profile with realistic data sizes (not toy examples)
- Run multiple iterations (`min_iterations = 10`)
- Check memory: `filter_gc = FALSE` to see GC pressure
- Use `bench::press()` to benchmark across parameter combinations:

```r
bench::press(
  n = c(1e3, 1e4, 1e5),
  {
    x <- rnorm(n)
    bench::mark(mean(x), sum(x)/length(x))
  }
)
```

## Step 4: Choose Fix Based on Bottleneck

| Bottleneck | Fix |
|-----------|-----|
| I/O | `arrow`, `duckdb`, caching |
| Aggregation on >1GB | `data.table`, `duckdb` |
| Independent iterations | `mirai::mirai_map()` |
| Model fitting (expensive per-item) | `crew` worker pool |
| String operations | `stringi` (faster than `stringr`) |
| Memory pressure | Process in chunks, use `arrow` |
