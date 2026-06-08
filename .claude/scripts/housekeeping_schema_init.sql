-- housekeeping_schema_init.sql
-- Unified DuckDB schema for the overnight housekeeping framework.
--
-- Tables:
--   worktree_gc_events     -- one row per worktree inspected/removed/skipped by any writer
--   housekeeping_runs      -- one row per cron/script invocation (heartbeat)
--   config_events          -- one row per config-file change detected by config_digest_cron.sh
--   kb_events              -- one row per knowledge-base change detected by kb_digest_daily_cron.sh
--   launchd_health_events  -- one row per launchd plist's last-observed state (llm#554)
--   roborev_daily_summary  -- per-project daily summary mirrored from roborev SQLite (llm#555)
--
-- All writers follow unified-observability-schema: id, session_id, source,
-- action, reason, fired_at / started_at + task-specific columns.
--
-- Apply with:
--   bash .claude/scripts/housekeeping_schema_apply.sh
--
-- Tracked in llm#550 Phase B, llm#552 Phase B, llm#553 Phase B, llm#554 Phase B, llm#555 Phase B.

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
-- TODO: consider UNIQUE (plist_label, fired_at) constraint -- see llm#567.
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

-- roborev_daily_summary: per-project daily summary mirrored from roborev's
-- own SQLite DB at ~/.roborev/reviews.db. Read-only bridge -- roborev keeps
-- owning its data; we just mirror per-project aggregates here so the 06:30
-- digest can render a roborev section without crossing DB boundaries.
-- One row per (project, window_end) -- daily aggregation.
--
-- Severity values in roborev output text: High | Medium | Low (NOT Critical/Major/Minor).
-- The issue body used critical/medium/low naming; this schema uses roborev's
-- actual terminology (high_open, medium_open, low_open) to match the source.
--
-- Project canonical naming follows data-glossary-and-entity-resolution rule (#474):
-- use repos.name from roborev (lowercase basename as stored by roborev itself).
-- No alias translation needed -- roborev already owns the canonical name.
-- Canonical names: llm, llmtelemetry, mycare, historical, etc.
--
-- Natural key is (project, window_end); uniqueness enforced via deterministic PK
-- (md5("<project>:<window_date>") formatted as UUID).
-- TODO: add UNIQUE (project, window_end) constraint -- see llm#567.
-- See llm#555 Phase B.
CREATE TABLE IF NOT EXISTS roborev_daily_summary (
  id                          TEXT PRIMARY KEY,
  fired_at                    TIMESTAMPTZ NOT NULL,       -- when the bridge ran
  window_start                TIMESTAMPTZ NOT NULL,
  window_end                  TIMESTAMPTZ NOT NULL,
  project                     TEXT NOT NULL,              -- canonical project name from roborev repos.name
  total_reviews_open          INTEGER,
  total_reviews_closed_today  INTEGER,
  high_open                   INTEGER,                    -- Severity: High (roborev actual terminology)
  medium_open                 INTEGER,                    -- Severity: Medium
  low_open                    INTEGER,                    -- Severity: Low
  oldest_open_days            INTEGER,
  autoclose_today             INTEGER,
  source_db_path              TEXT NOT NULL,              -- which roborev DB was read
  detail_json                 TEXT                        -- top-3 findings JSON for digest context
);
CREATE INDEX IF NOT EXISTS idx_roborev_daily_summary_fired_at ON roborev_daily_summary(fired_at);
CREATE INDEX IF NOT EXISTS idx_roborev_daily_summary_project_window ON roborev_daily_summary(project, window_end);

CREATE INDEX IF NOT EXISTS idx_worktree_gc_events_fired_at ON worktree_gc_events(fired_at);
CREATE INDEX IF NOT EXISTS idx_housekeeping_runs_task_started ON housekeeping_runs(task, started_at);
CREATE INDEX IF NOT EXISTS idx_config_events_fired_at ON config_events(fired_at);
CREATE INDEX IF NOT EXISTS idx_kb_events_fired_at ON kb_events(fired_at);
CREATE INDEX IF NOT EXISTS idx_launchd_health_events_fired_at ON launchd_health_events(fired_at);
CREATE INDEX IF NOT EXISTS idx_launchd_health_events_plist ON launchd_health_events(plist_label, fired_at);
