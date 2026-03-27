---
paths:
  - "R/**"
  - "inst/**"
  - ".claude/**"
---
# Safe Deletion Protocol

## The Rule

**NEVER delete files or directories without verification. Untracked does NOT mean disposable.**

Untracked files may be: WIP from a prior session, generated outputs not yet committed, agent worktree artifacts with unique content, data files that took hours to compute.

## Before Deleting Anything

| Check | Command | Must Pass |
|-------|---------|-----------|
| **Size** | `du -sh path/` | If >1MB: STOP, list contents, ask user |
| **Age** | `stat -f '%Sm' path/file` (macOS) | Note how old — recent files are more likely WIP |
| **Diff** | `diff <(ls path/) <(ls equivalent/)` | Check if content already exists elsewhere |
| **Recoverability** | Is it in git? `git status path/` | Untracked + deleted = **gone forever** |
| **User approval** | Ask before proceeding | MANDATORY for >1MB or any directory |

## Decision Table

| Situation | Action |
|-----------|--------|
| Tracked file, committed | Safe to `git checkout -- file` to restore |
| Tracked file, staged but not committed | `git stash` first, then decide |
| Untracked file, <1MB | OK to delete after checking it's not WIP |
| Untracked file, >1MB | **ASK USER** — list contents, show size and age |
| Untracked directory | **ALWAYS ASK** — may contain many files |
| `.claude/worktrees/` | Check branch status, diff against main, ask user |
| `_targets/objects/` | Check if gitignored or tracked per project policy |
| `inst/extdata/` | **NEVER delete without asking** — may be pre-computed data |

## Agent Worktree Cleanup

Agent worktrees (`.claude/worktrees/agent-*`) are created by Claude Code's `isolation: "worktree"` parameter. They should be auto-cleaned but sometimes persist.

**Before deleting a stale worktree:**
1. Check if the worktree branch still exists: `git branch -a | grep agent-`
2. Diff key files against main: `diff worktree/man/ man/`
3. Check file timestamps: `find .claude/worktrees/ -maxdepth 2 -type f -exec stat -f '%Sm %N' {} \; | head -10`
4. Report size: `du -sh .claude/worktrees/`
5. **Ask user before deleting**

## Forbidden Patterns

```bash
# WRONG: Delete without checking
rm -rf .claude/worktrees/

# WRONG: Assume untracked = safe to delete
git clean -fd

# WRONG: Delete based on directory name alone
rm -rf old_backup/

# RIGHT: Check, report, ask
du -sh .claude/worktrees/
find .claude/worktrees/ -maxdepth 2 -type f | head -20
echo "522MB worktree found. Contents above. Delete? (y/n)"
```

## Checklist

- [ ] Checked size (`du -sh`)
- [ ] Checked age (`stat` or `find -mtime`)
- [ ] Checked if content exists elsewhere (diff)
- [ ] Checked recoverability (tracked vs untracked)
- [ ] Asked user before deleting >1MB or any directory
