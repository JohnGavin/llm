---
name: pr-shipping-discipline
description: "Ship it" / "ready to ship" / "let's ship this" ALWAYS means open a PR. NEVER means merge directly to main. Mandatory.
metadata:
  type: rule
---

# Rule: PR-Shipping Discipline (Mandatory)

## When This Applies

Any time the orchestrator, an agent, the user, or a workflow step uses informal "shipping" language:

| Phrase | What it means |
|---|---|
| "ship it" / "ship this" / "let's ship" | Open a PR — never merge |
| "ready to ship" / "ready to go" | Open a PR — never merge |
| "shipping now" | Push the feature branch and open a PR — never merge |
| "let's land this" | Open a PR; merge ONLY if explicit user signal follows |
| "merge this" / "merge to main" | Explicit merge intent — proceed via `gh pr merge` |

The rule normalises ambiguous shorthand to the safer interpretation.

## CRITICAL: Default to PR, escalate to merge with explicit signal

The failure mode this rule prevents: a Claude version or a future contributor reads "ship it" as a green light to merge directly to main, bypassing PR review, CI checks, roborev review, and the merge-time AGENTS.md conflict-resolution we do at the orchestrator layer. Once `origin/main` has the commit, rolling back is non-trivial and the working state of dependents (worktrees, scheduled rebuilds) drifts.

The discipline is one-way: PR is always safe; direct merge requires explicit user authorisation per the parent `agent-no-push-to-main` rule (which enforces this at the hook level for agents).

## Decision table

| Caller | Phrase | Action |
|---|---|---|
| User / orchestrator says "ship it" | — | Open PR via `gh pr create --body-file …` |
| User / orchestrator says "merge it" | — | Merge ONLY after PR is mergeable, all checks pass, and user has acknowledged |
| Subagent emits "ready to ship" in its report | — | Treat as "PR opened" — never as merge authorisation |
| Workflow / script literal `ship_it()` function | — | The function must open a PR; if named `merge_it()` it may merge |
| User says "land this" + explicit `--merge` flag context | — | OK to merge (explicit intent) |

## Forbidden patterns

| Pattern | Why wrong | Fix |
|---|---|---|
| Subagent reads "ship it" in its prompt and calls `gh pr merge` | Bypasses the PR review surface | Subagent calls `gh pr create` only; orchestrator merges |
| `git push origin <feature>:main` interpreted from "ship it" | Same as direct merge; worse — bypasses the PR API | Push to feature branch, `gh pr create` |
| Orchestrator merges on its own initiative after an agent reports "ship it" | The agent's report is not user authorisation | Wait for explicit user direction to merge |
| Script `bin/ship.sh` that does both push AND merge | Conflates the two operations | Rename to `bin/ship-pr.sh` if it only opens PR; or split |

## Relationship to other rules

- [`agent-no-push-to-main`](agent-no-push-to-main.md) — hook-level enforcement that agents in worktrees CANNOT push to `main` regardless of prompt wording. This rule is the human-readable companion: shorthand language never overrides that gate.
- [`auto-delegation`](auto-delegation.md) — subagents are dispatched with explicit isolation; their reports are advisory, not authorisation
- [`destructive-ops-guard`](destructive-ops-guard.md) Part 3 — two-key confirmation pattern for irreversible operations; direct merges to main are class B (recoverable but expensive)
- [`bash-safety`](bash-safety.md) — `gh pr merge` is a single non-compound command; no `&&` chains around it
- [`permission-discipline`](permission-discipline.md) — `bypassPermissions` does not bypass the PR-vs-merge distinction; it just changes the confirmation surface for individual tool calls

## Allowed shorthand vocabulary

When "ship it" is used in user-facing language (PR titles, CHANGELOG entries, session-end summaries) it carries its informal meaning. The rule applies only to the *action* layer where the shorthand resolves into a tool call.

## Self-test

Mental check: after reading the phrase, the question to answer is:

> "Have I been authorised to mutate `origin/main` directly, or am I authorised to *propose* a change via PR?"

Default answer: PR. Override only on explicit "merge" / "merge to main" / "land directly" wording with no qualifier.

## Origin

[#469](https://github.com/JohnGavin/llm/issues/469) — Show Us Your (Agent) Skills Episode 1, Jeremiah Lowin's `ship-it` skill which "retrains 'ship it' to mean opening a PR rather than merging." This rule applies the same discipline to OUR shorthand vocabulary so the same surprise can't reach us via a future Claude version or a future contributor reading shorthand differently.

## Related

- [`agent-no-push-to-main`](agent-no-push-to-main.md)
- [`auto-delegation`](auto-delegation.md)
- [`destructive-ops-guard`](destructive-ops-guard.md)
- [`bash-safety`](bash-safety.md)
- [`skills-vs-mcp`](skills-vs-mcp.md) — companion authoring rule (skills steer behavior, MCP distributes business logic; this rule steers PR-vs-merge behavior at the language layer)
- [#469](https://github.com/JohnGavin/llm/issues/469) — origin
