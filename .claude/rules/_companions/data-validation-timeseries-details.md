# Companion: Time-Series Data Validation — Worked Code Examples

Worked code examples split out of the always-loaded
[`data-validation-timeseries`](../data-validation-timeseries.md) rule to keep
it lean. The normative content (the 9 numbered Core Requirements, Required
Targets table, Checklist) stays in the rule; this file is the verbatim R
snippets for Section 9 (Type Consistency on Join Keys), loaded on demand.

## Section 9 — Defensive coercion at every cross-series boundary

```r
x |> dplyr::mutate(date = as.Date(date)) |>
  dplyr::full_join(y |> dplyr::mutate(date = as.Date(date)), by = "date")
```

## Section 9 — `dv_join_key_types` validation target

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

## Section 9 — diagnostic when a join produces 0 complete cases

```r
cat("Left date class:",  paste(class(left$date),  collapse = "/"), "\n")
cat("Right date class:", paste(class(right$date), collapse = "/"), "\n")
```

## Reference Implementation

- `irishbuoys/R/tar_plans/plan_data_validation.R` (8 targets, all dplyr, no raw SQL)

## Section 9 — common upstream sources of POSIXct contamination

| Source | Returns POSIXct |
|--------|-----------------|
| `arrow::read_parquet()` on TIMESTAMP columns | Yes (sometimes; depends on schema) |
| HuggingFace parquet via DuckDB | TIMESTAMP loads as POSIXct |
| `lubridate::ymd_hms()` and friends | Always |
| FRED / yfinance helpers that don't coerce | Often (check the package) |
| `as.POSIXct(...)` anywhere upstream | Always |
