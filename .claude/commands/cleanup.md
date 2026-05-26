# /cleanup - Review and Simplify Work

Review the current session's work and identify opportunities to simplify, consolidate, or clean up.

## Purpose

Run this command periodically during longer sessions to:
- Identify redundant or over-engineered code
- Consolidate scattered changes
- Remove temporary debugging code
- Simplify complex solutions
- Clean up documentation

## Review Checklist

### 1. Code Changes Review

```bash
# Show all files changed in this session
git diff --name-only HEAD~5
git diff --stat HEAD~5
```

For each changed file, ask:
- Is this change necessary?
- Can it be simplified?
- Is there duplicated logic that can be extracted?
- Are there temporary fixes that should be made permanent (or removed)?

### 2. Documentation Review

Check for:
- Duplicate instructions across files (AGENTS.md, skills, commands)
- Outdated references
- Instructions that could be consolidated
- Verbose sections that could be shortened

### 3. Configuration Review

Check for:
- Unused entries in `_quarto.yml`, `default.nix`, etc.
- Overly complex workflow configurations
- Redundant CI steps

### 4. Cleanup Actions

After review, suggest:
- Files to consolidate or remove
- Code to simplify
- Documentation to merge
- Dead code to delete

## Output Format

```
## Cleanup Review

### Files Changed This Session
[list of files with brief description]

### Simplification Opportunities
1. [specific suggestion]
2. [specific suggestion]

### Redundancies Found
- [duplicate/redundant item]

### Recommended Actions
- [ ] [action 1]
- [ ] [action 2]

### Questions for User
- [any clarifications needed]
```

## When to Use

- After completing a complex debugging session
- Before ending a long session
- When a feature is complete but feels over-engineered
- After multiple iterative fixes to the same issue

## Worktree Hygiene (#199)

Stale git worktrees accumulate under `~/docs_gh/` across projects. Run the
sweeper to surface candidates, then decide what to remove.

### Step 1 — Dry-run sweep

```bash
bash ~/.claude/scripts/worktree_gc.sh
```

Output lines tagged `[would-remove]` are fully-merged, clean, and older than
7 days. Lines tagged `[keep-*]` show why a worktree was spared.

### Step 2 — Handle branches that FAIL the patch-id gate

Any branch with unique patches (`[keep-unmerged]`) was NOT auto-listed. These
may be squash-merged (different patch-id but content is in main). For each:

1. **`git cherry main <branch>`** — if all lines are `-`, patch is in main.
2. **Closing-PR check** — `gh issue view <N> --comments` and
   `gh pr list --search "closed:<N>" --state closed` to confirm squash-merge.
3. **Unique-strings check** — grep 2–3 distinctive strings from
   `git diff main...<branch>` against `R/ tests/ vignettes/`.

See the `branch-salvage-workflow` rule for the full decision matrix.

### Step 3 — Remove confirmed stale worktrees

After human confirmation, apply removals:

```bash
AGE_DAYS=7 bash ~/.claude/scripts/worktree_gc.sh --apply
```

The sweeper only removes if patch-id gate + clean + age all pass. It never
removes locked, agent-managed (`/.claude/worktrees/`), or dirty worktrees.
Repos with a `.no-worktree-gc` file are skipped entirely.
