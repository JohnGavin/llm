---
paths:
  - "R/plan_*backtest*.R"
  - "R/plan_*qa*.R"
  - "R/tar_plans/plan_*.R"
---
# Rule: Backtest Robustness (Parameter Sensitivity & Regime Testing)

## When This Applies
Any project that backtests a trading strategy, betting model, or signal.

## CRITICAL: Reject Sharp Peaks, Require Plateaus

A strategy that only works at one "perfect" parameter setting is overfit.
Robust strategies work across a **broad region** of parameter space.

## Mandatory Checks

### 1. Parameter Sensitivity Sweep

Every backtest pipeline with tunable parameters MUST include a
`qa_parameter_robustness` target that varies each key param ±20%
and measures Sharpe/ROI degradation.

```r
tar_target(qa_parameter_robustness, {
  # For each tunable parameter, evaluate at -20%, base, +20%
  param_grid <- expand.grid(
    min_edge = c(0.024, 0.03, 0.036),
    rho = c(-0.156, -0.13, -0.104)
  )

  results <- purrr::pmap_dfr(param_grid, function(...) {
    params <- list(...)
    pnl <- run_backtest_with_params(params)
    tibble::tibble(!!!params, roi = pnl$roi, sharpe = pnl$sharpe)
  })

  # FAIL if Sharpe drops >50% at any ±20% perturbation
  base_sharpe <- results$sharpe[results$min_edge == 0.03 & results$rho == -0.13]
  worst_sharpe <- min(results$sharpe)
  ratio <- worst_sharpe / base_sharpe

  if (!is.na(ratio) && ratio < 0.5) {
    cli::cli_warn(c(
      "!" = "Parameter sensitivity: Sharpe drops {round((1-ratio)*100)}% at ±20%",
      "i" = "Strategy may be overfit to specific parameters"
    ))
  }

  results
}, cue = tar_cue(mode = "always"))
```

### 2. Regime-Conditional Evaluation

Separate backtest results by **volatility regime** (or equivalent risk
proxy). A strategy that only profits in low-vol and loses in high-vol
has hidden risk.

```r
tar_target(qa_regime_robustness, {
  # Classify each period as high/low vol
  bets <- ah_walkforward_all |>
    dplyr::mutate(
      regime = dplyr::if_else(
        rolling_vol > median(rolling_vol, na.rm = TRUE),
        "high_vol", "low_vol"
      )
    )

  bets |>
    dplyr::group_by(model, regime) |>
    dplyr::summarise(
      n_bets = dplyr::n(),
      roi_pct = round(100 * sum(net) / sum(stake), 1),
      sharpe = mean(net) / sd(net),
      .groups = "drop"
    )
})
```

### 3. Multi-Frequency Evaluation (where applicable)

For strategies that could be evaluated at different frequencies, test
at multiple timescales (daily, weekly, monthly aggregation). For
single-event markets (football matches), this means testing per-season
and per-league stability.

## Robustness Heatmap

When reporting results with a tuned parameter, include a heatmap of
the objective (Sharpe or ROI) across a 2D param grid. Reject if the
optimal cell is an isolated peak surrounded by negative performance.

## Red Flags

| Pattern | Problem |
|---------|---------|
| Single optimal parameter | Overfit — real edge spans a region |
| Strategy works in 1 league only | Sample-specific, not generalizable |
| Strategy works in 1 season only | Temporal anomaly, not systematic |
| Sharpe > 2.0 in backtest | Suspiciously good — check for leakage first |

## What This Rule Prevents

- Publishing a "+5% ROI" result that only exists at `min_edge = 0.0317`
- Deploying a strategy that fails in the first high-vol regime
- Confusing in-sample parameter mining with genuine edge

## Related Rules

- `look-ahead-bias-prevention` — temporal leakage
- `backtest-partitions` — train/test/validation splits
- `statistical-reporting` — FPR, effect sizes
