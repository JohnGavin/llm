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
--   secret_scan_store_state -- latest key-NAME-set baseline per known credential store (llm#1196)
--   roborev_retention_events -- one row per item-type pruned by roborev_retention.sh (llm#929)
--   private_data_scan_findings -- one row per finding from private_data_scan.sh (2026-08-22 PII incident)
--   eval_runs              -- one row per eval-harness fixture attempt (llm#816)
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
  status          TEXT NOT NULL,             -- 'ok' | 'failed' | 'partial' | 'deferred' | 'skipped'
                                              -- 'skipped' (llm#1340): the job ran and had nothing to
                                              -- do (e.g. combined config+KB digest, no changes in
                                              -- the window, no email sent). Healthy, NOT a failure;
                                              -- readers must bucket it with 'ok'/'deferred'.
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

-- secret_scan_store_state: one row per KNOWN_CREDENTIAL_STORES entry (see
-- secret_exposure_scan.sh detector 5, llm#1196) -- the LATEST observed key
-- NAME set for that store, replaced (delete-then-insert) on every run that
-- can reach a store. NOT an append-only ledger like secret_scan_findings
-- above -- this is "current state", used only to compute a delta on the
-- NEXT run. key_names is a comma-joined, sorted, de-duplicated list of
-- variable NAMES -- NEVER a credential value; a known store's whole job is
-- to hold credentials, so tracking values here would defeat the point of
-- detector 5 (assert invariants that can change, not "contains secrets").
-- PK is store_path itself (one row per store, not one per run).
CREATE TABLE IF NOT EXISTS secret_scan_store_state (
  store_path  TEXT PRIMARY KEY,
  key_count   INTEGER NOT NULL,
  key_names   TEXT NOT NULL,
  updated_at  TIMESTAMPTZ NOT NULL
);

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
  item_type   TEXT NOT NULL,             -- 'backup' | 'joblog' | 'quarantine' | 'search_backup' (no CHECK constraint; comment-only doc)
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

-- eval_runs: one row per fixture ATTEMPT from an eval harness run (llm#816).
-- Written by roborev_eval_run.sh (harness='roborev'); a --runs N invocation
-- writes N rows per fixture sharing one run_id. The per-fixture verdict
-- (majority of completed attempts) is NOT stored: it is derived at read time
-- by `roborev_eval_run.sh --report <config_hash>`, so the aggregation rule can
-- change without rewriting history (decouple running from grading).
-- result is PASS | FAIL | ERROR; ERROR is indeterminate (never a pass, never a
-- fail) and includes timeouts. config_hash is the sha256 of the effective
-- reviewer config text (agent/model keys, global + per-repo overrides), NOT
-- the text itself, so the daily email can ask "was this config evaluated?".
-- agent / model hold 'config-default' when the harness ran with the
-- repo's configured default rather than an explicit override.
-- Natural key is (run_id, fixture, attempt).
CREATE TABLE IF NOT EXISTS eval_runs (
  run_id      TEXT NOT NULL,
  run_at      TIMESTAMPTZ NOT NULL,
  harness     TEXT NOT NULL,             -- 'roborev' (room for other harnesses, llm#816)
  fixture     TEXT NOT NULL,             -- fixture directory name
  attempt     INTEGER NOT NULL,          -- 1..n within the run
  agent       TEXT NOT NULL,
  model       TEXT NOT NULL,
  config_hash TEXT NOT NULL,             -- sha256 of effective reviewer config, or 'unspecified'
  result      TEXT NOT NULL,             -- 'PASS' | 'FAIL' | 'ERROR' (no CHECK constraint; comment-only doc)
  reason      TEXT,
  latency_ms  BIGINT,
  PRIMARY KEY (run_id, fixture, attempt)
);
CREATE INDEX IF NOT EXISTS idx_eval_runs_config_hash ON eval_runs(config_hash, run_at);

CREATE INDEX IF NOT EXISTS idx_worktree_gc_events_fired_at ON worktree_gc_events(fired_at);
CREATE INDEX IF NOT EXISTS idx_branch_gc_events_fired_at ON branch_gc_events(fired_at);
CREATE INDEX IF NOT EXISTS idx_branch_gc_events_project_branch ON branch_gc_events(project, branch_name);
CREATE INDEX IF NOT EXISTS idx_housekeeping_runs_task_started ON housekeeping_runs(task, started_at);
CREATE INDEX IF NOT EXISTS idx_config_events_fired_at ON config_events(fired_at);
CREATE INDEX IF NOT EXISTS idx_kb_events_fired_at ON kb_events(fired_at);
CREATE INDEX IF NOT EXISTS idx_launchd_health_events_fired_at ON launchd_health_events(fired_at);
CREATE INDEX IF NOT EXISTS idx_launchd_health_events_plist ON launchd_health_events(plist_label, fired_at);

-- ===========================================================================
-- Column and table metadata (COMMENT ON). Additive and idempotent: COMMENT ON
-- only overwrites the comment string, never data, so re-applying this file to
-- the live DB is safe. A number or status is only readable if its meaning,
-- unit and provenance travel with it, so every table and column documents:
-- what it means, the unit for numeric/time columns, the allowed values for
-- enum-like columns, and whether a value can be estimated or indeterminate.
-- Each comment was derived from the INSERT/UPDATE in the writing script, not
-- guessed; where no writer was found the comment says "writer not found".
-- Guarded by tests/test_housekeeping_schema_comments.sh (fails on any table
-- or column with a NULL or empty comment).
--
-- NOTE: the eval_runs comments live HERE, after the eval_runs index, on
-- purpose: roborev_eval_run.sh ensure_eval_table() extracts the eval_runs DDL
-- with a sed range ending at idx_eval_runs, so a table created that way has
-- no comments until this file is applied.
-- ===========================================================================

-- worktree_gc_events ---------------------------------------------------------
COMMENT ON TABLE worktree_gc_events IS 'One row per git worktree inspected, removed or skipped. Written by .claude/scripts/worktree_gc.sh (write_gc_event, overnight sweep) and by the /cleanup-worktrees command (.claude/commands/cleanup-worktrees.md, action "archived"). Rows are observations of a decision, not a live inventory.';
COMMENT ON COLUMN worktree_gc_events.id IS 'Unique event id. worktree_gc.sh writes a UUID v4 string; /cleanup-worktrees writes 32 hex characters (lower(hex(randomblob(16)))).';
COMMENT ON COLUMN worktree_gc_events.fired_at IS 'UTC instant the event was recorded (TIMESTAMPTZ).';
COMMENT ON COLUMN worktree_gc_events.source IS 'Writer identity. Found: "worktree_gc.sh", "cleanup-worktrees-command". The schema file also lists "session_init_phase7f", "session_init_phase1e", "cc.sh": writer not found.';
COMMENT ON COLUMN worktree_gc_events.session_id IS 'Claude session id. Always NULL in the writers found (worktree_gc.sh and /cleanup-worktrees both write NULL); NULL means not attributed to a session, not unknown-by-error.';
COMMENT ON COLUMN worktree_gc_events.location_pattern IS 'Which worktree_gc.sh sweep pattern matched the path. Allowed values written by worktree_gc.sh: "siblings", "agent", "convention". /cleanup-worktrees writes whatever pattern label the operator supplies.';
COMMENT ON COLUMN worktree_gc_events.project IS 'Project (repo directory name) that owns the worktree, as derived by the writer.';
COMMENT ON COLUMN worktree_gc_events.worktree_path IS 'Absolute filesystem path of the worktree at the time of the event.';
COMMENT ON COLUMN worktree_gc_events.branch IS 'Branch checked out in the worktree. worktree_gc.sh writes an empty string (not NULL) when it was not resolved (for example the opt-out skip).';
COMMENT ON COLUMN worktree_gc_events.action IS 'Outcome. Written by worktree_gc.sh: removed, removed_squash, would_remove, would_remove_squash (dry-run, nothing deleted), skipped_optout, skipped_cwd, skipped_locked, skipped_unmerged, skipped_cherry_error, skipped_uncommitted, skipped_age, skipped_remove_failed. Written by /cleanup-worktrees: archived. Listed in the schema file but writer not found: skipped_main, flagged. No CHECK constraint enforces this list. would_* rows are predictions, not deletions.';
COMMENT ON COLUMN worktree_gc_events.reason IS 'Free-text explanation of the action, set by the writer (for example "all gates passed", "dirty working tree", "age 3600s < threshold 86400s"). Not machine-parseable.';
COMMENT ON COLUMN worktree_gc_events.size_mb IS 'Disk usage of the worktree directory in megabytes, from du -sm at event time (an integer; 0 when the path is missing or unreadable, so 0 can mean unknown).';

-- housekeeping_runs ----------------------------------------------------------
COMMENT ON TABLE housekeeping_runs IS 'One row per cron/script invocation (heartbeat). Inserted at start and updated at end by many writers, including worktree_gc.sh, branch_gc.sh, bin/config_digest_cron.sh, bin/kb_digest_daily_cron.sh, bin/launchd_health_weekly_cron.sh, roborev_bridge_to_unified.sh, secret_exposure_scan.sh, private_data_scan.sh, private_data_history_audit.sh, roborev_retention.sh, roborev_requeue_dropped.sh, roborev_job_reaper.sh, roborev_metrics_etl.R, credential_single_source_check.sh, capability_registry_regen_cron.sh, staleness_collect.sh. A row with ended_at NULL is a run that never recorded its end (crashed, killed or still running), not a success.';
COMMENT ON COLUMN housekeeping_runs.id IS 'Unique run id (UUID string generated by the writing script).';
COMMENT ON COLUMN housekeeping_runs.task IS 'Job name, free text chosen by each writer. Found: worktree_gc, branch_gc, config_digest, kb_digest, launchd_health, roborev_bridge, secret_exposure_scan, private_data_scan, private_data_history_audit, roborev_retention, roborev_requeue_dropped, roborev_job_reaper, roborev_metrics_etl, credential_single_source_check, capability_registry_regen, staleness_collect. The schema file also lists stage1_findings and self_review_verify: writer not found.';
COMMENT ON COLUMN housekeeping_runs.source_script IS 'Path of the script that wrote the row. Absolute for most writers; roborev_metrics_etl.R writes a relative path.';
COMMENT ON COLUMN housekeeping_runs.started_at IS 'UTC instant the run started (TIMESTAMPTZ).';
COMMENT ON COLUMN housekeeping_runs.ended_at IS 'UTC instant the run finished (TIMESTAMPTZ). NULL means the end was never recorded (indeterminate: crash, kill or still running).';
COMMENT ON COLUMN housekeeping_runs.status IS 'Run outcome (no CHECK constraint). Values written: ok, failed, partial, deferred, skipped, running. Most writers insert "ok" at START and only overwrite it at end, so status=ok with ended_at NULL is NOT a confirmed success. branch_gc.sh and roborev_metrics_etl.R insert "running" at start. "skipped" (llm#1340): ran and had nothing to do, healthy. "deferred" (llm#947/#970): precondition such as DNS absent, NOT a failure. "partial": some steps failed (for example the digest email). Readers must not bucket skipped or deferred with failed.';
COMMENT ON COLUMN housekeeping_runs.rows_written IS 'Count of rows the run wrote to its event table(s) (an integer count of rows, not bytes). Default 0. Some writers update it only at end, so 0 on an unfinished run means not yet recorded.';
COMMENT ON COLUMN housekeeping_runs.error_text IS 'Error message for a failed or partial run. Only branch_gc.sh, roborev_bridge_to_unified.sh and roborev_metrics_etl.R populate it; NULL for every other writer, so NULL does not mean no error.';
COMMENT ON COLUMN housekeeping_runs.detail_json IS 'Optional run detail text. Only roborev_requeue_dropped.sh writes it; NULL for all other writers.';

-- branch_gc_events -----------------------------------------------------------
COMMENT ON TABLE branch_gc_events IS 'One row per local git branch inspected by .claude/scripts/branch_gc.sh (llm#585): deleted or kept, with the reason. Written by branch_gc.sh db_emit().';
COMMENT ON COLUMN branch_gc_events.id IS 'Unique event id (lower-case UUID from uuidgen, or a nanosecond timestamp fallback).';
COMMENT ON COLUMN branch_gc_events.fired_at IS 'UTC instant the event was recorded (current_timestamp, TIMESTAMPTZ).';
COMMENT ON COLUMN branch_gc_events.source IS 'Writer identity; always "branch_gc.sh".';
COMMENT ON COLUMN branch_gc_events.project IS 'Repository (project) name the branch belongs to, for example "llm" or "historical".';
COMMENT ON COLUMN branch_gc_events.branch_name IS 'Local branch name inspected.';
COMMENT ON COLUMN branch_gc_events.branch_tip_sha IS 'Commit SHA of the branch tip at inspection time (git hash; recovery handle).';
COMMENT ON COLUMN branch_gc_events.action IS 'Decision (no CHECK constraint). Written by branch_gc.sh: deleted_merged, deleted_squash, deleted_reimpl, kept_unmerged, kept_protected, kept_checked_out, kept_young, kept_grace, kept_delete_failed, kept_dryrun (would have deleted; dry-run only).';
COMMENT ON COLUMN branch_gc_events.closing_pr IS 'GitHub PR number that closed the branch via squash-merge. NULL when no closing PR was found or looked up.';
COMMENT ON COLUMN branch_gc_events.age_days IS 'Age of the branch tip commit in whole days at inspection time.';
COMMENT ON COLUMN branch_gc_events.reason IS 'Free-text explanation of the action set by branch_gc.sh (for example "git cherry main branch all -"). Not machine-parseable.';

-- config_events --------------------------------------------------------------
COMMENT ON TABLE config_events IS 'One row per config-file change (per commit and file) detected in the last 24h by bin/config_digest_cron.sh (Step 1b, from git log --numstat). Read by the config digest email.';
COMMENT ON COLUMN config_events.id IS 'Unique event id (UUID v4 string).';
COMMENT ON COLUMN config_events.fired_at IS 'UTC instant the digest run recorded the event (TIMESTAMPTZ). This is the cron run time, not the commit time.';
COMMENT ON COLUMN config_events.source IS 'Writer identity; always "config_digest_cron.sh".';
COMMENT ON COLUMN config_events.file_path IS 'Config file path as reported by git log --numstat, relative to the repo root.';
COMMENT ON COLUMN config_events.change_type IS 'Kind of change derived from numstat. Written: added (only lines added), removed (only lines deleted), modified (both, or a binary file). The schema file also lists permission_change: writer not found.';
COMMENT ON COLUMN config_events.diff_summary IS 'Human-readable diff summary. Never written by bin/config_digest_cron.sh (its INSERT omits the column): writer not found, always NULL.';
COMMENT ON COLUMN config_events.diff_lines IS 'Count of changed lines in the commit for this file: lines added for added, lines deleted for removed, added plus deleted for modified. 0 for binary files, where git numstat gives no counts (so 0 can mean not measurable).';
COMMENT ON COLUMN config_events.commit_sha IS 'Short (7-character) git commit SHA that made the change.';

-- kb_events ------------------------------------------------------------------
COMMENT ON TABLE kb_events IS 'One row per knowledge-base change (per commit and file) detected by bin/kb_digest_daily_cron.sh (Step 1b, from git log --numstat on the knowledge repo raw/, wiki/, outputs/). Read by the knowledge-base digest section.';
COMMENT ON COLUMN kb_events.id IS 'Unique event id (lower-case UUID from uuidgen).';
COMMENT ON COLUMN kb_events.fired_at IS 'UTC instant the digest run recorded the event (TIMESTAMPTZ). This is the cron run time, not the commit time.';
COMMENT ON COLUMN kb_events.source IS 'Writer identity; always "kb_digest_daily_cron.sh".';
COMMENT ON COLUMN kb_events.layer IS 'Knowledge-base layer, derived from the path prefix. Allowed values: raw, wiki, outputs (anything else falls back to outputs).';
COMMENT ON COLUMN kb_events.path IS 'File path relative to the knowledge/ repo root.';
COMMENT ON COLUMN kb_events.action IS 'Kind of change derived from numstat. Written: created (only lines added), modified (everything else, including binary and fully-deleted files). The schema file also lists flagged_no_sources, flagged_ai_inferred, broken_link: writer not found.';
COMMENT ON COLUMN kb_events.details IS 'Free-text detail. Never written by bin/kb_digest_daily_cron.sh (its INSERT omits the column): writer not found, always NULL.';
COMMENT ON COLUMN kb_events.commit_sha IS 'Short (7-character) git commit SHA of the knowledge repo that made the change.';

-- launchd_health_events ------------------------------------------------------
COMMENT ON TABLE launchd_health_events IS 'One row per launchd plist per run: its last observed state, from launchctl print. Written by bin/launchd_health_weekly_cron.sh (Step 1b, with up to 3 insert attempts on lock contention). Read by the cron-health digest section. A missing or stale row is itself the signal of a broken cron job.';
COMMENT ON COLUMN launchd_health_events.id IS 'Unique event id (lower-case UUID from uuidgen).';
COMMENT ON COLUMN launchd_health_events.fired_at IS 'UTC instant the health check observed the plist (TIMESTAMPTZ).';
COMMENT ON COLUMN launchd_health_events.source IS 'Writer identity; always "launchd_health_weekly_cron.sh".';
COMMENT ON COLUMN launchd_health_events.plist_label IS 'launchd job label, for example "com.claude.worktree-gc".';
COMMENT ON COLUMN launchd_health_events.state IS 'Observed state. Written: loaded_ok (last exit 0 or 78), loaded_recent_fail (other exit code), unloaded (not loaded), unknown (llm#962: launchctl output could not be parsed; INDETERMINATE, readers must NOT count it as a failure). The schema file also lists orphan and the legacy spelling missing: writer not found for orphan; readers still accept missing for pre-rename rows.';
COMMENT ON COLUMN launchd_health_events.last_exit_code IS 'Integer exit status of the last run from launchctl print. NULL when the job has never exited or the state is unknown. 0 and 78 (no more processes, idle) are treated as healthy.';
COMMENT ON COLUMN launchd_health_events.last_fired_at IS 'Intended: UTC instant of the last launchd fire (TIMESTAMPTZ). bin/launchd_health_weekly_cron.sh always writes NULL, so the value is always NULL (not parsed, not zero).';
COMMENT ON COLUMN launchd_health_events.next_fire_at IS 'Intended: UTC instant of the next scheduled fire (TIMESTAMPTZ). bin/launchd_health_weekly_cron.sh always writes NULL, so the value is always NULL (not parsed, not zero).';
COMMENT ON COLUMN launchd_health_events.detail IS 'Free-text detail set by the writer, typically "runs=N; last_exit=C" (runs is a count of launchd runs, or "?" when unparsed).';

-- roborev_daily_summary ------------------------------------------------------
COMMENT ON TABLE roborev_daily_summary IS 'Per-project daily summary mirrored read-only from the roborev SQLite DB (~/.roborev/reviews.db) by .claude/scripts/roborev_bridge_to_unified.sh. One row per (project, UTC day); the primary key is a deterministic md5-derived UUID of project and date, so a same-day re-run is a no-op (INSERT OR IGNORE) and does not refresh the counts. Counts are snapshots at fired_at.';
COMMENT ON COLUMN roborev_daily_summary.id IS 'Deterministic UUID-formatted md5 of "<project>:<UTC date>" (roborev_bridge_to_unified.sh).';
COMMENT ON COLUMN roborev_daily_summary.fired_at IS 'UTC instant the bridge ran (TIMESTAMPTZ); also the window end.';
COMMENT ON COLUMN roborev_daily_summary.window_start IS 'UTC start of the 24-hour aggregation window (TIMESTAMPTZ): fired_at minus 24 hours.';
COMMENT ON COLUMN roborev_daily_summary.window_end IS 'UTC end of the aggregation window (TIMESTAMPTZ); equals fired_at. Open-review counts are not windowed, only closed_today and autoclose_today are.';
COMMENT ON COLUMN roborev_daily_summary.project IS 'Canonical project name, roborev repos.name (lower-case basename as stored by roborev).';
COMMENT ON COLUMN roborev_daily_summary.total_reviews_open IS 'Count of roborev reviews with closed = 0 for the project at run time (count of reviews, not findings).';
COMMENT ON COLUMN roborev_daily_summary.total_reviews_closed_today IS 'Count of closed reviews whose review created_at falls in the last 24h (filter is on created_at, not close time, so it approximates closures today).';
COMMENT ON COLUMN roborev_daily_summary.high_open IS 'Count of open reviews classified Severity High, from text or structured findings matching. A classification heuristic (LIKE patterns), not a verified severity.';
COMMENT ON COLUMN roborev_daily_summary.medium_open IS 'Count of open reviews classified Severity Medium (same heuristic as high_open).';
COMMENT ON COLUMN roborev_daily_summary.low_open IS 'Count of open reviews classified Severity Low (same heuristic as high_open). high, medium and low need not sum to total_reviews_open: reviews with no recognisable severity are counted in none of them.';
COMMENT ON COLUMN roborev_daily_summary.oldest_open_days IS 'Age in whole days of the oldest open review, from review_jobs.finished_at to now. 0 when there is none or finished_at is NULL (so 0 can mean unknown).';
COMMENT ON COLUMN roborev_daily_summary.autoclose_today IS 'Count of closures with closure_type = "stale" created in the last 24h (auto-closed stale reviews). 0 when the closures table has no matching rows.';
COMMENT ON COLUMN roborev_daily_summary.source_db_path IS 'Path of the roborev SQLite DB that was read.';
COMMENT ON COLUMN roborev_daily_summary.detail_json IS 'Digest context for the top 3 open findings (highest severity first), as a JSON string value of up to 500 characters, or the JSON literal null when none. Truncated text, not structured findings.';

-- etl_freshness --------------------------------------------------------------
COMMENT ON TABLE etl_freshness IS 'One row per ETL data source recording FACTS about its freshness; the staleness verdict is computed at read time by the staleness_status view (llm#893), not stored here. Upserted (INSERT OR REPLACE on source_name) by .claude/scripts/etl_freshness_upsert.sh, command_usage_staging_import.sh, skill_usage_staging_import.sh, backfill_command_usage.R and backfill_skill_usage.R.';
COMMENT ON COLUMN etl_freshness.source_name IS 'Primary key: ETL source identifier (for example "command_usage").';
COMMENT ON COLUMN etl_freshness.last_row_ts IS 'Timestamp of the newest data row the source holds: MAX of a timestamp column of its table, or the mtime of its file (UTC) in etl_freshness_upsert.sh. TIMESTAMP without time zone. NULL when it could not be determined (indeterminate, not stale).';
COMMENT ON COLUMN etl_freshness.last_etl_run_ts IS 'Timestamp the ETL writer last ran (current_timestamp at upsert, TIMESTAMP without time zone). Records when the ETL ran, not that it succeeded in loading new data.';
COMMENT ON COLUMN etl_freshness.expected_cadence_hours IS 'Expected hours between ETL runs (DOUBLE, hours). NULL for event-driven sources with no SLA; a blank or non-numeric cadence argument is stored as NULL.';
COMMENT ON COLUMN etl_freshness.status IS 'VESTIGIAL (llm#893/#913): no longer written by etl_freshness_upsert.sh (NULL there), but command_usage_staging_import.sh and skill_usage_staging_import.sh still write "unknown". Do not read it; use the staleness_status view.';

-- data_quality_incidents -----------------------------------------------------
COMMENT ON TABLE data_quality_incidents IS 'One row per known window in which a table/column values are NOT trustworthy (for example imputed or estimated values that would be read as observed). Written once per incident, not continuously: seeded by .claude/scripts/data_quality_incidents_seed.sql (via data_quality_incidents_seed_apply.sh) and by .claude/scripts/backfill_agent_runs_1045.sh. Consumers of the named asset/column must check this table before presenting an aggregate as real.';
COMMENT ON COLUMN data_quality_incidents.id IS 'Primary key: fixed human-chosen string (for example "llm913-sessions-duration_min-20260724"), so re-seeding is idempotent.';
COMMENT ON COLUMN data_quality_incidents.asset IS 'Table (or other data asset) affected, for example "sessions" or "agent_runs".';
COMMENT ON COLUMN data_quality_incidents.column_name IS 'Affected column, for example "duration_min". NULL means the whole asset.';
COMMENT ON COLUMN data_quality_incidents.window_start IS 'Start of the untrustworthy window (TIMESTAMP without time zone), the earliest affected started_at.';
COMMENT ON COLUMN data_quality_incidents.window_end IS 'End of the untrustworthy window (TIMESTAMP without time zone). NULL means the incident is still open.';
COMMENT ON COLUMN data_quality_incidents.reason IS 'Free-text statement of why the values are not trustworthy and what was done (for example a backfilled estimate). Never treat the affected values as observed.';
COMMENT ON COLUMN data_quality_incidents.issue_ref IS 'GitHub issue reference for the incident, for example "llm#913 / llm#915". NULL if none.';
COMMENT ON COLUMN data_quality_incidents.recorded_at IS 'Timestamp the incident row was recorded (TIMESTAMP without time zone).';

-- secret_scan_findings -------------------------------------------------------
COMMENT ON TABLE secret_scan_findings IS 'One row per finding from .claude/scripts/secret_exposure_scan.sh (write_findings_to_db, one batched INSERT per run). Append-only: each run is a distinct observation. Never stores a credential value. Joins to housekeeping_runs.id via run_id (task = secret_exposure_scan).';
COMMENT ON COLUMN secret_scan_findings.id IS 'Deterministic md5 of run_id:detector:file_path:line_num:name, so replaying the same run write is idempotent.';
COMMENT ON COLUMN secret_scan_findings.run_id IS 'housekeeping_runs.id of the scan run that produced the finding (no enforced foreign key).';
COMMENT ON COLUMN secret_scan_findings.fired_at IS 'UTC instant the scan run started (TIMESTAMPTZ); identical for all findings of one run.';
COMMENT ON COLUMN secret_scan_findings.detector IS 'Detector id as text. Written: "1" (whole-environment capture), "2" (credential shape or assignment), "3" (bad file permissions), "4" (commented-out credential assignment), "5" (known credential store invariants, llm#1196). The schema file comment on this column lists only 1-4 and is out of date.';
COMMENT ON COLUMN secret_scan_findings.severity IS 'Finding severity. Allowed values written: "high", "critical".';
COMMENT ON COLUMN secret_scan_findings.file_path IS 'Path of the file (or credential store) the finding is about.';
COMMENT ON COLUMN secret_scan_findings.line_num IS 'Line number as text (not integer); "-" for file-level findings with no line (detector 3 and the detector 5 non-value findings).';
COMMENT ON COLUMN secret_scan_findings.name IS 'Finding-class label (for example "cred-shape", "bad-permissions", "known-store-key-delta"), never the matched literal.';
COMMENT ON COLUMN secret_scan_findings.note IS 'Fixed generic description for the finding class. By contract NEVER contains a credential value.';

-- secret_scan_store_state ----------------------------------------------------
COMMENT ON TABLE secret_scan_store_state IS 'Latest observed key-NAME set per known credential store (detector 5, llm#1196). Current state, not a ledger: secret_exposure_scan.sh record_store_state() deletes then re-inserts the row each run, and the next run computes a delta against it. Holds variable NAMES only, never values.';
COMMENT ON COLUMN secret_scan_store_state.store_path IS 'Primary key: path of the known credential store file.';
COMMENT ON COLUMN secret_scan_store_state.key_count IS 'Count of distinct variable names in the store at the last observation (integer count of names).';
COMMENT ON COLUMN secret_scan_store_state.key_names IS 'Comma-joined, sorted, de-duplicated variable NAMES in the store. NEVER credential values.';
COMMENT ON COLUMN secret_scan_store_state.updated_at IS 'UTC instant the baseline was last replaced (TIMESTAMPTZ).';

-- roborev_retention_events ---------------------------------------------------
COMMENT ON TABLE roborev_retention_events IS 'One row per item type pruned by .claude/scripts/roborev_retention.sh (llm#929). Written only on --apply, never on --dry-run, so no rows for a day means a dry-run or nothing run, not that nothing needed pruning. Joins to housekeeping_runs.id via run_id.';
COMMENT ON COLUMN roborev_retention_events.id IS 'Unique event id: the run id plus an item suffix (-backups, -joblogs, -quarantine, -searchbak).';
COMMENT ON COLUMN roborev_retention_events.fired_at IS 'UTC instant the apply run started (TIMESTAMPTZ).';
COMMENT ON COLUMN roborev_retention_events.source IS 'Writer identity; always "roborev_retention.sh".';
COMMENT ON COLUMN roborev_retention_events.run_id IS 'housekeeping_runs.id of the retention run (no enforced foreign key).';
COMMENT ON COLUMN roborev_retention_events.item_type IS 'Kind of item pruned (no CHECK constraint). Allowed values written: backup (DB snapshots), joblog (logs/jobs/<id>.log), quarantine, search_backup.';
COMMENT ON COLUMN roborev_retention_events.action IS 'What was done; always "removed" in the writer found.';
COMMENT ON COLUMN roborev_retention_events.count IS 'Number of items (files or directories) removed for this item_type (integer count).';
COMMENT ON COLUMN roborev_retention_events.bytes IS 'Bytes reclaimed (BIGINT, bytes). CAUTION: the "backup" row stores the run TOTAL bytes across all item types (writer passes total_bytes), while the other rows store their own item_type bytes, so summing bytes over a run double counts.';

-- private_data_scan_findings -------------------------------------------------
COMMENT ON TABLE private_data_scan_findings IS 'One row per finding from .claude/scripts/private_data_scan.sh (deny-list exact-value hits plus generic E.164 phone, UK postcode and IBAN patterns), batched via write_findings_to_db. Never stores a PII value. Joins to housekeeping_runs.id via run_id (task = private_data_scan).';
COMMENT ON COLUMN private_data_scan_findings.id IS 'Deterministic md5 of run_id:source:location:line_num:rule, so replaying the same run write is idempotent.';
COMMENT ON COLUMN private_data_scan_findings.run_id IS 'housekeeping_runs.id of the scan run (no enforced foreign key).';
COMMENT ON COLUMN private_data_scan_findings.fired_at IS 'UTC instant the scan run started (TIMESTAMPTZ); identical for all findings of one run.';
COMMENT ON COLUMN private_data_scan_findings.source IS 'Which matcher produced the finding. Allowed values: "denylist" (exact-value deny list), "generic" (pattern match).';
COMMENT ON COLUMN private_data_scan_findings.severity IS 'Finding severity. Allowed values: "critical", "high".';
COMMENT ON COLUMN private_data_scan_findings.location IS 'Where the match was found: "staged:<path>", "<sha12>:<path>" (commit history) or "<path>".';
COMMENT ON COLUMN private_data_scan_findings.line_num IS 'Line number of the match as text (not integer).';
COMMENT ON COLUMN private_data_scan_findings.rule IS 'Finding-class label. Allowed values: "known-value", "e164-phone", "uk-postcode", "iban". Never the matched literal.';
COMMENT ON COLUMN private_data_scan_findings.note IS 'Fixed generic description for the rule. By contract NEVER contains a PII value.';

-- eval_runs ------------------------------------------------------------------
COMMENT ON TABLE eval_runs IS 'One row per eval-harness fixture ATTEMPT (llm#816), written by .claude/scripts/roborev_eval_classify.py insert_sql() on behalf of .claude/scripts/roborev_eval_run.sh (harness = roborev). A --runs N invocation writes N rows per fixture sharing one run_id. The per-fixture verdict is NOT stored: it is derived at read time by roborev_eval_run.sh --report <config_hash>. Natural key (run_id, fixture, attempt).';
COMMENT ON COLUMN eval_runs.run_id IS 'UUID shared by all attempts of one harness invocation.';
COMMENT ON COLUMN eval_runs.run_at IS 'UTC instant the harness invocation started (TIMESTAMPTZ); identical for all rows of a run, not the per-attempt time.';
COMMENT ON COLUMN eval_runs.harness IS 'Which eval harness wrote the row. Currently "roborev"; room for others (llm#816).';
COMMENT ON COLUMN eval_runs.fixture IS 'Fixture directory name evaluated.';
COMMENT ON COLUMN eval_runs.attempt IS 'Attempt number within the run, 1..n (integer count; n is the --runs value).';
COMMENT ON COLUMN eval_runs.agent IS 'Reviewer agent used, or "config-default" when the harness ran with the repo configured default rather than an explicit override.';
COMMENT ON COLUMN eval_runs.model IS 'Reviewer model used, or "config-default" when no explicit override was given.';
COMMENT ON COLUMN eval_runs.config_hash IS 'sha256 of the effective reviewer config text (agent/model keys, global plus per-repo), NOT the text itself, or "unspecified" when none was supplied. Lets reports ask whether a config was evaluated.';
COMMENT ON COLUMN eval_runs.result IS 'Attempt outcome (no CHECK constraint). Allowed values: PASS, FAIL, ERROR. ERROR is INDETERMINATE: never a pass and never a fail; it includes timeouts (reason starts with "TIMEOUT:"), diff apply failures and review errors.';
COMMENT ON COLUMN eval_runs.reason IS 'Free-text explanation of the result (classifier reason, or error/timeout text). Tabs and newlines are replaced by spaces. NULL is possible.';
COMMENT ON COLUMN eval_runs.latency_ms IS 'Wall-clock time of the attempt in milliseconds (BIGINT, ms). NULL if non-numeric; 0 for attempts that failed before the review ran (for example a diff that did not apply), so 0 means not measured.';
