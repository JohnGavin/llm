---
paths:
  - "R/plan_*backtest*.R"
  - "R/plan_*oos*.R"
  - "R/plan_*evaluation*.R"
  - "R/*regime*.R"
---
# Rule: Risk Regime Evaluation

## When This Applies
Any project that backtests strategies on time-series data (financial,
sports betting, or any temporal prediction task).

## CRITICAL: Risk Classification > Return Prediction

Markets are too noisy for reliable return prediction. Risk regimes
(high-risk vs low-risk periods) are more stable, persistent, and
detectable. The question is not "What will returns be?" but
"Is this a high-risk or low-risk environment?"

## Thesis

| Property | Return prediction | Risk classification |
|----------|------------------|---------------------|
| Precision needed | High (exact values) | Low (binary/ternary) |
| Stability | Unstable (noise-dominated) | Stable (clustered, persistent) |
| Detectability | Hard | Easier (vol, correlation, drawdown) |
| Actionability | Requires sizing precision | Adjust exposure up/down |

## Mandatory: Regime-Conditional Metrics

Every backtest with >1 year of data MUST report metrics **separately by
risk regime**. A strategy with positive aggregate Sharpe may hide losses
in high-risk periods that cluster and compound.

### Regime Definition

Use the simplest available risk proxy. Prefer market-derived over model-derived:

```r
# Option 1: Rolling volatility (most common)
classify_regime <- function(returns, window = 20L, quantile_threshold = 0.8) {
  vol <- slider::slide_dbl(returns, sd, .before = window - 1, .complete = TRUE)
  threshold <- quantile(vol, quantile_threshold, na.rm = TRUE)
  dplyr::case_when(
    is.na(vol) ~ "unknown",
    vol > threshold ~ "high_risk",
    TRUE ~ "normal"
  )
}

# Option 2: Drawdown-based (for equity curves)
classify_regime_dd <- function(cumulative_pnl, dd_threshold = 0.1) {
  peak <- cummax(cumulative_pnl)
  dd <- (peak - cumulative_pnl) / pmax(peak, 1)
  dplyr::if_else(dd > dd_threshold, "drawdown", "normal")
}

# Option 3: For football/sports — seasonal or league-specific
# (e.g. end-of-season matches are noisier due to dead rubbers / desperation)
```

### Regime-Conditional Report

```r
tar_target(regime_metrics, {
  bets |>
    dplyr::mutate(regime = classify_regime(rolling_returns)) |>
    dplyr::group_by(model, regime) |>
    dplyr::summarise(
      n_bets = dplyr::n(),
      roi_pct = round(100 * sum(net) / sum(stake), 1),
      sharpe = mean(net) / sd(net),
      max_dd = max(cummax(cumsum(net)) - cumsum(net)),
      .groups = "drop"
    )
})
```

## Exposure Scaling by Regime

Once regimes are classified:
- **Low-risk** → increase exposure (larger positions, more bets)
- **High-risk** → reduce exposure (smaller positions, fewer bets, or exit)

This is not about predicting returns — it's about **allocating risk correctly**.

```r
regime_exposure <- function(regime, base_stake) {
  switch(regime,
    "normal" = base_stake,
    "high_risk" = base_stake * 0.5,   # halve stake in high-risk
    "low_risk" = base_stake * 1.5,    # increase in low-risk
    base_stake
  )
}
```

## Tail Risk Separation

The prompt notes: "correlations require bivariate normality — better to
separate the 80% normal-risk middle from the 10% in each tail."

For any analysis using correlations or covariances:
- Compute correlations on the **middle 80%** of data (normal regime)
- Compute tail risk separately for **each tail** (may be asymmetric)
- Document which regime each correlation applies to

## Football-Specific Regimes

For sports betting, regime proxies include:
- **End-of-season** (matchday > 30): dead rubbers, motivation variance
- **Early-season** (matchday < 5): less data for rolling features
- **Derby / rivalry matches**: different dynamics
- **Promoted/relegated teams**: structural breaks in team quality

## Red Flags

| Signal | Problem |
|--------|---------|
| Strategy profitable only in "normal" regime | Will lose when regime shifts |
| No regime breakdown in results | Hiding tail risk |
| Correlations computed on full sample | Tail correlations differ from normal |
| Single aggregate Sharpe reported | May average over wildly different sub-periods |

## Related Rules

- `backtest-robustness` — parameter sensitivity across regimes
- `position-sizing-guardrails` — exposure scaling by regime
- `statistical-reporting` — report regime alongside every metric
- `composite-alert-scoring` — direction modifier for worsening trends
