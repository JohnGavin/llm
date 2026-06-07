-- housekeeping_schema_init.sql
-- Unified DuckDB schema for the overnight housekeeping framework.
--
-- Tables:
--   worktree_gc_events  — one row per worktree inspected/removed/skipped by any writer
--   housekeeping_runs   — one row per cron/script invocation (heartbeat)
--
-- All writers follow unified-observability-schema: id, session_id, source,
-- action, reason, fired_at / started_at + task-specific columns.
--
-- Apply with:
--   bash .claude/scripts/housekeeping_schema_apply.sh
--
-- Tracked in llm#550 Phase B.

CREATE TABLE IF NOT EXISTS worktree_gc_events (
  id                TEXT PRIMARY KEY,
  fired_at          TIMESTAMPTZ NOT NULL,
  source            TEXT NOT NULL,           -- 'worktree_gc.sh' | 'session_init_phase7f' | 'session_init_phase1e' | 'cc.sh'
  session_id        TEXT,                    -- NULL for cron-driven
  location_pattern  TEXT NOT NULL,           -- which sweep pattern matched
  project           TEXT,
  worktree_path     TEXT NOT NULL,
  branch            TEXT,
  action            TEXT NOT NULL,           -- 'removed' | 'skipped_locked' | 'skipped_uncommitted' | 'skipped_age' | 'skipped_cwd' | 'skipped_main' | 'flagged' | 'archived'
  reason            TEXT,
  size_mb           INTEGER
);

CREATE TABLE IF NOT EXISTS housekeeping_runs (
  id              TEXT PRIMARY KEY,
  task            TEXT NOT NULL,             -- 'worktree_gc' | 'config_digest' | 'kb_digest' | 'launchd_health' | 'roborev_bridge' | 'stage1_findings' | 'self_review_verify'
  source_script   TEXT NOT NULL,             -- absolute path to script
  started_at      TIMESTAMPTZ NOT NULL,
  ended_at        TIMESTAMPTZ,
  status          TEXT NOT NULL,             -- 'ok' | 'failed' | 'partial'
  rows_written    INTEGER DEFAULT 0,
  error_text      TEXT,
  detail_json     TEXT
);

CREATE INDEX IF NOT EXISTS idx_worktree_gc_events_fired_at ON worktree_gc_events(fired_at);
CREATE INDEX IF NOT EXISTS idx_housekeeping_runs_task_started ON housekeeping_runs(task, started_at);
