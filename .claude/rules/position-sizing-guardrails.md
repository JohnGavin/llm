---
paths:
  - "R/*kelly*.R"
  - "R/*sizing*.R"
  - "R/*stake*.R"
  - "R/plan_*oos*.R"
  - "R/plan_*backtest*.R"
---
# Rule: Position Sizing Guardrails

## When This Applies
Any project that converts model predictions into bet sizes or portfolio weights.

## CRITICAL: Sizing Determines Survival, Not Signals

Position sizing is more important than entry signals. A correct prediction
with wrong sizing leads to ruin. A mediocre prediction with correct sizing
survives.

## Mandatory Guardrails

### 1. Max Risk Per Bet (MANDATORY)

Every sizing function MUST enforce a maximum stake as a fraction of bankroll:

```r
# In kelly.R or equivalent
kelly_fraction <- function(prob, odds, fraction = 0.25, max_stake_pct = 0.05) {
  edge <- prob * odds - 1
  if (edge <= 0) return(0)
  kelly <- edge / (odds - 1)
  stake <- kelly * fraction
  min(stake, max_stake_pct)  # NEVER exceed max_stake_pct of bankroll
}
```

Default `max_stake_pct = 0.05` (5% of bankroll per bet). This prevents
Kelly overbetting when edge estimate is noisy.

### 2. Sizing Comparison in Every Backtest (MANDATORY)

Every backtest MUST compare at least **flat** vs **fractional Kelly** staking.
The comparison reveals whether sizing adds or destroys value.

```r
# Already in ah_walkforward_all: both flat and kelly staking modes
# REQUIRED: summary table showing both side-by-side
tar_target(sizing_comparison, {
  ah_walkforward_summary |>
    dplyr::select(model, staking, n_bets, roi_pct, max_dd, sharpe)
})
```

If Kelly is worse than flat, the edge estimates are unreliable.

### 3. Drawdown-Constrained Sizing (RECOMMENDED)

Size positions so that **expected maximum drawdown** stays within tolerance:

```r
# Given: willing to tolerate X% max drawdown
# Solve for: position size that keeps E[max_dd] <= X%
constrained_stake <- function(expected_dd_pct, tolerance_dd_pct, base_stake) {
  if (expected_dd_pct <= 0) return(base_stake)
  scale <- tolerance_dd_pct / expected_dd_pct
  min(base_stake * scale, base_stake)  # never increase beyond base
}
```

### 4. Volatility-Scaled Sizing (RECOMMENDED for multi-asset)

Higher volatility → smaller positions. Keeps risk consistent across bets:

```r
# Scale stake inversely with recent realized volatility
vol_scaled_stake <- function(base_stake, current_vol, target_vol) {
  if (is.na(current_vol) || current_vol <= 0) return(base_stake)
  scale <- target_vol / current_vol
  base_stake * min(scale, 2.0)  # cap at 2x base to prevent extreme sizing
}
```

## Anti-Patterns

| Wrong | Right |
|-------|-------|
| Kelly with no fraction (full Kelly) | Fractional Kelly (0.25 default) |
| Kelly stake > 10% of bankroll | Cap at `max_stake_pct` |
| Only testing one staking mode | Compare flat vs Kelly minimum |
| Sizing based on in-sample edge | Size based on OOS edge estimates |
| No drawdown analysis | Report max DD for every sizing mode |

## Drawdown Recovery Table

| Max Drawdown | Recovery Needed | Implication |
|---:|---:|---|
| 10% | 11% | Manageable |
| 20% | 25% | Uncomfortable |
| 30% | 43% | Dangerous |
| 50% | 100% | Survival risk |
| 70% | 233% | Effectively terminal |

This is why `max_stake_pct` exists — to prevent sequences of losses
from creating irrecoverable drawdowns.

## Position Sizing = Risk Control First

The hierarchy:
1. **Survive** — size so worst-case sequence doesn't wipe out
2. **Compound** — size so long-term growth is positive
3. **Optimize** — only then tune for maximum growth rate

Never skip to step 3.

## Related Rules

- `backtest-robustness` — sizing must be robust to parameter perturbation
- `backtest-partitions` — sizing parameters tuned on test, not validation
- `look-ahead-bias-prevention` — edge estimates must be OOS
- `resulting-prohibition` — prevent outcome-driven position changes
- `valuation-spread-threshold` — tactical tilt caps
