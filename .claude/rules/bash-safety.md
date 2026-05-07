---
description: Bash command safety — no compound commands, safe deletion, git -C patterns
---

# Rule: Bash Command Safety

Consolidated from: `no-compound-commands`, `git-no-compound-cd`, `safe-deletion`.

## When This Applies

Every Bash tool call, without exception.

---

## Part 1: No Compound Commands (Universal `&&` Ban)

### CRITICAL: Never Use `&&` in Bash Commands

Compound commands with `&&` trigger confirmation prompts that interrupt workflow.
Some prompts (e.g., `cd && git`) are hardcoded and cannot be bypassed even with
`bypassPermissions`. To eliminate ALL such prompts, this rule bans `&&` entirely.

**One command per Bash call. No exceptions.**

### Why

1. **Eliminates all confirmation prompts** — no `&&` means no compound-command guards fire
2. **Explicit audit trail** — each tool call shows exactly one operation
3. **No cwd leakage** — `cd` in one call affects subsequent calls
4. **Failure isolation** — if command A fails, command B doesn't run silently in wrong state

### Substitution Patterns

| Forbidden | Required |
|-----------|----------|
| `cd ~/repo && git status` | `git -C ~/repo status` |
| `cd ~/repo && git add . && git commit` | Two separate Bash calls |
| `cd ~/repo && make build` | `make -C ~/repo build` |
| `cd ~/repo && npm test` | `npm test --prefix ~/repo` |
| `cd ~/repo && Rscript script.R` | `Rscript ~/repo/script.R` |
| `cd ~/repo && nix-shell --run "cmd"` | `nix-shell ~/repo/default.nix --run "cmd"` |
| `cd ~/repo && cat file.txt` | Use `Read` tool with `~/repo/file.txt` |
| `cmd1 && cmd2` | Two separate Bash calls |
| `cmd1; cmd2` | Two separate Bash calls |

### Dependent Operations

When command B depends on command A, use **separate sequential Bash calls**:

```
# First call:
Bash("git -C ~/repo add file.R")
# Second call (after first succeeds):
Bash("git -C ~/repo commit -m 'msg'")
```

### Exception: Subshells for Atomicity

When atomicity is required (rare):

```bash
(cd ~/repo && tar czf ../backup.tgz .)
```

The subshell `()` isolates the `cd` so it doesn't leak.

### Exception: Heredocs

Heredocs for multi-line strings are allowed:

```bash
git -C ~/repo commit -m "$(cat <<'EOF'
Commit subject
Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

### Forbidden Patterns

| Pattern | Why forbidden |
|---------|---------------|
| `cmd1 && cmd2` | Compound command — triggers guards |
| `cd dir && cmd` | Triggers hardcoded bare-repo guard |
| `cmd1; cmd2` | Semicolon chains have same issues |
| `cmd1 \|\| cmd2` | OR chains — same category |
| `cmd1 & cmd2` | Background chains — unpredictable |

---

## Part 2: Safe Deletion Protocol

### CRITICAL: Untracked Does NOT Mean Disposable

Untracked files may be: WIP from a prior session, generated outputs not yet committed, agent worktree artifacts with unique content, data files that took hours to compute.

### Before Deleting Anything

| Check | Command | Must Pass |
|-------|---------|-----------|
| **Size** | `du -sh path/` | If >1MB: STOP, list contents, ask user |
| **Age** | `stat -f '%Sm' path/file` (macOS) | Note how old — recent files are more likely WIP |
| **Diff** | `diff <(ls path/) <(ls equivalent/)` | Check if content exists elsewhere |
| **Recoverability** | `git status path/` | Untracked + deleted = **gone forever** |
| **User approval** | Ask before proceeding | MANDATORY for >1MB or any directory |

### Decision Table

| Situation | Action |
|-----------|--------|
| Tracked file, committed | Safe to `git checkout -- file` to restore |
| Untracked file, <1MB | OK to delete after checking it's not WIP |
| Untracked file, >1MB | **ASK USER** — list contents, show size and age |
| Untracked directory | **ALWAYS ASK** — may contain many files |
| `.claude/worktrees/` | Check branch status, diff against main, ask user |
| `_targets/objects/` | Check if gitignored or tracked per project policy |
| `inst/extdata/` | **NEVER delete without asking** — may be pre-computed data |

### Forbidden Deletion Patterns

```bash
# WRONG: Delete without checking
rm -rf .claude/worktrees/

# WRONG: Assume untracked = safe to delete
git clean -fd

# RIGHT: Check, report, ask
du -sh .claude/worktrees/
find .claude/worktrees/ -maxdepth 2 -type f | head -20
# Then ask user
```

---

## Related

- `permission-mode-discipline` — permission modes
- `destructive-ops-guard` — API-level destructive operations
