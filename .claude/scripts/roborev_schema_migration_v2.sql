-- roborev_schema_migration_v2.sql
-- DB schema migration for closure-loop automation (JohnGavin/llm#163 Slice 3).
--
-- Adds two tables to ~/.roborev/reviews.db:
--   closures           — records auto-close decisions (approved or wontfix)
--   fix_rejected_queue — holds fix commits that roborev re-reviewed and rejected
--
-- IDEMPOTENT: uses CREATE TABLE IF NOT EXISTS throughout.
-- Safe to re-run on an already-migrated DB — no existing rows are touched.
--
-- Usage:
--   sqlite3 ~/.roborev/reviews.db < roborev_schema_migration_v2.sql
--
-- Forward-compatible: uses no DROP/ALTER on existing tables.
-- The reviews(closed) column still controls what "open" means for all existing
-- queries; the closures table is an additive audit layer.
--
-- References:
--   reviews(id)     — the original finding that was closed
--   review_jobs(id) — the re-review job that produced the approval verdict
--
-- Issue: JohnGavin/llm#163

-- ─────────────────────────────────────────────────────────────────────────────
-- Table: closures
--
-- One row per auto-closed finding. Written when:
--   (a) The commit message contains "closes/fixes roborev #N"
--   (b) roborev re-reviews the fix commit
--   (c) The re-review verdict is approved (verdict_bool = 1)
--
-- Columns:
--   id                    — surrogate key
--   finding_id            — FK → reviews(id): the original failing finding
--   closure_commit_sha    — the commit SHA that claimed to fix the finding
--                           (from the "closes roborev #N" message)
--   closure_review_job_id — FK → review_jobs(id): the job that produced the
--                           approving re-review. NULL if the closure_type is
--                           'wontfix' or 'manual' (no re-review needed).
--   closure_type          — one of:
--                             'approved'  = re-review passed; auto-closed
--                             'wontfix'   = commit msg used "wontfix roborev #N"
--                             'manual'    = closed by a human via `roborev close`
--                             'stale'     = file deleted for ≥30d; auto-staleness
--   closure_reason        — optional free-text. Required for 'wontfix' closures
--                           (the "[reason: ...]" tag from the commit message).
--   created_at            — UTC timestamp (ISO-8601)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS closures (
  id                    INTEGER PRIMARY KEY AUTOINCREMENT,
  finding_id            INTEGER NOT NULL
                          REFERENCES reviews(id),
  closure_commit_sha    TEXT    NOT NULL,
  closure_review_job_id INTEGER
                          REFERENCES review_jobs(id),
  closure_type          TEXT    NOT NULL
                          CHECK(closure_type IN ('approved','wontfix','manual','stale')),
  closure_reason        TEXT,
  created_at            TEXT    NOT NULL
                          DEFAULT (datetime('now'))
);

-- Fast lookup by finding (the most common query: "is finding N already closed?")
CREATE INDEX IF NOT EXISTS idx_closures_finding_id
  ON closures(finding_id);

-- Lookup by commit (the verifier queries: "what did this commit close?")
CREATE INDEX IF NOT EXISTS idx_closures_commit_sha
  ON closures(closure_commit_sha);

-- Lookup by closure type (for stats: how many auto vs manual vs wontfix)
CREATE INDEX IF NOT EXISTS idx_closures_type
  ON closures(closure_type);

-- ─────────────────────────────────────────────────────────────────────────────
-- Table: fix_rejected_queue
--
-- One row per fix commit that roborev re-reviewed and rejected (verdict_bool=0).
-- These require human triage before the finding can be closed.
--
-- Columns:
--   id                   — surrogate key
--   finding_ids_json     — JSON array of integers, e.g. [1551, 1545].
--                          Multi-finding commits are recorded as a unit.
--                          All-or-nothing rule: if ANY cited ID is rejected,
--                          ALL cited IDs for that commit go into the queue.
--   fix_commit_sha       — the commit SHA that claimed to fix the finding(s)
--   rejection_job_id     — FK → review_jobs(id): the re-review job that rejected
--                           the fix. NULL when rejection is inferred (no re-review
--                           ran, e.g. roborev binary unavailable).
--   rejection_summary    — first 500 chars of the re-review output, for quick
--                           human triage without opening the DB browser
--   attempted_at         — UTC timestamp when the verifier ran (ISO-8601)
--   resolved             — 0 = needs triage, 1 = human has triaged this entry
--                           (either accepted the fix manually or re-opened for
--                           another attempt)
--   resolved_at          — UTC timestamp when resolved was set to 1. NULL while
--                           still pending.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS fix_rejected_queue (
  id                  INTEGER PRIMARY KEY AUTOINCREMENT,
  finding_ids_json    TEXT    NOT NULL,
  fix_commit_sha      TEXT    NOT NULL,
  rejection_job_id    INTEGER
                        REFERENCES review_jobs(id),
  rejection_summary   TEXT,
  attempted_at        TEXT    NOT NULL
                        DEFAULT (datetime('now')),
  resolved            INTEGER NOT NULL DEFAULT 0,
  resolved_at         TEXT
);

-- Fast lookup for the triage UI: all unresolved entries
CREATE INDEX IF NOT EXISTS idx_frq_unresolved
  ON fix_rejected_queue(resolved)
  WHERE resolved = 0;

-- Lookup by commit (idempotency guard: don't re-queue the same commit twice)
CREATE INDEX IF NOT EXISTS idx_frq_commit_sha
  ON fix_rejected_queue(fix_commit_sha);

-- ─────────────────────────────────────────────────────────────────────────────
-- Verification query (run after migration to confirm tables exist)
-- ─────────────────────────────────────────────────────────────────────────────

SELECT 'migration_v2' AS label,
       (SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='closures')        AS closures_exists,
       (SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='fix_rejected_queue') AS frq_exists;
