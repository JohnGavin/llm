-- housekeeping_schema_init.sql
-- Unified DuckDB schema for the overnight housekeeping framework.
--
-- Tables:
--   worktree_gc_events     -- one row per worktree inspected/removed/skipped by any writer
--   housekeeping_runs      -- one row per cron/script invocation (heartbeat)
--   config_events          -- one row per config-file change detected by config_digest_cron.sh
--   kb_events              -- one row per knowledge-base change detected by kb_digest_daily_cron.sh
--   launchd_health_events  -- one row per launchd plist's last-observed state (llm#554)
--
-- All writers follow unified-observability-schema: id, session_id, source,
-- action, reason, fired_at / started_at + task-specific columns.
--
-- Apply with:
--   bash .claude/scripts/housekeeping_schema_apply.sh
--
-- Tracked in llm#550 Phase B, llm#552 Phase B, llm#553 Phase B, llm#554 Phase B.

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

-- config_events: one row per config-file change detected by config_digest_cron.sh.
-- Written by bin/config_digest_cron.sh after Step 1 (generate digest) completes.
-- Queried by the 06:30 digest to surface the "Config changes (24h)" section.
-- See llm#552 Phase B.
CREATE TABLE IF NOT EXISTS config_events (
  id            TEXT PRIMARY KEY,
  fired_at      TIMESTAMPTZ NOT NULL,
  source        TEXT NOT NULL,                 -- 'config_digest_cron.sh'
  file_path     TEXT NOT NULL,                 -- relative to repo root
  change_type   TEXT NOT NULL,                 -- 'added' | 'modified' | 'removed' | 'permission_change'
  diff_summary  TEXT,
  diff_lines    INTEGER,
  commit_sha    TEXT
);

-- kb_events: one row per knowledge-base change detected by kb_digest_daily_cron.sh.
-- Written after the markdown digest is generated.
-- Queried by the 06:30 digest to surface the "Knowledge base (24h)" section.
-- See llm#553 Phase B.
CREATE TABLE IF NOT EXISTS kb_events (
  id            TEXT PRIMARY KEY,
  fired_at      TIMESTAMPTZ NOT NULL,
  source        TEXT NOT NULL,                 -- 'kb_digest_daily_cron.sh'
  layer         TEXT NOT NULL,                 -- 'raw' | 'wiki' | 'outputs'
  path          TEXT NOT NULL,                 -- relative to knowledge/
  action        TEXT NOT NULL,                 -- 'created' | 'modified' | 'flagged_no_sources' | 'flagged_ai_inferred' | 'broken_link'
  details       TEXT,
  commit_sha    TEXT
);

-- launchd_health_events: one row per launchd plist's last-observed state.
-- Written by launchd_health_weekly_cron.sh (per-plist row, one batch per run).
-- Queried by the 06:30 digest to surface the "Cron health (last fire)" section.
-- A missing or stale row for any plist is the meta-check that flags broken cron jobs.
-- Natural key is (plist_label, fired_at); uniqueness enforced by primary key on id.
-- TODO: consider UNIQUE (plist_label, fired_at) constraint — see llm#567.
-- See llm#554 Phase B.
CREATE TABLE IF NOT EXISTS launchd_health_events (
  id              TEXT PRIMARY KEY,
  fired_at        TIMESTAMPTZ NOT NULL,
  source          TEXT NOT NULL,           -- 'launchd_health_weekly_cron.sh'
  plist_label     TEXT NOT NULL,           -- e.g. 'com.claude.worktree-gc'
  state           TEXT NOT NULL,           -- 'loaded_ok' | 'loaded_recent_fail' | 'unloaded' | 'missing' | 'orphan'
  last_exit_code  INTEGER,
  last_fired_at   TIMESTAMPTZ,             -- from launchctl print (NULL when not parseable)
  next_fire_at    TIMESTAMPTZ,             -- from launchctl print (NULL when not scheduled/parseable)
  detail          TEXT
);

CREATE INDEX IF NOT EXISTS idx_worktree_gc_events_fired_at ON worktree_gc_events(fired_at);
CREATE INDEX IF NOT EXISTS idx_housekeeping_runs_task_started ON housekeeping_runs(task, started_at);
CREATE INDEX IF NOT EXISTS idx_config_events_fired_at ON config_events(fired_at);
CREATE INDEX IF NOT EXISTS idx_kb_events_fired_at ON kb_events(fired_at);
CREATE INDEX IF NOT EXISTS idx_launchd_health_events_fired_at ON launchd_health_events(fired_at);
CREATE INDEX IF NOT EXISTS idx_launchd_health_events_plist ON launchd_health_events(plist_label, fired_at);
