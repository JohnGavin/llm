---
paths:
  - ".claude/rules/human-in-the-loop-decision-points.md"
---

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


## Sections Moved from the Rule Body (2026-09-21 line-limit pass)

Original verbatim text moved out of the rule; the normative summary stays in the rule. Includes the full Auto-Merge origin rationale.

PR merge is Class C by default (explicit verb required, every time). A
**global toggle** in `~/.claude/CLAUDE.md` — `**Auto-Merge Policy:** ON` /
`OFF` — lets the user opt merges into Class D (proceed automatically)
*without restating it per session or per PR*. The toggle applies to every
project, not just this one — that is the point: a per-session verbal grant
("merge anything clean this session") does not scale for a prolific solo
maintainer and has to be re-typed every time.

2. The merge-gate / roborev consistency check reports a genuine PASS —
   **never** an indeterminate result (exit code 3, per
   `checks-must-distinguish-unknown`) treated as a pass. An indeterminate
   gate always falls back to Class C (ask), regardless of the toggle — a
   gate that cannot tell you whether it checked anything is not evidence of
   safety.

This is advisory, not hook-enforced: no technical mechanism currently blocks
a merge call the way `agent_push_guard.sh` blocks a worktree-agent push to
`main`. The policy trades a firm technical backstop for zero session-to-session
friction — a deliberate choice, made explicitly rather than by default (see
Origin below). It depends entirely on this rule being read and followed, the
same as every other advisory rule in this corpus; a GitHub branch-protection
review requirement was considered and explicitly declined as an enforcement
mechanism because it reintroduces the same manual click-through friction the
toggle exists to remove.

A PR touching **any** excluded path reverts to standard Class C — the toggle
does not override this list under any circumstance, and repo visibility
(public vs. private) is deliberately NOT a criterion here: a private repo is
not automatically low-stakes (it typically holds more sensitive content, not
less), so exclusion is based on change class, never on repo visibility alone.

User request 2026-08-28: repeated manual "merge" confirmations were the
higher-friction cost for a prolific solo maintainer running many small,
independently-verified PRs per session; a session-scoped verbal grant was
rejected as still requiring the user to remember and restate it every
session, so the toggle is global instead. Full auto-merge on green gates
alone (no exclusion list) was explicitly rejected: this repo's own incident
history shows automated checks passing when they should not have — the
2026-08-11 credential leak passed the model's own pre-commit self-check, the
phone-number leak passed automated PII scanning for four months across nine
commits, and roborev itself has shipped phantom-failure counts, quota
misclassification, and silently-dropped reviews (`#923`/`#927`/`#904`/`#928`).
The exclusion list targets exactly the paths where those incidents actually
occurred. Improving the underlying gates' own false-negative rate (so "gate
says clean" is trustworthy more often) is tracked separately as its own
priority initiative — this section governs the merge policy, not gate
quality.

```
Agent: "I'll do these Class D actions:
  1. Edit R/foo.R — add NA check
  2. Edit tests/test-foo.R — add matching test
  3. git commit + push to feat/fix-foo
Confirm? (or say 'stop' to cancel)"
```

See [`_companions/human-in-the-loop-decision-points-details.md`](_companions/human-in-the-loop-decision-points-details.md)
for the full worked examples (wrong/right auto-merge, wrong/right scope
expansion). The normative rule above is complete without it.

- [#477](https://github.com/JohnGavin/llm/issues/477) — origin issue.
- [#450](https://github.com/JohnGavin/llm/issues/450) — parent design tracker (Salesforce Principle 5).
