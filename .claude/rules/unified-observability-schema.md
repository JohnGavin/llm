---
name: unified-observability-schema
description: Every observable event (hook fired, agent dispatched, command run, finding logged, error) flows into ONE DuckDB at ~/.claude/logs/unified.duckdb. No project invents its own log file or sqlite DB for these signals.
metadata:
  type: rule
paths:
  - ".claude/hooks/**"
  - ".claude/scripts/**"
  - "bin/**"
  - "**/*.sql"
---

# Rule: Unified Observability Schema (Mandatory)

## When This Applies

Every new logging surface, every hook that wants to record state, every script
that emits events, and every agent run. Applies to:

- New hooks in `~/.claude/hooks/` that fire on tool calls
- New agents that produce structured output (runs, findings, decisions)
- New session-management scripts (`session_init.sh`, `session_stop.sh`, etc.)
- New quality-gate checks that produce per-event findings
- Any shell script or R code that currently writes to a custom log file or
  a project-local SQLite/DuckDB

## CRITICAL: One DuckDB, One Schema Family, All Projects

Every observable event in the stack writes to a single unified DuckDB at
`~/.claude/logs/unified.duckdb`. This is a user-level store, not a
project-level one — all projects share it. The reasons a unified store
matters: (1) cross-session and cross-project queries become trivial JOIN
operations; (2) the overnight self-review job (`self_review_stage1.sql`) can
reason about the full system without stitching together custom log formats;
(3) drift over time is visible because cause-and-effect chains are traceable
in a single query. A custom per-project log file or a second DuckDB silently
breaks all of those properties.

## The 5-Dim Model

Every event row answers five questions. Map new events to these columns:

| Dimension | Column(s) | Example values |
|---|---|---|
| **WHO** | `session_id`, `agent_id` | `cc-20260604-102303`, `agent-aacf1e88` |
| **WHAT** | `event_type` | `roborev_post_review`, `claude_edit_file`, `hook_fired`, `git_commit` |
| **WHEN** | `timestamp` / `fired_at` / `started_at` | ISO-8601 UTC |
| **WHERE** | `project`, `repo`, `file_path` | `llm`, `JohnGavin/llm`, `R/foo.R` |
| **HOW** | `status`, `error_text`, `duration_ms` | `ok`, `failed`, `1234` |

Not every table has all five columns. Small lookup tables (e.g., `sessions`)
carry WHO + WHEN + WHERE. Event tables (e.g., `hook_events`, `agent_runs`)
carry all five.

## Canonical Tables

The following tables are the blessed sinks in `unified.duckdb`. Write to
these before proposing a new table:

| Table | Primary signal | Key columns |
|---|---|---|
| `sessions` | One row per Claude Code session | `session_id`, `project`, `started_at`, `ended_at`, `model` |
| `agent_runs` | One row per subagent dispatch | `id`, `session_id`, `agent_type`, `model`, `started_at`, `ended_at`, `status` |
| `hook_events` | One row per hook fire | `id`, `session_id`, `hook_name`, `event_type`, `fired_at`, `duration_ms`, `output_preview` |
| `errors` | One row per error/exception | `id`, `session_id`, `source`, `error_text`, `context`, `logged_at` |
| `roborev_reviews` | One roborev review result | `id`, `repo`, `commit_sha`, `severity`, `finding_text`, `created_at`, `closed` |
| `roborev_findings` | Individual finding rows | `id`, `review_id`, `file`, `line`, `severity`, `body` |
| `self_review_findings_stage1` | Overnight detector findings | `finding_id`, `finding_type`, `session_id`, `severity`, `evidence`, `detected_at` |

## How to Add a New Event Type

1. **Check the canonical table list above.** If an existing table covers
   the new event (e.g., it is a hook fire → use `hook_events`), write to
   that table. No new schema needed.

2. **If no table fits**, draft a minimal schema with at least the five
   dimension columns. Post a schema proposal as a comment on the issue or
   PR before landing code — one reviewer must acknowledge it.

3. **Write a thin shell or R helper** that INSERTs the row. Keep the helper
   under 30 lines. Do NOT embed SQL strings in hook logic; source the helper.

4. **Add an `INSERT OR IGNORE` guard** using the primary-key or a
   content-hash so replaying the writer is safe.

5. **Test the insert locally** with `duckdb ~/.claude/logs/unified.duckdb`
   and a `SELECT *` from the target table before committing.

6. **Do NOT migrate all existing writers in the same PR.** Each writer
   migration is a separate PR referencing the issue.

## Worked Example

```bash
# hook_events writer (pure bash, ~15 lines)
_db="${HOME}/.claude/logs/unified.duckdb"
_session="${CLAUDE_SESSION_ID:-unknown}"
_fired="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
_hook="compound_guard.sh"
_type="compound_command_blocked"
_preview="${1:-}" # first 120 chars of the blocked command

duckdb "$_db" <<SQL
INSERT OR IGNORE INTO hook_events
  (id, session_id, hook_name, event_type, fired_at, duration_ms, output_preview)
VALUES (
  gen_random_uuid()::VARCHAR,
  '${_session}',
  '${_hook}',
  '${_type}',
  TIMESTAMPTZ '${_fired}',
  NULL,
  '${_preview}'
);
SQL
```

The same pattern applies in R using `DBI::dbExecute()` against the same path.

## Forbidden Patterns

| Pattern | Why wrong | Fix |
|---|---|---|
| `sqlite3 ~/.claude/myproject.db "INSERT ..."` | Custom per-project DB; invisible to unified queries | Use `duckdb ~/.claude/logs/unified.duckdb` + canonical table |
| `duckdb /tmp/project_events.duckdb ...` | Project-local DuckDB; breaks cross-session joins | Write to `unified.duckdb` |
| `echo "$(date) event" >> ~/.claude/logs/custom.log` | Unstructured flat file; can't JOIN | Add a row to `hook_events` or `errors` |
| `echo "finding: ..." >> knowledge/wiki/findings.md` | Wiki is human-readable narrative, not structured data | Use `self_review_findings_stage1` |
| `roborev_reviews.db` at a project-specific path | Siloed signal; roborev dashboard won't see it | Write to `~/.claude/logs/unified.duckdb` roborev tables |
| New table with no WHO + WHEN columns | Cannot trace event to session or time | Always include `session_id` + a timestamp column |

## Related

- `external-code-zero-trust` — no custom log writers from third-party SaaS
- `permission-discipline` — unified.duckdb is a user-level file; no project
  should have write access via a credential other than the shell user
- `cron-auto-pull-discipline` — scheduled jobs that write events must use
  this schema, not custom files
- `data-glossary-and-entity-resolution` (#474) — entity identifiers
  (`session_id`, `agent_id`, `repo`) must match the canonical glossary before
  being written into unified.duckdb
- `.claude/scripts/self_review_stage1.sql` — the canonical consumer of these
  tables; any new table must have a corresponding detector or be documented
  as "Phase 2"
- [#475](https://github.com/JohnGavin/llm/issues/475) — origin issue
- [#450](https://github.com/JohnGavin/llm/issues/450) — parent design tracker
  (Salesforce 8 Principles, Principle 3: Enable unified observability)
