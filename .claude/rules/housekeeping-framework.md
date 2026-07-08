---
description: 5-point template for recurring housekeeping tasks — script, launchd plist, events table, digest section, session-init phase
paths:
  - ".claude/scripts/**"
  - ".claude/launchd/**"
  - "bin/**"
---

# Rule: Housekeeping Framework (Convention)

## When This Applies

Every new recurring housekeeping task — anything that runs on a schedule (cron /
launchd), fires on a hook (session-init phase), or responds to a user command
(`/cleanup-*`) and whose purpose is maintenance rather than feature work.

Examples: worktree cleanup, log rotation, ETL cache trim, stale-issue triage,
knowledge-base compaction, session-ledger archival.

## Source

JohnGavin/llm#550 — "Unified stale-worktree cleanup". Root cause: worktree GC,
session-init Phase 7f, and manual `/cleanup` all addressed the same problem via
independent, non-communicating code paths. No unified report existed, so the
maintenance load was invisible. The framework was extracted from Phase E as the
repeatable pattern that makes future tasks predictable.

---

## CRITICAL: The 5-Point Template

Every housekeeping task MUST ship all 5 components. A task that ships only some
components is incomplete — it will either produce no report, produce a silent
failure, or duplicate infrastructure that already exists.

### 1. A script under `.claude/scripts/` or `bin/`

Follow `cron-auto-pull-discipline`: auto-pull `origin/main` before running so
every `gh pr merge` actually ships. Log HEAD SHA after the pull. Script must be
idempotent — safe to run multiple times without side effects.

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

### 2. A launchd plist under `.claude/launchd/`

Slot the task into one of five pre-dawn / morning / digest / business-hours /
weekly slots:

| Slot | Time window | Example tasks |
|------|-------------|---------------|
| **pre-dawn detector** | 00:00–04:00 | worktree GC, log rotation, cache trim |
| **morning verifier** | 04:00–06:00 | data freshness checks, CI-failure scans |
| **digest emit** | 06:30 | overnight self-review email, KB digest |
| **business-hours nudge** | 09:00–17:00 | PR-status pulse, config digest |
| **weekly rollup** | Monday AM | roborev weekly summary, stale-issue triage |

Use an existing slot when possible — the 00:04 `com.claude.worktree-gc` plist
already runs `worktree_gc.sh`. Add a new plist only when no existing slot fits.

Minimum plist structure:

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

### 3. An events table in `unified.duckdb`

Follow `unified-observability-schema`: every event row answers WHO / WHAT /
WHEN / WHERE / HOW using the 5-dim model. Minimum columns:

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

### 4. A section in the 06:30 digest email

Extend `send_overnight_self_review_email.R`. Do NOT create a new email job.

Pattern: add a `sec_N_block <- collapsible_block(...)` that queries the task's
events table for the last 24h, and insert it into the `email_body <- paste0(...)`
assembly.

If the task has no 24h data (e.g. runs weekly), the section should emit a
one-liner: "No events in the last 24 h." rather than an empty block.

### 5. A session-init phase (IF task has session-relevant findings)

Add a phase to `session_init.sh` ONLY when the task produces findings that
are actionable at session start (e.g. "N worktrees need triage"). Advisory
output only — no work, no network calls, no blocking. Must have a 5-second
timeout and fail-open (`|| true`).

When adding a phase:
1. Pick a letter suffix in the correct position (see `session-init-phases` rule)
2. Update the phase inventory table in `session-init-phases.md`
3. Keep the phase under 15 lines of logic

---

## Checklist for a New Housekeeping Task

Before considering a task "shipped":

- [ ] Script has auto-pull block (`cron-auto-pull-discipline`)
- [ ] Script inserts `housekeeping_runs` start row; updates it at end
- [ ] Script writes one `my_task_events` row per item inspected
- [ ] `duckdb`-absent guard: script continues when `duckdb` is not in PATH
- [ ] Launchd plist slotted into an existing time window (or new plist justified)
- [ ] Digest email section added to `send_overnight_self_review_email.R`
- [ ] Session-init phase added (if findings are session-actionable)
- [ ] Phase inventory table in `session-init-phases.md` updated
- [ ] `SELFTEST=1` path added to script (run against temp dirs)
- [ ] `housekeeping_schema_apply.sh` updated with new table DDL

---

## Unused-surface census (subtractive-first enforcement)

Realises the Simplicity principle (see `AGENTS.md` Core Rules). Automation/config surface accretes; periodically flag what is unused so it can be pruned under the Chesterton guard. Data sources: the `command_usage` (#747) and `skill_usage` (#744) tables in `~/.claude/logs/unified.duckdb`. A command/skill/rule with zero recorded invocations is a *candidate*, not an automatic deletion: it must ALSO be confirmed covered elsewhere (a hook, pulse, banner field, or sibling command) before removal. This census is advisory — it produces a review list for a human, never auto-deletes. Follow-up: automate it as a `*-pulse` job (tracked separately).

---

## Existing Task Inventory

| Task | Script | Launchd plist | Events table | Email section | Session-init phase |
|------|--------|---------------|--------------|---------------|--------------------|
| Worktree GC | `worktree_gc.sh` | `com.claude.worktree-gc` (00:04) | `worktree_gc_events` | Section 3b (24h footprint) | Phase 7f (agent only) |
| Stage-1 findings | `self_review_stage1.sh` | `com.claude.self-review-stage1` (02:30) | `self_review_findings_stage1` | Section 1 (new findings) | — |
| Overnight email | `send_overnight_self_review_email.R` | `com.claude.overnight-self-review-email` (06:30) | — (writer) | — (is the email) | — |
| roborev autoclose | `roborev_autoclose.sh` | `com.claude.roborev-autoclose` (09:15 weekly) | — (roborev DB) | — | Phase 8 (roborev status) |
| KB digest | `kb_digest_daily_cron.sh` | `com.claude.kb-digest-email` (07:00) | — | — | — |

---

## Forbidden Patterns

| Pattern | Why wrong | Fix |
|---------|-----------|-----|
| New housekeeping script without `housekeeping_runs` row | No heartbeat; monitoring gaps invisible | Add insert/update pattern |
| New email digest job instead of extending the 06:30 email | Email proliferation; reader fatigue | Add a section to `send_overnight_self_review_email.R` |
| Session-init phase that does network calls or file writes | Blocks session start for everyone | Advisory queries only; 5s timeout; fail-open |
| Launchd plist without `StandardOutPath` + `StandardErrorPath` | Errors lost silently | Always add both log path keys |
| Script without `SKIP_CRON_PULL` guard | Can't test without auto-pulling | Wrap auto-pull in `if [ -z "${SKIP_CRON_PULL:-}" ]` |
| Events table without `INSERT OR IGNORE` | Duplicate rows on replay | Add OR IGNORE on the id primary key |

---

## Related

- `cron-auto-pull-discipline` — auto-pull requirement for every cron wrapper
- `unified-observability-schema` — 5-dim model for event tables
- `session-init-phases` — phase inventory; update when adding a session phase
- `worktree-location` — convention this framework's GC task cleans up to
- `branch-salvage-workflow` — patch-id detection used by `worktree_gc.sh`
- `housekeeping_schema_apply.sh` — applies `worktree_gc_events` and `housekeeping_runs` DDL
- llm#550 — origin issue (Phases A–E)
- llm#199 — original `worktree_gc.sh` ticket
