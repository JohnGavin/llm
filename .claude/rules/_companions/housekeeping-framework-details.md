# Companion: Housekeeping Framework — Full Code Templates + Task Inventory

Full code templates and the current task-inventory table split out of the
always-loaded [`housekeeping-framework`](../housekeeping-framework.md) rule to
keep it lean. The normative content (CRITICAL 5-point requirement, the 5
component descriptions, Checklist, Forbidden Patterns) stays in the rule; this
file is the copy-pasteable templates and the descriptive inventory of existing
tasks, loaded on demand.

## 1. Script Skeleton

```bash
# Minimum structure for a housekeeping script
set -euo pipefail
REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

# Auto-pull (cron-auto-pull-discipline)
if [ -z "${SKIP_CRON_PULL:-}" ]; then
  git -C "$REPO_ROOT" fetch origin main 2>/dev/null
  git -C "$REPO_ROOT" merge --ff-only origin/main 2>/dev/null \
    && log "deploy: ff to $(git -C "$REPO_ROOT" rev-parse --short HEAD)"
fi
log "HEAD: $(git -C "$REPO_ROOT" rev-parse --short HEAD) $(git -C "$REPO_ROOT" log -1 --format='%s')"

# Insert housekeeping_runs start row
# ... task work ...
# Update housekeeping_runs end row
```

## 2. Launchd Plist Template

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.claude.my-task</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>/Users/johngavin/docs_gh/llm/.claude/scripts/my_task_cron.sh</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>  <integer>0</integer>
    <key>Minute</key><integer>4</integer>
  </dict>
  <key>StandardOutPath</key>
  <string>/Users/johngavin/.claude/logs/my_task.log</string>
  <key>StandardErrorPath</key>
  <string>/Users/johngavin/.claude/logs/my_task.err</string>
</dict>
</plist>
```

## 3. Events Table + `housekeeping_runs` DDL

```sql
CREATE TABLE IF NOT EXISTS my_task_events (
  id         TEXT PRIMARY KEY,
  fired_at   TIMESTAMPTZ NOT NULL,   -- WHEN
  source     TEXT NOT NULL,           -- WHO (script name)
  session_id TEXT,                    -- WHO (NULL for cron)
  action     TEXT NOT NULL,           -- WHAT
  reason     TEXT,                    -- HOW (why this action)
  detail_json TEXT                    -- task-specific payload
);
```

Use `INSERT OR IGNORE` for idempotency. Write one row per item inspected.

Every script invocation MUST also write to `housekeeping_runs`:

```sql
-- At invocation start
INSERT OR IGNORE INTO housekeeping_runs
  (id, task, source_script, started_at, status, rows_written)
VALUES ('<uuid>', 'my_task', '/path/to/script.sh', current_timestamp, 'ok', 0);

-- At invocation end (UPDATE the same row)
UPDATE housekeeping_runs
SET ended_at = current_timestamp,
    rows_written = <N>,
    status = 'ok'        -- or 'failed' / 'partial'
WHERE id = '<uuid>';
```

## Existing Task Inventory

| Task | Script | Launchd plist | Events table | Email section | Session-init phase |
|------|--------|---------------|--------------|---------------|--------------------|
| Worktree GC | `worktree_gc.sh` | `com.claude.worktree-gc` (00:04) | `worktree_gc_events` | Section 3b (24h footprint) | Phase 7f (agent only) |
| Stage-1 findings | `self_review_stage1.sh` | `com.claude.self-review-stage1` (02:30) | `self_review_findings_stage1` | Section 1 (new findings) | — |
| Overnight email | `send_overnight_self_review_email.R` | `com.claude.overnight-self-review-email` (06:30) | — (writer) | — (is the email) | — |
| roborev autoclose | `roborev_autoclose.sh` | `com.claude.roborev-autoclose` (09:15 weekly) | — (roborev DB) | — | Phase 8 (roborev status) |
| KB digest | `kb_digest_daily_cron.sh` | `com.claude.kb-digest-email` (07:00) | — | — | — |
