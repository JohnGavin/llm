# Companion: Unified Observability Schema — Worked Example

Worked code example split out of the always-loaded
[`unified-observability-schema`](../unified-observability-schema.md) rule to
keep it under the rules size limit. The normative content (the 5-Dim Model,
Canonical Tables, Data Quality Incidents, How to Add a New Event Type,
Forbidden Patterns) stays in the rule; this file is the runnable snippet,
loaded on demand.

## `hook_events` writer — worked bash example

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
