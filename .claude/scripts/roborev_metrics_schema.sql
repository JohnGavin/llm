-- roborev_metrics_schema.sql
-- CREATE TABLE IF NOT EXISTS for all 7 roborev_* tables in unified.duckdb.
--
-- SCHEMAS FROZEN — llmtelemetry#144 depends on these column names and types.
-- Do NOT modify column names or types without a coordinated bump across both repos.
-- Tracked in llm#226.
--
-- All 9 tables are created on every ETL invocation (idempotent).
-- Slice 1 populates: roborev_daily_metrics, roborev_review_lifecycle.
-- Slice 2 populates: roborev_agent_performance, roborev_threshold_changes,
--   roborev_cadence_efficacy, codex_provider_invocations (#380).
-- Slice 3 (#286) populates: roborev_finding_lineage;
--   view roborev_finding_lineage_summary is rebuilt as CREATE OR REPLACE VIEW.
-- model_pricing (llm#795) is seeded on every ETL --apply run via
--   seed_model_pricing() in roborev_metrics_etl.R (not just at first
--   table creation — see that function's docstring).

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

-- ADDITIVE columns (llm#928, 2026-08-06) — safe under the FROZEN note above:
-- nothing is renamed or retyped, and downstream selects by name.
--
-- WHY: `reviews_passed`/`reviews_failed` are derived from `reviews.verdict_bool`,
-- which only exists once a job produced a review. A job that FAILS never
-- produces one, so it counts in `reviews_created` and in neither of the other
-- two — job-level failure had no column at all. On 2026-08-03 this table read
-- `reviews_failed = 5` for llm while 582 jobs actually failed that day.
--
-- `reviews_failed` keeps its meaning (verdict failed) and its name;
-- llmtelemetry#144 reads it. The new columns sit alongside it.
--
-- ALTER ... ADD COLUMN IF NOT EXISTS is idempotent in DuckDB and backfills
-- existing rows with the DEFAULT. Note DuckDB rejects NOT NULL in ADD COLUMN
-- ("Adding columns with constraints not yet supported"), so these carry
-- DEFAULT 0 only — matching the intent without the constraint.
ALTER TABLE roborev_daily_metrics ADD COLUMN IF NOT EXISTS jobs_failed           INTEGER DEFAULT 0;
ALTER TABLE roborev_daily_metrics ADD COLUMN IF NOT EXISTS jobs_failed_ephemeral INTEGER DEFAULT 0;
ALTER TABLE roborev_daily_metrics ADD COLUMN IF NOT EXISTS jobs_failed_quota     INTEGER DEFAULT 0;
ALTER TABLE roborev_daily_metrics ADD COLUMN IF NOT EXISTS jobs_failed_agent     INTEGER DEFAULT 0;
ALTER TABLE roborev_daily_metrics ADD COLUMN IF NOT EXISTS jobs_failed_other     INTEGER DEFAULT 0;

-- ADDITIVE columns (llm#928 items 3-4, 2026-08-29) — same FROZEN-safe pattern
-- as the jobs_failed_* block above.
--
-- is_ephemeral: TRUE when this (date, repo) row's jobs came from a repo whose
-- root_path lives under a temp root (agent worktree / test fixture, llm#923).
-- #928 found `roborev_daily_metrics` (the mirror) holding 720 dead repo names
-- vs 20 real ones, because #923's cleanup deleted the ephemeral rows from the
-- SOURCE (reviews.db) but never touched this mirror. Lets downstream
-- consumers exclude the noise without a destructive rebuild of history.
--
-- jobs_dropped: jobs enqueued in this window that, once stale, have NEITHER a
-- review (verdict) NOR a jobs_failed_* classification — generalises #927
-- ("commits with a failed review and no successful review", reported by
-- nothing) to jobs stuck at status='queued'/'running' forever, which are
-- exactly as invisible to `reviews_created`/`reviews_passed`/`reviews_failed`.
ALTER TABLE roborev_daily_metrics ADD COLUMN IF NOT EXISTS jobs_dropped INTEGER DEFAULT 0;
ALTER TABLE roborev_daily_metrics ADD COLUMN IF NOT EXISTS is_ephemeral BOOLEAN DEFAULT FALSE;

-- ── roborev_review_lifecycle ──────────────────────────────────────────────
-- Per-review timeline. One row per review (keyed on review_id from reviews.id).
-- PK: review_id
-- ADDITIVE columns (llm#379, 2026-05-31) — safe; downstream uses SELECT by name:
--   fix_commit_sha, fix_commit_at, fix_method
-- fix_method vocabulary: manual | commit_reference | pr_close |
--   autoclose_severity | unknown
-- Unblocks llmtelemetry #146 Q4 (time-to-fix), Q9 (false-positive rate),
-- Q14 (closing-the-loop funnel).
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
  fix_commit_sha               VARCHAR,
  fix_commit_at                TIMESTAMP,
  fix_method                   VARCHAR,
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

-- ── codex_provider_invocations ───────────────────────────────────────────
-- One row per codex_with_fallback.sh invocation (from ~/.claude/logs/codex_fallback/*.jsonl).
-- Populated by roborev_metrics_etl.R via read_codex_fallback_jsonl().
-- Token counts are approximated from byte sizes (4 bytes ≈ 1 token).
-- Cost is computed via the versioned model_pricing table below (llm#795).
-- PK: invocation_id
CREATE TABLE IF NOT EXISTS codex_provider_invocations (
  invocation_id          VARCHAR   NOT NULL,
  ts                     TIMESTAMP NOT NULL,
  primary_provider       VARCHAR   NOT NULL DEFAULT 'codex',
  primary_classification VARCHAR   NOT NULL DEFAULT 'unknown',
  fallback_used          BOOLEAN   NOT NULL DEFAULT FALSE,
  fallback_provider      VARCHAR,
  final_provider         VARCHAR   NOT NULL,
  duration_sec           DOUBLE,
  response_bytes         BIGINT,
  prompt_bytes           BIGINT,
  prompt_tokens          BIGINT,
  completion_tokens      BIGINT,
  model                  VARCHAR,
  cost_usd               DOUBLE,
  PRIMARY KEY (invocation_id)
);

-- ── model_pricing ─────────────────────────────────────────────────────────
-- Versioned, date-effective LLM pricing (llm#795). Replaces the previously
-- hand-typed PRICING_TABLE literal that lived in roborev_metrics_etl.R —
-- that literal carried a stale comment promising a migration "under #380"
-- (closed, unrelated) that never happened.
--
-- Seeded here (first table creation only) AND by roborev_metrics_etl.R's
-- seed_model_pricing() on every --apply run — the ETL's schema-init step
-- skips ALL DDL/INSERT once every expected table already exists, so this
-- seed INSERT below would otherwise only ever fire once.
--
-- Matching: longest-matching model_prefix wins; among ties, the greatest
-- effective_from <= the record's date wins. model_prefix = '__default__'
-- is the fallback for unmatched/unknown models (sonnet-tier pricing,
-- unchanged behaviour from before #795).
-- PK: (model_prefix, effective_from)
CREATE TABLE IF NOT EXISTS model_pricing (
  model_prefix         VARCHAR NOT NULL,
  input_usd_per_mtok   DOUBLE  NOT NULL,
  output_usd_per_mtok  DOUBLE  NOT NULL,
  effective_from       DATE    NOT NULL,
  source_url           VARCHAR,
  PRIMARY KEY (model_prefix, effective_from)
);

-- Seed rows — behaviour-preserving migration: identical input/output pairs
-- to the PRICING_TABLE literal this replaces. effective_from is a single
-- conservative floor date (2024-01-01) for every row, so ALL historical
-- agent_runs rows price at today's rates — identical to the prior embedded-
-- constant behaviour. source_url points at the provider's official pricing
-- page as of 2026-07-30.
INSERT INTO model_pricing
  (model_prefix, input_usd_per_mtok, output_usd_per_mtok, effective_from, source_url)
VALUES
  ('claude-opus-4',     15.00,  75.00,  DATE '2024-01-01', 'https://www.anthropic.com/pricing'),
  ('claude-sonnet-4',    3.00,  15.00,  DATE '2024-01-01', 'https://www.anthropic.com/pricing'),
  ('claude-haiku-4',     0.80,   4.00,  DATE '2024-01-01', 'https://www.anthropic.com/pricing'),
  ('claude-opus-3-7',   15.00,  75.00,  DATE '2024-01-01', 'https://www.anthropic.com/pricing'),
  ('claude-sonnet-3-7',  3.00,  15.00,  DATE '2024-01-01', 'https://www.anthropic.com/pricing'),
  ('claude-haiku-3-7',   0.80,   4.00,  DATE '2024-01-01', 'https://www.anthropic.com/pricing'),
  ('claude-opus-3-5',   15.00,  75.00,  DATE '2024-01-01', 'https://www.anthropic.com/pricing'),
  ('claude-sonnet-3-5',  3.00,  15.00,  DATE '2024-01-01', 'https://www.anthropic.com/pricing'),
  ('claude-haiku-3-5',   0.80,   4.00,  DATE '2024-01-01', 'https://www.anthropic.com/pricing'),
  ('gpt-5',              0.15,   0.60,  DATE '2024-01-01', 'https://openai.com/api/pricing'),
  ('gpt-4',              2.50,  10.00,  DATE '2024-01-01', 'https://openai.com/api/pricing'),
  ('gpt-3',              0.50,   1.50,  DATE '2024-01-01', 'https://openai.com/api/pricing'),
  ('o1',                15.00,  60.00,  DATE '2024-01-01', 'https://openai.com/api/pricing'),
  ('o3',                10.00,  40.00,  DATE '2024-01-01', 'https://openai.com/api/pricing'),
  ('gemini-2.5',         0.075,  0.30,  DATE '2024-01-01', 'https://ai.google.dev/gemini-api/docs/pricing'),
  ('gemini-2',           0.10,   0.40,  DATE '2024-01-01', 'https://ai.google.dev/gemini-api/docs/pricing'),
  ('gemini-1',           0.125,  0.375, DATE '2024-01-01', 'https://ai.google.dev/gemini-api/docs/pricing'),
  ('__default__',        3.00,  15.00,  DATE '2024-01-01', 'https://www.anthropic.com/pricing')
ON CONFLICT (model_prefix, effective_from) DO NOTHING;

-- ── roborev_finding_lineage_summary (view) ────────────────────────────────
-- Per-finding summary: attempt count, time-to-close, verdict chain.
-- Rebuilt as CREATE OR REPLACE VIEW on each ETL run (views are cheap to recreate).
CREATE OR REPLACE VIEW roborev_finding_lineage_summary AS
SELECT
  fl.finding_id,
  (SELECT rl.repo
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

-- ── roborev_fix_method_trend ──────────────────────────────────────────────
-- Daily snapshot of fix_method bucket distribution across ALL closed reviews
-- (not just the ETL window). Written by the ETL at the end of every --apply run.
-- PK: (run_date, bucket) — one ETL run = 4 rows (one per bucket).
-- pct_of_closed = n_closed / n_closed_total * 100.
-- Leading indicator for #359 commit-msg hook adoption (target: commit_reference
-- bucket >= 5% within 6 weeks of hook going live).
-- Tracked in llm#389.
CREATE TABLE IF NOT EXISTS roborev_fix_method_trend (
  run_date        DATE    NOT NULL,
  bucket          VARCHAR NOT NULL,
  n_closed        INTEGER NOT NULL DEFAULT 0,
  n_closed_total  INTEGER NOT NULL DEFAULT 0,
  pct_of_closed   DOUBLE  NOT NULL DEFAULT 0.0,
  PRIMARY KEY (run_date, bucket)
);

-- ── Migration: add fix-commit link columns to existing lifecycle tables ────
-- llm#379 — additive ALTER TABLE for databases created before 2026-05-31.
-- DuckDB: ALTER TABLE ... ADD COLUMN IF NOT EXISTS is idempotent.
ALTER TABLE IF EXISTS roborev_review_lifecycle
  ADD COLUMN IF NOT EXISTS fix_commit_sha VARCHAR;
ALTER TABLE IF EXISTS roborev_review_lifecycle
  ADD COLUMN IF NOT EXISTS fix_commit_at TIMESTAMP;
ALTER TABLE IF EXISTS roborev_review_lifecycle
  ADD COLUMN IF NOT EXISTS fix_method VARCHAR;
