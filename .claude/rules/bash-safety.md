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

## Part 3: External Diff Drivers Make Diff-Content Scans Vacuous

### CRITICAL: `git diff | grep '^+'` Silently Sees Nothing When an External Diff Tool Is Configured

If `diff.external` (or the `GIT_EXTERNAL_DIFF` env var) is set — e.g.
`git config diff.external difft` for [difftastic](https://github.com/Wilfred/difftastic)
— every command that goes through git's diff machinery (`git diff`,
`git log -p`, `git show <commit>`, `git diff-tree -p`) renders its output
through that external tool instead of the standard unified format. A
structural differ's output does not use `+`/`-` line prefixes, so any script
piping diff output into a `grep '^+'`-style content scan (PII scrubbing, a
secret scan, a code-review grep) returns **zero matches regardless of actual
content** — no error, no warning, a clean bill of health that means nothing.

**Verified on this machine, live** (`git config --get diff.external` returns
`difft --display inline`, set both globally and per-repo):

```bash
$ git diff HEAD~1 -- some-changed-file.sh | grep -c '^+'
0
$ git diff --no-ext-diff HEAD~1 -- some-changed-file.sh | grep -c '^+'
10
```

Ten real added lines, zero matches on the default path.

### The Fix: `--no-ext-diff`, Not an Env-Var Override

Add `--no-ext-diff` to any `git diff` / `git log -p` / `git show` invocation
whose output a script will parse programmatically (never to a diff shown
to a human — that's the whole point of configuring an external differ).

```bash
# CORRECT — forces the standard unified format regardless of diff.external
git diff --no-ext-diff HEAD~1 -- file.sh | grep '^+'
git log --all -p --no-ext-diff | grep -aoE "$PATTERN"

# WRONG — silently vacuous when diff.external is configured
git diff HEAD~1 -- file.sh | grep '^+'
```

**`GIT_EXTERNAL_DIFF=` (set to empty) does NOT work as a bypass** — verified:
it makes git try to execute an empty string as the diff program, which
fails outright (`error: cannot run : No such file or directory`) rather than
falling back to the built-in differ. Same result for `git -c diff.external=`.
`--no-ext-diff` is the only invocation-scoped override that actually works.

### Audit of This Repo's Own Scripts (2026-08-29, llm#997)

Grepped `.claude/hooks/**` and `.claude/scripts/**` for `git diff`, `git log
-p`, and `git show` calls whose output feeds a pattern-matching scan. Result:
every content-parsing call site already guards against this —

| Script | Guard already in place |
|---|---|
| `.claude/hooks/repo_visibility_guard.sh` | `git log --all -p --no-ext-diff` (added 2026-08-22, citing this same issue as belt-and-braces) |
| `.claude/scripts/branch_gc.sh` (`sample_unique_strings()`) | `git diff --no-ext-diff "${def}...${branch}"` |
| `.claude/scripts/private_data_scan.sh` | Documents this exact hazard in its own header and avoids content diff entirely — uses `git diff --cached --name-only` / `git diff-tree --name-only -r` (file lists, never content) |
| `.claude/scripts/check_skill_security.sh`, `.claude/scripts/phi_scan.sh`, `.claude/scripts/indeterminate_precommit.sh` | Use `git diff --name-only` (file paths only) — structurally unaffected by `diff.external` regardless |

No follow-up fix is needed in this repo today. Flagging this section so a
**future** script that adds a new `git diff \| grep`-style content scan
carries `--no-ext-diff` from the start, rather than being discovered only
when a review silently passes something it should have caught.

---

## Related

- `permission-mode-discipline` — permission modes
- `destructive-ops-guard` — API-level destructive operations
- [JohnGavin/llm#997](https://github.com/JohnGavin/llm/issues/997) — origin of Part 3
