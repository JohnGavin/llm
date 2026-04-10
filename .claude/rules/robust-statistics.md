---
paths:
  - "R/**"
  - "src/**"
  - "**/*.py"
---
# Rule: Robust Statistics for Outlier-Prone Data

## When This Applies
Computing central tendency or dispersion on any data where outliers are plausible:
- Clinical data with infection spikes, treatment responses, lab errors
- Financial data with regime changes, fat-tail returns
- System monitoring with burst traffic, GC pauses, incident spikes
- Sensor data with calibration glitches
- A/B tests with whale users

## CRITICAL: SD and mean are NOT appropriate for outlier-prone data

The sample mean and standard deviation have breakdown point 0 — a single extreme value corrupts them arbitrarily. Use robust alternatives.

| Quantity | Non-robust | Robust | Breakdown point |
|---|---|---|---:|
| Central tendency | `mean(x)` | `median(x)` | 50% |
| Dispersion | `sd(x)` | `mad(x)` (median absolute deviation) | 50% |
| Z-score | `(x - mean) / sd` | `(x - median) / mad` | 50% |
| Correlation | Pearson | Spearman rank | ~50% |

## Worked Example: Why MAD Beats SD for Anomaly Detection

Neutrophil time series with two infection spikes:

```r
values <- c(2.0, 1.5, 2.5, 12.0, 8.0, 2.2, 1.8, 2.3, 11.0, 0.9)
#                          ^^^^  ^^^                     ^^^^^
#                          spike spike                   genuine crash
```

| Method | Baseline | Dispersion | z-score of 0.9 |
|---|---:|---:|---:|
| Mean + SD | 4.42 | 4.11 | **0.86** (unremarkable) |
| Median + MAD | 2.15 | 0.93 | **1.34** (flagged) |

The SD-based approach misses the genuine crash because the spikes inflated SD. The MAD approach catches it.

## Required Pattern

```r
# R
robust_zscore <- function(x, latest = x[length(x)]) {
  if (length(x) == 0) return(NA_real_)
  stopifnot("`latest` must be length 1" = length(latest) == 1)
  # Exclude latest from baseline to avoid self-contamination
  baseline_x <- x[-length(x)]
  if (length(baseline_x) < 4) return(NA_real_)  # too few for stable median/MAD
  baseline <- stats::median(baseline_x, na.rm = TRUE)
  dispersion <- stats::mad(baseline_x, na.rm = TRUE)
  if (dispersion < .Machine$double.eps * max(1, abs(baseline))) {
    # Near-zero dispersion; NA means "zero-dispersion outlier", not missing input
    return(if (abs(latest - baseline) < .Machine$double.eps * max(1, abs(baseline))) 0 else NA_real_)
  }
  abs(latest - baseline) / dispersion
}
# Note: this returns magnitude only. For the direction modifier in
# composite-alert-scoring, use the signed residual (latest - baseline).
```

```python
# Python
import numpy as np
from scipy import stats

def robust_zscore(x, latest=None):
    if latest is None:
        latest = x[-1]
    # Exclude latest from baseline to avoid self-contamination
    baseline_x = x[:-1]
    if len(baseline_x) < 4:
        return float('nan')
    baseline = np.median(baseline_x)
    dispersion = stats.median_abs_deviation(baseline_x, scale='normal')
    if dispersion == 0:
        # Near-equality for floats; nan means "zero-dispersion outlier", not missing input
        return 0.0 if np.isclose(latest, baseline) else float('nan')
    return abs(latest - baseline) / dispersion
```

## Minimum Observations

Do not compute robust statistics on fewer than **5 observations** (4 baseline + 1 latest):
- Median of < 4 baseline values is unstable
- MAD of < 4 baseline values is meaningless
- Fall back to simpler signal (distance from target, last-known, etc.)

```r
if (length(x) < 5) {
  return(list(score = NA_real_, baseline = NA_real_, mad = NA_real_))
}
```

## Windowing for Time Series

For time-stamped data, use a **time-based window** (last N days), not a count-based window (last K points):

```r
# RIGHT: time-based
cutoff <- max(dates) - window_days
in_window <- dates >= cutoff
window_vals <- values[in_window]

# WRONG: count-based (mixes timeframes when sampling is irregular)
window_vals <- tail(values, 30)
```

Irregular sampling (lab results, sensor data with gaps) makes count-based windows silently combine different time periods.

## When Mean + SD IS Appropriate

- The data-generating process is provably Gaussian (very rare in practice)
- Outliers have been explicitly removed or handled
- You're doing maximum likelihood estimation with a normal likelihood
- You have a theoretical reason to prefer efficiency over robustness

Default to robust estimators; justify non-robust choices.

## Scale Factor Note

R's `stats::mad()` multiplies the raw MAD by 1.4826 by default, making it a consistent estimator of σ for Gaussian data. This is usually what you want. Python's `scipy.stats.median_abs_deviation(..., scale='normal')` does the same. If you pass `constant = 1` / `scale = 1.0` you get the raw MAD.

## Red Flags in Code Review

1. **`abs(x - mean(x)) / sd(x)` on any data likely to have outliers**
2. **Pearson correlation on returns or sensor data**
3. **`scale()` on columns with heavy tails**
4. **No MAD = 0 edge case handling** (causes division by zero)
5. **Count-based rolling windows on irregularly sampled time series**
6. **Z-score threshold of "2 or 3" applied to non-Gaussian data** — the normal-distribution intuition doesn't hold

## Related
- `statistical-reporting` — effect sizes, uncertainty
- `data-validation-timeseries` — time-series quality checks
- `half-life-decay` — time-decay weighting
- `composite-alert-scoring` — uses robust z-score as surprise component
