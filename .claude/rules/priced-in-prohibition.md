---
name: priced-in-prohibition
description: Require evidence of incremental predictive power before using signals derived from publicly available information
type: rule
---

# Rule: Prohibit Acting on Priced-In Information

## Source

Swedroe evidence-based investing framework (wiki: `knowledge/wiki/swedroe-evidence-investing.md`, Gap 6).

## When This Applies

Any project constructing trading signals from publicly available information — macro indicators, earnings announcements, analyst consensus, news sentiment, sector rotations, or economic data releases.

## CRITICAL: Public Information Carries No Edge

A signal derived from information available to all market participants is already reflected in current prices. This is distinct from look-ahead bias (using future data) — it is about **currently available but already-priced** information.

Before incorporating a signal based on public data, require evidence that the signal provides **incremental** predictive power beyond what is already reflected in prices. The burden of proof is on the signal, not on the market.

## Required Checks

| Check | Question | Fail condition |
|-------|----------|---------------|
| Information availability | Is this data available to institutional investors? | If yes, assume priced in |
| Incremental power | Does the signal predict returns **after** controlling for known factors (Fama-French, momentum, etc.)? | No residual alpha = priced in |
| Implementation edge | Is our edge in *processing speed* or *structural access*, not information content? | If edge is "we read the data" → no edge |
| Decay rate | Does the signal's predictive power decay within minutes/hours of release? | Fast decay = already being traded on |

## Forbidden Patterns

| Pattern | Why wrong |
|---------|-----------|
| "GDP growth is slowing, so short equities" | Consensus macro is fully priced |
| "Analyst consensus is bullish" | Consensus = priced in by definition |
| "This sector is overvalued based on P/E" | Relative valuation is the most-watched metric |
| Signal from a widely-followed indicator without decay analysis | No evidence of incremental power |

## Acceptable Signals

| Type | Why it may work |
|------|----------------|
| Structural/behavioural anomalies with academic evidence across markets | Persistent mispricing documented over decades |
| Proprietary data not available to the market | Genuine information asymmetry |
| Speed advantage on public data (HFT context) | Edge is execution, not information |
| Cross-asset signals the market segments ignore | Institutional silos create blind spots |

## Related

- `look-ahead-bias-prevention` — covers temporal leakage; this rule covers information-already-priced
- `cross-geography-pervasiveness` — pervasiveness test strengthens evidence against data mining
- `backtest-robustness` — parameter sensitivity; this rule adds information-content scrutiny
