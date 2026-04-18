---
description: Never use cd && git compound commands — use git -C instead
---

# Rule: No `cd &&` Compound Commands

## When This Applies
Every time Claude calls a Bash tool that operates on files or repos in any
directory other than the current working directory. Applies to git commands
(where it is CRITICAL) and to all other tools (where it is MANDATORY).

## CRITICAL: Never Use `cd <dir> && git ...`

Claude Code has a hardcoded safety guard that prompts for approval whenever
a Bash call combines `cd` with `git`. The exact prompt is:

> Compound commands with cd and git require approval to prevent bare repository attacks

This guard fires **even when `defaultMode` is `bypassPermissions`**. It is
independent of the permissions allow-list and cannot be disabled via the
`Bash(...)` permission patterns.

The guard exists because a bare repo at `<dir>` could redirect git operations
to attacker-controlled hooks. The safe alternative is to use `git -C <dir>`
which sets the working directory inside git itself, with no shell `cd`.

## Mandatory Substitution

Every git subcommand accepts `-C <path>` as the FIRST argument:

| Wrong (triggers approval prompt) | Right (no prompt) |
|---|---|
| `cd ~/repo && git status` | `git -C ~/repo status` |
| `cd ~/repo && git status -u` | `git -C ~/repo status -u` |
| `cd ~/repo && git log --oneline -5` | `git -C ~/repo log --oneline -5` |
| `cd ~/repo && git diff` | `git -C ~/repo diff` |
| `cd ~/repo && git diff HEAD~1` | `git -C ~/repo diff HEAD~1` |
| `cd ~/repo && git add file.R` | `git -C ~/repo add file.R` |
| `cd ~/repo && git commit -m "msg"` | `git -C ~/repo commit -m "msg"` |
| `cd ~/repo && git push` | `git -C ~/repo push` |
| `cd ~/repo && git pull` | `git -C ~/repo pull` |
| `cd ~/repo && git fetch` | `git -C ~/repo fetch` |
| `cd ~/repo && git branch --show-current` | `git -C ~/repo branch --show-current` |
| `cd ~/repo && git remote -v` | `git -C ~/repo remote -v` |
| `cd ~/repo && git stash` | `git -C ~/repo stash` |
| `cd ~/repo && git rev-parse HEAD` | `git -C ~/repo rev-parse HEAD` |

### Multi-step git operations

Chain multiple `git -C` calls instead of one `cd`:

```bash
# Wrong — single approval prompt
cd ~/repo && git add file.R && git commit -m "fix" && git push

# Right — no prompts
git -C ~/repo add file.R && \
  git -C ~/repo commit -m "fix" && \
  git -C ~/repo push
```

### Heredoc commit messages

```bash
# Right
git -C ~/repo commit -m "$(cat <<'EOF'
Commit subject

Detailed body explaining the change.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

## Non-git Compound Commands (ALSO MANDATORY)

The bare-repo guard targets `cd ... && git` specifically, but the principle
applies to ALL compound commands with `cd`. Reasons:

1. **Claude Code's cwd persists** between Bash calls — a `cd` in one call
   changes cwd for all subsequent calls, causing surprising path resolution
2. **Readability** — `cd X && cmd` hides which directory the command runs in;
   absolute paths or `-C` flags are self-documenting
3. **Failure mode** — if `cd` fails silently (e.g., `cd ~/typo; rm -rf *`)
   the subsequent command runs in the WRONG directory

### Substitution table

| Wrong (compound `cd`) | Right (no `cd`) |
|---|---|
| `cd ~/repo && make build` | `make -C ~/repo build` |
| `cd ~/repo && npm test` | `npm test --prefix ~/repo` |
| `cd ~/repo && Rscript script.R` | `Rscript ~/repo/script.R` |
| `cd ~/repo && python script.py` | `python ~/repo/script.py` |
| `cd ~/repo && cat file.txt` | Use the `Read` tool on `~/repo/file.txt` |
| `cd ~/repo && ls` | `ls ~/repo/` |
| `cd ~/repo && wc -l *.R` | `wc -l ~/repo/*.R` |
| `cd ~/repo && tar czf ../out.tgz .` | `tar czf ~/out.tgz -C ~/repo .` |
| `cd ~/repo && nix-shell --run "cmd"` | `nix-shell ~/repo/default.nix --run "cmd"` |
| `cd ~/repo && sqlite3 db.sqlite ".tables"` | `sqlite3 ~/repo/db.sqlite ".tables"` |

### When `cd` IS needed

Some tools have no `-C` equivalent and require cwd to be the project root
(e.g., `targets::tar_make()`, some test runners). In those cases, use a
**subshell** to prevent cwd leaking:

```bash
# Acceptable: subshell isolates the cd
(cd ~/repo && Rscript -e 'targets::tar_make()')
```

The key constraint: **never leave cwd permanently changed by a Bash call**.

## Working Example

`~/.claude/hooks/session_stop.sh` lines 39-40 use `git -C` correctly:

```bash
git -C "$CLAUDE_DIR" rev-parse --git-dir >/dev/null 2>&1
changes=$(git -C "$CLAUDE_DIR" status -s 2>/dev/null | head -5)
```

## Why This Is a Rule (Not Just Advice)

- The approval prompt interrupts every git operation in non-cwd directories
- `bypassPermissions` mode does NOT bypass this guard
- The fix is one-character (add `-C`) and zero-cost
- The substitution is mechanical and applies to every git subcommand
- There is no downside to `git -C` — it works identically to `cd && git`

## Forbidden Patterns

| Pattern | Why wrong |
|---|---|
| `cd <dir> && git ...` | Triggers approval prompt |
| `cd <dir>; git ...` | Same trigger |
| `pushd <dir> && git ... && popd` | Same trigger |
| `(cd <dir> && git ...)` | The subshell may bypass the guard but is harder to read; prefer `git -C` |

## Related

- Working example: `~/.claude/hooks/session_stop.sh:39-40`
- Memory: `feedback_no-compound-cd`
- AGENTS.md Git/GitHub line documents the rule
