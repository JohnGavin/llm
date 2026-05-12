---
description: NA values silently propagate through roll_mean/sd/quantile — choose policy by gap type, default to length-preserving min-obs windowed stat
paths:
  - "R/**"
  - "explorations/**"
---
# Rule: NA Propagation in Rolling and Aggregate Statistics

## When This Applies

Any R code computing rolling means, rolling standard deviations, quantiles, or any aggregate statistic (`RcppRoll::roll_mean`, `slider::slide_dbl`, `base::mean/sd`, `stats::quantile/median`) on a data series that came from an external source (API, parquet, database join).

## CRITICAL: Rolling Stats Return NA When ANY Input Value Is NA

`RcppRoll::roll_mean(x, n = 63)` returns NA for window k if ANY of the 63 values is NA. This is the R default (`na.rm = FALSE`). A dataset with scattered NAs can cause near-zero spike/event detection with **no error message** — just wrong counts silently.

## Why `filter(!is.na())` Is the Wrong Default

Stripping NAs upstream collapses the date axis. A 5-day NA gap becomes invisible to downstream code; joins on `date` then either drop rows or carry forward incorrectly. The output series is misaligned with the source tibble (different `nrow()`). Only acceptable when the downstream consumer is itself an aggregate (`summarise`) that does not need date alignment.

## Policy by Gap Type (apply in this order)

| Gap type | Right tool |
|----------|-----------|
| Weekend / holiday in a calendar-day series | Reindex to a trading calendar (`bizdays::bizseq()`) so these stop being NAs |
| Single missing day in slow-moving series (rates, GDP) | LOCF with `maxgap ≤ 3` (`zoo::na.locf(maxgap = 3, na.rm = FALSE)`) |
| Sparse NAs in a series for which we want a windowed stat | NA-aware rolling with **min-obs threshold** (default helper) |
| Multi-week outage (real provider gap) | Leave as NA — do not impute |
| Backtest features | **Never** linear interpolate (`zoo::na.approx`) — uses tomorrow's value, look-ahead bias (see `look-ahead-bias-prevention` rule) |

## Default: Length-Preserving Helper with Min-Obs Gate

Projects should provide a `roll_mean_safe(x, n, min_frac)` helper (and siblings for sd, quantile) that:

1. Wraps `slider::slide_dbl()` with `.before = n - 1L, .complete = FALSE`.
2. Inside the closure, requires `sum(!is.na(w)) >= ceiling(min_frac * n)` non-NA values.
3. Returns `NA_real_` when the window is too thin; otherwise computes with `na.rm = TRUE`.
4. Preserves vector length — no upstream `filter(!is.na(.))` needed.

Reference implementation: [historicaldata project, `R/utils_rolling.R`](https://github.com/JohnGavin/historicaldata/blob/main/R/utils_rolling.R) — three sibling helpers (`roll_mean_safe`, `roll_sd_safe`, `roll_quantile_safe`).

```r
# CORRECT: length-preserving, honest about coverage
series |>
  dplyr::arrange(date) |>
  dplyr::mutate(
    rolling_ma = roll_mean_safe(value, n = 63, min_frac = 0.5)
  )

# DEFENSIBLE BUT BLUNT: drops rows, requires re-join to restore date axis
series |>
  dplyr::filter(!is.na(value)) |>
  dplyr::mutate(rolling_ma = RcppRoll::roll_mean(value, n = 63, fill = NA))

# WRONG: scattered NAs propagate silently
series |>
  dplyr::mutate(rolling_ma = RcppRoll::roll_mean(value, n = 63, fill = NA))
```

## `min_frac` choice by stat

| Stat | Default `min_frac` | Why |
|------|-------------------|-----|
| `mean` | 0.5 | Tolerates more missingness; estimate is unbiased with 50% coverage |
| `sd` | 0.7 | Variance estimate degrades faster than mean |
| `quantile(0.95)` | 0.9 | Extreme quantiles need near-full coverage to be meaningful |

## When `na.rm = TRUE` Inside the Window Is Not Enough

Bare `na.rm = TRUE` without a min-obs gate produces values from absurdly thin windows (1 of 63 obs → "mean" that is meaningless). Always pair `na.rm = TRUE` with a coverage threshold.

For base R / stats functions:
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

2026-05-12: `hd_macro("VIXCLS")` returned 9470 daily rows with ~302 scattered NULLs. `roll_mean(n=63)` returned NA for 8959/9470 rows. VIX spike detection found 5 events vs expected ~50. No error — just wrong counts. Initial fix: blunt `filter(!is.na(value))`. Refined 2026-05-12 same day: that fix collapses the date axis; replaced with `roll_mean_safe(value, n, min_frac = 0.5)` that preserves length and gates on coverage.

## Related

- `data-validation-timeseries` rule — validate series completeness before analysis (min-obs gate is item 7 there)
- `systematic-debugging` rule — check data shape before blaming logic
- `look-ahead-bias-prevention` rule — why interpolation is forbidden for backtest features
