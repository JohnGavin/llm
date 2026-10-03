---
description: Bash command safety — no compound commands, safe deletion, git -C patterns
---

# Rule: Bash Command Safety

Consolidated from: `no-compound-commands`, `git-no-compound-cd`, `safe-deletion`.

## When This Applies

Every Bash tool call, without exception.

---

## Part 1: No Compound Commands (Universal `&&` Ban)

> **Status: ENFORCED (block mode).** `COMPOUND_GUARD_MODE=block`: any Bash call containing `&&`, `||`, `;` (outside a subshell), or `|` between independent commands is rejected before reaching the shell. Fix the call and retry — do not work around the guard.

### Agent Dispatch Template

Every Agent dispatch involving Bash MUST include the verbatim Bash discipline prefix at the top of the prompt. See [_companions/bash-safety-dispatch-template.md](_companions/bash-safety-dispatch-template.md) for the full text and rationale.

### CRITICAL: Never Use `&&` in Bash Commands

Compound commands with `&&` trigger confirmation prompts that interrupt workflow. Some prompts (e.g., `cd && git`) are hardcoded and cannot be bypassed even with `bypassPermissions`. To eliminate ALL such prompts, this rule bans `&&` entirely. **One command per Bash call. No exceptions.**

### Why

No compound-command confirmation prompts, an explicit audit trail (one operation per call), no cwd leakage, and isolated failures. Full rationale: companion doc.

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

Never `rm -rf .claude/worktrees/` or `git clean -fd` unchecked: run `du -sh`, list contents, then ask. Code block: companion doc.

---

## Part 3: External Diff Drivers Make Diff-Content Scans Vacuous

### CRITICAL: `git diff | grep '^+'` Silently Sees Nothing When an External Diff Tool Is Configured

If `diff.external` (or `GIT_EXTERNAL_DIFF`) is set (e.g. difftastic), `git diff`, `git log -p`, `git show` and `git diff-tree -p` render through the external tool, not unified `+`/`-` format, so any script piping diff output into a `grep '^+'`-style content scan (PII, secret, code-review grep) returns **zero matches regardless of actual content** — no error, a clean bill of health that means nothing. Verified reproduction: companion doc.

### The Fix: `--no-ext-diff`, Not an Env-Var Override

Add `--no-ext-diff` to any `git diff` / `git log -p` / `git show` invocation whose output a script will parse programmatically (never to a diff shown to a human — that's the whole point of configuring an external differ). `GIT_EXTERNAL_DIFF=` (set empty) does NOT work as a bypass — verified, see companion doc.

```bash
# CORRECT — forces the standard unified format regardless of diff.external
git diff --no-ext-diff HEAD~1 -- file.sh | grep '^+'
git log --all -p --no-ext-diff | grep -aoE "$PATTERN"

# WRONG — silently vacuous when diff.external is configured
git diff HEAD~1 -- file.sh | grep '^+'
```

A 2026-08-29 audit (llm#997) found every existing content-parsing call site in `.claude/hooks/**` and `.claude/scripts/**` already guarded; a **future** script that adds a content scan must carry `--no-ext-diff` from the start. Audit table: companion doc.

---

## Related

- `permission-mode-discipline` — permission modes
- `destructive-ops-guard` — API-level destructive operations
- [JohnGavin/llm#997](https://github.com/JohnGavin/llm/issues/997) — origin of Part 3
