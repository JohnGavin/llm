---
description: 5-class decision taxonomy — Classes A/B/C stop for the human; D/E proceed automatically
---

# Rule: Human-in-the-Loop Decision Points (Mandatory)

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

Class D names the boundary where automation is the CORRECT default: opening a PR is Class D, merging it is Class C. Prefer the plain name **"publish gate"** for Class C when talking to the user: it *publishes a change beyond the sandbox into a shared/visible place* and so requires an explicit action verb, never a bare "yes".

**Default-PR-not-merge:** PR open is Class D; PR merge is Class C. Ambiguous phrasing ("ship it", "land this", "let's push") resolves to Class D (open PR) unless the user supplies an explicit Class C verb ("merge", "merge to main", "land directly"); verb table in `pr-shipping-discipline`. The A-E examples apply to every tool surface (Bash, gh CLI, Edit/Write, Agent dispatch, MCP tool; per-surface table in the companion doc).

## Conditional Auto-Merge (Auto-Merge Policy)

PR merge is Class C by default (explicit verb, every time). A **global toggle** in `~/.claude/CLAUDE.md` (`**Auto-Merge Policy:** ON` / `OFF`) lets the user opt merges into Class D (proceed automatically) without restating it per session or per PR; it applies to every project.

**When the toggle is ON**, a PR merges without asking IFF **all** of:

1. Every CI check reports success — not pending, not skipped, not
   inconclusive. If CI is unavailable (banner `ci:UNAVAILABLE`/`ci:unknown`), this condition cannot be met: merge stays Class C, and the PR body lists the local stand-in gates run and their results — see [`_companions/ci-outage-local-gates.md`](_companions/ci-outage-local-gates.md).
2. The merge-gate / roborev consistency check reports a genuine PASS, **never** an indeterminate result (exit code 3, per `checks-must-distinguish-unknown`) treated as a pass. An indeterminate gate always falls back to Class C (ask), regardless of the toggle. That includes a gate that has not yet seen a completed review for every commit in the PR: a missing or still-running review is not a clean one (#1274).
3. The PR's diff touches **none** of the Auto-Merge Exclusion List paths
   below.

**When the toggle is OFF** (the historical default), every merge stays Class
C exactly as documented above — nothing else in this rule changes.

**Label every auto-merge.** A PR merged under this policy (no explicit "merge" verb in the user's own words) gets the `auto-merged` label at merge time: `gh pr edit <n> --add-label auto-merged`, then `gh pr merge`. A merge the user asked for by name gets no label. GitHub records every merge as the owner, so without the label an automatic merge cannot be told from an instructed one afterwards, and the #1274 audit cannot be done.

This is advisory, not hook-enforced (no mechanism blocks a merge call); the rationale is in the companion doc.

### Auto-Merge Exclusion List (always Class C, regardless of the toggle)

Paths (reasons in the companion doc):

- `.claude/hooks/**`; `.claude/rules/**`
- `.claude/scripts/**` that handle credentials, secrets, or destructive operations
- Scripts that change state on their own schedule — anything that closes, reopens, deletes, reaps, garbage-collects or (re)loads things (e.g. `roborev_*autoclose*`, `roborev_auto_close.sh`, `roborev_revalidate.R`, reapers, `worktree_gc.sh`, `branch_gc.sh`), their `bin/launchd-recorders/*` wrappers, and `.claude/launchd/**` (they go live via launchd with no human in the loop, #1274)
- `default.nix`, `default.R`, `.claude/settings.json`
- `AGENTS.md` (which `~/.claude/CLAUDE.md` symlinks to) and any project's `CLAUDE.md` (they hold the toggle and a copy of this list, #1285)
- Any diff touching a credential/secret file, `.Renviron`, `secrets.env`, or a rotation script
- DB schema / migration files (`*_schema.sql`, `*_schema_apply.sh`)
- Content published to a live, public-facing surface (rendered GH Pages HTML source, public dashboard export scripts)

A PR touching **any** excluded path reverts to standard Class C; the toggle never overrides this list. Repo visibility (public vs. private) is deliberately NOT a criterion: exclusion is based on change class, never visibility alone.

Origin and full rationale (user request 2026-08-28; incidents #923/#927/#904/#928): companion doc.

## Class D Bounded-Confirm Pattern

Class D does NOT require confirmation — but when the scope of a Class D action is **larger than what was explicitly authorised**, the agent MUST bound it before executing.

**When to bound:** the agent plans to take ≥ 3 Class D actions OR touches files outside the explicitly named scope.

**Pattern:** declare the scope before executing, e.g. "I'll do these Class D actions: 1. Edit R/foo.R 2. Edit tests/test-foo.R 3. commit + push to feat/fix-foo. Confirm? (or say 'stop')". Verbatim block: companion doc.

The bounded-confirm is NOT a confirmation prompt for individual Class D ops. It is a **scope declaration** so the human can redirect before the work begins.

## Forbidden Patterns

| Pattern | Class | Fix |
|---|---|---|
| Agent auto-merges after "ship it" | C | Default to PR open (Class D); wait for "merge" |
| Agent accepts "yes" for Class A/B | A/B | Require the target name from memory in a fresh turn (same-turn echo = single principal) |
| Agent prints the target name in the same turn as the Class A prompt | A | Print the prompt without the target; wait for the next turn |
| Agent retries after refusal | A/B | Accept refusal, report, stop |
| Agent skips a Class C checkpoint because "user said go ahead earlier" | C | Each Class C action requires its own explicit verb |
| Agent silently does 7 Class D ops when told "tidy these up" | D | Emit bounded-confirm for ≥ 3 Class D ops |
| Agent classifies PR merge as Class D | C | Reclassify as C unless the Auto-Merge Policy conditions are genuinely met |
| Auto-Merge ON, merge-gate returned indeterminate (exit 3), agent treats it as a pass | C | Fall back to Class C (ask) unless the gate is a genuine pass (`checks-must-distinguish-unknown`) |
| Auto-Merge ON and the agent merges a PR touching an excluded path | C | The exclusion list is absolute: reclassify as C, require explicit verb |

## Related

- `destructive-ops-guard` Part 3 (original A/B/C taxonomy); `pr-shipping-discipline` (verb table); `permission-discipline` (MCP tiers map to E/D/A-C); `auto-delegation` (bounded-confirm fires when planned Class D scope exceeds authorisation); `agent-identity-and-task-scopes` (#476); `checks-must-distinguish-unknown` (indeterminate is not a pass).
- Hook: `~/.claude/hooks/destructive_api_guard.sh` enforces Class A/B at the Bash level.
- Worked examples (wrong/right auto-merge, wrong/right scope expansion) and Auto-Merge origin rationale: [`_companions/human-in-the-loop-decision-points-details.md`](_companions/human-in-the-loop-decision-points-details.md); the normative rule above is complete without it.
- `~/.claude/CLAUDE.md` carries the actual `**Auto-Merge Policy:**` toggle line.
- Origin: [#477](https://github.com/JohnGavin/llm/issues/477), accepted from [#450](https://github.com/JohnGavin/llm/issues/450) (Salesforce Principle 5).
