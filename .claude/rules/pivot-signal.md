---
description: Trigger pivot or escalation after repeated failures on the same task
paths:
  - "**"
---
# Rule: Pivot Signal on Repeated Failures

## When This Applies

During any coding task when consecutive tool calls fail on the same objective.

## Trigger Thresholds

| Consecutive failures | Action |
|---------------------|--------|
| 3 | Pause. Re-read the error. State what you've tried and why it failed. Try a different approach. |
| 5 | Escalate to user: "I've tried N approaches for [task]. The failures are: [list]. Should I continue, pivot, or get your input?" |
| 7 | Stop attempting. Report all failed approaches with error details. Suggest the user try manually or file an issue. |

## What Counts as a Failure

- Bash command exits non-zero on the same task
- Edit tool fails to find the old_string
- Test still fails after a fix attempt
- Same error message appears after a change

## What Does NOT Count

- Expected failures in TDD (RED phase)
- Deliberate exploration (trying multiple grep patterns)
- Background tasks that haven't completed yet

## How to Pivot

1. State the current approach and why it's failing
2. List alternatives not yet tried
3. Pick the most promising alternative OR escalate to user
4. Do NOT retry the same approach with minor variations more than twice
