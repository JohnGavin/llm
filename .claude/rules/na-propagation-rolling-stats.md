---
description: NA values silently propagate through roll_mean/sd/quantile — always filter before rolling stats
paths:
  - "R/**"
  - "explorations/**"
---
# Rule: NA Propagation in Rolling and Aggregate Statistics

## When This Applies

Any R code computing rolling means, rolling standard deviations, quantiles, or any aggregate statistic (`RcppRoll::roll_mean`, `slider::slide_dbl`, `base::mean/sd`, `stats::quantile/median`) on a data series that came from an external source (API, parquet, database join).

## CRITICAL: Rolling Stats Return NA When ANY Input Value Is NA

`RcppRoll::roll_mean(x, n = 63)` returns NA for window k if ANY of the 63 values is NA. This is the R default (`na.rm = FALSE`). A dataset with scattered NAs can cause near-zero spike/event detection with **no error message** — just wrong counts silently.

## Mandatory: Filter NAs Before Any Rolling Stat

```r
# CORRECT: filter before rolling mean
series |>
  dplyr::filter(!is.na(value)) |>          # mandatory
  dplyr::mutate(
    rolling_ma = RcppRoll::roll_mean(value, n = 63, fill = NA)
  )

# WRONG: scattered NAs propagate silently
series |>
  dplyr::mutate(
    rolling_ma = RcppRoll::roll_mean(value, n = 63, fill = NA)
  )
```

For base R functions with `na.rm` parameter, always set explicitly:
```r
mean(x, na.rm = TRUE)
sd(x, na.rm = TRUE)
quantile(x, probs = 0.95, na.rm = TRUE)
```

## Diagnostic Pattern

When spike/event counts are suspiciously low:

```r
cat("Non-NA rolling-stat rows:", sum(!is.na(df$rolling_ma)), "of", nrow(df), "\n")
cat("Non-NA date range:", format(min(df$date[!is.na(df$rolling_ma)])),
    "to", format(max(df$date[!is.na(df$rolling_ma)])), "\n")
# If non-NA starts years after data start → NA propagation from scattered NAs
```

## Data Sources Most Likely to Have Scattered NAs

| Source | Common cause |
|--------|-------------|
| HuggingFace parquet (`hd_macro()`, `hd_ohlcv()`) | Non-trading days, data gaps, revision NAs |
| FRED series | Series gaps, measurement revisions |
| Joined tables | Join mismatches create NAs in non-matching rows |
| Crypto exchanges | Exchange outages, delisting gaps |

## Origin

2026-05-12: `hd_macro("VIXCLS")` returned 9470 daily rows with ~302 scattered NULLs. `roll_mean(n=63)` returned NA for 8959/9470 rows. VIX spike detection found 5 events vs expected ~50. No error — just wrong counts. Fixed by adding `filter(!is.na(value))` before the rolling mean.

## Related

- `data-validation-timeseries` rule — validate series completeness before analysis
- `systematic-debugging` rule — check data shape before blaming logic
