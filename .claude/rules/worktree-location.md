---
description: Convention for where to create git worktrees — ~/worktrees/<project>/<branch>/ — and the cc-worktree.sh helper for programmatic enforcement
---
# Rule: Worktree Location Convention

## When This Applies

Every `git worktree add` call for any project under `~/docs_gh/`. Applies to
orchestrators, agents, and manual shell work. Convention is forward-looking —
existing sibling worktrees are migrated as a separate follow-up, not as part of
this rule.

## CRITICAL: All New Worktrees Go Under `~/worktrees/<project>/<branch>/`

## Why

Sibling worktrees (`~/docs_gh/<proj>-<branch>/`) pollute the project-parent
directory. When `ls ~/docs_gh/` grows to include `llm`, `llm-fix-foo`,
`llm-feat-bar`, `mycare`, `mycare-fix-baz`, the signal-to-noise ratio
collapses. `~/worktrees/` separates ephemeral workspaces from canonical
checkouts.

Benefits:

- `ls ~/docs_gh/` shows canonical repos only
- `ls ~/worktrees/llm/` shows all active worktrees for one project
- `ls ~/worktrees/` shows which projects have active worktrees
- Path is off the project directory, so nix `default.nix` paths and
  `_targets.R` relative paths stay unambiguous

## Required Pattern

```bash
# CORRECT: worktree goes under ~/worktrees/<project>/<branch>/
git -C ~/docs_gh/llm worktree add ~/worktrees/llm/feat/fix-foo -b feat/fix-foo

# Using the wrapper script (preferred)
~/.claude/scripts/cc-worktree.sh llm feat/fix-foo
```

The path form is always: `~/worktrees/<project-name>/<branch-name>/`

Branch names with slashes are kept as-is in the path, e.g.
`~/worktrees/llm/feat/fix-foo/` (the `feat/` prefix becomes a sub-directory).

## Wrapper Script

`~/.claude/scripts/cc-worktree.sh <project-name> <branch-name> [base-branch=main]`

- Resolves project path by searching under `~/docs_gh/` for a git repo root
  whose basename matches `<project-name>`
- Creates worktree at `~/worktrees/<project-name>/<branch-name>/`
- Calls `git worktree add -b <branch-name> <path> <base-branch>`
- Re-applies overlays if `default.post.sh` exists in the new worktree
  (per `nix-agent-shell-protocol` rule)
- Logs every invocation to `~/.claude/logs/cc-worktree.log`
- `--dry-run` flag prints the commands without executing them
- Exits non-zero with a clear message on: branch already exists, project not
  found, worktree path already exists

See the script source at `.claude/scripts/cc-worktree.sh`.

## Forbidden Patterns

| Pattern | Why wrong | Fix |
|---------|-----------|-----|
| `git worktree add ../llm-feat-foo -b feat/foo` | Sibling pollutes `~/docs_gh/` listing | Use `~/worktrees/llm/feat/foo/` |
| `git worktree add .claude/worktrees/agent-123` | Internal harness path, not for manual/orchestrator use | Use `~/worktrees/<project>/<branch>/` |
| Relative worktree path | Breaks when cwd differs between creation and use | Always absolute path |
| `cd ~/docs_gh/llm && git worktree add` | Compound-command ban — triggers hook rejection | `git -C ~/docs_gh/llm worktree add ...` |

## Listing and Cleanup

```bash
# List all worktrees for a project
git -C ~/docs_gh/llm worktree list

# Remove a finished worktree
git -C ~/docs_gh/llm worktree remove ~/worktrees/llm/feat/fix-foo

# Prune stale worktree references
git -C ~/docs_gh/llm worktree prune
```

## Never start a session in the worktree-parent dir

`~/worktrees/<project>/` (and `~/worktrees/<project>/feat/`, `.../fix/`, etc.)
are parent directories, not checkouts. They contain no `.git`, no source code —
only the actual worktrees nested beneath. Starting a Claude session there loads
the full project context (via `additionalDirectories` in `settings.json`) plus
all global rules, but cwd is functionally empty — every relative path resolves
to nothing useful.

Valid session-start cwds:

- `~/docs_gh/<project>/` — canonical main checkout (default for everyday work)
- `~/worktrees/<project>/<branch>/` — a specific worktree (only when deliberately
  working on that branch in isolation)

Two layers enforce this:

1. **`cc.sh` auto-redirect (primary).** If launched anywhere under
   `~/worktrees/<project>/` that is not a real worktree, the wrapper `cd`s to
   `~/docs_gh/<project>/` and prints a one-line note before exec'ing `claude`.
   Set `CC_NO_REDIRECT=1` to skip (rarely needed).
2. **`session_init.sh` Phase 1e (backstop).** If a session somehow starts in a
   worktree-parent (e.g. `claude` invoked directly, not via `cc.sh`), Phase 1e
   prints a `WORKTREE-PARENT:` block listing the active worktrees and the two
   valid `cd` targets. Advisory — does not block.

## Agent Dispatch

When spawning an agent with `isolation: "worktree"`, the harness creates its
own worktree under the project's `.claude/worktrees/` path. That is an
internal harness convention and is NOT overridden by this rule. This rule
applies to orchestrator-created worktrees intended for long-running parallel
work or manual branch sessions.

## Related

- `nix-agent-shell-protocol` — when regenerating `default.nix` in a worktree,
  use Form A (subshell) or Form B (setwd) to avoid cwd-drift; if
  `default.post.sh` exists, `cc-worktree.sh` runs it automatically
- `auto-delegation` — `isolation: "worktree"` for Bash-capable agents;
  see the "Mandatory: isolation:worktree" section and the cross-ref to
  `~/.claude/scripts/cc-worktree.sh` for canonical path creation
- `bash-safety` — no `cd <dir> && git ...`; use `git -C <path>` for all
  git operations
