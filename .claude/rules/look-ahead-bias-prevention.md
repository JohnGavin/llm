---
paths: ["**/plan_qa*.R", "**/backtest*", "**/features*.R", "**/_targets.R"]
---

# Rule: Look-Ahead Bias Prevention (MANDATORY for all backtests)

## When This Applies
Any project that trains a model on historical data and evaluates it — sports betting,
trading strategies, clinical prediction, churn models, any temporal prediction task.

## The Lesson (footbet, 2026-04-13)

A Poisson GLM showed **+1,148,385% ROI** in-sample but **-100% ROI** out-of-sample
(complete bankroll wipeout). The in-sample "profit" was entirely look-ahead bias:
fitting ~40 team coefficients per league on data that overlapped the test matches.
The +0.5% log-loss improvement from SoT features was real (calibration) but
translated to zero P&L improvement because the model had no genuine edge over
the closing line.

This is not a bug — the code was correct. The bias was structural: evaluating
a model on the same temporal period it was trained on, then treating the result
as evidence of predictive ability.

## The Three Leakage Types (ordered by detectability)

| Type | What leaks | Detection | Footbet example |
|---|---|---|---|
| **Same-match** | Outcome used as feature | `dplyr::lag()` audit | Using fthg to predict ftr |
| **Cross-period** | Future data in training set | Train/test date assertion | GLM fitted on 2015-2025, tested on 2015-2025 |
| **Within-fold bet-time** | Data unavailable at decision time | As-of join (`apply_asof_cutoff`) | Wednesday xG used for Monday bet |

## MANDATORY: QA Target in Every Backtest Pipeline

Every project with a backtest MUST include a `qa_look_ahead_bias` target in
`plan_qa_gates.R` (or equivalent). This target runs on every `tar_make()` and
fails the pipeline if any check fails.

### Required checks

See `model-evaluation-calibration` skill reference: `qa-bias-template.md` for implementation template.

The target must run 4 checks (checks 1–4 below) and report via `cli::cli_warn` on failure,
`cli::cli_alert_success` on pass. Use `cue = targets::tar_cue(mode = "always")`.

### Check 2 thresholds (calibrate per project)

| In-sample vs OOS gap | Interpretation | Action |
|---|---|---|
| < 20pp | Normal generalisation loss | OK |
| 20–100pp | Suspicious — investigate | Warn, log to CHANGELOG |
| > 100pp | Almost certain look-ahead bias | **FAIL pipeline** |
| In-sample profit + OOS wipeout | Definitive bias | **FAIL pipeline**, block commit |

## Red Flags — STOP Before Evaluating P&L

Before computing ROI, Sharpe, or any P&L metric, verify:

1. **Was the model trained on data that excludes the test period?**
   - If `fit_poisson_glm(matches_long)` uses ALL matches but `find_value_bets()`
     also uses ALL matches — that's look-ahead bias.
   - Fix: use `oos_split$train` for training, `oos_split$validate` for evaluation.

2. **Are rolling features computed with `dplyr::lag()`?**
   - If `rolling_xg` at match i uses xG from match i — that's same-match leakage.
   - Fix: `dplyr::lag(slider_mean(...))` ensures only i-1 and earlier are used.

3. **Are features available at bet decision time?**
   - If a rolling feature uses a midweek match result for a weekend bet, and the
     bettor couldn't have known the midweek result at decision time — that's
     within-fold leakage.
   - Fix: `apply_asof_cutoff()` with a 7-day buffer.

4. **Is the in-sample metric dramatically better than walk-forward?**
   - In-sample log-loss of 0.90 but walk-forward of 1.01 = the model memorised.
   - Log the gap in every experiment commit message.

## Structural Prevention (Pipeline Design)

Three patterns (see `qa-bias-template.md` for full code):

- **Separate train/evaluate targets**: never fit and evaluate on the same target's data.
- **Walk-forward CV per-fold**: return per-fold tibble, aggregate in a separate target.
- **P&L depends on OOS predictions**: `pnl` target must trace to `oos_*` or `cv_*` model, not a full-sample fit.

### Execution delay sensitivity (CHECK 5)

Re-run P&L with 1-5 period delays. If alpha disappears at t+1, the
edge is speed-dependent and may be impractical. See `execution-delay-sensitivity` rule.
Full CHECK 5 snippet in `qa-bias-template.md`.

## In Commit Messages (experiment format)

Every experiment commit MUST include the OOS metric alongside in-sample:

```
experiment: add SoT ratio to GLM features
metric_is: log_loss 1.011 (in-sample, 5 leagues)
metric_oos: log_loss 1.016 (walk-forward CV, same leagues)
delta: -0.005 (IS improves, OOS unchanged)
verdict: COMMIT (feature helps calibration, no P&L claim)
```

If `metric_is` improves but `metric_oos` doesn't, the improvement is likely memorisation.

## Forbidden Claims

| Claim | Why forbidden | Required instead |
|---|---|---|
| "ROI of X% on backtest" | Without specifying IS vs OOS | "OOS ROI of X% (train: 2015-2020, test: 2021-2023)" |
| "The model beats the market" | P&L on training data proves nothing | "OOS CLV of X pp (walk-forward, cut7)" |
| "Adding feature X improves P&L" | Must show OOS improvement | "Feature X improves OOS log-loss by Y% (P&L impact: TBD)" |
| "Sharpe ratio of X" | On what data? | "OOS Sharpe: X (IS Sharpe: Y, gap: Z)" |

## Agent Integration

- **`critic` agent**: When reviewing backtest code, check for temporal separation
  between training and evaluation data. Flag any target where `fit_*()` and
  `evaluate_*()` operate on the same dataset.
- **`r-debugger` agent**: When investigating "too good to be true" metrics,
  first hypothesis should be look-ahead bias, not a genuine finding.
- **`quality-gates` skill**: Deduct 20 points if `qa_look_ahead_bias` target
  is missing from a backtest pipeline. Deduct 50 if check 2 (divergence) fails.

## Related Rules

- `model-evaluation-calibration` — scoring rules and walk-forward methodology
- `statistical-reporting` — effect sizes, FPR, never say "significant"
- `verification-before-completion` — no claims without evidence
- `feature-leakage-temporal` (wiki) — the three leakage types
- `priced-in-prohibition` — information already reflected in prices
