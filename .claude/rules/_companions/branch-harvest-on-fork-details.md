# Companion: Branch Harvest on Fork — Incident Narrative + Worked Examples

Incident narrative and worked code/output examples split out of the
always-loaded [`branch-harvest-on-fork`](../branch-harvest-on-fork.md) rule
to keep it lean. The normative content (CRITICAL statement, Flag patterns
table, Triage outcomes table, Configuration, Scope, Anti-Patterns) stays in
the rule; this file is the incident narrative and verbatim examples, loaded
on demand.

## Source — full incident narrative

JohnGavin/premortem session 30, 2026-06-02. Lessons learnt L-4 (stranded-
branch harvesting): a previous session made substantive UI improvements on
`feat/cc-20260531-185103` (donut → DT table, bar → Cleveland dot plot, 13
inline `tt()` popups with embedded `<a href>` to GOV.UK + source code,
per-cell drilldown links). Several commits on that branch were tagged
"(session-limit-interrupted)". The branch was never merged to `main`. When
this session forked a new worktree from `main`, it inherited the OLD layout
and the user saw the regression as "you reverted my changes". Three full
re-do sessions followed before the discipline was added.

## Step 1 — Audit runs at session start (full 4-substep breakdown)

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

## Project-level keyword extension — worked example

```
branch-harvest-keywords: vetiver|plumber2|mlops|mycare-letters
```

## Step 3 — worked output example

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

## Per-branch silence — worked command

```bash
git notes --ref=harvest add -m "archived 2026-06-02 — improvements re-implemented in feat/cc-20260602-175001" <branch-tip-sha>
```

## Verification

After landing this rule:
1. `~/.claude/scripts/branch_harvest_audit.sh --selftest` → `N/N PASS`
2. Run the audit on a known-clean repo → zero output
3. Run the audit on the premortem worktree → SHOULD flag
   `feat/cc-20260531-185103` (the L-4 reference case)
4. `git notes --ref=harvest add -m "archived ..."` on a flagged branch's
   tip → next audit run skips it
