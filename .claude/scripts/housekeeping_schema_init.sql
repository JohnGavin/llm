-- housekeeping_schema_init.sql
-- Unified DuckDB schema for the overnight housekeeping framework.
--
-- Tables:
--   worktree_gc_events     -- one row per worktree inspected/removed/skipped by any writer
--   branch_gc_events       -- one row per local branch inspected/deleted/skipped (llm#585)
--   housekeeping_runs      -- one row per cron/script invocation (heartbeat)
--   config_events          -- one row per config-file change detected by config_digest_cron.sh
--   kb_events              -- one row per knowledge-base change detected by kb_digest_daily_cron.sh
--   launchd_health_events  -- one row per launchd plist's last-observed state (llm#554)
--   roborev_daily_summary  -- per-project daily summary mirrored from roborev SQLite (llm#555)
--   data_quality_incidents -- one row per known untrustworthy-data window (llm#913, llm#915)
--   secret_scan_findings   -- one row per finding from secret_exposure_scan.sh (llm#951)
--   roborev_retention_events -- one row per item-type pruned by roborev_retention.sh (llm#929)
--   private_data_scan_findings -- one row per finding from private_data_scan.sh (2026-08-22 PII incident)
--
-- All writers follow unified-observability-schema: id, session_id, source,
-- action, reason, fired_at / started_at + task-specific columns.
--
-- Apply with:
--   bash .claude/scripts/housekeeping_schema_apply.sh
--
-- Tracked in llm#550 Phase B, llm#552 Phase B, llm#553 Phase B, llm#554 Phase B, llm#555 Phase B, llm#585 Phase A.

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
  task            TEXT NOT NULL,             -- 'worktree_gc' | 'branch_gc' | 'config_digest' | 'kb_digest' | 'launchd_health' | 'roborev_bridge' | 'stage1_findings' | 'self_review_verify' | 'secret_exposure_scan'
  source_script   TEXT NOT NULL,             -- absolute path to script
  started_at      TIMESTAMPTZ NOT NULL,
  ended_at        TIMESTAMPTZ,
  status          TEXT NOT NULL,             -- 'ok' | 'failed' | 'partial' | 'deferred'
                                              -- 'deferred' (llm#947, llm#970): the job declined to
                                              -- run because its precondition (network/DNS) was
                                              -- absent within the bound -- NOT a failure. Written by
                                              -- callers of .claude/scripts/wait_for_resolvable_host.sh
                                              -- when it returns 2. Readers MUST NOT bucket 'deferred'
                                              -- alongside 'failed' -- same rationale as the 'unknown'
                                              -- state added to launchd_health_events.state above.
                                              -- No CHECK constraint enforces this enum (verified via
                                              -- duckdb_constraints() on the live table -- only
                                              -- PRIMARY KEY + NOT NULL exist), so no migration was
                                              -- required to add this value.
  rows_written    INTEGER DEFAULT 0,
  error_text      TEXT,
  detail_json     TEXT
);

-- branch_gc_events: one row per local branch inspected by branch_gc.sh.
-- Action taxonomy:
--   deleted_merged   — git cherry showed all '-' (fully patch-id merged)
--   deleted_squash   — closing PR squash-merged + tip-age >= BRANCH_GC_GRACE_DAYS
--   kept_unmerged    — has unique patches AND no closing squash-merge
--   kept_protected   — matched BRANCH_GC_PROTECTED_RE (main/master/release/* etc.)
--   kept_checked_out — checked out by a worktree (any repo)
--   kept_young       — tip-age < BRANCH_GC_MIN_AGE_DAYS
--   kept_grace       — closing PR squash-merged but tip-age < BRANCH_GC_GRACE_DAYS
--   kept_dryrun      — would have deleted; dry-run only
-- Tagged-but-not-deleted: see git notes --ref=branch-gc for recovery within
-- BRANCH_GC_NOTES_TTL_DAYS=30.
-- See llm#585 Phase A.
CREATE TABLE IF NOT EXISTS branch_gc_events (
  id              TEXT PRIMARY KEY,
  fired_at        TIMESTAMPTZ NOT NULL,
  source          TEXT NOT NULL,           -- 'branch_gc.sh'
  project         TEXT NOT NULL,           -- 'llm' | 'historical' | ...
  branch_name     TEXT NOT NULL,
  branch_tip_sha  TEXT NOT NULL,
  action          TEXT NOT NULL,
  closing_pr      INTEGER,                 -- NULL if no closing PR found
  age_days        INTEGER,
  reason          TEXT
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
  state           TEXT NOT NULL,           -- 'loaded_ok' | 'loaded_recent_fail' | 'unloaded' | 'unknown' | 'orphan'
                                            -- 'unknown' (llm#962 Part 1): launchctl output could not be parsed --
                                            -- MUST NOT be counted as a failure by readers. 'missing' is the
                                            -- pre-rename spelling of the same state; readers still accept it
                                            -- for rows written before the rename.
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

-- etl_freshness: one row per ETL data source, upserted by the source's own
-- writer after every run via .claude/scripts/etl_freshness_upsert.sh. Makes
-- silent ETL staleness impossible — records FACT columns (last_row_ts,
-- last_etl_run_ts, expected_cadence_hours) that .claude/scripts/
-- staleness_collect.sh reads as one input to the `staleness` table.
-- The authoritative staleness verdict is the `staleness_status` view
-- (recomputed at every read), surfaced by session_init.sh Phase 15d.
-- status: VESTIGIAL (llm#893/#913) — no longer written by
-- etl_freshness_upsert.sh; retained only so pre-existing rows still load.
-- Do not add readers of this column; use `staleness_status` instead.
-- PK: source_name.
-- See llm#309 Phase 1a; superseded by llm#893.
CREATE TABLE IF NOT EXISTS etl_freshness (
  source_name             VARCHAR PRIMARY KEY,
  last_row_ts             TIMESTAMP,
  last_etl_run_ts         TIMESTAMP,
  expected_cadence_hours  DOUBLE,
  status                  VARCHAR
);

-- data_quality_incidents: one row per known window where a table/column's
-- values are not trustworthy (e.g. imputed/estimated data that would
-- otherwise be silently read as observed data). Written once per incident
-- by whoever diagnoses it (human or agent) -- NOT a continuously-firing
-- event writer like the tables above. Consumers of the named asset/column
-- MUST check this table (or the incident marker it documents, e.g. a
-- `summary` tag) before presenting an aggregate as real.
-- PK is a fixed, human-chosen string (not gen_random_uuid) so re-seeding an
-- incident record is idempotent -- one row per incident, not one per apply.
-- See unified-observability-schema rule "Data Quality Incidents" section,
-- llm#913, llm#915.
CREATE TABLE IF NOT EXISTS data_quality_incidents (
  id            TEXT PRIMARY KEY,
  asset         TEXT NOT NULL,             -- e.g. 'sessions'
  column_name   TEXT,                      -- e.g. 'duration_min'; NULL = whole asset
  window_start  TIMESTAMP NOT NULL,
  window_end    TIMESTAMP,                 -- NULL = still open
  reason        TEXT NOT NULL,
  issue_ref     TEXT,                      -- e.g. 'llm#913 / llm#915'
  recorded_at   TIMESTAMP NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_data_quality_incidents_asset ON data_quality_incidents(asset, window_start);

-- secret_scan_findings: one row per finding from secret_exposure_scan.sh
-- (see the four detectors in secret-exposure-scanning.md), batched -- one
-- INSERT...SELECT per invocation via write_findings_to_db(), NOT one INSERT
-- per finding. Joins to housekeeping_runs(id) via run_id (task=
-- 'secret_exposure_scan') for the run-level heartbeat/status.
--
-- NEVER stores a credential value. `note` is the SAME fixed, detector-
-- specific description append_finding() already prints to stdout/--json/the
-- log file under the scanner's no-leaked-value contract; `name` is a
-- finding-class label (e.g. 'cred-shape', 'bad-permissions'), never the
-- matched literal. This table persists exactly the same 6-tuple the
-- existing reporters already emit -- nothing wider.
--
-- Deterministic PK: md5(run_id:detector:file_path:line_num:name) --
-- replaying the same run's write step (write_findings_to_db called twice
-- for the same run_id) is idempotent via INSERT OR IGNORE. A later run
-- (new run_id) for the same finding gets a new id, by design -- each run is
-- a distinct observation for the digest email's delta-vs-previous-run
-- section, not a dedup target.
-- See llm#951 (scanner half); llm#950 (guard half, same detector set).
CREATE TABLE IF NOT EXISTS secret_scan_findings (
  id          TEXT PRIMARY KEY,
  run_id      TEXT NOT NULL,             -- FK to housekeeping_runs.id
  fired_at    TIMESTAMPTZ NOT NULL,
  detector    TEXT NOT NULL,             -- '1' | '2' | '3' | '4'
  severity    TEXT NOT NULL,             -- 'high' | 'critical'
  file_path   TEXT NOT NULL,
  line_num    TEXT,                      -- '-' for detector 3 (file-level, no line)
  name        TEXT NOT NULL,             -- finding-class label, e.g. 'cred-shape'
  note        TEXT NOT NULL              -- fixed generic description -- NEVER a credential value
);
CREATE INDEX IF NOT EXISTS idx_secret_scan_findings_run_id ON secret_scan_findings(run_id);
CREATE INDEX IF NOT EXISTS idx_secret_scan_findings_fired_at ON secret_scan_findings(fired_at);
CREATE INDEX IF NOT EXISTS idx_secret_scan_findings_detector ON secret_scan_findings(detector, fired_at);

-- roborev_retention_events: one row per item-type removed by
-- roborev_retention.sh (llm#929) — 'backup' (DB snapshot) or 'joblog'
-- (logs/jobs/<id>.log). Written on --apply only (never on --dry-run), so
-- this table's absence of rows for a given day means the dry-run ran, not
-- that nothing needed pruning. Joins to housekeeping_runs.id via run_id.
CREATE TABLE IF NOT EXISTS roborev_retention_events (
  id          TEXT PRIMARY KEY,
  fired_at    TIMESTAMPTZ NOT NULL,
  source      TEXT NOT NULL,             -- 'roborev_retention.sh'
  run_id      TEXT NOT NULL,             -- FK to housekeeping_runs.id
  item_type   TEXT NOT NULL,             -- 'backup' | 'joblog'
  action      TEXT NOT NULL,             -- 'removed'
  count       INTEGER NOT NULL,          -- number of files removed
  bytes       BIGINT NOT NULL            -- cumulative bytes reclaimed
);
CREATE INDEX IF NOT EXISTS idx_roborev_retention_events_run_id ON roborev_retention_events(run_id);
CREATE INDEX IF NOT EXISTS idx_roborev_retention_events_fired_at ON roborev_retention_events(fired_at);

-- private_data_scan_findings: one row per finding from private_data_scan.sh
-- (deny-list exact-value hits + generic E.164/UK-postcode/IBAN pattern
-- hits), batched -- one INSERT...SELECT per invocation via
-- write_findings_to_db(), same convention as secret_scan_findings above.
-- Joins to housekeeping_runs(id) via run_id (task='private_data_scan').
--
-- NEVER stores a PII value. `note` is the same fixed, rule-specific,
-- non-leaking description private_data_scan.sh already prints to
-- stdout/--json/the log under its no-leaked-value contract; `rule` is a
-- finding-class label ('e164-phone' | 'uk-postcode' | 'iban' |
-- 'known-value'), never the matched literal.
--
-- Deterministic PK: md5(run_id:source:location:line_num:rule) -- replaying
-- the same run's write step is idempotent via INSERT OR IGNORE.
-- Origin: 2026-08-22 incident (personal phone number, 8 files, 9 commits,
-- 4 months exposed on a public repo). See private-data-scanning.md.
CREATE TABLE IF NOT EXISTS private_data_scan_findings (
  id          TEXT PRIMARY KEY,
  run_id      TEXT NOT NULL,             -- FK to housekeeping_runs.id
  fired_at    TIMESTAMPTZ NOT NULL,
  source      TEXT NOT NULL,             -- 'denylist' | 'generic'
  severity    TEXT NOT NULL,             -- 'critical' | 'high'
  location    TEXT NOT NULL,             -- 'staged:<path>' | '<sha12>:<path>' | '<path>'
  line_num    TEXT,
  rule        TEXT NOT NULL,             -- 'known-value' | 'e164-phone' | 'uk-postcode' | 'iban'
  note        TEXT NOT NULL              -- fixed generic description -- NEVER a PII value
);
CREATE INDEX IF NOT EXISTS idx_private_data_scan_findings_run_id ON private_data_scan_findings(run_id);
CREATE INDEX IF NOT EXISTS idx_private_data_scan_findings_fired_at ON private_data_scan_findings(fired_at);

CREATE INDEX IF NOT EXISTS idx_worktree_gc_events_fired_at ON worktree_gc_events(fired_at);
CREATE INDEX IF NOT EXISTS idx_branch_gc_events_fired_at ON branch_gc_events(fired_at);
CREATE INDEX IF NOT EXISTS idx_branch_gc_events_project_branch ON branch_gc_events(project, branch_name);
CREATE INDEX IF NOT EXISTS idx_housekeeping_runs_task_started ON housekeeping_runs(task, started_at);
CREATE INDEX IF NOT EXISTS idx_config_events_fired_at ON config_events(fired_at);
CREATE INDEX IF NOT EXISTS idx_kb_events_fired_at ON kb_events(fired_at);
CREATE INDEX IF NOT EXISTS idx_launchd_health_events_fired_at ON launchd_health_events(fired_at);
CREATE INDEX IF NOT EXISTS idx_launchd_health_events_plist ON launchd_health_events(plist_label, fired_at);
