# agent_runs Undercount Audit — Issue #491-b

**Date**: 2026-06-04  
**Analyst**: data-engineer agent  
**DB**: `~/.claude/logs/unified.duckdb`  
**Branch**: feat/491b-agent-runs-audit

---

## Schema

```sql
agent_runs (id, session_id, agent_type, model, started_at, ended_at,
            duration_sec, prompt_preview, status, tool_use_id, backfilled)
```

## Current Counts

| Metric | Count |
|--------|-------|
| Total rows | 147 |
| Today (2026-06-04) | 7 |
| Status = 'running' (stuck) | 23 |
| Status = 'done' | 124 (after today's rows) |
| agent_type = 'unknown' | 49 |
| model = 'inherited' | 82 |
| model = 'unknown' | 49 |

## Root Cause 1: 23 Stuck `running` Rows

**What**: PreToolUse fired for 23 dispatches but PostToolUse never completed the UPDATE.  
**Dates**: May 28 – June 1, 2026 (all fixer-type agents).  
**Why**: The `agent_stop` path in `log_session.sh` does three UPDATE attempts:
  1. By `tool_use_id` — should match but appears to have missed
  2. By session_id + agent_type + status='running' — fallback
  3. INSERT new row — last resort

The RETURNING clause in step 1 only fires if the row is updated. Evidence suggests
the PostToolUse hook either: (a) fired with a different session_id (session rolled),
(b) tool_use_id mismatch due to quoting, or (c) hook exited early (`.current_session`
file gone by PostToolUse time).

**Fix**: UPDATE all stuck rows to `status='timed_out'` where `started_at < NOW() - INTERVAL '2 hours'`.

## Root Cause 2: 49 `unknown` Rows (Historical)

**What**: `agent_type='unknown'` and `model='unknown'` for all 49 rows.  
**Dates**: All before May 25, 2026 — pre-hook-rewrite era.  
**Why**: Legacy hook implementation wrote agent_type/model as empty string which
`log_session.sh` stored as 'unknown'. The `log_agent_run.sh` rewrite on May 25
corrected this with the `_agent_type="general-purpose"` fallback.  
**Fix**: Not fixable retroactively without session transcript backfill. Document as known gap.

## Root Cause 3: `Task` Tool Not Captured

**What**: `settings.json` wires `log_agent_run.sh` only for the `Agent` matcher.  
**Impact**: If orchestrators use `Task` tool dispatches, those are invisible to `agent_runs`.  
**Evidence**: `hook_events` table has only 1 row; `errors` table has only 1 row.
Their respective producers (`log_session.sh hook` and `log_session.sh error`) are
never called by any active hook.  
**Fix**: Add `Task` matcher to `settings.json` `PreToolUse` and `PostToolUse` entries.
The `log_agent_run.sh` hook already reads `.tool_input.subagent_type` which is the
correct field for Task tool inputs too.

## Root Cause 4: `model='inherited'` (82 rows)

**What**: 82 rows have `model='inherited'` — the hook's fallback when `.tool_input.model`
is absent from the Agent dispatch payload.  
**Assessment**: NOT a bug. The orchestrator often dispatches without specifying a model,
letting the harness inherit the session default. The 'inherited' value accurately reflects
the dispatch parameters.  
**Fix**: None needed for accuracy. Could be enriched post-hoc from session metadata if needed.

## Fix Plan

### Fix 1: Mark stuck running rows as timed_out
```sql
UPDATE agent_runs 
SET status = 'timed_out', 
    ended_at = started_at + INTERVAL '1 hour',
    duration_sec = 3600
WHERE status = 'running' 
  AND started_at < CURRENT_TIMESTAMP - INTERVAL '2 hours';
```

### Fix 2: Add Task matcher to settings.json
Add to `PreToolUse` hooks array:
```json
{"matcher": "Task", "hooks": [{"type": "command", "command": "~/.claude/hooks/log_agent_run.sh"}]}
```
Add to `PostToolUse` hooks array:
```json
{"matcher": "Task", "hooks": [{"type": "command", "command": "~/.claude/hooks/log_agent_run.sh"}]}
```

### Non-fix: Historical unknown rows
Document as known gap (pre-May-25-2026). Backfill from JSONL transcripts is theoretically
possible but expensive — each session transcript would need parsing for Agent tool calls.
Recommend opening a child issue to evaluate feasibility separately.

## self_review_stage1.sql Impact

The stuck-loop detector (reads `agent_runs WHERE status='running' AND started_at > 1h ago`)
currently fires on all 23 stuck rows, generating false positives. After Fix 1, the detector
will only fire on genuinely stuck dispatches from the current session.

---

**Conclusion**: The hook infrastructure is sound for current sessions (7 rows captured today).
The two actionable fixes are: (1) mark orphaned running rows as timed_out, (2) add Task
matcher to capture Task-tool dispatches.
