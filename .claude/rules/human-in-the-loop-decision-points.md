---
description: 5-class decision taxonomy — Classes A/B/C stop for the human; D/E proceed automatically
---

# Rule: Human-in-the-Loop Decision Points (Mandatory)

## Origin

[#477](https://github.com/JohnGavin/llm/issues/477) — accepted from [#450](https://github.com/JohnGavin/llm/issues/450), Salesforce 8 Design Principles gap analysis, Principle 5 (Design for strategic human intervention and oversight).

Generalises the 3-class op taxonomy in `destructive-ops-guard` Part 3 to a project-wide 5-class decision taxonomy covering ALL human-in-the-loop checkpoints — not just destructive operations.

---

## When This Applies

Any orchestrator or agent decision that has one or more of:

- An **irreversible effect** — data destruction, production mutation, force-push
- A **cross-boundary effect** — PR merge, issue close, email send, gh comment visible externally
- A **scope-expanding effect** — action set larger than explicitly authorised ("tidy these up" ≠ "create 7 PRs across 4 worktrees")
- An **audit-trail-relevant effect** — anything a reviewer might ask "who decided that, and why?"

Purely local, read-only, or sandboxed operations (file reads, grep, query) do not require HITL.

---

## CRITICAL: Automation Runs by Default; HITL Is the Override

Automation is not wrong. The failure mode is automation that runs **past the boundary** of what the human authorised. The taxonomy below names the boundary for each class and requires the appropriate checkpoint before crossing it.

> If a decision touches Classes A, B, or C: **STOP and wait** for the human before executing.
> If the decision is Class D or E: **proceed** — no confirmation needed.

---

## The 5-Class Decision Taxonomy

| Class | Name | Examples | Checkpoint required |
|---|---|---|---|
| **A** | Catastrophic / irreversible | `DROP TABLE prod`; delete repo; force-push to main; revert a merged PR; rotate production credentials; destroy a volume | Out-of-band ack AND target name supplied from memory (agent must NOT print the target name in the same turn as the prompt) |
| **B** | Destructive / recoverable | `rm -rf` >100 MB; `git reset --hard`; force-push feature branch; bulk delete issues; revert uncommitted changes across multiple files | Target name included in the user's confirmation phrase |
| **C** | Cross-boundary visible | PR merge; issue close; email send; `gh comment` posted externally; Slack/webhook notification; public release tag | Explicit action verb in user reply: "merge", "send", "close", "release" — NOT just "yes" or "go ahead" |
| **D** | Scoped commit / local write | `gh pr create`; branch push (own branch); file Edit/Write in worktree; commit to feature branch; open PR (not merge) | No confirmation — proceed automatically |
| **E** | Read-only / advisory | `gh issue list`; grep; SQL query; `git log`; `tar_read()`; file Read; test run (no side effects) | No confirmation — proceed silently |

Class D is the key innovation over `destructive-ops-guard` Part 3: it explicitly names the boundary where automation is the CORRECT default. Opening a PR is Class D, merging it is Class C.

---

## Application Across Tool Surfaces

| Tool surface | Class A/B (STOP) | Class C (stop + verb) | Class D (proceed) | Class E (silent) |
|---|---|---|---|---|
| **Bash** | `rm -rf`, `git reset --hard`, credential commands | `gh pr merge`, `gh release create` | `git commit`, `git push` own branch | `git log`, `grep`, query |
| **gh CLI** | `gh repo delete`, force-push main | `gh pr merge`, `gh issue close`, `gh issue comment` (external) | `gh pr create`, `gh pr view` | `gh issue list`, `gh pr list` |
| **Edit / Write** | Overwrite tracked file outside worktree | Batch rename across ≥ 3 repos | Edit/Write in own worktree | Read |
| **Agent dispatch** | Agent deleting data or force-pushing main | Agent merging PRs or closing issues | Agent creating PRs, committing, pushing own branch | Agent reading, grepping, running read-only checks |
| **MCP tool** | Destructive write (classified `destructive`) | External publish (`write` tier) | Local write (`write` tier, sandboxed) | Read-only (`read` tier) |

---

## The Default-PR-Not-Merge Principle

`pr-shipping-discipline` establishes that "ship it" means **open a PR**, not merge. This rule provides the taxonomic reason: **PR open is Class D** (scoped, reversible, local to the PR surface) while **PR merge is Class C** (cross-boundary visible, explicit verb required).

Any ambiguous phrasing — "ship it", "land this", "let's push" — resolves to Class D (open PR) unless the user supplies an explicit Class C verb ("merge", "merge to main", "land directly").

See `pr-shipping-discipline` for the full verb decision table.

---

## Class D Bounded-Confirm Pattern (New)

Class D does NOT require confirmation — but when the scope of a Class D action is **larger than what was explicitly authorised**, the agent MUST bound it before executing.

**When to bound:** the agent plans to take ≥ 3 Class D actions OR touches files outside the explicitly named scope.

**Pattern:**

```
Agent: "I'll do these Class D actions:
  1. Edit R/foo.R — add NA check
  2. Edit tests/test-foo.R — add matching test
  3. git commit + push to feat/fix-foo
Confirm? (or say 'stop' to cancel)"
```

The bounded-confirm is NOT a confirmation prompt for individual Class D ops. It is a **scope declaration** so the human can redirect before the work begins.

---

## Forbidden Patterns

| Pattern | Class violated | Why wrong | Fix |
|---|---|---|---|
| Agent auto-merges after "ship it" | C | "ship it" is ambiguous shorthand | Default to PR open (Class D); wait for "merge" |
| Agent accepts "yes" for Class A/B | A/B | No target recall — same-turn echo = single principal | Require target name from memory in a fresh turn |
| Agent prints target name in the same turn as the Class A prompt | A | The user echoes the agent's own text; confirms nothing | Print prompt without the target; wait for next turn |
| Agent retries after refusal | A/B | Persistence pressure | Accept refusal, report, stop |
| Agent skips Class C checkpoint because "user said go ahead earlier in the session" | C | Prior session context is not per-action authorisation | Each Class C action requires its own explicit verb |
| Agent silently does 7 Class D ops when user said "tidy these up" | D | Scope expanded without bounded-confirm | Emit bounded-confirm for ≥ 3 Class D ops |
| Agent classifies PR merge as Class D | C | Merge is cross-boundary visible | Reclassify as C; require explicit verb |

---

## Worked Example

### Wrong — auto-merge on "ship it"

```
User:  "ship it"
Agent: [calls gh pr merge --squash --delete-branch]
       → Merged. Branch deleted.
```

Problem: "ship it" is ambiguous. The agent treated it as Class C authorisation without an explicit verb.

### Right — PR open + wait

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

### Wrong — scope expansion without bounded-confirm

```
User:  "tidy these up"
Agent: [silently creates 7 PRs across 4 worktrees, closes 3 issues]
       → Done.
```

Problem: scope expanded beyond the implicit authorisation. Class D but at large scale without bounded-confirm.

### Right — bounded-confirm before scale

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

---

## Related

- [`destructive-ops-guard`](destructive-ops-guard.md) — Part 3 contains the original 3-class taxonomy (A/B/C destructive ops); this rule generalises it to 5 classes and extends to ALL decision types. The A/B/C classes here are backward-compatible with Part 3.
- [`pr-shipping-discipline`](pr-shipping-discipline.md) — "ship it" = Class D (open PR); "merge it" = Class C (explicit verb). Taxonomic home for that rule's core principle.
- [`permission-discipline`](permission-discipline.md) — MCP tool classification (read/write/destructive) maps to E/D/A-C respectively.
- [`auto-delegation`](auto-delegation.md) — Class D detection hooks into decomposition decisions; bounded-confirm fires when planned Class D scope exceeds explicit authorisation.
- `agent-identity-and-task-scopes` (#476) — parallel rule; task scope limits what Class D ops an agent may initiate without re-checking.
- Hook: `~/.claude/hooks/destructive_api_guard.sh` — enforces Class A/B at the Bash level.
- [#477](https://github.com/JohnGavin/llm/issues/477) — origin issue.
- [#450](https://github.com/JohnGavin/llm/issues/450) — parent design tracker (Salesforce Principle 5).
