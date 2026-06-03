# Rule: Branch Harvest on Fork (Mandatory, All Projects)

## When This Applies

Every session start in every project that has unmerged feature branches.
The audit runs in Phase 7g of `session_init.sh` and is silent unless it
finds something. When it finds something, EVERY entry MUST be triaged
before any new work begins on user-facing surfaces.

## Source

JohnGavin/premortem session 30, 2026-06-02. Lessons learnt L-4 (stranded-
branch harvesting): a previous session made substantive UI improvements on
`feat/cc-20260531-185103` (donut → DT table, bar → Cleveland dot plot, 13
inline `tt()` popups with embedded `<a href>` to GOV.UK + source code,
per-cell drilldown links). Several commits on that branch were tagged
"(session-limit-interrupted)". The branch was never merged to `main`. When
this session forked a new worktree from `main`, it inherited the OLD layout
and the user saw the regression as "you reverted my changes". Three full
re-do sessions followed before the discipline was added.

## CRITICAL: Silence Is What Caused L-4

If the audit finds an unmerged feat branch that touches a user-facing
surface AND is older than 3 days, doing nothing about it is the FAILURE
MODE. The audit is advisory, not informational — every flagged branch
requires a triage decision in this session.

## The Discipline (4 steps)

### Step 1 — Audit runs at session start

`session_init.sh` Phase 7g calls
`~/.claude/scripts/branch_harvest_audit.sh`. The audit:

1. Resolves the upstream default branch:
   `git rev-parse --abbrev-ref origin/HEAD 2>/dev/null` →
   falls back to `main` if the symbolic-ref is unset.
2. Lists `git branch --no-merged <upstream-default>` for each name that
   matches `^[[:space:]]*feat/cc-`.
3. For each unmerged branch:
   - Reads the last 5 commit subjects via
     `git log -5 --format="%h %s" <branch>`.
   - Reads the tip date via `git log -1 --format=%cI <branch>`.
   - Sets flags from the patterns table below.
4. Emits one block per FLAGGED branch (silent if none).

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

Projects MAY extend this via a single line in their project-level
`.claude/CLAUDE.md`:
```
branch-harvest-keywords: vetiver|plumber2|mlops|mycare-letters
```
The extension is OR-joined with the default; never replaces it.

### Step 3 — Output format

For each FLAGGED branch (silent if none):

```
branch-harvest: 2 unmerged feat branches flagged
  feat/cc-20260531-185103 (12d stale) [SURFACE_TOUCHED, SESSION_INTERRUPTED]
    c389d1d  fix(dashboard): re-add mermaid-header.html CDN loader
    f0372c8  WIP: agent V UI overhaul (session-limit-interrupted)
    7db8be3  WIP: agent M server-side mermaid (session-limit-interrupted)
  feat/cc-20260530-201802 (3d stale) [SURFACE_TOUCHED]
    fe5c1d4  fix(model): v4.6 — charity-metric bug fix + SIPP-growth sensitivity
→ Triage: harvest | archive | discard.
  See branch-harvest-on-fork rule. Log: ~/.claude/logs/branch_harvest.log
```

The last line is the call-to-action. Sessions MUST pick one of the three
outcomes per flagged branch BEFORE starting work on a flagged surface.

### Step 4 — Triage outcomes (mandatory choice)

For every flagged branch, pick ONE outcome:

| Outcome | When | Action |
|---|---|---|
| **Harvest** | The branch contains improvements relevant to current work | Cherry-pick or re-implement BEFORE the new work begins; commit to the current branch and reference the source SHA in the message |
| **Archive** | Improvements are real but out of scope for this session | File a project issue naming the branch + commits + surfaces; add a git note (see below) so the audit stops flagging it |
| **Discard** | Branch is a dead end (rejected approach, superseded) | `git branch -D <branch>` (after confirming the user has authorised the destruction) |

Doing nothing is forbidden — silence is the failure mode that caused L-4.

### Per-branch silence (git notes)

To permanently silence the audit for a known-archived branch:

```bash
git notes --ref=harvest add -m "archived 2026-06-02 — improvements re-implemented in feat/cc-20260602-175001" <branch-tip-sha>
```

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

After landing this rule:
1. `~/.claude/scripts/branch_harvest_audit.sh --selftest` → `N/N PASS`
2. Run the audit on a known-clean repo → zero output
3. Run the audit on the premortem worktree → SHOULD flag
   `feat/cc-20260531-185103` (the L-4 reference case)
4. `git notes --ref=harvest add -m "archived ..."` on a flagged branch's
   tip → next audit run skips it

## Related

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
