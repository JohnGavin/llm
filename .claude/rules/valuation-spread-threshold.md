---
name: valuation-spread-threshold
description: Only deviate from policy weights when valuation spreads exceed 2-3 standard deviations from historical mean, capped at 5-10 percent of portfolio
type: rule
---

# Rule: Valuation-Spread Deviation Threshold with Position Cap

## Source

Swedroe evidence-based investing framework (wiki: `knowledge/wiki/swedroe-evidence-investing.md`, Gap 4).

## When This Applies

Any tactical allocation decision — deviating from policy weights based on valuation signals, factor spreads, or mean-reversion indicators.

## CRITICAL: Deviate Only at Extremes, Cap the Tilt

Swedroe operationalises tactical allocation as: only deviate from policy weights when valuation spreads reach 2-3 standard deviations from their long-term mean, and cap any tactical tilt at 5-10% of portfolio.

## Required Checks

| Parameter | Requirement |
|-----------|-------------|
| Spread metric | Define the valuation spread (e.g., value-growth P/E ratio, credit spread, yield curve) |
| Historical baseline | Compute long-term mean and standard deviation (minimum 20 years of data) |
| Deviation threshold | Only tilt when spread exceeds **2 SD** from mean |
| Position cap | Any tactical tilt capped at **5-10%** of total portfolio |
| Reversion plan | Document when to unwind the tilt (e.g., spread returns within 1 SD) |

## Decision Table

| Spread deviation | Action |
|-----------------|--------|
| < 1 SD | No tilt — stay at policy weights |
| 1-2 SD | Monitor — document but do not act |
| 2-3 SD | Tilt permitted — max 5% of portfolio |
| > 3 SD | Tilt permitted — max 10% of portfolio |

## Forbidden Patterns

| Pattern | Why wrong |
|---------|-----------|
| Tactical tilt based on "feels cheap/expensive" | No quantified threshold |
| Tilt > 10% of portfolio on any single signal | Unbounded risk |
| No reversion plan | Open-ended tactical bets become permanent drift |
| Short historical baseline (< 10 years) | SD estimates unreliable |

## Related

- `risk-regime-evaluation` — regime-conditional metrics; this rule adds spread-based allocation triggers
- `position-sizing-guardrails` — position caps; this rule adds tactical-tilt-specific caps
