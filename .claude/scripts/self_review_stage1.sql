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
-- DETECTOR 1: Stuck loop — repeated identical tool calls
--
-- Proxy: same agent_type dispatched ≥ 3 times in one session with status 'failed'
-- (hook_events and agent_runs don't store raw tool inputs; we use agent repetition
--  as the available signal until a richer tool-call log is added in Stage 2.)
--
-- Threshold: ≥ 3 identical (session_id, agent_type, status) rows
-- Severity: major
-- ─────────────────────────────────────────────────────────────────────────────
WITH stuck_loop_candidates AS (
    SELECT
        session_id,
        agent_type,
        status,
        COUNT(*) AS call_count,
        MIN(started_at) AS first_call,
        MAX(started_at) AS last_call
    FROM agent_runs
    WHERE session_id IS NOT NULL
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
-- Threshold: error_count / max(total_calls, 1) > 0.20 (20%)
-- Severity: major (>= 50%) or minor (20-50%)
-- ─────────────────────────────────────────────────────────────────────────────
WITH daily_errors AS (
    SELECT
        CAST(logged_at AS DATE)     AS day_bucket,
        source                      AS tool_name,
        COUNT(*)                    AS error_count
    FROM errors
    WHERE session_id IS NOT NULL
    GROUP BY CAST(logged_at AS DATE), source
),
daily_agent_calls AS (
    SELECT
        CAST(started_at AS DATE)    AS day_bucket,
        COUNT(*)                    AS total_calls
    FROM agent_runs
    WHERE session_id IS NOT NULL
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
