# Diagnosis: hook_events + errors ETL Dead Tables

**Issue:** JohnGavin/llm#491
**Branch:** feat/491a-hook-events-etl-diag
**Diagnosed:** 2026-06-04

---

## Executive Summary

Both `hook_events` and `errors` tables in `~/.claude/logs/unified.duckdb` have
been effectively dead since their creation. Each contains exactly one row, both
of which are manual test inserts from the original wiring commit (`0ca76f2`,
2026-04-24). No real production data has ever entered either table.

Root causes are distinct for each table:

- **`hook_events`**: One caller exists (`context_monitor.sh`) but it only fires
  when `CLAUDE_CONTEXT_USAGE_PERCENT > 0`. That env var is never reliably set —
  the hook exits at line 13 before reaching the insert call.

- **`errors`**: Zero callers. The `error` action exists in `log_session.sh` but
  nothing in any hook or script ever invokes it.

---

## Evidence

### Database state (queried 2026-06-04)

```
hook_events (1 row):
  id=1, session_id='test-session', hook_name='context_monitor',
  event_type='PostToolUse', fired_at=2026-04-24 09:20:23
  → Manual test insert. session_id='test-session' is a literal placeholder.

errors (1 row):
  id=1, session_id='BCAF1C31-730A-43BD-85A2-7E2724673983',
  source='signal_notes', error_text='your signal message text here',
  context='llm', logged_at=2026-04-20 19:27:15
  → Manual test insert. error_text is placeholder text from the wiring commit.
```

### Git history for log_session.sh

```
0ca76f2  2026-04-24  "wiring commit — Tested: hook_events=1 row, agent_runs=1 row"
d2ce9e7             fix agent_runs completion
2e039a4  2026-05-23  refactor to use -init /dev/null
```

The single test rows were inserted as part of `0ca76f2`. No subsequent commits
inserted additional real rows.

---

## Root Cause: hook_events

### Only caller: context_monitor.sh (PostToolUse:Bash|Task)

`context_monitor.sh` lines 13–15:
```bash
USAGE_PCT="${CLAUDE_CONTEXT_USAGE_PERCENT:-0}"
if [ "$USAGE_PCT" -eq 0 ] 2>/dev/null; then
  exit 0
fi
```

The hook exits early when `CLAUDE_CONTEXT_USAGE_PERCENT` is zero or unset.
The DuckDB insert (line 39) is BELOW this early exit and therefore never reached.
`CLAUDE_CONTEXT_USAGE_PERCENT` is rarely populated in practice; the hook
effectively always exits at line 14.

The hook IS properly wired in `settings.json` under `PostToolUse` with
`matcher: "Bash|Task"` — the wiring is correct, the logic is the problem.

### Active canonical log files (confirmed 2026-06-04)

These log files are actively written to, proving the underlying hooks fire:
```
~/.claude/logs/compound_guard.log       1.8 MB   last write: 2026-06-04 19:19
~/.claude/logs/agent_push_blocked.log   14 KB    last write: 2026-06-04 11:15
~/.claude/logs/destructive_blocked.log  204 KB   last write: 2026-06-04 19:13
~/.claude/logs/worktree_post_verify.log 50 KB    last write: 2026-06-04 19:14
```

---

## Root Cause: errors

### Zero callers

A grep of all hooks and scripts for `log_session.*error` and `log_session.sh error`
returns no results. The `error` action block exists in `log_session.sh` lines 41–47
but is completely unwired.

No hook calls `log_session.sh error ...` anywhere in `.claude/hooks/` or
`.claude/scripts/`.

---

## Fix Strategy

### Fix A: hook_events — make context_monitor.sh fire unconditionally

Move the DuckDB insert BEFORE the early-exit guard on `USAGE_PCT`. The hook
fires on every `PostToolUse:Bash|Task` event; every such event is a meaningful
hook_event to record regardless of context percentage. The context-percentage
threshold only applies to the warning/compression logic that follows.

Specifically: move lines 35–40 (the DuckDB insert block) to BEFORE line 13
(the `if [ "$USAGE_PCT" -eq 0 ]` guard), so the insert runs unconditionally
on every PostToolUse event.

### Fix B: errors — wire blocking hooks to call log_session.sh error

The three hooks that currently only write to flat log files also have access to
a session ID and should call `log_session.sh error` when they block:

1. **compound_command_guard.sh** (mode=block, exit 1): add a call to
   `log_session.sh error` before the `exit 1` block, with `source=compound_guard`
   and the blocked command as `error_text`.

2. **agent_push_guard.sh** (when blocking): add a call to `log_session.sh error`
   before the `exit 2` block, with `source=agent_push_guard`.

3. **destructive_api_guard.sh** (when blocking): add a call to `log_session.sh error`
   before the `exit 1` block, with `source=destructive_api_guard`.

All three hooks already have access to `$HOME/.claude/logs/.current_session` to
retrieve the session ID.

---

## Files to Modify

| File (relative to repo root) | Change |
|---|---|
| `.claude/hooks/context_monitor.sh` | Move DuckDB insert block before the USAGE_PCT=0 early exit |
| `.claude/hooks/compound_command_guard.sh` | Add `log_session.sh error` call in block-mode exit path |
| `.claude/hooks/agent_push_guard.sh` | Add `log_session.sh error` call in both block paths |

### Out of scope for this PR
- `destructive_api_guard.sh`: similar pattern but lower priority; tracked
  as a follow-up in the parent issue.
- Backfill ETL from existing log files: the canonical log files have 40+ days
  of history; a separate backfill script could populate the tables from them.
  Not included in this PR to keep the change small and focused.
