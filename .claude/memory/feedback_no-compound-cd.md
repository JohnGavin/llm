---
name: feedback_no-compound-cd
description: Never use `cd <dir> && git` in Bash calls — triggers bare-repo approval prompt
type: feedback
---

Claude Code prompts for approval whenever a Bash call uses `cd <dir> && git ...`:

> Compound commands with cd and git require approval to prevent bare repository attacks

This guard fires **even when `defaultMode` is `bypassPermissions`** in
`~/.claude/settings.json`. It is a hardcoded safety check, independent of the
permissions allow-list. No `Bash(...)` permission entry can disable it.

**Why:** A bare repo at `<dir>` could redirect git operations to attacker-controlled
hooks. The guard exists to protect against this.

**How to apply:** Always use `git -C <dir> <subcommand>` instead of
`cd <dir> && git <subcommand>`. Every git subcommand accepts `-C <path>` as the
first flag. No exceptions.

| Wrong | Right |
|---|---|
| `cd ~/repo && git status` | `git -C ~/repo status` |
| `cd ~/repo && git add file && git commit -m "msg"` | `git -C ~/repo add file && git -C ~/repo commit -m "msg"` |
| `cd ~/repo && git log --oneline -5` | `git -C ~/repo log --oneline -5` |

**Working example:** `~/.claude/hooks/session_stop.sh` lines 39-40 use `git -C "$CLAUDE_DIR"`.

**For non-git compound commands:** the bare-repo guard targets `cd ... && git`
specifically. Other tools (ast-grep, make, Rscript) don't trigger the same prompt,
but the cleaner pattern is still to use absolute paths or `-C` flags.

**See:** `git-no-compound-cd` rule for the full substitution table.
