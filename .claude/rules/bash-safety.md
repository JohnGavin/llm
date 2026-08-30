---
description: Bash command safety — no compound commands, safe deletion, git -C patterns
---

# Rule: Bash Command Safety

Consolidated from: `no-compound-commands`, `git-no-compound-cd`, `safe-deletion`.

## When This Applies

Every Bash tool call, without exception.

---

## Part 1: No Compound Commands (Universal `&&` Ban)

> **Status: ENFORCED (block mode)**
> `COMPOUND_GUARD_MODE=block` is active in `settings.json`. Any Bash call
> containing `&&`, `||`, `;` (outside a subshell), or `|` between independent
> commands is rejected by the pre-tool hook with a retry message. The command
> never reaches the shell. Fix the call and retry — do not attempt to work
> around the guard.

### Agent Dispatch Template

Every Agent dispatch involving Bash MUST include the verbatim Bash discipline prefix at the top of the prompt. See [_companions/bash-safety-dispatch-template.md](_companions/bash-safety-dispatch-template.md) for the full text and rationale.

### CRITICAL: Never Use `&&` in Bash Commands

Compound commands with `&&` trigger confirmation prompts that interrupt workflow. Some prompts (e.g., `cd && git`) are hardcoded and cannot be bypassed even with `bypassPermissions`. To eliminate ALL such prompts, this rule bans `&&` entirely. **One command per Bash call. No exceptions.**

### Why

Eliminates all confirmation prompts (no `&&` means no compound-command guards fire), gives an explicit audit trail (each tool call shows exactly one operation), prevents cwd leakage (`cd` in one call would otherwise affect subsequent calls), and isolates failures (command A failing can't let command B run silently in the wrong state).

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

### Dependent Operations, Subshells, and Heredocs

When command B depends on command A, use **separate sequential Bash calls** (`Bash("git -C ~/repo add file.R")`, then `Bash("git -C ~/repo commit -m 'msg'")`). When atomicity is required (rare), a subshell isolates the `cd` so it doesn't leak: `(cd ~/repo && tar czf ../backup.tgz .)`. Heredocs for multi-line strings (e.g. commit messages) are allowed:

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

## Part 3: External Diff Drivers Make Diff-Content Scans Vacuous

### CRITICAL: `git diff | grep '^+'` Silently Sees Nothing When an External Diff Tool Is Configured

If `diff.external` (or the `GIT_EXTERNAL_DIFF` env var) is set — e.g. `git config diff.external difft` for [difftastic](https://github.com/Wilfred/difftastic) — every command that goes through git's diff machinery (`git diff`, `git log -p`, `git show <commit>`, `git diff-tree -p`) renders its output through that external tool instead of the standard unified format. A structural differ's output does not use `+`/`-` line prefixes, so any script piping diff output into a `grep '^+'`-style content scan (PII scrubbing, a secret scan, a code-review grep) returns **zero matches regardless of actual content** — no error, no warning, a clean bill of health that means nothing. Verified live reproduction on this machine: companion doc.

### The Fix: `--no-ext-diff`, Not an Env-Var Override

Add `--no-ext-diff` to any `git diff` / `git log -p` / `git show` invocation whose output a script will parse programmatically (never to a diff shown to a human — that's the whole point of configuring an external differ). `GIT_EXTERNAL_DIFF=` (set empty) does NOT work as a bypass — verified, see companion doc.

```bash
# CORRECT — forces the standard unified format regardless of diff.external
git diff --no-ext-diff HEAD~1 -- file.sh | grep '^+'
git log --all -p --no-ext-diff | grep -aoE "$PATTERN"

# WRONG — silently vacuous when diff.external is configured
git diff HEAD~1 -- file.sh | grep '^+'
```

A 2026-08-29 audit (llm#997) of every content-parsing `git diff`/`git log -p`/`git show` call site in `.claude/hooks/**` and `.claude/scripts/**` found all of them already guarded (`repo_visibility_guard.sh`, `branch_gc.sh`, `private_data_scan.sh`, and three name-only scanners) — no follow-up fix needed today. Full audit table: companion doc. Flagging this section so a **future** script that adds a new content scan carries `--no-ext-diff` from the start.

---

## Related

- `permission-mode-discipline` — permission modes
- `destructive-ops-guard` — API-level destructive operations
- [JohnGavin/llm#997](https://github.com/JohnGavin/llm/issues/997) — origin of Part 3
