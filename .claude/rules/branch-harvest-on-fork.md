---
description: Session-start audit of unmerged feat branches — triage harvest/archive/discard before new work begins
paths:
  - ".claude/scripts/branch_harvest*"
  - ".claude/hooks/session_init*"
---

# Rule: Branch Harvest on Fork (Mandatory, All Projects)

## When This Applies

Every session start in every project that has unmerged feature branches.
The audit runs in Phase 7g of `session_init.sh` and is silent unless it
finds something. When it finds something, EVERY entry MUST be triaged
before any new work begins on user-facing surfaces.

## Source

JohnGavin/premortem session 30, 2026-06-02, Lessons learnt L-4. See the
companion doc for the full stranded-branch incident narrative.

## CRITICAL: Silence Is What Caused L-4

If the audit finds an unmerged feat branch that touches a user-facing
surface AND is older than 3 days, doing nothing about it is the FAILURE
MODE. The audit is advisory, not informational — every flagged branch
requires a triage decision in this session.

## The Discipline (4 steps)

### Step 1 — Audit runs at session start

`session_init.sh` Phase 7g calls `~/.claude/scripts/branch_harvest_audit.sh`,
which resolves the upstream default branch, lists unmerged `feat/cc-*`
branches, reads each one's recent commits and tip date, sets flags from the
patterns table below, and emits one block per FLAGGED branch (silent if
none). The full 4-substep breakdown is in the companion doc.

### Step 2 — Flag patterns

| Flag | Trigger |
|---|---|
| `SESSION_INTERRUPTED` | Any commit subject in last 5 matches `(session-limit-interrupted\|^WIP:\|\(WIP\))` |
| `SURFACE_TOUCHED` | Any commit subject in last 5 matches the surface keyword regex (see below) |
| `STALE` | Branch tip date is older than 3 days from now |

A branch is REPORTED if it has `SESSION_INTERRUPTED` OR
(`SURFACE_TOUCHED` AND `STALE`).

`SURFACE_KEYWORDS` (default, case-insensitive regex):
```
dashboard|vignette|readme|\.qmd|\.css|\.scss|model/|R/|app/|plumber|shiny|figure|chart|plot|table|caption|font|render|website|docs/
```

Projects MAY extend this via a `branch-harvest-keywords:` line in their
project-level `.claude/CLAUDE.md`. The extension is OR-joined with the
default; never replaces it.

### Step 3 — Output format

For each FLAGGED branch (silent if none), the audit emits a block ending in
a call-to-action line. Sessions MUST pick one of the three outcomes per
flagged branch BEFORE starting work on a flagged surface. A worked output
example is in the companion doc.

### Step 4 — Triage outcomes (mandatory choice)

For every flagged branch, pick ONE outcome:

| Outcome | When | Action |
|---|---|---|
| **Harvest** | The branch contains improvements relevant to current work | Cherry-pick or re-implement BEFORE the new work begins; commit to the current branch and reference the source SHA in the message |
| **Archive** | Improvements are real but out of scope for this session | File a project issue naming the branch + commits + surfaces; add a git note (see below) so the audit stops flagging it |
| **Discard** | Branch is a dead end (rejected approach, superseded) | `git branch -D <branch>` (after confirming the user has authorised the destruction) |

Doing nothing is forbidden — silence is the failure mode that caused L-4.

### Per-branch silence (git notes)

To permanently silence the audit for a known-archived branch, add a
`git notes --ref=harvest` note to the branch tip SHA. A worked command is in
the companion doc.

The audit reads `git notes --ref=harvest show <sha>` for each flagged
branch's tip and skips any branch with a note whose body starts with
`archived ` or `harvested `.

## Configuration

### Project-level override (per-project `.claude/CLAUDE.md`)

Single line in the project's `.claude/CLAUDE.md`:

```
branch-harvest: enforce        # block edits to surface files until triaged (advisory by default)
branch-harvest-keywords: …     # extra regex OR-joined with defaults (optional)
branch-harvest-skip: regex     # ignore branch names matching this regex (optional)
```

### Session-level skip

```bash
CLAUDE_BRANCH_HARVEST=0 claude
```

Skips Phase 7g entirely for this session. Use only when investigating
something unrelated where the audit noise is a distraction. Logged.

## Scope

- **Own project repo only.** Cross-project sessions (llm authority) do NOT
  audit other repos at session start; run `/branch-harvest <repo>`
  manually for cross-repo audits. Rationale: noise at every session start
  for the meta-config session would dwarf actionable signal.
- **Feature branches only.** The audit looks for `feat/cc-*` and
  `feat/*` names. Branches named `wip/`, `experiment/`, `spike/` are
  intentionally ignored (they are self-flagged as throwaway).
- **Worktree branches excluded.** Names matching
  `^worktree-agent-` are skipped — these are harness-managed and
  auto-cleaned by Phase 7f.

## Anti-Patterns

| Pattern | Why wrong | Fix |
|---|---|---|
| Forking a new worktree without checking `git branch --no-merged main` | Strands prior work; the failure mode that caused L-4 | Phase 7g runs the check automatically |
| Acknowledging the audit then starting unrelated work without triage | Silence is the failure mode | Triage every flagged branch first |
| Deleting a flagged branch without user confirmation | Destructive without authorisation | `git branch -D` requires user OK; document in audit log |
| Auto-cherry-picking from a flagged branch | Cherry-pick may not match the new session's scope | Always re-implement OR ask user to confirm cherry-pick |
| Skipping the audit because "this session is short" | The next session inherits the same orphan | Run it; cost is < 1 s |

## Verification

Selftest + a 4-step manual verification checklist are in the companion doc.

## Related

- [`_companions/branch-harvest-on-fork-details.md`](_companions/branch-harvest-on-fork-details.md) — incident narrative and worked examples split out of this rule
- `cross-cutting-rename` — the SECOND ask of the same rename was a
  symptom of stranded improvements; harvest catches them earlier
- `branch-salvage-workflow` — what to do AFTER you've decided to look at
  a stale branch; harvest is the BEFORE check
- `worktree-location` — where new worktrees live; the audit runs in the
  current worktree's repo
- `auto-delegation` — agent dispatches in worktrees; the harvest output
  informs which branches a subagent should NOT re-create work on
- premortem `knowledge_base/lessons_learnt.md` L-4 — origin case
- premortem issue 0021 — reference implementation
