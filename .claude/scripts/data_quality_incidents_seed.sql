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
-- NOTE ON CAUSE: the MECHANISM is proven by code inspection (two Stop-chain
-- hooks consuming one one-shot sentinel; see llm#915). The TRIGGER -- what
-- changed to put the system into that state, and when -- is NOT established.
--
-- An earlier revision of this file asserted that the onset predated llm#809's
-- merge because "the gating change was evidently live from a local branch
-- before the PR merged". That explanation is REFUTED. It was inference, not
-- a query result, and the queries contradict it:
--
--   1. `~/.claude/hooks` is a symlink to ~/docs_gh/llm/.claude/hooks, so hooks
--      resolve ONLY to the main checkout -- never to a worktree or branch.
--   2. The main checkout's HEAD did not move between 2026-07-22 09:35:57 and
--      2026-07-24 10:34:12 (`git -C ~/docs_gh/llm reflog show --date=iso-local
--      HEAD`). llm#809 was authored on a branch 2026-07-23 15:53:26 (8f5ea23),
--      merged 2026-07-24 10:32:09 (a34fea3), and reached the hook path at the
--      fast-forward pull 2026-07-24 10:34:12 -- not before.
--   3. 103 affected sessions started BEFORE that pull (06:08:18 -> 10:34:12),
--      i.e. while the llm#809 code demonstrably was not on the hook path.
--
-- So llm#809's deploy is not the onset, and the local-branch story cannot be
-- the reason it isn't. Do not restate EITHER the merge timestamp or that
-- explanation as the cause.
--
-- What IS established: nothing under version control changed across the onset.
-- The whole Stop chain was frozen -- settings.json and settings.local.json are
-- both symlinks into the same main checkout (and settings.local.json declares
-- no Stop hooks at all), and every hook script on the chain was byte-identical
-- through the window. The transition was nonetheless total, not gradual:
--
--   date        reaped  real-duration
--   2026-07-23    16      91
--   2026-07-24   108       0
--
-- The onset therefore falls in the unobserved overnight gap 2026-07-23
-- 23:50:22 -> 2026-07-24 06:08:18 (no sessions ran), and its trigger is
-- external to this repo -- a harness/environment change is the leading
-- hypothesis, UNCONFIRMED and deliberately not asserted here. Consequence
-- worth noting: llm#915 hardened the hook against the state, but whatever
-- produced that state is unidentified and could recur.
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
