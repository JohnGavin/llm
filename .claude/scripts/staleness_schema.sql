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

CREATE TABLE IF NOT EXISTS staleness (
  asset_kind              TEXT NOT NULL,   -- etl_source | launchd_job | artifact | collector
  asset_id                TEXT NOT NULL,   -- e.g. 'roborev', 'com.claude.worktree-gc', 'staleness_collect'
  project                 TEXT,            -- canonical project (NULL = global)
  last_seen_ts            TIMESTAMPTZ,     -- the FACT: when it last produced/ran (NULL = never observed)
  expected_cadence_hours  DOUBLE NOT NULL, -- MANDATORY — no 'unknown' escape hatch (defect 2)
  last_exit_code          INTEGER,
  observed_at             TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (asset_kind, asset_id)
);

-- staleness_status: status computed at READ time, not stored (defect 1 fix).
-- A NULL last_seen_ts (never observed) is treated as 'stale' — fail-safe, not
-- benign like the old 'unknown' vocabulary.
CREATE OR REPLACE VIEW staleness_status AS
SELECT
  *,
  CASE
    WHEN last_seen_ts IS NULL
      OR now() - last_seen_ts > (expected_cadence_hours * INTERVAL '1 hour')
      THEN 'stale'
    ELSE 'fresh'
  END AS status,
  now() - observed_at AS observation_age
FROM staleness;

CREATE INDEX IF NOT EXISTS idx_staleness_asset_kind ON staleness(asset_kind);
