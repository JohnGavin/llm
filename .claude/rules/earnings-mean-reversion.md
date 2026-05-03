---
name: earnings-mean-reversion
description: Apply 40-percent-per-year mean-reversion decay to abnormal earnings growth features to avoid overstating persistence
type: rule
---

# Rule: Earnings Mean-Reversion Rate in Feature Construction

## Source

Swedroe evidence-based investing framework (wiki: `knowledge/wiki/swedroe-evidence-investing.md`, Gap 3). Fama research on abnormal earnings growth.

## When This Applies

Any feature engineering that uses earnings growth, revenue growth, or profit margin trends as predictive inputs.

## CRITICAL: Abnormal Earnings Growth Reverts at ~40%/Year

Fama found that abnormal earnings growth reverts to the mean at approximately 40% per year. This means trailing earnings growth features **overestimate persistence** unless explicit decay is applied.

A feature that uses raw trailing 3-year earnings growth implicitly assumes persistence. The economic prior says 60% of abnormal growth disappears each year.

## Required When Using Earnings-Based Features

| Requirement | Detail |
|-------------|--------|
| Apply mean-reversion decay | Use exponential decay with half-life consistent with ~40%/yr reversion |
| Document the decay assumption | State the reversion rate used and its source |
| Sensitivity test | Sweep decay rate ±50% and report impact on signal strength |
| Compare raw vs decayed | Show that raw (no decay) features overfit vs decayed versions |

## Implementation

```r
# Decay abnormal earnings growth at 40%/yr
decay_rate <- 0.40
# For quarterly data: quarterly_decay = 1 - (1 - 0.40)^(1/4) ≈ 0.119
quarterly_decay <- 1 - (1 - decay_rate)^(1/4)

# Apply to trailing earnings growth
decayed_growth <- raw_growth * (1 - quarterly_decay)^quarters_ago
```

## Forbidden Patterns

| Pattern | Why wrong |
|---------|-----------|
| Raw trailing earnings growth as feature | Assumes persistence, contradicts Fama |
| Extrapolating recent earnings trend | Mean reversion makes extrapolation dangerous |
| No documented decay assumption | Implicit assumption = unexamined assumption |

## Related

- `backtest-robustness` — parameter sensitivity; decay rate is a parameter to sweep
- `backtesting-assumptions` — default assumptions table; add decay priors
