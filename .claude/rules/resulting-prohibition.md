---
name: resulting-prohibition
description: Judge strategy decisions by process quality and evidence, not by recent outcomes or performance
type: rule
---

# Rule: Prohibit "Resulting" — Judge Decisions by Process, Not Outcome

## Source

Swedroe evidence-based investing framework (wiki: `knowledge/wiki/swedroe-evidence-investing.md`, Gap 1). Also: Annie Duke, *Thinking in Bets*; Robert Rubin's decision framework.

## When This Applies

Any strategy revision, position change, or model update triggered by recent performance — good or bad.

## CRITICAL: Outcomes Are Not Evidence

"Resulting" is judging the quality of a decision by its outcome instead of by the quality of the decision-making process. A strategy that loses money for 3 years may be executing a sound process within its historically documented drawdown range. A strategy that makes money may be lucky.

Before any strategy revision, require documentation of what new **evidence** (not new **outcome**) justifies the change.

## Required Before Strategy Revision

| Question | Must answer |
|----------|------------|
| What new evidence (not outcome) motivates this change? | Cite paper, structural shift, or regime change |
| Is current performance within the historically documented range? | Compare to `underperformance-prior` rule |
| Would you have made this change if recent performance were flat? | If no → resulting |
| Is the revision improving the *process* or chasing the *outcome*? | Must be process |

## Forbidden Patterns

| Pattern | Why wrong |
|---------|-----------|
| "Strategy lost money for 2 years, let's change parameters" | Resulting — 2yr loss may be normal for this factor |
| "This worked great last quarter, let's increase allocation" | Resulting — recency bias |
| "Our Sharpe dropped from 1.2 to 0.8, something is wrong" | Resulting — unless structural evidence of regime change |
| Changing position sizes after a drawdown without new evidence | Outcome-driven, not process-driven |

## Acceptable Revisions

| Trigger | Why valid |
|---------|-----------|
| New academic paper shows factor is explained by another factor | Evidence of structural change |
| Market microstructure changed (new regulations, venues) | Execution assumptions violated |
| Factor crowding metric exceeds historical range | Process-based signal |
| Cost structure changed (commissions, borrow rates) | Assumptions violated |

## Related

- `backtest-robustness` — parameter sensitivity protects against overfitting
- `position-sizing-guardrails` — prevent outcome-driven position changes
- `underperformance-prior` — defines historically normal drawdown durations
