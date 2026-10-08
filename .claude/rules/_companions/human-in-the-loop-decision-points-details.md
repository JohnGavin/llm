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

This file (`_companions/human-in-the-loop-decision-points-details.md`) holds
the full worked examples (wrong/right auto-merge, wrong/right scope
expansion). The normative rule in the parent is complete without it.

- [#477](https://github.com/JohnGavin/llm/issues/477) — origin issue.
- [#450](https://github.com/JohnGavin/llm/issues/450) — parent design tracker (Salesforce Principle 5).


## Moved from the `human-in-the-loop-decision-points` rule body (2026-10-03, always-loaded baseline trim)

Verbatim text removed from the rule body to cut the always-loaded instruction baseline. The normative requirement is restated in the rule; this is the supporting detail.

### Origin (#477 / #450)

## Origin

[#477](https://github.com/JohnGavin/llm/issues/477) — accepted from [#450](https://github.com/JohnGavin/llm/issues/450), Salesforce 8 Design Principles gap analysis, Principle 5 (Design for strategic human intervention and oversight).

Generalises the 3-class op taxonomy in `destructive-ops-guard` Part 3 to a project-wide 5-class decision taxonomy covering ALL human-in-the-loop checkpoints — not just destructive operations.


### Application Across Tool Surfaces table and Default-PR-Not-Merge Principle

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


### Auto-merge: advisory, not hook-enforced (rationale)

This is advisory, not hook-enforced: no mechanism blocks a merge call the way `agent_push_guard.sh` blocks a worktree-agent push to `main`. The policy trades a firm technical backstop for zero session-to-session friction, a deliberate choice; a GitHub branch-protection review requirement was declined because it reintroduces the click-through friction the toggle exists to remove.

### Auto-Merge Exclusion List: original 'Why excluded' column

| Path / change class | Why excluded |
|---|---|
| `.claude/hooks/**` | Controls what every future action is allowed to do — the trust boundary itself |
| `.claude/rules/**` (especially mandatory / safety-critical rules) | Same reasoning as hooks — this is the policy layer, including the auto-merge policy defined in this very section |
| `.claude/scripts/**` that handle credentials, secrets, or destructive operations | Direct incident history: the 2026-08-11 credential leak and the phone-number leak both originated in script-level handling |
| Scripts that change state on their own schedule — anything that closes, reopens, deletes, reaps, garbage-collects or (re)loads things (e.g. `roborev_*autoclose*`, `roborev_auto_close.sh`, `roborev_revalidate.R`, reapers, `worktree_gc.sh`, `branch_gc.sh`), their `bin/launchd-recorders/*` wrappers, and `.claude/launchd/**` | A merged change goes live within hours via launchd with no human in the loop. On 2026-09-27 a paused auto-closer was reloaded by an unidentified mechanism and closed 117 reviews (#1274) |
| `default.nix`, `default.R`, `.claude/settings.json` | Environment/permission configuration — a bad merge here can silently change what every subsequent session is allowed to do |
| `AGENTS.md` (which `~/.claude/CLAUDE.md` symlinks to) and any project's `CLAUDE.md` | Holds the Auto-Merge Policy toggle and a copy of this exclusion list; if it could auto-merge, a green PR could switch the toggle or narrow this list with no human "merge" (review 10610, #1285) |
| Any diff touching a credential/secret file, `.Renviron`, `secrets.env`, or a rotation script | `credential-management` / `secrets-single-source` safety-critical surface |
| DB schema / migration files (`*_schema.sql`, `*_schema_apply.sh`) | Effectively irreversible once other writers depend on the new shape |
| Content published to a live, public-facing surface (rendered GH Pages HTML source, public dashboard export scripts) | Public blast radius — see `public-private-repo-boundary` |

### Auto-Merge Origin

### Origin

User request 2026-08-28: repeated manual "merge" confirmations were the higher-friction cost for a prolific solo maintainer, and a session-scoped verbal grant still had to be restated every session, so the toggle is global. Full auto-merge on green gates alone was rejected because this repo's incident history shows automated checks passing when they should not have; the exclusion list targets the paths where those incidents occurred. Full rationale (incidents #923/#927/#904/#928): companion doc.


### Related (full annotated list)

## Related

- [`destructive-ops-guard`](../destructive-ops-guard.md) — Part 3 contains the original 3-class taxonomy (A/B/C destructive ops); this rule generalises it to 5 classes and extends to ALL decision types. The A/B/C classes here are backward-compatible with Part 3.
- [`pr-shipping-discipline`](../pr-shipping-discipline.md) — "ship it" = Class D (open PR); "merge it" = Class C (explicit verb). Taxonomic home for that rule's core principle.
- [`permission-discipline`](../permission-discipline.md) — MCP tool classification (read/write/destructive) maps to E/D/A-C respectively.
- [`auto-delegation`](../auto-delegation.md) — Class D detection hooks into decomposition decisions; bounded-confirm fires when planned Class D scope exceeds explicit authorisation.
- `agent-identity-and-task-scopes` (#476) — parallel rule; task scope limits what Class D ops an agent may initiate without re-checking.
- Hook: `~/.claude/hooks/destructive_api_guard.sh` — enforces Class A/B at the Bash level.
- [#477](https://github.com/JohnGavin/llm/issues/477) — origin issue; [#450](https://github.com/JohnGavin/llm/issues/450) — parent design tracker (Salesforce Principle 5).
- `checks-must-distinguish-unknown` — the "indeterminate ≠ pass" requirement the Auto-Merge Policy's second condition depends on.
- `~/.claude/CLAUDE.md` — Core Rules carries the actual `**Auto-Merge Policy:**` toggle line; this file is the mechanism it activates.


## Moved from the `human-in-the-loop-decision-points` rule body (2026-10-03, always-loaded baseline trim)

Verbatim text removed from the rule body to cut the always-loaded instruction baseline. The normative requirement is restated in the rule; this is the supporting detail.

### Class D framing and 'publish gate' working-name note (full text)

Class D is the key innovation over `destructive-ops-guard` Part 3: it explicitly names the boundary where automation is the CORRECT default. Opening a PR is Class D, merging it is Class C.

> **Working name — "publish gate".** Prefer the plain-language name **"publish gate"** over the jargon label "Class C" when talking to the user or in tooling: a publish-gate action *publishes a change beyond the sandbox into a shared/visible place* (merge to main, close an issue, post an external comment, cut a release) and so requires an explicit action verb, never a bare "yes". "Class C" remains the formal taxonomy label; "publish gate" is its user-facing synonym.

### Per-surface pointer and Default-PR-Not-Merge paragraph (as shortened in pass 1)

Class by tool surface: the A-E examples above apply to every surface (Bash, gh CLI, Edit/Write, Agent dispatch, MCP tool); the per-surface table is in the companion doc.

**Default-PR-not-merge:** PR open is Class D; PR merge is Class C. Ambiguous phrasing ("ship it", "land this", "let's push") resolves to Class D (open PR) unless the user supplies an explicit Class C verb ("merge", "merge to main", "land directly"). Verb table: `pr-shipping-discipline`.
## Conditional Auto-Merge (Auto-Merge Policy)

### Auto-Merge origin pointer / Class D heading (re-stitched)

Origin and full rationale (user request 2026-08-28; incidents #923/#927/#904/#928): companion doc.
## Class D Bounded-Confirm Pattern (New)

### Bounded-confirm example (pass 1 wording)

**Pattern:**

Example: "I'll do these Class D actions: 1. Edit R/foo.R (add NA check) 2. Edit tests/test-foo.R (matching test) 3. git commit + push to feat/fix-foo. Confirm? (or say 'stop' to cancel)" Verbatim block: companion doc.

### Forbidden Patterns: original 4-column table (with 'Why wrong')

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

### Worked Example pointer

## Worked Example

This file (`_companions/human-in-the-loop-decision-points-details.md`) holds the full worked examples (wrong/right auto-merge, wrong/right scope expansion) and the full Auto-Merge origin rationale. The normative rule in the parent is complete without it.



## Moved from the `human-in-the-loop-decision-points` rule body (2026-10-03, always-loaded baseline trim)

Verbatim text removed from the rule body to cut the always-loaded instruction baseline. The normative requirement is restated in the rule; this is the supporting detail.

### Exclusion List table as shortened in pass 1 (path | reason)

| Path / change class | Why excluded |
|---|---|
| `.claude/hooks/**` | The trust boundary itself |
| `.claude/rules/**` (especially mandatory / safety-critical rules) | The policy layer, including this auto-merge policy |
| `.claude/scripts/**` that handle credentials, secrets, or destructive operations | Script-level handling caused the 2026-08-11 credential leak and the phone-number leak |
| Scripts that change state on their own schedule — anything that closes, reopens, deletes, reaps, garbage-collects or (re)loads things (e.g. `roborev_*autoclose*`, `roborev_auto_close.sh`, `roborev_revalidate.R`, reapers, `worktree_gc.sh`, `branch_gc.sh`), their `bin/launchd-recorders/*` wrappers, and `.claude/launchd/**` | Goes live within hours via launchd with no human in the loop (#1274: a reloaded auto-closer closed 117 reviews on 2026-09-27) |
| `default.nix`, `default.R`, `.claude/settings.json` | Environment/permission configuration |
| `AGENTS.md` (which `~/.claude/CLAUDE.md` symlinks to) and any project's `CLAUDE.md` | Holds the toggle and a copy of this list (review 10610, #1285) |
| Any diff touching a credential/secret file, `.Renviron`, `secrets.env`, or a rotation script | `credential-management` / `secrets-single-source` safety-critical surface |
| DB schema / migration files (`*_schema.sql`, `*_schema_apply.sh`) | Effectively irreversible once other writers depend on the new shape |
| Content published to a live, public-facing surface (rendered GH Pages HTML source, public dashboard export scripts) | Public blast radius — `public-private-repo-boundary` |
