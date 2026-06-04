# Issue #492 — AGENTS.md audit analysis

## What the audit checks

`.claude/scripts/agents_md_audit.sh` (invoked by `session_init.sh` Phase 11)
compares **section header counts** in `AGENTS.md` against the **live filesystem**:

| AGENTS.md header | Filesystem source |
|---|---|
| `## Agents (N)` | `~/.claude/agents/*.md` |
| `## Skills (N)` | `~/.claude/skills/*/` |
| `## Commands (N)` | `~/.claude/commands/*.md` |
| `## Rules (N)` | `~/.claude/rules/*.md` |
| `## Memory (N files at ...)` | `~/.claude/projects/<proj>/memory/*.md` |

There is **no separate canonical mapping file**. The audit is "header count vs
live filesystem", not "list-of-rules vs list-of-rules". The mandatory-rules row
that PR #487 modified is NOT inspected by the audit.

## What the audit does NOT check

- The `**Mandatory rules:**` inline list (the row #487 modified)
- The `**Mandatory skills:**` inline list
- Any cross-reference between AGENTS.md content and rule/skill file existence
- The Hooks header (only counts `*.sh`, but Hooks header has a free-form label)

## Was the drift from #487?

No. PR #487's AGENTS.md diff (commit `8eb4cb6`) only changed one line: it added
`mermaid-dashboard-pattern` to the inline mandatory-rules list. It did NOT
touch the four section headers (`## Skills`, `## Rules`, `## Commands`,
`## Memory`).

The drift the audit reported on 2026-06-04 was **pre-existing**: multiple
skills/rules/commands/memory files had accumulated since the headers were last
updated. #487 was the most recent of many additions.

```
AGENTS.md: DRIFT skills:65→73 rules:54→67 cmds:15→20 mem:16→18
```

## Fix applied

Bumped the four stale section headers in `AGENTS.md` to match the live
filesystem at the time of fix:

| Section | Was | Now |
|---|---|---|
| Skills | 65 | 73 |
| Rules | 54 | 67 |
| Commands | 15 | 20 |
| Memory | 16 | 18 |

Audit after fix: `AGENTS.md: ok (12a 73s 67r 20c 18m)` (exit 0).

## Why this will keep happening

Every new skill, rule, command, or memory file added under `~/.claude/`
shifts the live count. AGENTS.md's section header is a manually-maintained
number. Future-proofing options (out of scope here):

1. Make the header generic: `## Skills` (no count) — audit would need to skip
   when count is absent
2. Auto-bump the header from a pre-commit hook
3. Track via `make audit-fix` that rewrites the four numbers in place

For now: bump the counts when the audit DRIFTs.

## Related

- Issue #492 — this analysis
- PR #487 — `mermaid-dashboard-pattern` rule (triggered the user-facing
  WARN, but the rule's addition was not the drift cause)
- `.claude/scripts/agents_md_audit.sh` — the audit script
- `.claude/hooks/session_init.sh` Phase 11 — where the audit runs
