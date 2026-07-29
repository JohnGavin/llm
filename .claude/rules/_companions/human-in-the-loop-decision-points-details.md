# Companion: Human-in-the-Loop Decision Points — Worked Examples

Worked examples split out of the always-loaded
[`human-in-the-loop-decision-points`](../human-in-the-loop-decision-points.md)
rule to keep it lean. The normative content (5-Class Decision Taxonomy,
Application Across Tool Surfaces, Class D Bounded-Confirm Pattern, Forbidden
Patterns) stays in the rule; this file is the four worked dialogue examples,
loaded on demand.

## Wrong — auto-merge on "ship it"

```
User:  "ship it"
Agent: [calls gh pr merge --squash --delete-branch]
       → Merged. Branch deleted.
```

Problem: "ship it" is ambiguous. The agent treated it as Class C authorisation without an explicit verb.

## Right — PR open + wait

```
User:  "ship it"
Agent: "Opening PR #42 (Class D — scoped commit). Waiting for you to
        review before merge."
       [calls gh pr create --title "..." --body-file /tmp/body.md]
       → PR created: https://github.com/JohnGavin/llm/pull/42

User:  "merge this"
Agent: "Merging PR #42 (Class C — cross-boundary visible).
        Confirm: type 'merge pr 42' to proceed."
       [waits for next turn]

User:  "merge pr 42"
Agent: [calls gh pr merge 42 --squash]
       → Merged.
```

## Wrong — scope expansion without bounded-confirm

```
User:  "tidy these up"
Agent: [silently creates 7 PRs across 4 worktrees, closes 3 issues]
       → Done.
```

Problem: scope expanded beyond the implicit authorisation. Class D but at large scale without bounded-confirm.

## Right — bounded-confirm before scale

```
User:  "tidy these up"
Agent: "I'll make these Class D changes:
  1. R/foo.R — replace stop() with cli_abort()
  2. R/bar.R — same pattern
  3. R/baz.R — same pattern
  4. tests/test-foo.R — update expectation
  5. commit + push feat/tidy-cli-errors
Confirm or redirect?"

User:  "yes, do it"
Agent: [executes the 5 bounded Class D ops]
       → Done.
```
