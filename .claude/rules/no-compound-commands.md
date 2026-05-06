---
description: Ban all && compound commands — use separate Bash calls or -C flags
---

# Rule: No Compound Commands (Universal `&&` Ban)

## When This Applies

Every Bash tool call, without exception.

## CRITICAL: Never Use `&&` in Bash Commands

Compound commands with `&&` trigger confirmation prompts that interrupt workflow.
Some prompts (e.g., `cd && git`) are hardcoded and cannot be bypassed even with
`bypassPermissions`. To eliminate ALL such prompts, this rule bans `&&` entirely.

**One command per Bash call. No exceptions.**

## Why This Rule Exists

1. **Eliminates all confirmation prompts** — no `&&` means no compound-command guards fire
2. **Explicit audit trail** — each tool call shows exactly one operation
3. **No cwd leakage** — `cd` in one call affects subsequent calls; avoiding it entirely is safer
4. **Failure isolation** — if command A fails, command B doesn't run silently in wrong state

## Substitution Patterns

### Git Commands

Use `git -C <path>` instead of `cd && git`:

| Forbidden | Required |
|-----------|----------|
| `cd ~/repo && git status` | `git -C ~/repo status` |
| `cd ~/repo && git add . && git commit -m "msg"` | Two calls: `git -C ~/repo add .` then `git -C ~/repo commit -m "msg"` |
| `git add . && git commit -m "msg" && git push` | Three separate Bash calls |

### Build Tools

Use `-C` flags where available:

| Forbidden | Required |
|-----------|----------|
| `cd ~/repo && make build` | `make -C ~/repo build` |
| `cd ~/repo && npm test` | `npm test --prefix ~/repo` |
| `make build && make test` | Two separate Bash calls |

### R/Python Scripts

Use absolute paths:

| Forbidden | Required |
|-----------|----------|
| `cd ~/repo && Rscript script.R` | `Rscript ~/repo/script.R` |
| `cd ~/repo && python script.py` | `python ~/repo/script.py` |
| `Rscript a.R && Rscript b.R` | Two separate Bash calls |

### Nix Shell

Use absolute path to default.nix:

| Forbidden | Required |
|-----------|----------|
| `cd ~/repo && nix-shell --run "cmd"` | `nix-shell ~/repo/default.nix --run "cmd"` |

### File Operations

Use dedicated tools or absolute paths:

| Forbidden | Required |
|-----------|----------|
| `cd ~/repo && cat file.txt` | Use `Read` tool with `~/repo/file.txt` |
| `cd ~/repo && ls` | `ls ~/repo/` |
| `mkdir foo && cd foo && touch bar` | Three separate calls, or `mkdir -p ~/full/path && touch ~/full/path/bar` as two calls |

### Dependent Operations (Sequential Requirement)

When command B genuinely depends on command A completing first, use **separate sequential Bash calls**:

```
# First call:
Bash("git -C ~/repo add file.R")

# Second call (after first succeeds):
Bash("git -C ~/repo commit -m 'msg'")

# Third call:
Bash("git -C ~/repo push")
```

### Truly Atomic Operations

Some operations are genuinely atomic and lose meaning if split. Use a **subshell** as the
escape hatch (but prefer avoiding this):

```bash
# Acceptable ONLY when atomicity is required:
(cd ~/repo && tar czf ../backup.tgz .)
```

The subshell `()` isolates the `cd` so it doesn't leak to subsequent calls.

## Parallel Independent Commands

If commands A and B are independent (don't depend on each other), call them in parallel
using multiple Bash tool invocations in the same message:

```
# In one message, two parallel tool calls:
Bash("git -C ~/repo status")
Bash("ls ~/repo/docs/")
```

This is faster than `&&` chaining and provides clearer output separation.

## Forbidden Patterns

| Pattern | Why forbidden |
|---------|---------------|
| `cmd1 && cmd2` | Compound command — triggers guards |
| `cmd1 && cmd2 && cmd3` | Multi-compound — multiple guard triggers |
| `cd dir && cmd` | Specifically triggers hardcoded bare-repo guard |
| `cmd1; cmd2` | Semicolon chains have same issues |
| `cmd1 \|\| cmd2` | OR chains — same category |
| `cmd1 & cmd2` | Background chains — unpredictable |

## The One Exception: Heredocs

Heredocs for multi-line strings (e.g., commit messages) are allowed because they're
not command chaining — they're string construction:

```bash
git -C ~/repo commit -m "$(cat <<'EOF'
Commit subject

Body text here.

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

## Enforcement

This rule is enforced by:
1. Agent self-compliance (this document)
2. Future: PreToolUse hook that rejects Bash calls containing `&&`

## Related

- `git-no-compound-cd` — predecessor rule (now subsumed by this universal ban)
- `permission-mode-discipline` — permission modes; this rule eliminates compound-command guards entirely
