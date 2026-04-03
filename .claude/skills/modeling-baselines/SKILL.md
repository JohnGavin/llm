---
name: modeling-baselines
description: Use when starting predictive modeling to enforce baseline-first workflow, comparing ML models against simple GLM/GLMM baselines, or preventing premature complexity. Triggers: baseline model, GLM baseline, model comparison, modeling workflow, simple model first.
---
# Modeling Baselines

## Description

Enforce a baseline-first modeling workflow. Every predictive model MUST be compared against a simple GLM/GLMM baseline before acceptance. This prevents premature complexity and ensures ML models demonstrably outperform interpretable alternatives.

## Purpose

Use this skill when:
- Fitting any predictive or classification model
- Evaluating whether ML (xgboost, random forest, neural net) is justified
- Working with hierarchical or grouped data (use GLMM)
- Building ranking models for multi-competitor outcomes
- Deciding between frequentist and Bayesian approaches

## Core Rule

> **No ML model is accepted without a GLM/GLMM baseline comparison.**

If the baseline performs comparably, prefer it for interpretability.

## Eval/Experiment File Separation (MANDATORY)

Separate **immutable evaluation code** from **mutable experiment code**:

| File | Mutable? | Contains |
|------|----------|---------|
| `R/evaluate.R` | **NO** — frozen | Metric computation, cross-validation, scoring functions |
| `R/train.R` or `R/model_*.R` | **YES** — experiment here | Model fitting, hyperparameters, architecture |
| `tests/testthat/test-oracle.R` | **NO** — frozen | Known-correct reference values for sanity checks |

**Why:** If both eval and model code change simultaneously, you can't tell whether a metric improvement came from a better model or a bug in the evaluation. Freeze eval first, then iterate on the model.

**test-oracle.R pattern:** Store known-correct outputs for reference inputs:
```r
test_that("baseline predictions match reference", {
  ref_preds <- readRDS(test_path("fixtures", "baseline_predictions.rds"))
  current_preds <- predict(fit_baseline(test_data), test_data)
  expect_equal(current_preds, ref_preds, tolerance = 1e-6)
})
```

## Baseline-First Workflow

### Step 1: Fit the GLM/GLMM Baseline

```r
# Simple outcome: logistic regression baseline
baseline_glm <- glm(
  outcome ~ predictor_1 + predictor_2 + predictor_3,
  family = binomial(link = "logit"),
  data = training_data
)

# Grouped/hierarchical data: mixed-effects baseline
baseline_glmm <- lme4::glmer(
  outcome ~ predictor_1 + predictor_2 + (1 | group_id),
  family = binomial(link = "logit"),
  data = training_data
)
```

### Step 2: Evaluate Baseline with Proper Scoring

```r
# See model-evaluation-calibration skill for details
baseline_preds <- predict(baseline_glm, newdata = test_data, type = "response")

yardstick::mn_log_loss_vec(
  truth = test_data$outcome,
  estimate = baseline_preds,
  event_level = "second"
)
```

### Step 3: Fit the Complex Model

Only after the baseline is established:

```r
# tidymodels interface (canonical)
library(tidymodels)

xgb_spec <- boost_tree(
  trees = 500,
  tree_depth = tune(),
  learn_rate = tune()
) |>
  set_engine("xgboost") |>
  set_mode("classification")

xgb_wf <- workflow() |>
  add_recipe(recipe(outcome ~ ., data = training_data)) |>
  add_model(xgb_spec)
```

### Step 4: Compare on Same Metrics

```r
# Both models evaluated on IDENTICAL hold-out set with IDENTICAL metrics
comparison <- tibble::tibble(
  model = c("GLM Baseline", "XGBoost"),
  log_loss = c(baseline_log_loss, xgb_log_loss),
  brier = c(baseline_brier, xgb_brier),
  calibration_slope = c(baseline_cal, xgb_cal)
)
```

## Ranking Models

For multi-competitor outcomes (e.g., which item ranks first), use dedicated ranking models:

### Plackett-Luce

```r
library(PlackettLuce)

# Rankings: each row is an ordering of competitors
rankings <- as.rankings(ranking_matrix)
pl_model <- PlackettLuce(rankings)

# Extract worth parameters (probabilities)
coef(pl_model, log = FALSE)
```

### Bradley-Terry (Pairwise)

```r
library(BradleyTerry2)

bt_model <- BTm(
  outcome = 1,
  player1 = home,
  player2 = away,
  data = pairwise_data
)
```

## Bayesian Multilevel Models

When uncertainty quantification matters or priors encode domain knowledge:

```r
library(brms)

bayes_model <- brms::brm(
  outcome ~ predictor_1 + predictor_2 + (1 | group_id),
  family = bernoulli(link = "logit"),
  data = training_data,
  prior = c(
    prior(normal(0, 2), class = "b"),        # Weakly informative
    prior(exponential(1), class = "sd")       # Shrinkage on group effects
  ),
  chains = 4,
  cores = 4,
  seed = 42
)

# Posterior predictive check (mandatory)
pp_check(bayes_model, ndraws = 100)

# Extract predictions with uncertainty
posterior_epred(bayes_model, newdata = test_data) |>
  posterior_summary()
```

**Prior selection rules:**
- Always specify priors explicitly (never rely on defaults without checking)
- Use weakly informative priors unless domain knowledge justifies stronger
- Document prior choices in DECISIONS.md (see `analysis-rationale-logging` skill)
- Run prior predictive checks to verify priors produce plausible outcomes

## tidymodels as Canonical Interface

All models (baseline and complex) should use `tidymodels` for consistency:

```r
library(tidymodels)

# Recipe: preprocessing shared across models
shared_recipe <- recipe(outcome ~ ., data = training_data) |>
  step_normalize(all_numeric_predictors()) |>
  step_dummy(all_nominal_predictors())

# Baseline spec
glm_spec <- logistic_reg() |>
  set_engine("glm")

# Complex spec
xgb_spec <- boost_tree(trees = 500) |>
  set_engine("xgboost") |>
  set_mode("classification")

# Workflow set for comparison
model_set <- workflow_set(
  preproc = list(shared = shared_recipe),
  models = list(glm = glm_spec, xgb = xgb_spec)
)

# Fit all with same resamples
results <- model_set |>
  workflow_map(
    resamples = vfold_cv(training_data, v = 5),
    metrics = metric_set(mn_log_loss, brier_class, roc_auc)
  )

autoplot(results)
```

## Separation of Concerns

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│  Feature Layer  │ →  │   Model Layer   │ →  │ Decision Layer  │
│                 │    │                 │    │                 │
│ Raw data →      │    │ Features →      │    │ Probabilities → │
│ Features        │    │ Probabilities   │    │ Actions         │
└─────────────────┘    └─────────────────┘    └─────────────────┘
```

- **Model layer** outputs calibrated probabilities only
- **Decision layer** converts probabilities to actions (see `analysis-rationale-logging` Decision Layer section)
- Never embed business logic in the model layer

## targets Integration

```r
# R/tar_plans/plan_models.R
plan_models <- function() {
  list(
    tar_target(baseline_glm, fit_baseline(training_data)),
    tar_target(baseline_metrics, evaluate_model(baseline_glm, test_data)),
    tar_target(complex_model, fit_complex(training_data)),
    tar_target(complex_metrics, evaluate_model(complex_model, test_data)),
    tar_target(
      model_comparison,
      compare_models(baseline_metrics, complex_metrics)
    )
  )
}
```

## Anti-Patterns

```r
# BAD: Jump straight to complex model
model <- xgboost::xgb.train(params, dtrain, nrounds = 1000)

# GOOD: Baseline first, then compare
baseline <- glm(y ~ ., family = binomial, data = train)
# ... evaluate baseline ...
# ... THEN try xgboost if baseline insufficient ...

# BAD: Compare on accuracy alone
accuracy(baseline) vs accuracy(xgb)

# GOOD: Compare on proper scoring rules
mn_log_loss(baseline) vs mn_log_loss(xgb)

# BAD: Use ML defaults without understanding
xgboost(data, nrounds = 100)  # What are we optimizing?

# GOOD: Explicit objective matching the problem
boost_tree() |> set_mode("classification")  # Clear intent
```

## Model Code Checklist

When editing model code, verify:
1. **Baseline comparison**: Does this model have a GLM/GLMM baseline?
2. **Proper scoring**: Using proper scoring rules (log loss, Brier), not just accuracy/AUC?
3. **Calibration**: Is calibration assessed (reliability diagram, calibration slope)?
4. **Time-aware CV**: For time data, using walk-forward splits (`rsample::sliding_period()`), not `vfold_cv()`?
5. **Separation of concerns**: Model outputs probabilities only, business logic in separate decision layer?
6. **Versioning**: Trained model pinned with metadata (`pins::pin_write()` or `vetiver::vetiver_pin_write()`)?

## Related Skills

- `model-evaluation-calibration` - Proper scoring and backtesting
- `mlops-deployment` - Versioning and serving trained models
- `analysis-rationale-logging` - Document model selection decisions
- `test-driven-development` - Test model code, not just model performance
