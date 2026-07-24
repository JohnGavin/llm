-- session_reaper.sql — llm#803
--
-- Closes `sessions` rows that were abandoned without ever firing a real
-- session-end Stop event (killed session, crashed harness, /clear, machine
-- sleep/reboot). The normal path (session_stop.sh, gated on the one-shot
-- /bye sentinel — see llm#803) writes `ended_at` exactly once, at the
-- session's real end. Sessions that never call /bye legitimately never hit
-- that path, so `ended_at` stays NULL forever without this sweep.
--
-- Staleness threshold: 6 hours since started_at. Chosen above the observed
-- p99 real session duration (~96 minutes across 4620 historical rows with a
-- genuine ended_at) plus a buffer for long working sessions, while staying
-- far below "abandoned for days". A currently-running session's own row is
-- never touched by this rule: its started_at is "just now", so it cannot be
-- more than 6 hours old yet.
--
-- Imputed end time: `started_at + INTERVAL 2 HOUR`, a fixed conservative
-- estimate. A session with no stop event 6+ hours after it started almost
-- certainly ended long before the reaper runs; 2 hours approximates a
-- typical working session without polluting duration_min with multi-day
-- outliers for rows that sat open across a sleep/reboot. The imputed nature
-- is recorded in `summary` so downstream analytics can filter or exclude
-- these rows from duration-sensitive aggregates.
UPDATE sessions
SET ended_at = started_at + INTERVAL 2 HOUR,
    duration_min = 120.0,
    summary = trim(COALESCE(summary, '') || ' [llm#803 reaper: ended_at is an ESTIMATE, no Stop event observed within 6h]')
WHERE ended_at IS NULL
  AND started_at < current_timestamp - INTERVAL 6 HOUR;
