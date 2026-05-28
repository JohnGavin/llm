-- roborev_metrics_schema.sql
-- CREATE TABLE IF NOT EXISTS for all 7 roborev_* tables in unified.duckdb.
--
-- SCHEMAS FROZEN — llmtelemetry#144 depends on these column names and types.
-- Do NOT modify column names or types without a coordinated bump across both repos.
-- Tracked in llm#226.
--
-- All 7 tables are created on every ETL invocation (idempotent).
-- Slice 1 populates: roborev_daily_metrics, roborev_review_lifecycle.
-- Slice 2 populates: roborev_agent_performance, roborev_threshold_changes,
--   roborev_cadence_efficacy.
-- Slice 3 (#286) populates: roborev_finding_lineage;
--   view roborev_finding_lineage_summary is rebuilt as CREATE OR REPLACE VIEW.

-- ── roborev_daily_metrics ─────────────────────────────────────────────────
-- Per-day × per-repo rollup.
-- PK: (date, repo)
CREATE TABLE IF NOT EXISTS roborev_daily_metrics (
  date                        DATE      NOT NULL,
  repo                        VARCHAR   NOT NULL,
  reviews_created             INTEGER   NOT NULL DEFAULT 0,
  reviews_passed              INTEGER   NOT NULL DEFAULT 0,
  reviews_failed              INTEGER   NOT NULL DEFAULT 0,
  reviews_autoclosed_severity INTEGER   NOT NULL DEFAULT 0,
  reviews_autoclosed_age      INTEGER   NOT NULL DEFAULT 0,
  parse_fail_count            INTEGER   NOT NULL DEFAULT 0,
  threshold_effective         VARCHAR,
  etl_run_at                  TIMESTAMP NOT NULL,
  PRIMARY KEY (date, repo)
);

-- ── roborev_review_lifecycle ──────────────────────────────────────────────
-- Per-review timeline. One row per review (keyed on review_id from reviews.id).
-- PK: review_id
CREATE TABLE IF NOT EXISTS roborev_review_lifecycle (
  review_id                    BIGINT    NOT NULL,
  job_id                       BIGINT    NOT NULL,
  repo                         VARCHAR   NOT NULL,
  agent                        VARCHAR,
  model                        VARCHAR,
  branch                       VARCHAR,
  commit_sha                   VARCHAR,
  created_at                   TIMESTAMP,
  started_at                   TIMESTAMP,
  finished_at                  TIMESTAMP,
  duration_s                   DOUBLE,
  verdict                      CHAR(1),
  severity_max                 VARCHAR,
  closed_at                    TIMESTAMP,
  close_reason                 VARCHAR,
  autoclose_threshold_at_close VARCHAR,
  PRIMARY KEY (review_id)
);

-- ── roborev_agent_performance ─────────────────────────────────────────────
-- Per-day × per-agent rollup. Slice 2 will populate.
-- PK: (date, agent, model)
CREATE TABLE IF NOT EXISTS roborev_agent_performance (
  date             DATE    NOT NULL,
  agent            VARCHAR NOT NULL,
  model            VARCHAR NOT NULL DEFAULT '',
  n_runs           INTEGER NOT NULL DEFAULT 0,
  pass_count       INTEGER NOT NULL DEFAULT 0,
  fail_count       INTEGER NOT NULL DEFAULT 0,
  error_count      INTEGER NOT NULL DEFAULT 0,
  p50_duration_s   DOUBLE,
  p90_duration_s   DOUBLE,
  total_tokens_in  BIGINT,
  total_tokens_out BIGINT,
  total_cost_usd   DOUBLE,
  PRIMARY KEY (date, agent, model)
);

-- ── roborev_threshold_changes ─────────────────────────────────────────────
-- Audit trail for severity-threshold changes. Slice 2 will populate.
-- PK: (changed_at_utc, repo)
CREATE TABLE IF NOT EXISTS roborev_threshold_changes (
  changed_at_utc TIMESTAMP NOT NULL,
  repo           VARCHAR   NOT NULL,
  old_threshold  VARCHAR,
  new_threshold  VARCHAR   NOT NULL,
  source         VARCHAR,
  actor          VARCHAR,
  PRIMARY KEY (changed_at_utc, repo)
);

-- ── roborev_cadence_efficacy ──────────────────────────────────────────────
-- Per-day × per-repo. Answers "did cadence reduction cost us reviews?"
-- Slice 2 will populate.
-- PK: (date, repo)
CREATE TABLE IF NOT EXISTS roborev_cadence_efficacy (
  date                       DATE    NOT NULL,
  repo                       VARCHAR NOT NULL,
  polls_run                  INTEGER NOT NULL DEFAULT 0,
  polls_noop                 INTEGER NOT NULL DEFAULT 0,
  polls_enqueued             INTEGER NOT NULL DEFAULT 0,
  reviews_created_via_poll   INTEGER NOT NULL DEFAULT 0,
  reviews_created_via_hook   INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (date, repo)
);

-- ── roborev_finding_lineage ───────────────────────────────────────────────
-- Heuristic re-review chain. One row per (finding/review, attempt position).
-- Lineage is derived from observable signals only — no parent_job_id exists yet
-- (see llm#286 for the upstream ask). Priority of lineage_method:
--   1. parent_job_id  (forward-compatible when roborev starts populating it)
--   2. patch_id       (same patch re-reviewed across jobs, 31% set)
--   3. commit_branch  (same repo+branch+commit_id reviewed >1 time)
--   4. solo           (single-attempt finding, no re-review detected)
-- PK: (finding_id, attempt_n) — finding_id = reviews.id
CREATE TABLE IF NOT EXISTS roborev_finding_lineage (
  finding_id          BIGINT    NOT NULL,
  attempt_n           INTEGER   NOT NULL,
  lineage_method      VARCHAR   NOT NULL,
  job_id              BIGINT    NOT NULL,
  created_at          TIMESTAMP,
  verdict_bool        INTEGER,
  closed              INTEGER   NOT NULL DEFAULT 0,
  chain_size          INTEGER   NOT NULL DEFAULT 1,
  is_closing_attempt  BOOLEAN   NOT NULL DEFAULT FALSE,
  PRIMARY KEY (finding_id, attempt_n)
);

-- ── roborev_finding_lineage_summary (view) ────────────────────────────────
-- Per-finding summary: attempt count, time-to-close, verdict chain.
-- Rebuilt as CREATE OR REPLACE VIEW on each ETL run (views are cheap to recreate).
CREATE OR REPLACE VIEW roborev_finding_lineage_summary AS
SELECT
  fl.finding_id,
  (SELECT rp.name
   FROM roborev_review_lifecycle rl
   JOIN roborev_finding_lineage fl2 ON fl2.finding_id = rl.review_id
                                    AND fl2.attempt_n = 1
   WHERE fl2.finding_id = fl.finding_id
   LIMIT 1) AS repo,
  MIN(fl.lineage_method)                            AS lineage_method,
  COUNT(*)                                          AS n_attempts,
  MIN(fl.created_at)                                AS created_at_first,
  MAX(CASE WHEN fl.closed = 1 THEN fl.created_at END) AS closed_at_last,
  ROUND(
    EXTRACT(EPOCH FROM
      (MAX(CASE WHEN fl.closed = 1 THEN fl.created_at END) - MIN(fl.created_at))
    ) / 3600.0,
    2
  )                                                 AS time_to_close_hrs,
  STRING_AGG(
    CASE WHEN fl.verdict_bool = 1 THEN 'clean' ELSE 'fail' END,
    '→' ORDER BY fl.attempt_n
  )                                                 AS verdict_chain
FROM roborev_finding_lineage fl
GROUP BY fl.finding_id;
