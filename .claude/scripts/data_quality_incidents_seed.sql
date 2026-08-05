-- data_quality_incidents_seed.sql — seed rows for known data-quality incidents.
--
-- Idempotent: INSERT OR IGNORE on a fixed PK, safe to re-run.
-- Apply with:
--   bash .claude/scripts/data_quality_incidents_seed_apply.sh
-- (requires the `data_quality_incidents` table -- run
--  housekeeping_schema_apply.sh first if the table does not exist yet).
--
-- ---------------------------------------------------------------------------
-- Incident: llm#913 / llm#915 -- sessions.duration_min / ended_at not real
-- ---------------------------------------------------------------------------
-- From 2026-07-24 until the fix merged (2026-08-05), session_stop.sh's DB
-- stop-write never fired: a /bye sentinel was consumed by an earlier hook in
-- the Stop chain (fixed in llm#915). session_reaper.sql (llm#803) backfilled
-- every affected row with synthetic constants (ended_at = started_at +
-- INTERVAL 2 HOUR, duration_min = 120.0) and tagged `summary` with the
-- marker '[llm#803 reaper: ended_at is an ESTIMATE, no Stop event observed
-- within 6h]'. Decision: mark the window untrustworthy: do NOT attempt to
-- backfill real durations.
--
-- window_start / window_end below are NOT hand-typed -- they are the
-- min/max started_at of every reaper-marked row in the affected window,
-- read directly off the live DB (reproducible-ingestion rule) via:
--
--   duckdb -init /dev/null -readonly ~/.claude/logs/unified.duckdb -c \
--     "SELECT min(started_at), max(started_at), count(*) FROM sessions \
--      WHERE summary LIKE '%llm#803 reaper%' AND started_at >= '2026-07-24';"
--
-- Result at the time this incident was recorded (2026-08-05):
--   window_start = 2026-07-24 06:08:18.802979
--   window_end   = 2026-08-04 21:04:02.341085
--   n_affected   = 2003 (100% of sessions started_at >= 2026-07-24 up to
--                  window_end; 0 affected on/after 2026-08-05, confirming
--                  the fix landed and the window is closed)
--
-- The `>= '2026-07-24'` filter in the query above excludes reaper-marked
-- rows from *before* the outage (unrelated, ordinary abandoned/crashed
-- sessions that the reaper legitimately also catches) so window_start marks
-- the true start of the outage, not the reaper's general catch-all range.
-- One row per affected column (not a single row with column_name = NULL)
-- so a future automated consumer can join on the exact column it reads
-- without having to special-case a "whole asset" NULL.
INSERT OR IGNORE INTO data_quality_incidents
  (id, asset, column_name, window_start, window_end, reason, issue_ref, recorded_at)
VALUES (
  'llm913-sessions-duration_min-20260724',
  'sessions',
  'duration_min',
  TIMESTAMP '2026-07-24 06:08:18.802979',
  TIMESTAMP '2026-08-04 21:04:02.341085',
  'session_stop.sh DB stop-write never fired (Stop-chain sentinel consumed early); session_reaper.sql (llm#803) backfilled duration_min = 120.0 for every session in this window. Do not treat as observed duration.',
  'llm#913 / llm#915',
  TIMESTAMP '2026-08-05 00:00:00'
);

INSERT OR IGNORE INTO data_quality_incidents
  (id, asset, column_name, window_start, window_end, reason, issue_ref, recorded_at)
VALUES (
  'llm913-sessions-ended_at-20260724',
  'sessions',
  'ended_at',
  TIMESTAMP '2026-07-24 06:08:18.802979',
  TIMESTAMP '2026-08-04 21:04:02.341085',
  'session_stop.sh DB stop-write never fired (Stop-chain sentinel consumed early); session_reaper.sql (llm#803) backfilled ended_at = started_at + INTERVAL 2 HOUR for every session in this window. Do not treat as observed end time.',
  'llm#913 / llm#915',
  TIMESTAMP '2026-08-05 00:00:00'
);
