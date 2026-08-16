-- staleness_schema.sql
-- Unified staleness fact table + computed-status view for unified.duckdb.
--
-- llm#893 step 1: consolidates three overlapping stores (etl_freshness,
-- launchd_health_events, launchd_runs.duckdb) into one fact table with a
-- `asset_kind` discriminator, and fixes three defects present in the current
-- design:
--
--   1. `status` was STORED in etl_freshness, so the freshness table could go
--      stale itself (a row could read 'fresh' while the writer that set it
--      had not run in days). Here status is a VIEW (staleness_status) —
--      recomputed at every read, never cached.
--   2. `expected_cadence_hours` could be NULL, degrading to status='unknown'
--      which reads as benign. Here it is NOT NULL — every asset MUST have a
--      real cadence assigned by its writer (see staleness_collect.sh for the
--      reasoning behind each source's assigned value).
--   3. Every existing checker was itself a launchd job, so a total launchd
--      outage (llm#886) silenced the monitor along with everything else.
--      staleness_status is read out-of-band from session_init.sh (a
--      different trigger class — see staleness_banner.sh), not from another
--      launchd job.
--
-- `observation_age` in the view is what makes a stale *observation* visible:
-- even if last_seen_ts looks fresh, an old observed_at means the collector
-- itself hasn't run recently and the row should not be trusted at face value.
--
-- Idempotent: CREATE TABLE IF NOT EXISTS + CREATE OR REPLACE VIEW. Safe to
-- run multiple times.
--
-- Apply with:
--   bash .claude/scripts/staleness_schema_apply.sh
--
-- Tracked in llm#893 (steps 1-2 of the Sequencing plan). Steps 3-5
-- (repointing the email/dashboard, content checks, retiring
-- launchd_runs.duckdb) are out of scope for this migration.
--
-- llm#893 step 4 (section D — "extend beyond time") adds five nullable
-- columns below for CONTENT facts (magnitude, not just recency). Section D
-- is scoped to *scheduling and surfacing* content checks with the same
-- cadence machinery as steps 1-2; llm#892 owns the checks themselves. Three
-- concrete detectors are implemented here, each mapped to a real incident:
--
--   1. "A log stopped growing" (the llm#886 tell). Needs NO new columns —
--      it is a pure time check: last_seen_ts = the monitored file's mtime
--      (proxy for "last time it produced new content"), asset_kind=
--      'log_growth'. staleness_status.status (already computed above)
--      answers this directly, same as any other asset_kind.
--   2. "A log grew abnormally" (llm#887: 74 MB poller log). Needs a
--      magnitude fact and a per-asset ceiling — metric_value /
--      metric_value_prior / metric_threshold_high below. Same 'log_growth'
--      row as #1 carries both checks (one row, two questions).
--   3. "A DB grew without its row count growing" (llm#884: 7.1 GB / 61k
--      rows). Needs two magnitude facts (size, row count) so the view can
--      compute a density (bytes/row) and compare it to a ceiling —
--      metric_value/metric_aux (+ their _prior columns) and
--      metric_threshold_high, asset_kind='db_bloat'.
--
-- Retention rule (bounded, no unbounded growth): each row keeps at most the
-- CURRENT and the single PRIOR observation of each magnitude fact. The
-- collector reads the existing metric_value/metric_aux for an asset before
-- it upserts, and writes them into metric_value_prior/metric_aux_prior — a
-- fixed O(1)-per-asset footprint, not a growing history table. One delta
-- (current vs prior) is sufficient for the two magnitude-based detectors
-- above; nothing in section D needs a longer window.
--
-- All five new columns are NULL for every asset_kind that doesn't use them
-- (etl_source, launchd_job, collector) — existing INSERT OR REPLACE
-- statements from step 2 are unaffected because they never reference these
-- columns.

CREATE TABLE IF NOT EXISTS staleness (
  asset_kind              TEXT NOT NULL,   -- etl_source | launchd_job | artifact | collector | log_growth | db_bloat
  asset_id                TEXT NOT NULL,   -- e.g. 'roborev', 'com.claude.worktree-gc', 'staleness_collect'
  project                 TEXT,            -- canonical project (NULL = global)
  last_seen_ts            TIMESTAMPTZ,     -- the FACT: when it last produced/ran (NULL = never observed)
  expected_cadence_hours  DOUBLE NOT NULL, -- MANDATORY — no 'unknown' escape hatch (defect 2)
  last_exit_code          INTEGER,
  observed_at             TIMESTAMPTZ NOT NULL,
  -- llm#893 step 4 (section D) — content-fact columns, NULL unless asset_kind
  -- is 'log_growth' or 'db_bloat'. See the block comment above for meaning.
  metric_value            DOUBLE,          -- current magnitude (bytes for log_growth; DB size bytes for db_bloat)
  metric_value_prior      DOUBLE,          -- previous observation's metric_value (2-deep retention, see above)
  metric_aux              DOUBLE,          -- secondary magnitude (db_bloat only: total row count); NULL otherwise
  metric_aux_prior        DOUBLE,          -- previous observation's metric_aux
  metric_threshold_high   DOUBLE,          -- per-asset ceiling: max healthy delta (log_growth) or density (db_bloat)
  PRIMARY KEY (asset_kind, asset_id)
);

-- Idempotent widen for a `staleness` table created before llm#893 step 4.
ALTER TABLE staleness ADD COLUMN IF NOT EXISTS metric_value DOUBLE;
ALTER TABLE staleness ADD COLUMN IF NOT EXISTS metric_value_prior DOUBLE;
ALTER TABLE staleness ADD COLUMN IF NOT EXISTS metric_aux DOUBLE;
ALTER TABLE staleness ADD COLUMN IF NOT EXISTS metric_aux_prior DOUBLE;
ALTER TABLE staleness ADD COLUMN IF NOT EXISTS metric_threshold_high DOUBLE;

-- staleness_status: status computed at READ time, not stored (defect 1 fix).
-- A NULL last_seen_ts (never observed) is treated as 'stale' — fail-safe, not
-- benign like the old 'unknown' vocabulary.
--
-- content_status (llm#893 step 4) is a SECOND, independent verdict computed
-- the same way — never stored, always recomputed — answering "is the
-- magnitude of this asset unusual?" rather than "is it recent?". NULL means
-- "not a content-checked asset_kind" or "not enough history yet" (first-ever
-- observation has no prior to diff against); 'normal'/'abnormal_growth'/
-- 'bloat' mean the check ran. One query
-- (`SELECT * FROM staleness_status WHERE status='stale' OR content_status
-- NOT IN ('normal')`) still answers "what is wrong?" across both axes, per
-- the one-table-one-query discipline in section A of llm#893.
CREATE OR REPLACE VIEW staleness_status AS
SELECT
  *,
  CASE
    WHEN last_seen_ts IS NULL
      OR now() - last_seen_ts > (expected_cadence_hours * INTERVAL '1 hour')
      THEN 'stale'
    ELSE 'fresh'
  END AS status,
  now() - observed_at AS observation_age,
  CASE
    WHEN asset_kind = 'log_growth' THEN
      CASE
        WHEN metric_value_prior IS NULL OR metric_threshold_high IS NULL THEN NULL
        WHEN (metric_value - metric_value_prior) > metric_threshold_high THEN 'abnormal_growth'
        ELSE 'normal'
      END
    WHEN asset_kind = 'db_bloat' THEN
      CASE
        WHEN metric_aux IS NULL OR metric_aux = 0 OR metric_threshold_high IS NULL THEN NULL
        WHEN (metric_value / metric_aux) > metric_threshold_high THEN 'bloat'
        ELSE 'normal'
      END
    ELSE NULL
  END AS content_status
FROM staleness;

CREATE INDEX IF NOT EXISTS idx_staleness_asset_kind ON staleness(asset_kind);
