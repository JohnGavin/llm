---
name: model-evaluation-calibration
description: Use when evaluating model performance with proper scoring rules, assessing calibration of probability estimates, or implementing time-aware backtesting. Triggers: model evaluation, calibration, scoring rules, backtesting, probability calibration, cross-validation.
---
# Model Evaluation & Calibration

## Description

Enforce proper model evaluation using scoring rules, calibration assessment, and time-aware backtesting. Prevents misleading evaluation from accuracy-only metrics, random CV on time-series, and uncalibrated probability estimates.

## Purpose

Use this skill when:
- Evaluating any predictive or classification model
- Assessing probability calibration
- Designing cross-validation for time-dependent data
- Monitoring model performance over time (drift detection)
- Reporting model performance to stakeholders

## Core Rules

1. **Never judge a model by accuracy or ROI alone** — use proper scoring rules
2. **Never use random CV on time-dependent data** — use walk-forward splits
3. **Always assess calibration** — a model that says "70% chance" must be right ~70% of the time
4. **Always report uncertainty** — point estimates of metrics are insufficient

## Proper Scoring Rules

Proper scoring rules incentivize honest probability estimates. A model cannot game them by being overconfident or underconfident.

### Log Loss (Cross-Entropy)

The gold standard for classification. Heavily penalizes confident wrong predictions.

```r
library(yardstick)

# Binary classification
predictions |>
  mn_log_loss(truth = outcome, estimate = .pred_positive, event_level = "second")

# Multiclass
predictions |>
  mn_log_loss(truth = outcome, .pred_class_A, .pred_class_B, .pred_class_C)
```

### Brier Score

Mean squared error for probabilities. Ranges 0 (perfect) to 1 (worst). Decomposable into calibration + refinement.

```r
predictions |>
  brier_class(truth = outcome, .pred_positive, event_level = "second")
```

### CRPS (Continuous Ranked Probability Score)

For continuous probabilistic forecasts (not just point predictions):

```r
library(scoringRules)

# For distributional forecasts
crps_norm(y = actual_values, mean = predicted_mean, sd = predicted_sd)
```

### Metric Set (Mandatory Minimum)

```r
# Always evaluate with this minimum set
model_metrics <- yardstick::metric_set(
  mn_log_loss,
  brier_class,
  roc_auc,
  pr_auc
)

# Apply to predictions
predictions |>
  model_metrics(truth = outcome, .pred_positive, event_level = "second")
```

## Calibration Assessment

### Calibration Curves (Reliability Diagrams)

```r
library(probably)

# Windowed calibration plot
predictions |>
  cal_plot_windowed(
    truth = outcome,
    estimate = .pred_positive,
    event_level = "second",
    window_size = 0.1
  )
```

### Calibration Metrics

```r
# Calibration slope and intercept (logistic recalibration)
cal_fit <- glm(
  as.numeric(outcome == "positive") ~ qlogis(.pred_positive),
  family = binomial,
  data = predictions
)

# Perfect calibration: intercept = 0, slope = 1
calibration_intercept <- coef(cal_fit)[1]
calibration_slope <- coef(cal_fit)[2]

# If slope < 1: model is overconfident
# If slope > 1: model is underconfident
```

### Post-hoc Calibration (if needed)

```r
library(probably)

# Isotonic regression calibration
cal_obj <- cal_estimate_isotonic(predictions, truth = outcome, estimate = .pred_positive)

# Apply to new predictions
calibrated_preds <- cal_apply(new_predictions, cal_obj)
```

## Walk-Forward Backtesting

### Never Use Random CV on Time-Series

```r
# BAD: Random CV ignores temporal structure
vfold_cv(data, v = 10)  # Leaks future information!

# GOOD: Walk-forward (expanding window)
library(rsample)

time_splits <- sliding_period(
  data,
  index = date,
  period = "month",
  lookback = 12,     # Train on 12 months
  assess_stop = 1,    # Test on 1 month ahead
  step = 1            # Slide by 1 month
)

# Or rolling origin
rolling_splits <- rolling_origin(
  data,
  initial = 365,     # First 365 observations for training
  assess = 30,       # Next 30 for testing
  skip = 29,         # Slide by 30 (non-overlapping test sets)
  cumulative = TRUE  # Expanding training window
)
```

### Backtest Evaluation

```r
# Fit and evaluate across all time splits
backtest_results <- time_splits |>
  purrr::map_dfr(function(split) {
    train <- rsample::training(split)
    test <- rsample::testing(split)

    model <- fit_model(train)
    preds <- predict_model(model, test)

    tibble::tibble(
      split_id = split$id,
      test_start = min(test$date),
      test_end = max(test$date),
      log_loss = yardstick::mn_log_loss_vec(test$outcome, preds),
      brier = yardstick::brier_class_vec(test$outcome, preds),
      n_obs = nrow(test)
    )
  })
```

### Stress Testing Backtests

```r
# Bootstrap confidence intervals on backtest metrics
library(rsample)

boot_metrics <- bootstraps(backtest_results, times = 1000) |>
  purrr::map_dfr(function(split) {
    d <- rsample::analysis(split)
    tibble::tibble(
      mean_log_loss = mean(d$log_loss),
      worst_log_loss = max(d$log_loss),
      pct_profitable = mean(d$log_loss < threshold)
    )
  })

# Report: mean, 5th percentile (worst case), 95th percentile
quantile(boot_metrics$mean_log_loss, probs = c(0.05, 0.5, 0.95))
```

## Drift Detection

### Feature Distribution Monitoring

```r
# Compare feature distributions across time windows
library(pointblank)

monitor_drift <- function(reference_data, current_data, columns) {
  purrr::map_dfr(columns, function(col) {
    ks_test <- ks.test(reference_data[[col]], current_data[[col]])
    tibble::tibble(
      feature = col,
      ks_statistic = ks_test$statistic,
      p_value = ks_test$p.value,
      drift_detected = ks_test$p.value < 0.01
    )
  })
}

# Validate no drift exceeds threshold
drift_results <- monitor_drift(
  reference_data = training_data,
  current_data = recent_data,
  columns = feature_columns
)

if (any(drift_results$drift_detected)) {
  cli::cli_alert_warning("Feature drift detected in: {drift_results$feature[drift_results$drift_detected]}")
}
```

### Prediction Drift

```r
# Monitor prediction distribution over time
prediction_summary <- predictions_log |>
  dplyr::group_by(period = lubridate::floor_date(timestamp, "week")) |>
  dplyr::summarise(
    mean_pred = mean(predicted_prob),
    sd_pred = sd(predicted_prob),
    n = dplyr::n(),
    .groups = "drop"
  )

# Alert if mean prediction shifts significantly
# (model may need retraining)
```

## Volatility & Time-Series Features

### Rolling Statistics

```r
# Feature engineering for time-dependent models
library(slider)

data_with_features <- data |>
  dplyr::arrange(date) |>
  dplyr::mutate(
    # Rolling mean and volatility
    value_roll_mean_7 = slide_dbl(value, mean, .before = 6, .complete = TRUE),
    value_roll_sd_7 = slide_dbl(value, sd, .before = 6, .complete = TRUE),
    value_roll_mean_30 = slide_dbl(value, mean, .before = 29, .complete = TRUE),

    # Rate of change
    value_pct_change = (value - dplyr::lag(value)) / dplyr::lag(value),

    # Regime indicator (high vs low volatility)
    volatility_regime = dplyr::if_else(
      value_roll_sd_7 > median(value_roll_sd_7, na.rm = TRUE),
      "high", "low"
    )
  )
```

## targets Integration

Model evaluation results should be pipeline targets for reproducibility:

```r
# R/tar_plans/plan_evaluation.R
plan_evaluation <- function() {
  list(
    tar_target(time_splits, create_time_splits(prepared_data)),
    tar_target(
      backtest_results,
      run_backtest(time_splits, model_spec),
      packages = c("yardstick", "rsample")
    ),
    tar_target(calibration_plot, plot_calibration(backtest_results)),
    tar_target(drift_report, assess_drift(training_data, recent_data)),
    tar_target(
      evaluation_summary,
      summarise_evaluation(backtest_results, drift_report)
    )
  )
}
```

## Reporting Template

Every model evaluation report must include:

1. **Proper scoring metrics** (log loss, Brier) with confidence intervals
2. **Calibration curve** (reliability diagram)
3. **Walk-forward performance over time** (line plot of metric by period)
4. **Worst-case analysis** (worst backtest window, bootstrap 5th percentile)
5. **Drift assessment** (feature and prediction distribution stability)
6. **Comparison to baseline** (see `modeling-baselines` skill)

## Anti-Patterns

```r
# BAD: Accuracy-only evaluation
accuracy(predictions)  # Misleading for imbalanced classes

# GOOD: Proper scoring rules
mn_log_loss(predictions) + brier_class(predictions)

# BAD: Random CV on time-series
vfold_cv(time_series_data)  # Future leakage!

# GOOD: Walk-forward splits
sliding_period(time_series_data, index = date, period = "month")

# BAD: No calibration check
"Model achieves 0.85 AUC"  # Probabilities may be meaningless

# GOOD: Calibration verified
"Model achieves 0.85 AUC with calibration slope 0.98 (well-calibrated)"

# BAD: Single-number summary
"Log loss = 0.42"  # How variable? What's worst case?

# GOOD: With uncertainty
"Log loss = 0.42 [95% CI: 0.38-0.47], worst backtest window: 0.61"
```

## Related Skills

- `modeling-baselines` - Baseline models to compare against
- `mlops-deployment` - Deploy evaluated models with versioning
- `data-validation-pointblank` - Validate input data before scoring
- `analysis-rationale-logging` - Document evaluation decisions
