---
name: underperformance-prior
description: Require evidence that current underperformance exceeds documented historical ranges before revising strategies
type: rule
---

# Rule: Require Long-Underperformance Prior Before Strategy Revision

## Source

Swedroe evidence-based investing framework (wiki: `knowledge/wiki/swedroe-evidence-investing.md`, Gap 2). Documented historical underperformance periods.

## When This Applies

Any decision to revise, abandon, or reduce allocation to a strategy based on underperformance.

## CRITICAL: Multi-Year Underperformance Is Historically Normal

Swedroe documents that 13-40 year underperformance periods are not anomalies — they are the documented norm for well-known factors and asset classes:

| Asset/Factor | Underperformance period | Duration |
|-------------|------------------------|----------|
| S&P 500 vs T-bills | 1929-1943 | 14 years |
| S&P 500 vs T-bills | 1966-1982 | 16 years |
| S&P 500 vs T-bills | 2000-2012 | 12 years |
| Large growth vs 20yr treasuries | 1969-2008 | 39 years |

## Required Before Abandoning a Strategy

| Check | Question |
|-------|----------|
| Historical range | What is the longest documented underperformance period for this factor/asset class? |
| Current duration | How long has the current underperformance lasted? |
| Comparison | Is current drawdown duration within the documented range? |
| Conclusion | If within range → underperformance is **not** evidence against the strategy |

## Decision Table

| Current underperformance vs historical max | Action |
|-------------------------------------------|--------|
| < 50% of historical max duration | Normal — no revision warranted |
| 50-100% of historical max duration | Monitor — document but do not revise |
| > 100% of historical max duration | Investigate — may indicate structural change |
| > 150% + structural evidence | Consider revision (with `resulting-prohibition` checks) |

## Forbidden Patterns

| Pattern | Why wrong |
|---------|-----------|
| "Value has underperformed for 5 years, it's dead" | 5yr is well within historical range |
| "Our factor hasn't worked since 2020" | 3-6yr drawdowns are normal |
| Abandoning a strategy without checking historical drawdown durations | No prior calibration |

## Related

- `backtest-partitions` — partition-based evaluation
- `resulting-prohibition` — outcome vs process distinction
- `risk-regime-evaluation` — regime-conditional metrics
