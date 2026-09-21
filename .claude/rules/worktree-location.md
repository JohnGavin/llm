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

Sibling worktrees (`~/docs_gh/<proj>-<branch>/`) pollute the project-parent directory. `~/docs_gh/worktrees/` separates ephemeral workspaces from canonical checkouts while keeping the docs_gh tree one unit (llm#582). Benefits and full rationale: companion doc.

## Transition (llm#582, decided 2026-06-12)

The previous convention was `~/worktrees/<project>/<branch>/`. Existing worktrees there stay valid until finished: do NOT mass-migrate live worktrees, and put NO NEW worktrees there. `worktree_gc.sh`, `cc.sh` and session-init Phase 1e recognise both bases.

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

Resolves the project under `~/docs_gh/`, creates the worktree at the required path via `git worktree add -b`, re-applies `default.post.sh` overlays (per `nix-agent-shell-protocol`), logs to `~/.claude/logs/cc-worktree.log`, supports `--dry-run`, and exits non-zero on: branch already exists, project not found, worktree path already exists.

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

## CRITICAL: Multiple worktrees may exist outside `~/docs_gh/` — verify the canonical checkout before working

A project's real, actively-used checkout is not guaranteed to live under
`~/docs_gh/<project>/` at all. A privacy-sensitive project (health, financial,
or other PHI/PII-bearing data — see `public-private-repo-boundary`) may be
deliberately kept entirely outside the `docs_gh` tree, e.g. under a personal
iCloud/local-only path, while `~/docs_gh/worktrees/<project>/<branch>/`
contains only stale, forked-and-diverged mirror worktrees of the same repo
that nobody has cleaned up.

**Do not infer the canonical checkout from directory naming or a partial
`find`/`mdfind` scoped to `~/docs_gh/`.** `git worktree list`, run from ANY
known checkout of the repo — even a stale one — enumerates every worktree of
that repo regardless of where it physically lives, because worktrees share
one `.git` object store. Run it FIRST, before starting real work, whenever a
project might have more than one checkout:

```bash
git -C <any-known-checkout-of-the-project> worktree list
```

Then identify which entry is actually current: check `git log -1
--format='%ci'` per worktree, and prefer the one with the freshest commits
AND/OR uncommitted in-progress changes (`git status --short`) over the one
that merely has the most recent timestamp among a partial set you already
happened to find. A worktree whose last commit is identical to another
worktree's *older* tip is a strong signal it forked off and was abandoned —
see `branch-harvest-on-fork`.

**Origin:** 2026-09-18/19, mycare project. An agent worked a whole session in a stale `~/docs_gh/worktrees/mycare/feat/...` worktree, chosen because it had the newest commit among those a `docs_gh`-scoped search surfaced, while the live checkout sat outside `docs_gh` (it holds real patient data) and had genuinely diverged; the work had to be re-applied by hand. Full narrative: companion doc.

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

Two layers enforce this: `cc.sh` auto-redirects to `~/docs_gh/<project>/` with a one-line note (`CC_NO_REDIRECT=1` to skip); `session_init.sh` Phase 1e (backstop, advisory) prints a `WORKTREE-PARENT:` block listing active worktrees and the two valid `cd` targets. Details: companion doc.

## Agent Dispatch

When spawning an agent with `isolation: "worktree"`, the harness creates its
own worktree under the project's `.claude/worktrees/` path. That is an
internal harness convention and is NOT overridden by this rule. This rule
applies to orchestrator-created worktrees intended for long-running parallel
work or manual branch sessions.

## Related

- [`_companions/worktree-location-details.md`](_companions/worktree-location-details.md) — rationale, benefits, origin incident, enforcement detail split out of this rule
- `nix-agent-shell-protocol` — when regenerating `default.nix` in a worktree,
  use Form A (subshell) or Form B (setwd) to avoid cwd-drift; if
  `default.post.sh` exists, `cc-worktree.sh` runs it automatically
- `auto-delegation` — `isolation: "worktree"` for Bash-capable agents;
  see the "Mandatory: isolation:worktree" section and the cross-ref to
  `~/.claude/scripts/cc-worktree.sh` for canonical path creation
- `bash-safety` — no `cd <dir> && git ...`; use `git -C <path>` for all
  git operations
