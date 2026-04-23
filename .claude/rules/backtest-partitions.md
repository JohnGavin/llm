---
paths:
  - "R/plan_*backtest*.R"
  - "R/plan_*drif*.R"
  - "R/plan_*factor*.R"
  - "R/plan_*partition*.R"
---
# Rule: Mandatory Train/Test/Validation Partitions for Backtests

## When This Applies
Any project that backtests a trading strategy, signal, or model.

## CRITICAL: Three Partitions, Not Two

Every backtest MUST use a 3-way temporal split:

| Partition | Purpose | When to use |
|-----------|---------|-------------|
| **Training** | Model fitting, signal estimation, expanding window | During development |
| **Testing** | Calibration, hyperparameter tuning, strategy comparison | During development |
| **Validation** | Final one-shot evaluation | ONCE, before production |

A 2-way split (IS/OOS) is insufficient — "OOS" gets used for both tuning AND evaluation, which is snooping.

## Partition Boundaries

All strategies in a project MUST share partition dates from a single `bt_partitions` target:

```r
plan_partitions <- function() {
  list(targets::tar_target(bt_partitions, {
    list(
      equity = list(
        train_start = as.Date("2005-01-01"),
        train_end   = as.Date("2019-12-31"),
        test_start  = as.Date("2020-01-01"),
        test_end    = as.Date("2022-12-31"),
        val_start   = as.Date("2023-01-01"),
        val_end     = as.Date("2026-12-31")
      )
    )
  }))
}
```

## Validation Is Sealed

- Validation metrics are NOT computed automatically by `tar_make()`
- Validation requires an explicit manual target or script
- Once you look at validation results and change the strategy, the validation partition becomes another test set — the seal is broken
- Document in the vignette which partition each metric comes from

## Metrics Labelling

Every metrics table MUST label the partition:

```r
bind_rows(
  calc_metrics(train_data, "Training"),
  calc_metrics(test_data, "Testing"),
  calc_metrics(val_data, "Validation"),
  calc_metrics(all_data, "Full Period")
)
```

## Related Rules

- `statistical-reporting` — report partition alongside every metric
- `look-ahead-bias-prevention` — validation prevents peek-ahead
- `quarto-vignette-evidence` — vignettes must state which partition
- `backtest-robustness` — parameter sensitivity & regime testing
- `position-sizing-guardrails` — sizing comparison & max risk per bet
- `risk-regime-evaluation` — regime-conditional metrics
- `execution-delay-sensitivity` — alpha decay & delayed execution
- `underperformance-prior` — historically normal drawdown durations
