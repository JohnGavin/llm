# Look-Ahead Bias QA Template

Implementation templates for the `look-ahead-bias-prevention` rule.

## qa_look_ahead_bias target

```r
targets::tar_target(
  qa_look_ahead_bias,
  {
    checks <- list()

    # CHECK 1: Train/test temporal separation
    if (exists("wf_splits") && length(wf_splits) > 0) {
      violations <- vapply(wf_splits, function(sp) {
        sp$train_start >= sp$test_start
      }, logical(1))
      checks$temporal_separation <- list(
        pass = !any(violations),
        detail = paste0(sum(violations), "/", length(wf_splits),
                        " folds have train/test overlap")
      )
    }

    # CHECK 2: In-sample vs OOS divergence detector
    if (exists("pnl_summary") && exists("oos_validate_summary")) {
      is_roi <- pnl_summary$roi_pct
      oos_roi <- oos_validate_summary$roi_pct
      divergence <- is_roi - oos_roi
      checks$roi_divergence <- list(
        pass = divergence < 100,
        detail = sprintf("IS ROI: %.1f%%, OOS ROI: %.1f%%, gap: %.0fpp",
                          is_roi, oos_roi, divergence)
      )
    }

    # CHECK 3: Feature timestamp audit
    feature_files <- list.files("R", pattern = "features?\\.R$",
                                 full.names = TRUE)
    rolling_fns <- grep("rolling_|cumulative_|compute_.*features",
                         unlist(lapply(feature_files, readLines)),
                         value = TRUE)
    uses_lag <- grepl("dplyr::lag|\\blag\\(|apply_asof_cutoff", rolling_fns)
    checks$feature_lag <- list(
      pass = all(uses_lag) || length(rolling_fns) == 0,
      detail = paste0(sum(!uses_lag), " rolling feature lines missing lag/cutoff")
    )

    # CHECK 4: No full-sample model (structural — review DAG manually)

    # REPORT
    n_pass <- sum(vapply(checks, function(x) x$pass, logical(1)))
    n_total <- length(checks)

    if (n_pass < n_total) {
      failed <- names(checks)[!vapply(checks, function(x) x$pass, logical(1))]
      details <- vapply(checks[failed], function(x) x$detail, character(1))
      cli::cli_warn(c(
        "!" = "Look-ahead bias checks: {n_pass}/{n_total} passed",
        "x" = paste(failed, details, sep = ": ")
      ))
    } else {
      cli::cli_alert_success("Look-ahead bias: {n_total}/{n_total} checks passed")
    }

    list(checks = checks, n_pass = n_pass, n_total = n_total,
         timestamp = Sys.time())
  },
  cue = targets::tar_cue(mode = "always")
)
```

## Structural prevention patterns

### Separate train and evaluate targets

```r
# WRONG: single target that trains and evaluates on same data
tar_target(model_performance, {
  model <- fit(all_data)
  evaluate(model, all_data)  # LOOK-AHEAD BIAS
})

# RIGHT: separate targets with explicit temporal split
tar_target(model_trained, fit(train_data))
tar_target(model_oos_eval, evaluate(model_trained, validate_data))
```

### Walk-forward CV returns per-fold metrics

```r
# WRONG: aggregate metric hides per-fold variation
tar_target(cv_result, mean(fold_metrics))

# RIGHT: return per-fold, aggregate separately
tar_target(cv_folds, evaluate_per_fold(data))
tar_target(cv_summary, summarise_cv(cv_folds))
```

### P&L targets MUST depend on OOS predictions

```r
# WRONG: pnl depends on full-sample fit
tar_target(pnl_glm, simulate_pnl(value_bets_glm, ...))

# RIGHT: pnl depends on oos predictions
tar_target(oos_pnl, simulate_pnl(oos_validate_bets, ...))
```

## CHECK 5: Execution delay sensitivity

```r
delays <- c(0, 1, 3, 5)
delay_results <- purrr::map_dfr(delays, function(d) {
  pnl <- evaluate_with_delay(predictions, odds, delay_periods = d)
  tibble::tibble(delay = d, roi = pnl$roi, sharpe = pnl$sharpe)
})
checks$execution_delay <- list(
  pass = delay_results$roi[delay_results$delay == 1] > delay_results$roi[1] * 0.5,
  detail = sprintf("t+0 ROI: %.1f%%, t+1 ROI: %.1f%%",
                    delay_results$roi[1],
                    delay_results$roi[delay_results$delay == 1])
)
```

Note: `readLines(feature_files)` was fixed to `unlist(lapply(feature_files, readLines))`
to handle multiple files (original bug from prior review).
