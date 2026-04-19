---
paths:
  - "R/plan_*backtest*.R"
  - "R/plan_*drif*.R"
  - "R/plan_*factor*.R"
  - "R/plan_*portfolio*.R"
  - "R/plan_*xgb*.R"
---
# Rule: Backtesting Assumptions (Mandatory for All Strategies)

## Default Assumptions

Unless explicitly noted otherwise, ALL backtests use:

| Assumption | Default | Source |
|------------|---------|--------|
| Execution time | Market close (4 PM ET) | Standard institutional practice |
| Transaction cost | 0.10% per trade (0.20% round-trip) | Conservative retail estimate |
| Cash return | 3-month US Treasury rate (RF from FF3) | Risk-free rate |
| Dividends | Reinvested | Total return basis |
| Taxes | Excluded | Pre-tax returns |
| Expense ratio | Most liquid similar ETF (e.g. SPY for S&P 500) | Real-world cost |
| Execution delay | Test t+1, t+2, t+5 to measure alpha decay | Robustness check |

## Every Backtest MUST Report

1. **Gross returns** (before costs)
2. **Net returns** (after transaction costs + expense ratio)
3. **Alpha decay** at t+1, t+2, t+5 execution delays
4. **Which assumptions differ from defaults** (if any)

## Position Sizing

- Risk a FIXED percentage per trade (default 1-2%)
- Fractional Kelly sizing based on acceptable max drawdown
- Adaptive by volatility: higher vol → smaller positions
- Standardise expected DD across trade types

## Exit Conditions

Define exit conditions BEFORE entry:
- Stop-loss level (fixed or trailing)
- Time-based exit (max holding period)
- Signal reversal exit
- Conditions may be adaptive but DEFINITION is fixed and known in advance

## Judge by P&L

- P&L is the primary metric, not Sharpe
- Returns are NOT normal → do not rely on standard deviation/volatility
- Sharpe is secondary/indicative only
- Sort leaderboards by risk metrics (DD, CVaR) not Sharpe

## Related Rules

- `backtest-partitions` — train/test/validation split
- `strategy-vignette-template` — vignette structure
- `statistical-reporting` — effect sizes, FPR
