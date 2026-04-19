---
paths:
  - "R/plan_*backtest*.R"
  - "R/plan_*drif*.R"
  - "R/plan_*portfolio*.R"
---
# Rule: Robustness Testing (Mandatory for All Strategies)

## Core Principle

> Robustness > Optimisation. Prefer broad stable plateaus over sharp peaks.
> Know when things break AND have precomputed what to do about it.

## Mandatory Tests

Every strategy MUST include these robustness checks:

### 1. Alpha Decay (t+1 to t+10)

Trade with 1, 2, 5, 10 day execution delay. Measure P&L degradation.
If >50% of alpha vanishes by t+2, the signal is too fragile.

### 2. Parameter Sensitivity

Vary key parameters ±20% (e.g. lookback window, decile cutoff, elastic net alpha).
If performance changes >30%, the strategy is overfit to specific parameters.

### 3. Regime Stress

Split data by VIX regime (low/medium/high/crisis). Report metrics per regime.
A strategy that only works in one regime is not robust.

### 4. Bootstrap Resampling

Block bootstrap monthly returns (preserve autocorrelation). Report 5th/95th
percentile of Sharpe/DD across 1000 resamples. If 5th percentile Sharpe < 0,
the strategy may be noise.

### 5. Subperiod Stability

Split training data into 3+ equal subperiods. Report metrics per subperiod.
If any subperiod has opposite sign to full period, investigate.

## Reporting

Each robustness test produces a table or plot in the vignette's "Robustness" tab.

## Red Flags

| Signal | Meaning |
|--------|---------|
| Alpha disappears at t+2 | Signal is execution-dependent, not information |
| Performance flips sign in one subperiod | Possible regime-specific or spurious |
| Bootstrap 5th percentile Sharpe < 0 | Strategy may be indistinguishable from noise |
| Parameter sensitivity > 30% | Overfit to specific settings |
| Works only in high/low VIX | Regime-dependent, needs dynamic sizing |

## Related

- `backtesting-assumptions` — cost model, execution delays
- `backtest-partitions` — train/test/validation
- `statistical-reporting` — FPR, effect sizes
