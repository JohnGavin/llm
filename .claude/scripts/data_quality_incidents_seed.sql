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
-- Boundaries are derived, not hand-typed (reproducible-ingestion rule).
-- NOTE ON TIMEZONE: `sessions.started_at` is a NAIVE TIMESTAMP in LOCAL time
-- (UTC+1 / BST at the time of the incident). Both bounds below are therefore
-- expressed in local time so they compare directly against `started_at`.
-- Mixing in a UTC instant here silently shifts the window by an hour.
--
-- window_start -- the last session with a REAL (non-reaper) duration, i.e.
-- the last known-good moment. Derived via:
--
--   duckdb -init /dev/null -readonly ~/.claude/logs/unified.duckdb -c \
--     "SELECT max(started_at) FROM sessions \
--      WHERE duration_min IS NOT NULL AND duration_min <> 120.0;"
--   -- 2026-07-23 23:50:22.360453
--
-- The first AFFECTED session is 2026-07-24 06:08:18.802979 (an overnight gap
-- separates the two, so the exact onset is unobservable; we take the first
-- affected row as window_start, which is the conservative choice -- it never
-- marks a known-good row as suspect).
--
-- window_end -- the instant the llm#915 fix went LIVE on this machine. That is
-- the deploy, not the merge: `~/.claude/hooks/` symlinks into the main
-- checkout, so the fix took effect at the fast-forward pull, not at PR merge
-- (llm#510). Derived via:
--
--   stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' \
--     /Users/johngavin/docs_gh/llm/.claude/hooks/session_stop.sh
--   -- 2026-08-05 17:29:22
--
-- DO NOT derive window_end from max(started_at) of reaper-marked rows. The
-- reaper only marks a session once it has been abandoned >6h, so at any given
-- moment the most recent affected sessions are NOT yet marked. Doing so ended
-- the window ~20h early and left 33 affected sessions outside it, reading as
-- trustworthy. "Zero marked rows today" means "not yet reaped", NOT "not
-- affected" -- an absence-of-evidence error of exactly the kind llm#913 is about.
--
-- Verified for the window below: n = 2036, of which 0 have a real duration and
-- 33 are not yet reaped (they will acquire the reaper marker later, and are
-- affected regardless).
--
-- NOTE ON CAUSE: the mechanism is proven by code inspection (two Stop-chain
-- hooks consuming one one-shot sentinel; see llm#915). The onset, however,
-- PREDATES the merge of llm#809 (2026-07-24 10:32:09 local) by ~4h -- the
-- gating change was evidently live from a local branch before the PR merged.
-- Do not restate the merge timestamp as the onset.
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
  TIMESTAMP '2026-08-05 17:29:22',
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
  TIMESTAMP '2026-08-05 17:29:22',
  'session_stop.sh DB stop-write never fired (Stop-chain sentinel consumed early); session_reaper.sql (llm#803) backfilled ended_at = started_at + INTERVAL 2 HOUR for every session in this window. Do not treat as observed end time.',
  'llm#913 / llm#915',
  TIMESTAMP '2026-08-05 00:00:00'
);
