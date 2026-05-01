---
paths:
  - "vignettes/**"
  - "*.qmd"
  - "*.Rmd"
---
# Rule: Audience-Appropriate Communication

## When This Applies
Any prose: vignettes, README, issue/PR descriptions, captions, reports.

## CRITICAL: Match Style to Reader

| Audience | Style |
|----------|-------|
| Developers | Precise, assume domain knowledge, code examples |
| Stakeholders | Lead with conclusion, plain language, quantify uncertainty |
| Issue trackers | State what changed and why, not how |

## Examples

```
Developer:   "Use glmmTMB::predict(re.form=NA) for population-level predictions"
Stakeholder: "Cases decreased 23% (95% CI: 18-28%) vs prior quarter"
Issue:       "Fix: age filter was inverted, now correctly excludes minors"
```

## Forbidden Patterns

| Pattern | Why wrong | Fix |
|---------|-----------|-----|
| "It should be noted that..." | Wordy filler | Delete, state the fact directly |
| "In order to..." | Verbose | "To..." |
| Jargon without definition | Alienates non-specialists | Define on first use |
| Hedging in code comments ("maybe", "probably") | Suggests untested code | Document assumptions clearly |
| Paragraphs > 150 words in vignettes | Hard to scan | Break into headed sections |
