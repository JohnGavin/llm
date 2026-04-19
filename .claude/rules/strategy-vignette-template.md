---
paths:
  - "docs/*backtest*.qmd"
  - "docs/*strategy*.qmd"
  - "docs/*rotation*.qmd"
  - "docs/drif*.qmd"
  - "docs/factor*.qmd"
---
# Rule: Strategy Vignette Template (Mandatory for All Backtests)

## When This Applies
Every vignette that presents a backtested trading strategy.

## Required Tabs Per Strategy Page

Every strategy page MUST have these tabs in this order:

### 1. Definition (What)

Explain the strategy to someone who has never seen it. Include:

- **What:** One-paragraph plain-English description
- **Rationale (Market Dynamics):** WHY this works — microstructure, behavioral bias, liquidity effects
- **Step-by-step example:** Walk through ONE month with concrete numbers
- **Key distinction:** How this differs from related strategies (with links)

### 2. Performance (Equity Curve)

- Equity curve plot with OOS/validation dashed line
- Caption with credibility caveats (high vol, extreme returns, short OOS window)
- NEVER present an equity curve without acknowledging its limitations

### 3. Metrics (Table)

- Transposed table (`hd_dt_wide()`) with Training / Testing / Validation / Full periods
- **Risk metrics FIRST** (in this order): Max DD, CVaR, Vol
- Then return metrics: CAGR, P&L (cumulative $), Sharpe (secondary)
- Gross AND net (after 0.20% round-trip cost)
- For stock-level: also show long-only vs long-short

### 4. Assumptions

Per `backtesting-assumptions` rule:
- Execution: close, costs, cash return, fees
- Which defaults apply, which are overridden

### 5. Robustness

Per `robustness-testing` rule:
- Alpha decay at t+1, t+2, t+5
- Parameter sensitivity ±20%
- Regime stress (VIX-based)
- Bootstrap confidence interval on Sharpe

### 6. Pros & Cons

Table format:

| | Detail |
|--|--------|
| **Pros** | ... |
| **Cons** | ... |
| **Works well** | Market conditions where strategy thrives |
| **Works badly** | Market conditions where strategy fails |
| **Factor exposure** | Which common risk factors explain the returns |

### 5. References

Links to: related strategy vignettes, original research papers, data sources.

## Comparison Page (When Multiple Strategies)

### Summary Tab

Table mapping signals × levels with links to each strategy definition.

### Equity Curves Tab

- Label it "Equity Curves" not "All Strategies"
- Include credibility caveats in caption
- Acknowledge when curves look unrealistic

### Metrics Tab

- All strategies in one table with partition columns
- Include links to where each strategy is defined

### Key Findings Tab

Group findings by category, ordered by importance:

| Category | Order |
|----------|-------|
| **P&L** | Raw returns, CAGR, cumulative |
| **OOS / Validation** | Out-of-sample performance, generalisation |
| **Risk** | Volatility, drawdown, tail risk |
| **Robustness** | Stability across regimes, factor exposure, data snooping |

Use tables, not prose. Each finding has evidence in the adjacent column.

## Anti-Patterns

| Wrong | Right |
|-------|-------|
| "Cross-sectional backtests on 660 stocks, compared with factor-level" | Define WHAT you're doing, step by step |
| Single "Key Findings" callout with bullet list | Grouped table by P&L/OOS/Risk/Robustness |
| Equity curve without credibility caveat | "These curves should be interpreted with caution: 44% vol..." |
| "All Strategies" tab label | "Equity Curves" — describe what it IS |
| Metrics without links to strategy definitions | Every strategy name links to its Definition tab |

## Related Rules

- `backtest-partitions` — Train/Test/Validation split
- `statistical-reporting` — Effect sizes, no "significant"
- `look-ahead-bias-prevention` — OOS methodology
- `visualization-standards` — Caption requirements
