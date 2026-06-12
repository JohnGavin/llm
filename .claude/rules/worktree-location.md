---
description: Convention for where to create git worktrees — ~/docs_gh/worktrees/<project>/<branch>/ — and the cc-worktree.sh helper for programmatic enforcement
---
# Rule: Worktree Location Convention

## When This Applies

Every `git worktree add` call for any project under `~/docs_gh/`. Applies to
orchestrators, agents, and manual shell work. Convention is forward-looking —
existing sibling worktrees are migrated as a separate follow-up, not as part of
this rule.

## CRITICAL: All New Worktrees Go Under `~/docs_gh/worktrees/<project>/<branch>/`

## Why

Sibling worktrees (`~/docs_gh/<proj>-<branch>/`) pollute the project-parent
directory. When `ls ~/docs_gh/` grows to include `llm`, `llm-fix-foo`,
`llm-feat-bar`, `mycare`, `mycare-fix-baz`, the signal-to-noise ratio
collapses. `~/docs_gh/worktrees/` separates ephemeral workspaces from canonical
checkouts while keeping the whole docs_gh tree a single unit (one path to
back up, find, and grep across all project worktrees — llm#582).

Benefits:

- `ls ~/docs_gh/` shows canonical repos plus exactly one `worktrees/` dir
- `ls ~/docs_gh/worktrees/llm/` shows all active worktrees for one project
- `ls ~/docs_gh/worktrees/` shows which projects have active worktrees
- Worktrees live next to the projects, not at home root — easier backup
  and discovery
- Path is off the project directory, so nix `default.nix` paths and
  `_targets.R` relative paths stay unambiguous

## Transition (llm#582, decided 2026-06-12)

The previous convention was `~/worktrees/<project>/<branch>/`. Existing
worktrees there remain valid until they finish their lifecycle — do NOT
mass-migrate live worktrees. No NEW worktrees go to the legacy base.
`worktree_gc.sh` sweeps both bases; `cc.sh`'s worktree-parent redirect and
session-init Phase 1e recognise both. The `~/worktrees/` references die
with the last legacy worktree.

## Required Pattern

```bash
# CORRECT: worktree goes under ~/docs_gh/worktrees/<project>/<branch>/
git -C ~/docs_gh/llm worktree add ~/docs_gh/worktrees/llm/feat/fix-foo -b feat/fix-foo

# Using the wrapper script (preferred)
~/.claude/scripts/cc-worktree.sh llm feat/fix-foo
```

The path form is always: `~/docs_gh/worktrees/<project-name>/<branch-name>/`

Branch names with slashes are kept as-is in the path, e.g.
`~/docs_gh/worktrees/llm/feat/fix-foo/` (the `feat/` prefix becomes a sub-directory).

## Wrapper Script

`~/.claude/scripts/cc-worktree.sh <project-name> <branch-name> [base-branch=main]`

- Resolves project path by searching under `~/docs_gh/` for a git repo root
  whose basename matches `<project-name>`
- Creates worktree at `~/docs_gh/worktrees/<project-name>/<branch-name>/`
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
| `git worktree add ../llm-feat-foo -b feat/foo` | Sibling pollutes `~/docs_gh/` listing | Use `~/docs_gh/worktrees/llm/feat/foo/` |
| `git worktree add .claude/worktrees/agent-123` | Internal harness path, not for manual/orchestrator use | Use `~/docs_gh/worktrees/<project>/<branch>/` |
| Relative worktree path | Breaks when cwd differs between creation and use | Always absolute path |
| `cd ~/docs_gh/llm && git worktree add` | Compound-command ban — triggers hook rejection | `git -C ~/docs_gh/llm worktree add ...` |

## Listing and Cleanup

```bash
# List all worktrees for a project
git -C ~/docs_gh/llm worktree list

# Remove a finished worktree
git -C ~/docs_gh/llm worktree remove ~/docs_gh/worktrees/llm/feat/fix-foo

# Prune stale worktree references
git -C ~/docs_gh/llm worktree prune
```

## Never start a session in the worktree-parent dir

`~/docs_gh/worktrees/<project>/` (and `~/docs_gh/worktrees/<project>/feat/`, `.../fix/`, etc.)
are parent directories, not checkouts. They contain no `.git`, no source code —
only the actual worktrees nested beneath. Starting a Claude session there loads
the full project context (via `additionalDirectories` in `settings.json`) plus
all global rules, but cwd is functionally empty — every relative path resolves
to nothing useful.

Valid session-start cwds:

- `~/docs_gh/<project>/` — canonical main checkout (default for everyday work)
- `~/docs_gh/worktrees/<project>/<branch>/` — a specific worktree (only when deliberately
  working on that branch in isolation)

Two layers enforce this:

1. **`cc.sh` auto-redirect (primary).** If launched anywhere under
   `~/docs_gh/worktrees/<project>/` that is not a real worktree, the wrapper `cd`s to
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
