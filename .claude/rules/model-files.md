---
paths:
  - "R/model_*.R"
  - "R/models/**"
  - "R/tar_plans/plan_model*.R"
---
# Model Code Checklist

## Reminders

When editing model code, verify:

1. **Baseline comparison**: Does this model have a GLM/GLMM baseline? (see `modeling-baselines` skill)
2. **Proper scoring**: Are you using proper scoring rules (log loss, Brier), not just accuracy/AUC? (see `model-evaluation-calibration` skill)
3. **Calibration**: Is calibration assessed (reliability diagram, calibration slope)? A model predicting "70% chance" should be right ~70% of the time.
4. **Time-aware CV**: For time-dependent data, are you using walk-forward splits (`rsample::sliding_period()`), not random `vfold_cv()`?
5. **Separation of concerns**: Does the model output probabilities only, with business logic in a separate decision layer?
6. **Versioning**: Is the trained model pinned with metadata (`pins::pin_write()` or `vetiver::vetiver_pin_write()`)? (see `mlops-deployment` skill)
