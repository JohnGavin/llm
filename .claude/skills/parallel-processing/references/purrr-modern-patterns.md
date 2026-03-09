# Modern purrr Patterns (1.1.0+)

Updated patterns replacing deprecated purrr functions.

## Row Binding: `list_rbind()` Replaces `map_dfr()`

```r
# OLD (deprecated)
purrr::map_dfr(files, readr::read_csv)

# NEW
purrr::map(files, readr::read_csv) |> purrr::list_rbind()
```

## Column Binding: `list_cbind()` Replaces `map_dfc()`

```r
# OLD (deprecated)
purrr::map_dfc(fns, \(f) f(data))

# NEW
purrr::map(fns, \(f) f(data)) |> purrr::list_cbind()
```

## Flattening: `list_flatten()` / `list_c()`

```r
# OLD (deprecated)
purrr::flatten_chr(x)

# NEW
purrr::list_c(x)
purrr::list_flatten(x)  # one level only
```

## Side Effects: `walk()` Family

```r
# Apply for side effects (file writing, plotting, messaging)
purrr::walk(plots, \(p) ggplot2::ggsave(p$name, p$plot))
purrr::walk2(data_list, names(data_list), \(d, n) {
  arrow::write_parquet(d, paste0(n, ".parquet"))
})

# iwalk for index + value
purrr::iwalk(results, \(result, name) {
  cli::cli_inform("Processed {name}: {nrow(result)} rows")
})
```

## Parallel Map (purrr 1.1.0+)

```r
# Sequential
results <- purrr::map(items, slow_fn)

# Parallel — just add .parallel = TRUE
results <- purrr::map(items, slow_fn, .parallel = TRUE)

# Configure workers
results <- purrr::map(items, slow_fn, .parallel = list(workers = 4))

# With progress
results <- purrr::map(items, slow_fn, .parallel = TRUE, .progress = TRUE)

# Works with all map variants
purrr::map_chr(items, extract_name, .parallel = TRUE)
purrr::map2(x, y, combine_fn, .parallel = TRUE)
purrr::pmap(params, multi_fn, .parallel = TRUE)
```

## Superseded Functions Reference

| Superseded | Replacement |
|-----------|-------------|
| `map_dfr()` | `map() |> list_rbind()` |
| `map_dfc()` | `map() |> list_cbind()` |
| `flatten()` | `list_flatten()` |
| `flatten_*()` | `list_c()` |
| `map_if(.else)` | `map_if()` (still works) |
| `splice()` | `list2(!!!x)` |
| `prepend()` | `c(new, old)` |
| `is_empty()` | `rlang::is_empty()` |

## `keep()` / `discard()` / `compact()`

```r
# Filter list elements by predicate
results |> purrr::keep(\(x) nrow(x) > 0)
results |> purrr::discard(\(x) is.null(x))
results |> purrr::compact()  # remove NULLs
```

## `pluck()` for Deep Extraction

```r
# Extract nested values safely
api_response |> purrr::pluck("data", "results", 1, "name")
api_response |> purrr::pluck("data", "missing", .default = NA)
```
