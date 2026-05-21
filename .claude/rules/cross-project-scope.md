---
name: cross-project-scope
description: Only llm sessions may work cross-project; all other sessions are own-tree-only and must file issues rather than directly editing other projects.
type: rule
---

# Rule: Cross-Project Scope — Only llm Sessions May Work Cross-Project

## Source

llm#190 + user feedback 2026-05-18 session ("you are supposed to only work on
issues related to this llm project. all issues related to other projects should
be moved over to that project and close that issue in this llm project").

## When This Applies

Every session start. Every time a non-llm session considers acting outside its
own project tree.

## CRITICAL: Only the llm Session Has Cross-Project Authority

The `llm` project is the **only** session allowed to do work across all projects.
All other projects may only do work within their own project tree.

The authority level is declared in each project's `.claude/CLAUDE.md` Project
Identity table:

```markdown
| Cross-project authority | true — this is the meta-config project; may work in any repo |
```

Any project without this declaration, or with `false`, is **own-tree-only**.
The `llm` project is the only one that should ever declare `true`.

## Declaration Mechanism

Add one row to the Project Identity table in `.claude/CLAUDE.md`:

| Value | Meaning |
|-------|---------|
| `true` | Full cross-project authority (llm only) |
| `false` | Own-tree-only (default for all other projects) |
| *(absent)* | Treated as `false` — own-tree-only |

Session-init reports the authority level at startup (see Phase 1d in
`session_init.sh`). This is advisory in Phase 1.

## Decision Table

### What the llm session MAY do

- Edit files in any project under `~/docs_gh/`
- Dispatch agents into any project's worktrees
- Run roborev refine/review on any project
- Create or close GitHub issues in any project
- Update rules, hooks, scripts, templates that affect all projects
- Commission cross-cutting changes that require coordinated edits across repos

### What a non-llm session MAY do

- Edit, run, test, and commit anything within its own project tree
- Create GitHub issues **in the target project** when reporting a finding
  (e.g., mycare session filing a mycare issue)
- Create a GitHub issue **in llm** when the finding is cross-cutting (affects
  rules, hooks, config, or multiple projects) — this is the ONE allowed
  cross-project action for non-llm sessions
- Read files in other projects for reference (read-only reconnaissance is fine)

### What a non-llm session MUST NOT do

| Forbidden action | Why |
|-----------------|-----|
| Edit files outside its own project tree | Creates untracked mutations with no audit trail |
| Dispatch agents into other projects' worktrees | bypassPermissions bounded to this project |
| Run `roborev refine` or `roborev comment` on other repos | Muddles provenance |
| Create or close issues in other projects (except the two cases above) | Cross-project filing is llm's job |
| Fix cross-cutting config/rule/tooling issues in place | These belong in llm; file an issue there |
| Call `git -C ~/docs_gh/<other-project>` to mutate state | Worktree isolation breach |

## Reporting Cross-Cutting Issues

When a non-llm session encounters an issue that clearly belongs elsewhere:

1. **Own-project issue**: file it in this project's GitHub repo (standard)
2. **Another project's issue**: file it in that project's GitHub repo. Note the source session in the issue body ("Found during mycare session on 2026-05-18").
3. **Cross-cutting issue** (rules, hooks, global config, two or more projects): file it in `llm` with label `cross-project`. Summarise what you found. Let the llm session execute the fix.

Do NOT attempt to implement the fix from the non-llm session. File, then stop.

## Session-Init Reporting

`session_init.sh` Phase 1d reads `$PWD/.claude/CLAUDE.md` and emits one line:

```
project-scope: cross-project=YES   # llm sessions
project-scope: own-tree-only       # all other sessions
```

If `.claude/CLAUDE.md` is absent or has no `Cross-project authority` row, the
default is `own-tree-only`.

## Forbidden Patterns

| Pattern | Why wrong | Fix |
|---------|-----------|-----|
| mycare session edits `~/docs_gh/llm/.claude/rules/foo.md` | Own-tree-only breach | File llm issue; let llm session fix |
| historical session dispatches agent into irishbuoys worktree | Cross-project dispatch | File issue in target project |
| footbet session closes an llm issue | Not that session's scope | llm session closes its own issues |
| Any session sets `Cross-project authority: true` except llm | Authority escalation | Revert; only llm may declare true |
| Non-llm session "just fixes a tiny thing" in a shared config | Starts with tiny, drifts large | File an issue; delegate to llm |

## Phase 2 Note

Phase 1 (this rule) is **advisory**. Hook enforcement — blocking Edit/Write/Bash
calls that target paths outside the session's declared scope — is tracked
separately and will be implemented only if Phase 1 violations are observed.

Phase 2 will add a PreToolUse hook that:
1. Resolves the canonical project root for the target path
2. Compares it to the current session's project root
3. Exits non-zero (blocking the call) if they differ AND the session lacks
   cross-project authority
4. Allows exceptions for `/tmp/*`, read-only reconnaissance, and
   cross-cutting issue creation

## Related

- `permission-discipline` — workspace modes, bypassPermissions scoping
- `auto-delegation` — isolation: worktree for agent dispatches
- `destructive-ops-guard` — hook-level blocking for API destructive ops
- llm#190 — origin issue and acceptance criteria
- llm#181 — Theme 1 audit (related agent-isolation hardening)
