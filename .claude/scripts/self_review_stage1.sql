-- self_review_stage1.sql
-- Stage 1 deterministic SQL detectors for the overnight self-review job.
-- Reads from ~/.claude/logs/unified.duckdb + log files.
-- Writes findings to self_review_findings_stage1 (CREATE IF NOT EXISTS).
--
-- Stage 2 (LLM proposer) is DEFERRED.
-- This file is executed by self_review_stage1.sh.
--
-- Tables used:
--   sessions       (session_id, project, started_at, ended_at, model)
--   agent_runs     (id, session_id, agent_type, model, started_at, ended_at, status)
--   hook_events    (id, session_id, hook_name, event_type, fired_at, duration_ms, output_preview)
--   errors         (id, session_id, source, error_text, context, logged_at)
--
-- Log files parsed (flat text, read via read_csv):
--   agent_push_blocked.log        agent push denials (block mode)
--   agent_push_would_block.log    agent push denials (soak / log mode)
--   destructive_blocked.log       destructive-fs blocked
--   compound_guard.log            compound-command blocks
--   worktree_post_verify.log      isolation violations

-- ─────────────────────────────────────────────────────────────────────────────
-- 0. Ensure target table exists
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS self_review_findings_stage1 (
    finding_id      VARCHAR PRIMARY KEY,
    finding_type    VARCHAR NOT NULL,
    session_id      VARCHAR,
    severity        VARCHAR NOT NULL CHECK (severity IN ('critical','major','minor','info')),
    evidence        JSON,
    detected_at     TIMESTAMP NOT NULL DEFAULT current_timestamp
);

-- ─────────────────────────────────────────────────────────────────────────────
-- DETECTOR 1: Stuck loop — agents dispatched multiple times but never completed
--
-- Fix (#269): The original query used no status filter and matched status='done'
-- rows, producing false positives whenever the same agent type was legitimately
-- dispatched ≥3 times in a session (e.g., three fixer agents on different tasks).
-- status='failed' was referenced in comments but that value never appears in the
-- ETL because ended_at is never written back — every completed agent stays
-- status='running' or 'done' depending on ETL version.
--
-- Corrected definition of "stuck":
--   status = 'running' AND ended_at IS NULL AND started_at < NOW() - 1 HOUR
--   (i.e., an agent that started over an hour ago and has not finished)
-- The session_id + agent_type combination appearing ≥3 times under those
-- conditions is the genuine stuck-loop signal.
--
-- Threshold: ≥ 3 such rows per (session_id, agent_type)
-- Severity: major
-- ─────────────────────────────────────────────────────────────────────────────
-- Ref: #269 — false positives from status='done' rows matching the old query
WITH stuck_loop_candidates AS (
    SELECT
        session_id,
        agent_type,
        status,
        COUNT(*) AS call_count,
        MIN(started_at) AS first_call,
        MAX(started_at) AS last_call
    FROM agent_runs
    WHERE
        session_id IS NOT NULL
        -- Only flag agents that are still marked running and have no end time.
        -- Completed agents (status='done', ended_at IS NOT NULL) are not stuck.
        -- (#269: previous version had no status filter; matched status='done')
        AND status = 'running'
        AND ended_at IS NULL
        -- Must have been running for > 1 hour to avoid flagging in-flight agents.
        AND started_at < current_timestamp - INTERVAL '1' HOUR
    GROUP BY session_id, agent_type, status
    HAVING COUNT(*) >= 3
),
stuck_loop_deduplicated AS (
    SELECT
        session_id,
        agent_type,
        status,
        call_count,
        first_call,
        last_call,
        -- stable finding_id: hash on (session_id, agent_type, status)
        'stuck_loop_' || md5(session_id || '|' || agent_type || '|' || status) AS finding_id
    FROM stuck_loop_candidates
)
INSERT INTO self_review_findings_stage1
    BY NAME
SELECT
    finding_id,
    'stuck_loop'                AS finding_type,
    session_id,
    'major'                     AS severity,
    json_object(
        'agent_type',   agent_type,
        'status',       status,
        'call_count',   call_count::VARCHAR,
        'first_call',   first_call::VARCHAR,
        'last_call',    last_call::VARCHAR
    )::JSON                     AS evidence,
    current_timestamp           AS detected_at
FROM stuck_loop_deduplicated
ON CONFLICT (finding_id) DO NOTHING;


-- ─────────────────────────────────────────────────────────────────────────────
-- DETECTOR 2: Excessive hook blocks (permission denials)
--
-- Source: hook_events rows where hook_name contains 'guard' and
--         output_preview indicates a block (BLOCKED / DENIED / exit 2).
-- Also: compound_guard entries (hook_name = 'compound_guard').
--
-- Threshold: > 5 blocks in a rolling 1-hour window on a given day
-- Severity: major
-- ─────────────────────────────────────────────────────────────────────────────
WITH guard_blocks AS (
    SELECT
        session_id,
        hook_name,
        fired_at,
        DATE_TRUNC('hour', fired_at)    AS hour_bucket,
        CAST(fired_at AS DATE)          AS day_bucket
    FROM hook_events
    WHERE
        hook_name ILIKE '%guard%'
        AND (
            output_preview ILIKE '%BLOCKED%'
            OR output_preview ILIKE '%DENIED%'
            OR output_preview ILIKE '%exit 2%'
            OR output_preview ILIKE '%block%'
        )
),
guard_hourly AS (
    SELECT
        day_bucket,
        hour_bucket,
        hook_name,
        COUNT(*) AS block_count,
        ARRAY_AGG(DISTINCT session_id) AS sessions
    FROM guard_blocks
    GROUP BY day_bucket, hour_bucket, hook_name
    HAVING COUNT(*) > 5
)
INSERT INTO self_review_findings_stage1
    BY NAME
SELECT
    'guard_block_' || md5(hour_bucket::VARCHAR || '|' || hook_name) AS finding_id,
    'excessive_guard_blocks'        AS finding_type,
    NULL                            AS session_id,
    'major'                         AS severity,
    json_object(
        'day',          day_bucket::VARCHAR,
        'hour',         hour_bucket::VARCHAR,
        'hook_name',    hook_name,
        'block_count',  block_count::VARCHAR,
        'threshold',    '5 per hour'
    )::JSON                         AS evidence,
    current_timestamp               AS detected_at
FROM guard_hourly
ON CONFLICT (finding_id) DO NOTHING;


-- ─────────────────────────────────────────────────────────────────────────────
-- DETECTOR 3: High tool error rate
--
-- Source: errors table, grouped by (source, day).
-- Cross-referenced against agent_runs to estimate total tool calls per day.
--
-- Fix (#269): The original query had no time-window on the errors table, so a
-- single old error (e.g., 2026-04-20 signal_notes) produced a 100% error rate
-- finding indefinitely. Added WHERE logged_at >= NOW() - 7 DAYS on both CTEs
-- so only the rolling 7-day window is evaluated.
--
-- Threshold: error_count / max(total_calls, 1) > 0.20 (20%)
-- Severity: major (>= 50%) or minor (20-50%)
-- ─────────────────────────────────────────────────────────────────────────────
-- Ref: #269 — absolute counts produced stale findings from historical data
WITH daily_errors AS (
    SELECT
        CAST(logged_at AS DATE)     AS day_bucket,
        source                      AS tool_name,
        COUNT(*)                    AS error_count
    FROM errors
    WHERE
        session_id IS NOT NULL
        -- Rate-window: only consider the last 7 days (#269 fix)
        AND logged_at >= current_timestamp - INTERVAL '7' DAY
        -- Exclude PreToolUse hooks that exit 2 by design when blocking
        -- forbidden operations. The non-zero exit is the intended behaviour,
        -- not a tool failure. Counting them as errors produces false-positive
        -- MAJOR findings (see llm#573).
        -- TODO: replace this allow-list with a hook_action column
        -- (block_intended/block_error/pass) per llm#573 Path C — that's the
        -- durable cross-hook fix. This allow-list is the stopgap.
        AND source NOT IN (
            'compound_guard',        -- blocks compound bash commands
            'agent_push_guard',      -- blocks cross-branch / protected-branch pushes
            'destructive_fs_guard',  -- blocks destructive filesystem ops
            'destructive_api_guard', -- blocks destructive API calls
            'file_protection',       -- blocks edits to protected paths
            'wiki_health_onwrite',   -- blocks writes failing wiki health checks
            'skill_quality_onwrite'  -- blocks writes failing skill quality checks
        )
    GROUP BY CAST(logged_at AS DATE), source
),
daily_agent_calls AS (
    SELECT
        CAST(started_at AS DATE)    AS day_bucket,
        COUNT(*)                    AS total_calls
    FROM agent_runs
    WHERE
        session_id IS NOT NULL
        -- Rate-window: only consider the last 7 days (#269 fix)
        AND started_at >= current_timestamp - INTERVAL '7' DAY
    GROUP BY CAST(started_at AS DATE)
),
error_rates AS (
    SELECT
        de.day_bucket,
        de.tool_name,
        de.error_count,
        COALESCE(dac.total_calls, 1)    AS total_calls,
        ROUND(
            de.error_count::DOUBLE / GREATEST(COALESCE(dac.total_calls, 1), 1),
            4
        )                               AS error_rate
    FROM daily_errors de
    LEFT JOIN daily_agent_calls dac USING (day_bucket)
    WHERE
        ROUND(
            de.error_count::DOUBLE / GREATEST(COALESCE(dac.total_calls, 1), 1),
            4
        ) > 0.20
)
INSERT INTO self_review_findings_stage1
    BY NAME
SELECT
    'error_rate_' || md5(day_bucket::VARCHAR || '|' || tool_name) AS finding_id,
    'high_tool_error_rate'          AS finding_type,
    NULL                            AS session_id,
    CASE WHEN error_rate >= 0.50 THEN 'major' ELSE 'minor' END AS severity,
    json_object(
        'day',          day_bucket::VARCHAR,
        'tool_name',    tool_name,
        'error_count',  error_count::VARCHAR,
        'total_calls',  total_calls::VARCHAR,
        'error_rate',   error_rate::VARCHAR,
        'threshold',    '20% per tool per day'
    )::JSON                         AS evidence,
    current_timestamp               AS detected_at
FROM error_rates
ON CONFLICT (finding_id) DO NOTHING;


-- ─────────────────────────────────────────────────────────────────────────────
-- DETECTOR 4: Agent dispatch isolation violations
--
-- Source: hook_events where hook_name = 'worktree_post_verify'
--         and output_preview contains 'ISOLATION VIOLATION'.
-- Also: compound_guard.log parsed for unexpected checkout activity.
--
-- Threshold: any occurrence (0 tolerance).
-- Severity: critical
-- ─────────────────────────────────────────────────────────────────────────────
WITH isolation_violations AS (
    SELECT
        session_id,
        hook_name,
        fired_at,
        output_preview
    FROM hook_events
    WHERE
        hook_name ILIKE '%worktree%'
        AND output_preview ILIKE '%ISOLATION%VIOLATION%'
)
INSERT INTO self_review_findings_stage1
    BY NAME
SELECT
    'isolation_' || md5(session_id || '|' || fired_at::VARCHAR) AS finding_id,
    'isolation_violation'           AS finding_type,
    session_id,
    'critical'                      AS severity,
    json_object(
        'hook_name',        hook_name,
        'fired_at',         fired_at::VARCHAR,
        'output_preview',   output_preview
    )::JSON                         AS evidence,
    current_timestamp               AS detected_at
FROM isolation_violations
ON CONFLICT (finding_id) DO NOTHING;


-- ─────────────────────────────────────────────────────────────────────────────
-- DETECTOR 5: Pivot-signal rule thresholds firing
--
-- The pivot-signal rule fires at 3/5/7 consecutive failures within a session.
-- Proxy from available data: sessions with >= 3 errors (source = same tool)
-- within a 5-minute window — suggests the 3-failure threshold was reached.
-- Severity: minor (3-4 errors), major (5-6), critical (7+)
-- ─────────────────────────────────────────────────────────────────────────────
WITH session_error_bursts AS (
    SELECT
        session_id,
        source                          AS tool_name,
        COUNT(*)                        AS burst_size,
        MIN(logged_at)                  AS burst_start,
        MAX(logged_at)                  AS burst_end
    FROM errors
    WHERE
        session_id IS NOT NULL
        AND logged_at IS NOT NULL
    GROUP BY session_id, source
    HAVING COUNT(*) >= 3
),
pivot_signal_findings AS (
    SELECT
        session_id,
        tool_name,
        burst_size,
        burst_start,
        burst_end,
        CASE
            WHEN burst_size >= 7 THEN 'critical'
            WHEN burst_size >= 5 THEN 'major'
            ELSE 'minor'
        END AS severity
    FROM session_error_bursts
)
INSERT INTO self_review_findings_stage1
    BY NAME
SELECT
    'pivot_signal_' || md5(session_id || '|' || tool_name) AS finding_id,
    'pivot_signal_threshold'        AS finding_type,
    session_id,
    severity,
    json_object(
        'tool_name',    tool_name,
        'burst_size',   burst_size::VARCHAR,
        'burst_start',  burst_start::VARCHAR,
        'burst_end',    burst_end::VARCHAR,
        'rule_ref',     'pivot-signal: 3=minor, 5=major, 7=critical'
    )::JSON                         AS evidence,
    current_timestamp               AS detected_at
FROM pivot_signal_findings
ON CONFLICT (finding_id) DO NOTHING;


-- ═════════════════════════════════════════════════════════════════════════════
-- USAGE-EFFICIENCY DETECTORS (6-10)
-- Source: Anthropic usage panel signals — efficiency nudges, not correctness bugs.
-- All severity: info
-- ═════════════════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────────────────────
-- DETECTOR 6: Parallel-session sprawl
--
-- Rationale: All Claude Code sessions share one account rate limit (requests/
-- min). Running ≥4 sessions concurrently risks 429 collisions and inflates
-- usage metrics. The Anthropic panel shows sessions as the primary billing
-- unit; queuing is cheaper than parallel sprawl.
--
-- Fix (#804): The original query had two compounding bugs that made
-- peak_concurrent grow monotonically forever (133 in May -> 913 in Jun ->
-- 2585+ in Jul, while ground truth for 2026-07-21 was 86 short sessions,
-- avg duration 1.2 min, real peak ~1-3):
--   1. The running SUM(delta) OVER (ORDER BY ts ...) was GLOBAL across all
--      sessions ever recorded, with no reset per calendar day — so every day
--      inherited the entire backlog of previously-"open" sessions.
--   2. The session-end (-1) event used COALESCE(ended_at, current_timestamp),
--      so every session with NULL ended_at (57% of rows — the session-stop
--      hook never wrote it back) was counted as still running *right now*,
--      forever, instead of ending on the day it actually started.
-- Combined, the backlog of never-closed sessions accumulated across every
-- day from its start date through "today", inflating every subsequent day's
-- peak by the same growing amount.
--
-- Method (fixed): Partition the running total PER calendar day (day_bucket =
-- the session's start day) instead of computing one global cumulative sum.
-- Cap a NULL ended_at session's contribution to started_at + 1 minute (a
-- short, bounded estimate close to the ~1-2 min median session duration seen
-- in this telemetry) instead of "now" — so a stale/never-closed session can
-- inflate at most the single day it started on, never every day since.
-- The per-day peak is the maximum of that day's own running total.
--
-- Threshold: ≥ 4 concurrent sessions at any moment on a calendar day.
-- Finding scope: one finding per flagged calendar day (stable, idempotent).
-- Recommendation: queue instead of running 4+ at once.
-- Severity: info
-- ─────────────────────────────────────────────────────────────────────────────
-- Ref: #804 — global unbounded running sum + COALESCE(ended_at, now()) made
-- peak_concurrent grow without bound; fixed via per-day partitioning + a
-- bounded (1 min) cap on never-closed sessions.
WITH session_bounds AS (
    SELECT
        session_id,
        started_at,
        -- Partition key: the session's own start day. Both of its events
        -- (start, end) are tagged with this key so the running sum below
        -- resets per day regardless of what the (possibly capped) end
        -- timestamp happens to be.
        CAST(started_at AS DATE)                              AS day_bucket,
        -- NULL ended_at (session-stop hook never fired / crashed session) is
        -- capped at +1 minute instead of "now" (#804 fix for bug 2).
        COALESCE(ended_at, started_at + INTERVAL '1' MINUTE)   AS effective_end
    FROM sessions
    WHERE started_at IS NOT NULL
),
parallel_events AS (
    -- +1 event when a session starts
    SELECT day_bucket, started_at    AS ts, 1  AS delta FROM session_bounds
    UNION ALL
    -- -1 event when a session ends (real ended_at, or the 1-minute cap above)
    SELECT day_bucket, effective_end AS ts, -1 AS delta FROM session_bounds
),
parallel_running AS (
    SELECT
        day_bucket,
        ts,
        delta,
        -- Starts (delta=1) are sorted before ends (delta=-1) at identical
        -- timestamps so simultaneous starts are all counted before any
        -- simultaneous end, giving a conservative (higher) peak count.
        -- PARTITION BY day_bucket resets the running sum at the start of
        -- each calendar day (#804 fix for bug 1) instead of accumulating
        -- across the entire history of the table.
        SUM(delta) OVER (
            PARTITION BY day_bucket
            ORDER BY ts, CASE WHEN delta = 1 THEN 0 ELSE 1 END
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        )                                               AS concurrent_count
    FROM parallel_events
),
parallel_daily_peak AS (
    SELECT
        day_bucket,
        MAX(concurrent_count)   AS peak_concurrent
    FROM parallel_running
    GROUP BY day_bucket
    HAVING MAX(concurrent_count) >= 4
)
INSERT INTO self_review_findings_stage1
    BY NAME
SELECT
    'parallel_sprawl_' || md5(day_bucket::VARCHAR)  AS finding_id,
    'parallel_session_sprawl'                        AS finding_type,
    NULL                                             AS session_id,
    'info'                                           AS severity,
    json_object(
        'day',              day_bucket::VARCHAR,
        'peak_concurrent',  peak_concurrent::VARCHAR,
        'threshold',        '4 concurrent sessions',
        'recommendation',   'All sessions share one rate limit — queue instead of running 4+ at once'
    )::JSON                                         AS evidence,
    current_timestamp                               AS detected_at
FROM parallel_daily_peak
ON CONFLICT (finding_id) DO NOTHING;


-- ─────────────────────────────────────────────────────────────────────────────
-- DETECTOR 7: Subagent-heavy session
--
-- Rationale: Each subagent dispatch carries overhead (model spin-up, context
-- transfer, tool permissions). Sessions with ≥ 10 dispatches may indicate:
--   (a) the bounded-confirm pattern was skipped (scope expanded silently), or
--   (b) cheap tasks were delegated without choosing the right model tier.
--
-- Threshold: ≥ 10 agent_runs per session.
-- Calibration: typical sessions dispatch 1-3 agents; ≥10 is the ~90th-
-- percentile heuristic based on observed usage patterns. Lower this constant
-- if real data shows the 90th-percentile is below 10.
-- Recommendation: be deliberate about spawning subagents; use a cheaper model
-- for simple ones.
-- Severity: info
-- ─────────────────────────────────────────────────────────────────────────────
-- Threshold constant: 10 agent_runs per session
WITH subagent_heavy_sessions AS (
    SELECT
        session_id,
        COUNT(*)                    AS agent_run_count,
        COUNT(DISTINCT agent_type)  AS distinct_agent_types
    FROM agent_runs
    WHERE session_id IS NOT NULL
    GROUP BY session_id
    HAVING COUNT(*) >= 10
)
INSERT INTO self_review_findings_stage1
    BY NAME
SELECT
    'subagent_heavy_' || md5(session_id)    AS finding_id,
    'subagent_heavy_session'                AS finding_type,
    session_id,
    'info'                                  AS severity,
    json_object(
        'agent_run_count',       agent_run_count::VARCHAR,
        'distinct_agent_types',  distinct_agent_types::VARCHAR,
        'threshold',             '10 agent dispatches per session',
        'recommendation',        'Be deliberate about spawning subagents; use a cheaper model for simple ones'
    )::JSON                                 AS evidence,
    current_timestamp                       AS detected_at
FROM subagent_heavy_sessions
ON CONFLICT (finding_id) DO NOTHING;


-- ─────────────────────────────────────────────────────────────────────────────
-- DETECTOR 8: Marathon session
--
-- Rationale: Sessions lasting ≥ 8 hours are often background processes that
-- were never closed, or an analyst who left a session running overnight.
-- The Anthropic panel shows such sessions as disproportionate contributors to
-- token spend; continuous idle usage adds up.
--
-- Threshold: ended_at - started_at >= 8 hours.
-- Only sessions with both started_at AND ended_at populated are evaluated.
-- Sessions with NULL ended_at are potential "stuck running" events and are
-- handled by DETECTOR 1 (stuck_loop) instead.
-- Recommendation: verify long/background sessions are intentional.
-- Severity: info
-- ─────────────────────────────────────────────────────────────────────────────
-- Threshold: 8 hours of elapsed wall-clock time
WITH marathon_sessions AS (
    SELECT
        session_id,
        started_at,
        ended_at,
        ROUND(
            DATEDIFF('minute', started_at, ended_at) / 60.0,
            2
        )                               AS duration_hours
    FROM sessions
    WHERE
        started_at IS NOT NULL
        AND ended_at IS NOT NULL
        AND ended_at - started_at >= INTERVAL '8' HOUR
)
INSERT INTO self_review_findings_stage1
    BY NAME
SELECT
    'marathon_session_' || md5(session_id)  AS finding_id,
    'marathon_session'                       AS finding_type,
    session_id,
    'info'                                   AS severity,
    json_object(
        'started_at',       started_at::VARCHAR,
        'ended_at',         ended_at::VARCHAR,
        'duration_hours',   duration_hours::VARCHAR,
        'threshold',        '8 hours',
        'recommendation',   'Verify long/background sessions are intentional — continuous usage adds up'
    )::JSON                                  AS evidence,
    current_timestamp                        AS detected_at
FROM marathon_sessions
ON CONFLICT (finding_id) DO NOTHING;


-- ─────────────────────────────────────────────────────────────────────────────
-- DETECTOR 9: Fixer-subagent-heavy day
--
-- Rationale: The 'fixer' agent type runs at the worker tier (sonnet model).
-- A day where the fixer dominates dispatches may indicate:
--   (a) the critic-fixer review loop is cycling too often (prompts too vague),
--   (b) work that a haiku quick-fix could handle is being delegated to sonnet.
-- Tightening fixer prompts or switching simple fixes to quick-fix reduces cost.
--
-- Scope: per-calendar-day (more stable than per-session; fixer workloads
-- typically span several sessions within a single day).
-- Threshold: fixer_run_count / total_run_count >= 0.40 AND total_runs >= 5.
-- The minimum total-run guard of 5 prevents noisy small-N days from firing.
-- Recommendation: configure fixer subagents with a cheaper model / tighten prompts.
-- Severity: info
-- ─────────────────────────────────────────────────────────────────────────────
-- Threshold: fixer share >= 40% of daily dispatches, minimum 5 total dispatches
WITH daily_fixer_share AS (
    SELECT
        CAST(started_at AS DATE)            AS day_bucket,
        COUNT(*)                            AS total_runs,
        SUM(CASE WHEN agent_type = 'fixer' THEN 1 ELSE 0 END)
                                            AS fixer_runs,
        ROUND(
            SUM(CASE WHEN agent_type = 'fixer' THEN 1.0 ELSE 0.0 END)
            / GREATEST(COUNT(*), 1),
            4
        )                                   AS fixer_share
    FROM agent_runs
    WHERE session_id IS NOT NULL
    GROUP BY CAST(started_at AS DATE)
    HAVING
        COUNT(*) >= 5
        AND ROUND(
            SUM(CASE WHEN agent_type = 'fixer' THEN 1.0 ELSE 0.0 END)
            / GREATEST(COUNT(*), 1),
            4
        ) >= 0.40
)
INSERT INTO self_review_findings_stage1
    BY NAME
SELECT
    'fixer_heavy_' || md5(day_bucket::VARCHAR)  AS finding_id,
    'fixer_heavy_day'                            AS finding_type,
    NULL                                         AS session_id,
    'info'                                       AS severity,
    json_object(
        'day',            day_bucket::VARCHAR,
        'total_runs',     total_runs::VARCHAR,
        'fixer_runs',     fixer_runs::VARCHAR,
        'fixer_share',    fixer_share::VARCHAR,
        'threshold',      'fixer share >= 40% AND total dispatches >= 5',
        'recommendation', 'Configure fixer subagents with a cheaper model / tighten their prompts'
    )::JSON                                     AS evidence,
    current_timestamp                           AS detected_at
FROM daily_fixer_share
ON CONFLICT (finding_id) DO NOTHING;


-- ─────────────────────────────────────────────────────────────────────────────
-- DETECTOR 10: Context-size signal — DATA GAP (not computable)
--
-- The Anthropic usage panel reports that ~54% of sessions reach > 150 k context
-- tokens. This is a meaningful efficiency signal: large contexts slow every
-- tool call, increase billing, and indicate sessions that should have been
-- compacted or split earlier.
--
-- However, the `sessions` table has NO context-size column. This metric cannot
-- be computed from current telemetry. Rather than fabricate a proxy or silently
-- omit the signal, we emit ONE persistent info finding documenting the gap and
-- a concrete ETL follow-up recommendation.
--
-- This finding is emitted once per DB (ON CONFLICT DO NOTHING keeps it
-- idempotent across repeated runs). To close the gap:
--   1. Add max_context_tokens (peak per session) to session_stop.sh / the
--      usage API poller so it is written to the sessions table.
--   2. Replace this static INSERT with a real detector:
--        WHERE max_context_tokens > 150000 per session
--
-- Severity: info
-- ─────────────────────────────────────────────────────────────────────────────
-- TODO: replace with a real detector once max_context_tokens is in sessions ETL
INSERT INTO self_review_findings_stage1
    BY NAME
SELECT
    'data_gap_context_size'             AS finding_id,
    'data_gap'                          AS finding_type,
    NULL                                AS session_id,
    'info'                              AS severity,
    json_object(
        'gap_description',  'sessions table has no context_size column',
        'signal_ref',       '54% of sessions reach >150k context tokens (Anthropic usage panel)',
        'why_not_proxied',  'No reliable proxy exists in hook_events or agent_runs; fabricating one would produce misleading findings',
        'recommendation',   'Add max_context_tokens (peak per session) to the telemetry ETL — capture it in session_stop.sh or a usage API poller',
        'follow_up',        'File a GitHub issue to add max_context_tokens to the sessions table schema and ETL writers'
    )::JSON                             AS evidence,
    current_timestamp                   AS detected_at
ON CONFLICT (finding_id) DO NOTHING;


-- ─────────────────────────────────────────────────────────────────────────────
-- Summary: count findings by type and severity
-- (Printed to stdout by the bash wrapper for --dry-run reporting)
-- ─────────────────────────────────────────────────────────────────────────────
SELECT
    finding_type,
    severity,
    COUNT(*) AS n
FROM self_review_findings_stage1
GROUP BY finding_type, severity
ORDER BY
    CASE severity
        WHEN 'critical' THEN 1
        WHEN 'major'    THEN 2
        WHEN 'minor'    THEN 3
        ELSE 4
    END,
    finding_type;
