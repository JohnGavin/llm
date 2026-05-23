-- roborev_metrics_schema.sql
-- CREATE TABLE IF NOT EXISTS for all 5 roborev_* tables in unified.duckdb.
--
-- SCHEMAS FROZEN — llmtelemetry#144 depends on these column names and types.
-- Do NOT modify column names or types without a coordinated bump across both repos.
-- Tracked in llm#226.
--
-- All 5 tables are created on every ETL invocation (idempotent).
-- Slice 1 populates: roborev_daily_metrics, roborev_review_lifecycle.
-- Slice 2 will populate: roborev_agent_performance, roborev_threshold_changes,
--   roborev_cadence_efficacy.

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
