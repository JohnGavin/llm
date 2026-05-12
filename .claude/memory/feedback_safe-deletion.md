---
name: feedback_safe-deletion
description: Never delete untracked files/dirs without verification — learned from 522MB worktree deletion incident
type: feedback
---

Never delete untracked files or directories without checking size, age, diff against tracked files, and asking the user.

**Why:** On 2026-03-27, deleted 522MB agent worktree (`.claude/worktrees/agent-ac00e125/`) from football project without verifying content was unique or asking user. Files were untracked and unrecoverable. Likely no unique content lost (main had 179 .Rd files vs ~20 in worktree) but unprovable.

**How to apply:** Before any `rm -rf`, `git clean`, or directory deletion:
1. `du -sh` — check size. >1MB = STOP and ask.
2. `stat -f '%Sm'` — check age. Recent = likely WIP.
3. `diff` key files against main — check uniqueness.
4. `git status` — untracked + deleted = gone forever.
5. Ask user before proceeding.

See `safe-deletion` rule for full protocol.
