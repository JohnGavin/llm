---
description: 5-class decision taxonomy — Classes A/B/C stop for the human; D/E proceed automatically
---

# Rule: Human-in-the-Loop Decision Points (Mandatory)

## Origin

[#477](https://github.com/JohnGavin/llm/issues/477) — accepted from [#450](https://github.com/JohnGavin/llm/issues/450), Salesforce 8 Design Principles gap analysis, Principle 5 (Design for strategic human intervention and oversight).

Generalises the 3-class op taxonomy in `destructive-ops-guard` Part 3 to a project-wide 5-class decision taxonomy covering ALL human-in-the-loop checkpoints — not just destructive operations.

## When This Applies

Any orchestrator or agent decision that has one or more of:

- An **irreversible effect** — data destruction, production mutation, force-push
- A **cross-boundary effect** — PR merge, issue close, email send, gh comment visible externally
- A **scope-expanding effect** — action set larger than explicitly authorised ("tidy these up" ≠ "create 7 PRs across 4 worktrees")
- An **audit-trail-relevant effect** — anything a reviewer might ask "who decided that, and why?"

Purely local, read-only, or sandboxed operations (file reads, grep, query) do not require HITL.

## CRITICAL: Automation Runs by Default; HITL Is the Override

Automation is not wrong. The failure mode is automation that runs **past the boundary** of what the human authorised. The taxonomy below names the boundary for each class and requires the appropriate checkpoint before crossing it.

> If a decision touches Classes A, B, or C: **STOP and wait** for the human before executing.
> If the decision is Class D or E: **proceed** — no confirmation needed.

## The 5-Class Decision Taxonomy

| Class | Name | Examples | Checkpoint required |
|---|---|---|---|
| **A** | Catastrophic / irreversible | `DROP TABLE prod`; delete repo; force-push to main; revert a merged PR; rotate production credentials; destroy a volume | Out-of-band ack AND target name supplied from memory (agent must NOT print the target name in the same turn as the prompt) |
| **B** | Destructive / recoverable | `rm -rf` >100 MB; `git reset --hard`; force-push feature branch; bulk delete issues; revert uncommitted changes across multiple files | Target name included in the user's confirmation phrase |
| **C** | **Publish gate** (cross-boundary visible) | PR merge; issue close; email send; `gh comment` posted externally; Slack/webhook notification; public release tag | Explicit action verb in user reply: "merge", "send", "close", "release" — NOT just "yes" or "go ahead". PR merge specifically may move to Class D under the **Auto-Merge Policy** toggle — see below |
| **D** | Scoped commit / local write | `gh pr create`; branch push (own branch); file Edit/Write in worktree; commit to feature branch; open PR (not merge) | No confirmation — proceed automatically |
| **E** | Read-only / advisory | `gh issue list`; grep; SQL query; `git log`; `tar_read()`; file Read; test run (no side effects) | No confirmation — proceed silently |

Class D is the key innovation over `destructive-ops-guard` Part 3: it explicitly names the boundary where automation is the CORRECT default. Opening a PR is Class D, merging it is Class C.

> **Working name — "publish gate".** Prefer the plain-language name **"publish gate"** over the jargon label "Class C" when talking to the user or in tooling: a publish-gate action *publishes a change beyond the sandbox into a shared/visible place* (merge to main, close an issue, post an external comment, cut a release) and so requires an explicit action verb, never a bare "yes". "Class C" remains the formal taxonomy label; "publish gate" is its user-facing synonym.

## Application Across Tool Surfaces

| Tool surface | Class A/B (STOP) | Class C (stop + verb) | Class D (proceed) | Class E (silent) |
|---|---|---|---|---|
| **Bash** | `rm -rf`, `git reset --hard`, credential commands | `gh pr merge`, `gh release create` | `git commit`, `git push` own branch | `git log`, `grep`, query |
| **gh CLI** | `gh repo delete`, force-push main | `gh pr merge`, `gh issue close`, `gh issue comment` (external) | `gh pr create`, `gh pr view` | `gh issue list`, `gh pr list` |
| **Edit / Write** | Overwrite tracked file outside worktree | Batch rename across ≥ 3 repos | Edit/Write in own worktree | Read |
| **Agent dispatch** | Agent deleting data or force-pushing main | Agent merging PRs or closing issues | Agent creating PRs, committing, pushing own branch | Agent reading, grepping, running read-only checks |
| **MCP tool** | Destructive write (classified `destructive`) | External publish (`write` tier) | Local write (`write` tier, sandboxed) | Read-only (`read` tier) |

## The Default-PR-Not-Merge Principle

`pr-shipping-discipline` establishes that "ship it" means **open a PR**, not merge. This rule provides the taxonomic reason: **PR open is Class D** (scoped, reversible, local to the PR surface) while **PR merge is Class C** (cross-boundary visible, explicit verb required).

Any ambiguous phrasing — "ship it", "land this", "let's push" — resolves to Class D (open PR) unless the user supplies an explicit Class C verb ("merge", "merge to main", "land directly").

See `pr-shipping-discipline` for the full verb decision table.

## Conditional Auto-Merge (Auto-Merge Policy)

PR merge is Class C by default (explicit verb required, every time). A
**global toggle** in `~/.claude/CLAUDE.md` — `**Auto-Merge Policy:** ON` /
`OFF` — lets the user opt merges into Class D (proceed automatically)
*without restating it per session or per PR*. The toggle applies to every
project, not just this one — that is the point: a per-session verbal grant
("merge anything clean this session") does not scale for a prolific solo
maintainer and has to be re-typed every time.

**When the toggle is ON**, a PR merges without asking IFF **all** of:

1. Every CI check reports success — not pending, not skipped, not
   inconclusive.
2. The merge-gate / roborev consistency check reports a genuine PASS —
   **never** an indeterminate result (exit code 3, per
   `checks-must-distinguish-unknown`) treated as a pass. An indeterminate
   gate always falls back to Class C (ask), regardless of the toggle — a
   gate that cannot tell you whether it checked anything is not evidence of
   safety.
3. The PR's diff touches **none** of the Auto-Merge Exclusion List paths
   below.

**When the toggle is OFF** (the historical default), every merge stays Class
C exactly as documented above — nothing else in this rule changes.

This is advisory, not hook-enforced: no technical mechanism currently blocks
a merge call the way `agent_push_guard.sh` blocks a worktree-agent push to
`main`. The policy trades a firm technical backstop for zero session-to-session
friction — a deliberate choice, made explicitly rather than by default (see
Origin below). It depends entirely on this rule being read and followed, the
same as every other advisory rule in this corpus; a GitHub branch-protection
review requirement was considered and explicitly declined as an enforcement
mechanism because it reintroduces the same manual click-through friction the
toggle exists to remove.

### Auto-Merge Exclusion List (always Class C, regardless of the toggle)

| Path / change class | Why excluded |
|---|---|
| `.claude/hooks/**` | Controls what every future action is allowed to do — the trust boundary itself |
| `.claude/rules/**` (especially mandatory / safety-critical rules) | Same reasoning as hooks — this is the policy layer, including the auto-merge policy defined in this very section |
| `.claude/scripts/**` that handle credentials, secrets, or destructive operations | Direct incident history: the 2026-08-11 credential leak and the phone-number leak both originated in script-level handling |
| `default.nix`, `default.R`, `.claude/settings.json` | Environment/permission configuration — a bad merge here can silently change what every subsequent session is allowed to do |
| Any diff touching a credential/secret file, `.Renviron`, `secrets.env`, or a rotation script | `credential-management` / `secrets-single-source` safety-critical surface |
| DB schema / migration files (`*_schema.sql`, `*_schema_apply.sh`) | Effectively irreversible once other writers depend on the new shape |
| Content published to a live, public-facing surface (rendered GH Pages HTML source, public dashboard export scripts) | Public blast radius — see `public-private-repo-boundary` |

A PR touching **any** excluded path reverts to standard Class C — the toggle
does not override this list under any circumstance, and repo visibility
(public vs. private) is deliberately NOT a criterion here: a private repo is
not automatically low-stakes (it typically holds more sensitive content, not
less), so exclusion is based on change class, never on repo visibility alone.

### Origin

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

## Forbidden Patterns

| Pattern | Class violated | Why wrong | Fix |
|---|---|---|---|
| Agent auto-merges after "ship it" | C | "ship it" is ambiguous shorthand | Default to PR open (Class D); wait for "merge" |
| Agent accepts "yes" for Class A/B | A/B | No target recall — same-turn echo = single principal | Require target name from memory in a fresh turn |
| Agent prints target name in the same turn as the Class A prompt | A | The user echoes the agent's own text; confirms nothing | Print prompt without the target; wait for next turn |
| Agent retries after refusal | A/B | Persistence pressure | Accept refusal, report, stop |
| Agent skips Class C checkpoint because "user said go ahead earlier in the session" | C | Prior session context is not per-action authorisation | Each Class C action requires its own explicit verb |
| Agent silently does 7 Class D ops when user said "tidy these up" | D | Scope expanded without bounded-confirm | Emit bounded-confirm for ≥ 3 Class D ops |
| Agent classifies PR merge as Class D | C | Merge is cross-boundary visible | Reclassify as C; require explicit verb, unless the Auto-Merge Policy conditions are genuinely met |
| Auto-Merge Policy is ON but the merge-gate returned indeterminate (exit 3), and the agent treats that as a pass | C | An unverifiable gate is not evidence of safety — `checks-must-distinguish-unknown` | Fall back to Class C (ask) whenever the gate result is anything other than a genuine pass |
| Auto-Merge Policy is ON and the agent merges a PR touching an excluded path (hooks/rules/scripts/schema/credentials/public surface) | C | The exclusion list is absolute — the toggle never overrides it | Reclassify as C; require explicit verb |

## Worked Example

See [`_companions/human-in-the-loop-decision-points-details.md`](_companions/human-in-the-loop-decision-points-details.md)
for the full worked examples (wrong/right auto-merge, wrong/right scope
expansion). The normative rule above is complete without it.

## Related

- [`destructive-ops-guard`](destructive-ops-guard.md) — Part 3 contains the original 3-class taxonomy (A/B/C destructive ops); this rule generalises it to 5 classes and extends to ALL decision types. The A/B/C classes here are backward-compatible with Part 3.
- [`pr-shipping-discipline`](pr-shipping-discipline.md) — "ship it" = Class D (open PR); "merge it" = Class C (explicit verb). Taxonomic home for that rule's core principle.
- [`permission-discipline`](permission-discipline.md) — MCP tool classification (read/write/destructive) maps to E/D/A-C respectively.
- [`auto-delegation`](auto-delegation.md) — Class D detection hooks into decomposition decisions; bounded-confirm fires when planned Class D scope exceeds explicit authorisation.
- `agent-identity-and-task-scopes` (#476) — parallel rule; task scope limits what Class D ops an agent may initiate without re-checking.
- Hook: `~/.claude/hooks/destructive_api_guard.sh` — enforces Class A/B at the Bash level.
- [#477](https://github.com/JohnGavin/llm/issues/477) — origin issue.
- [#450](https://github.com/JohnGavin/llm/issues/450) — parent design tracker (Salesforce Principle 5).
- `checks-must-distinguish-unknown` — the "indeterminate ≠ pass" requirement the Auto-Merge Policy's second condition depends on.
- `~/.claude/CLAUDE.md` — Core Rules carries the actual `**Auto-Merge Policy:**` toggle line; this file is the mechanism it activates.
