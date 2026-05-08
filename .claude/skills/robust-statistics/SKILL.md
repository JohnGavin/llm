# Skill: Robust Statistics for Outlier-Prone Data

Use when computing central tendency or dispersion on data where outliers are plausible:
clinical data, financial returns, system monitoring, sensor data, A/B tests.

## Triggers

- Computing z-scores or anomaly detection
- Analyzing clinical/lab data
- Financial return analysis
- Any mention of outliers or robust statistics

## CRITICAL: SD and mean are NOT appropriate for outlier-prone data

The sample mean and standard deviation have breakdown point 0 — a single extreme value corrupts them arbitrarily.

| Quantity | Non-robust | Robust | Breakdown point |
|---|---|---|---:|
| Central tendency | `mean(x)` | `median(x)` | 50% |
| Dispersion | `sd(x)` | `mad(x)` | 50% |
| Z-score | `(x - mean) / sd` | `(x - median) / mad` | 50% |
| Correlation | Pearson | Spearman rank | ~50% |

## Worked Example

Neutrophil time series with infection spikes:

```r
values <- c(2.0, 1.5, 2.5, 12.0, 8.0, 2.2, 1.8, 2.3, 11.0, 0.9)
```

| Method | Baseline | Dispersion | z-score of 0.9 |
|---|---:|---:|---:|
| Mean + SD | 4.42 | 4.11 | **0.86** (unremarkable) |
| Median + MAD | 2.15 | 0.93 | **1.34** (flagged) |

SD misses the genuine crash because spikes inflated it.

## Required Pattern (R)

```r
robust_zscore <- function(x, latest) {
  if (length(x) == 0) return(NA_real_)
  if (missing(latest)) {
    latest <- x[length(x)]
    baseline_x <- x[-length(x)]
  } else {
    stopifnot("`latest` must be length 1" = length(latest) == 1)
    baseline_x <- x
  }
  if (is.na(latest)) return(NA_real_)
  if (length(baseline_x) < 4) return(NA_real_)
  baseline <- stats::median(baseline_x, na.rm = TRUE)
  dispersion <- stats::mad(baseline_x, na.rm = TRUE)
  if (dispersion < .Machine$double.eps * max(1, abs(baseline))) {
    return(if (abs(latest - baseline) < .Machine$double.eps * max(1, abs(baseline))) 0 else NA_real_)
  }
  abs(latest - baseline) / dispersion
}
```

## Required Pattern (Python)

```python
import numpy as np
from scipy import stats

def robust_zscore(x, latest=None):
    if len(x) == 0:
        return float('nan')
    if latest is None:
        latest = x[-1]
        baseline_x = x[:-1]
    else:
        baseline_x = x
    if len(baseline_x) < 4:
        return float('nan')
    baseline = np.median(baseline_x)
    dispersion = stats.median_abs_deviation(baseline_x, scale='normal')
    eps_thresh = np.finfo(float).eps * max(1, min(abs(baseline), 1e15))
    if dispersion < eps_thresh:
        return 0.0 if abs(latest - baseline) < eps_thresh else float('nan')
    return abs(latest - baseline) / dispersion
```

## Minimum Observations

Do not compute robust statistics on fewer than **5 observations** (4 baseline + 1 latest).

## Windowing for Time Series

Use **time-based windows** (last N days), not count-based (last K points):

```r
# RIGHT: time-based
cutoff <- max(dates) - window_days
window_vals <- values[dates >= cutoff]

# WRONG: count-based (mixes timeframes when sampling is irregular)
window_vals <- tail(values, 30)
```

## When Mean + SD IS Appropriate

- Provably Gaussian data (rare)
- Outliers explicitly removed
- Maximum likelihood with normal likelihood
- Theoretical reason to prefer efficiency over robustness

Default to robust; justify non-robust.

## Scale Factor Note

R's `mad()` multiplies by 1.4826 by default (consistent estimator of σ for Gaussian).
Python's `median_abs_deviation(..., scale='normal')` does the same.

## Red Flags in Code Review

1. `abs(x - mean(x)) / sd(x)` on outlier-prone data
2. Pearson correlation on returns or sensor data
3. `scale()` on columns with heavy tails
4. No MAD = 0 edge case handling
5. Count-based rolling windows on irregular time series
6. Z-score threshold "2 or 3" on non-Gaussian data

## Related

- `statistical-reporting` rule — effect sizes, uncertainty
- `half-life-decay` rule — time-decay weighting
- `composite-alert-scoring` rule — uses robust z-score
