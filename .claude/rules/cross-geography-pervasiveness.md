---
name: cross-geography-pervasiveness
description: Require evidence of factor premiums across independent geographies before adopting systematic strategies
type: rule
---

# Rule: Require Cross-Geography Pervasiveness for Factor Adoption

## Source

Swedroe evidence-based investing framework (wiki: `knowledge/wiki/swedroe-evidence-investing.md`, Gap 5). Swedroe/Berkin five-criteria framework for factor evaluation.

## When This Applies

Any decision to adopt a new factor, signal, or systematic strategy for live deployment.

## CRITICAL: Single-Market Factors May Be Data-Mined

Swedroe requires a premium to be persistent, pervasive, robust, investable, and intuitive before deployment. Pervasiveness — working across geographies, asset classes, and time periods — is a stronger evidential bar than in-sample performance alone.

## Required Before Factor Adoption

| Criterion | Minimum evidence |
|-----------|-----------------|
| Pervasive | Premium documented in **at least 2 independent geographies/markets** |
| Persistent | Works across multiple decades, not just one regime |
| Robust | Survives alternative definitions (e.g., different P/B cutoffs for value) |
| Investable | Survives transaction costs, capacity constraints, liquidity filters |
| Intuitive | Has a risk-based or behavioural explanation for why it persists |

## Decision Table

| Evidence level | Action |
|---------------|--------|
| 1 market only | **Do not adopt** — insufficient evidence, may be data-mined |
| 2 markets, same region | Adopt with caution — possible regional bias |
| 2+ markets, different regions | Adopt — meets pervasiveness threshold |
| Global evidence (3+ regions) | Strong adoption case |

## Forbidden Patterns

| Pattern | Why wrong |
|---------|-----------|
| "Works in US equities 1990-2020" as sole evidence | Single market, single period |
| Factor discovered in one dataset, never replicated | Data mining until proven otherwise |
| Adopting a signal because it backtests well locally | No pervasiveness test |

## The Five Criteria Checklist

Before deploying any factor, document:

- [ ] **Persistent:** evidence across 20+ years
- [ ] **Pervasive:** evidence in 2+ independent markets
- [ ] **Robust:** survives alternative definitions
- [ ] **Investable:** net-of-cost returns positive
- [ ] **Intuitive:** risk or behavioural explanation documented

## Related

- `backtest-robustness` — parameter sensitivity; this rule adds geographic replication
- `priced-in-prohibition` — incremental power test; pervasiveness strengthens the case
- `backtesting-assumptions` — cost model; investability criterion requires cost-adjusted returns
