# Companion: Worktree Location Convention — Rationale, Origin Incident, Enforcement Detail

Rationale, incident narrative and verbose detail split out of the
always-loaded [`worktree-location`](../worktree-location.md) rule to keep it
under the repo's 150-line limit. The normative content (required path form,
wrapper script summary, Forbidden Patterns, canonical-checkout verification,
worktree-parent-dir prohibition, Related) stays in the rule; this file holds
the verbatim text moved out of it, loaded on demand.


## Sections Moved from the Rule Body (2026-09-21 line-limit pass)

Original verbatim text moved out of the rule; the normative summary stays in the rule.

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

The previous convention was `~/worktrees/<project>/<branch>/`. Existing
worktrees there remain valid until they finish their lifecycle — do NOT
mass-migrate live worktrees. No NEW worktrees go to the legacy base.
`worktree_gc.sh` sweeps both bases; `cc.sh`'s worktree-parent redirect and
session-init Phase 1e recognise both. The `~/worktrees/` references die
with the last legacy worktree.

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

**Origin:** 2026-09-18/19, mycare project. An agent worked an entire session
in `~/docs_gh/worktrees/mycare/feat/cc-20260907-100559` — found via a
`docs_gh`-scoped search and picked because it had the most recent commit
timestamp among the worktrees that search surfaced — while the actual live
checkout was `~/docs_/pers/NHS_health/data/antigravity/mycare/` on `main`,
kept outside `docs_gh` specifically because it holds real patient data. The
two had genuinely diverged: `main` already had independent, more current
work (new issues at numbers the stray branch's new issues collided with,
a same-day document already captured under a different, correct
convention). The stray branch's commits had to be re-derived and re-applied
on the real `main` by hand, and the stray worktree/branch deleted.

Two layers enforce this:

1. **`cc.sh` auto-redirect (primary).** If launched anywhere under
   `~/docs_gh/worktrees/<project>/` that is not a real worktree, the wrapper `cd`s to
   `~/docs_gh/<project>/` and prints a one-line note before exec'ing `claude`.
   Set `CC_NO_REDIRECT=1` to skip (rarely needed).
2. **`session_init.sh` Phase 1e (backstop).** If a session somehow starts in a
   worktree-parent (e.g. `claude` invoked directly, not via `cc.sh`), Phase 1e
   prints a `WORKTREE-PARENT:` block listing the active worktrees and the two
   valid `cd` targets. Advisory — does not block.
