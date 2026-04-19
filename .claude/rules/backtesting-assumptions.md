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
| Transaction cost (per trade) | 0.50% (1.00% round-trip) | Realistic for mid-cap, includes spread + impact |
| Estimated monthly turnover | 80% for decile strategies | High-turnover monthly sort |
| Short borrow rate | 3% annualised (0.25%/month) | General collateral rate |
| Return winsorisation | ±20% per month | Prevents compounding artifacts from extreme months |
| Cash return | 3-month US Treasury rate (RF from FF3) | Risk-free rate |
| Dividends | Reinvested | Total return basis |
| Taxes | Excluded | Pre-tax returns |
| Expense ratio | Most liquid similar ETF (e.g. SPY for S&P 500) | Real-world cost |
| Execution delay | Test t+1, t+2, t+5 to measure alpha decay | Robustness check |

### Cost Model Detail

Total monthly cost for a long-short decile strategy:
- **Transaction costs:** turnover × cost_per_trade × 2 (buy+sell) × 2 (both legs) = 0.80 × 0.005 × 4 = **1.6%/month**
- **Borrow cost:** 3%/12 = **0.25%/month**
- **Total:** ~**1.85%/month** for full-turnover long-short

This is why most academic long-short strategies are unprofitable after costs.
A strategy needs ~22% annual gross return just to break even on costs.

### Credibility Check

| Net CAGR | Credible? | Implication |
|----------|-----------|-------------|
| < -10% | No | Strategy loses money after costs — investigate |
| -10% to 0% | Marginal | Costs overwhelm gross returns |
| 0% to 10% | Plausible | Modest edge after costs |
| 10% to 20% | Suspicious | Verify assumptions carefully |
| > 20% | Not credible | Almost certainly unrealistic — check costs, survivorship, data |

## Every Backtest MUST Report

1. **Net returns only** (after ALL costs — transaction, borrow, winsorisation)
2. **Gross returns are secondary** — never lead with gross
3. **Alpha decay** at t+1, t+2, t+5 execution delays
4. **Total monthly cost** (transaction + borrow)
5. **Estimated turnover** (fraction of portfolio changed)
6. **Which assumptions differ from defaults** (if any)

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
