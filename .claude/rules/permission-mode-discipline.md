---
name: permission-mode-discipline
description: Tie Claude Code's --permission-mode to the physical workspace — bypassPermissions only inside worktrees or scratch dirs, default mode in main checkouts
type: rule
---

# Rule: Permission Mode Discipline

## Source

PocketOS / Cursor / Railway incident 2026-04-25: a flagship-model agent in unrestricted mode deleted a production volume (and same-volume backups) via a single API call. The system-prompt rule "never run destructive ops" was advisory and was ignored. Reduces blast radius by binding the permission mode to the physical workspace, not a per-session decision.

## When This Applies

Every `claude` invocation on this machine.

## CRITICAL: bypassPermissions is the highest-risk mode

`--permission-mode bypassPermissions` auto-approves every tool call. It is appropriate ONLY when the workspace is itself isolated:

- A git worktree on a feature branch (cannot push to main without explicit merge)
- A throwaway directory under `/tmp/` or `/private/tmp/`
- A container or VM

It is NEVER appropriate in:

- The main checkout of any project under `~/docs_gh/`
- Any cwd that contains live tokens, hooks, or push credentials
- Any cwd where a destructive op has irreversible consequences for shared state

## Workspace → Mode Map

| Workspace | Permission mode | Reason |
|---|---|---|
| `~/docs_gh/<project>/` (main checkout) | `default` (or `acceptEdits`) | Live `.Renviron`, hooks that touch `~/.claude/`, push access — destructive Bash must prompt |
| `/tmp/*`, `/private/tmp/*` | `bypassPermissions` | Throwaway; nothing pushable |
| Sibling worktree (e.g. `~/docs_gh/<project>-<task>/` or `/private/tmp/<wt>/`) | `bypassPermissions` | Branch-isolated; cannot affect main without explicit merge |

Detection rule: a checkout is a **worktree** iff `git rev-parse --git-common-dir` and `git rev-parse --git-dir` differ. Otherwise it is the **main** checkout.

## Enforcement

Two layers, both required:

### Layer 1 — Wrapper script (primary)

`~/.claude/scripts/cc.sh` selects `--permission-mode` based on cwd at session start. The user invokes `cc` instead of `claude` (alias in `~/.zshrc`).

### Layer 2 — Session-init advisory

`session_init.sh` Phase 1b reports the detected workspace kind and the expected mode. If the live `~/.claude/settings.json` `defaultMode` does not match the expected mode for the current workspace, it warns. This catches the case where a user invoked `claude` directly (bypassing `cc`).

## What changes for the user

In a **main checkout**, destructive Bash patterns (`rm -rf`, `git reset --hard`, `curl ... -X DELETE`, `gh api -X DELETE`, `psql -c "DROP"`) prompt before running. Read/Edit/Write to source files still auto-approve via `permissions.allow` in `settings.json`.

In a **worktree** or **scratch dir**, behaviour is unchanged from current `bypassPermissions`.

## Verification

```bash
# In main checkout — wrapper should pick default
cd ~/docs_gh/llm && ~/.claude/scripts/cc.sh --print-mode
# → expected: default

# In a worktree — wrapper should pick bypassPermissions
git -C ~/docs_gh/llm worktree add /tmp/llm-test feat/test
cd /tmp/llm-test && ~/.claude/scripts/cc.sh --print-mode
# → expected: bypassPermissions
```

## Forbidden Patterns

| Pattern | Why wrong |
|---|---|
| `claude --permission-mode bypassPermissions` from `~/docs_gh/<project>/` (main) | Lives next to live tokens, hooks, push credentials |
| Aliasing `claude` to always-bypass | Re-introduces the gap this rule closes |
| Setting `defaultMode: bypassPermissions` in `~/.claude/settings.json` and relying on per-session override | The default IS the failure mode; override is forgotten |
| Running destructive ops in `default` mode without reading prompts | Defeats the safety layer |

## Cautions when editing the symlinked settings.json

`~/.claude/settings.json` is a symlink to `~/docs_gh/llm/.claude/settings.json`. When you edit the live file, the change must flow through to the git-tracked target.

| Form | Symlink-safe? |
|---|---|
| Claude Code's Edit tool | ✓ writes through the symlink |
| Shell `>` redirect (`jq … > ~/.claude/settings.json`) | ✓ truncates and writes to the resolved target |
| `mv source target` | ✗ removes the symlink and replaces it with a regular file. The repo target loses the edit. |

**Recovery if `mv` broke the symlink:**
```bash
cp ~/.claude/settings.json ~/docs_gh/llm/.claude/settings.json
rm ~/.claude/settings.json
ln -s ~/docs_gh/llm/.claude/settings.json ~/.claude/settings.json
```

This came up mid-session 2026-05-05 (llm1) when applying jq edits via `mv`. Recovery cost ~3 tool calls; the lesson is cheap if remembered. See memory: `feedback_symlink-edit-vs-mv.md`.

## Migration

The current `~/.claude/settings.json` `defaultMode` is `bypassPermissions`. To adopt this rule:

1. Install `~/.claude/scripts/cc.sh` (this rule's companion script).
2. Add `alias claude='~/.claude/scripts/cc.sh'` to `~/.zshrc`.
3. Change `defaultMode` in `~/.claude/settings.json` to `default` so that any direct `claude` invocation also prompts on destructive Bash.
4. Audit `permissions.allow` patterns to ensure routine non-destructive Bash still auto-approves (Read/Edit/Write/Grep/Glob are tool-level, not pattern-level — they remain auto-approved).

## Related

- `safe-deletion` — `rm` discipline (subset of this rule's surface)
- `git-no-compound-cd` — git-specific safety guard (subset)
- `nix-agent-shell-protocol` — different isolation axis (env, not permission)
- Companion script: `~/.claude/scripts/cc.sh`
- Companion hook: `~/.claude/hooks/session_init.sh` Phase 1b
