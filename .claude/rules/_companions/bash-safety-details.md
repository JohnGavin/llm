# Companion: Bash Command Safety — Verified Reproduction and One-Time Audit

Verified reproduction output and a one-time completed audit split out of the
always-loaded [`bash-safety`](../bash-safety.md) rule to keep it under the
repo's line-count budget. The normative content (Part 1 compound-command
ban, Part 2 safe-deletion protocol, Part 3 CRITICAL statement and the
`--no-ext-diff` fix, Related) stays in the rule; this file is the verified
live reproduction and the completed 2026-08-29 audit table, loaded on
demand.

## Verified reproduction (live on this machine)

`git config --get diff.external` returns `difft --display inline`, set both
globally and per-repo:

```bash
$ git diff HEAD~1 -- some-changed-file.sh | grep -c '^+'
0
$ git diff --no-ext-diff HEAD~1 -- some-changed-file.sh | grep -c '^+'
10
```

Ten real added lines, zero matches on the default path.

**`GIT_EXTERNAL_DIFF=` (set to empty) does NOT work as a bypass** —
verified: it makes git try to execute an empty string as the diff program,
which fails outright (`error: cannot run : No such file or directory`)
rather than falling back to the built-in differ. Same result for
`git -c diff.external=`. `--no-ext-diff` is the only invocation-scoped
override that actually works.

## Audit of This Repo's Own Scripts (2026-08-29, llm#997)

Grepped `.claude/hooks/**` and `.claude/scripts/**` for `git diff`, `git log
-p`, and `git show` calls whose output feeds a pattern-matching scan.
Result: every content-parsing call site already guards against this —

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
