-- Cleanup script for ~/.roborev/reviews.db — phantom ephemeral repos (llm#923)
--
-- WHY: core.hooksPath is set GLOBALLY to ~/docs_gh/llm/git-hooks, so every git
-- repo on this machine inherits roborev's post-commit hook — including throwaway
-- repos created by test fixtures and agent runs under a temp root. Those repos
-- register themselves here and enqueue reviews, then get deleted, leaving rows
-- that can never be reviewed. Observed 2026-08-06: 1,723 phantom repos vs 27
-- real. llm#923 stops new ones being created; this removes the accumulated ones.
--
-- USAGE — do NOT run this by hand. Use the wrapper, which takes a backup first:
--   bash ~/.claude/scripts/cleanup_ephemeral_repos.sh --dry-run
--   bash ~/.claude/scripts/cleanup_ephemeral_repos.sh --apply
--
-- IDEMPOTENT — every DELETE is a no-op once the rows are gone.
--
-- ---------------------------------------------------------------------------
-- TWO DEFECTS IN THE PRE-llm#923 VERSION OF THIS FILE, both silent:
--
--   1. It matched only /tmp/ and /private/tmp/, missing /var/folders/ and
--      /private/var/folders/ — macOS's $TMPDIR, and the path R's tempdir()
--      actually returns outside a nix-shell. Those rows survived every run.
--   2. It deleted from `repos` ONLY. `PRAGMA foreign_keys` is 0 in this DB, so
--      the ~7,000 dependent rows in review_jobs/commits/reviews/responses were
--      silently ORPHANED rather than removed — and an orphaned review_jobs row
--      still counts as `failed`, and an orphaned open review still counts
--      toward the backlog. The cleanup looked successful while leaving the
--      actual noise in place.
--
-- Hence: match all four temp roots, and delete children before parents.
-- ---------------------------------------------------------------------------

BEGIN TRANSACTION;

CREATE TEMP TABLE _ph_repos AS
  SELECT id FROM repos
   WHERE root_path LIKE '/tmp/%'
      OR root_path LIKE '/private/tmp/%'
      OR root_path LIKE '/var/folders/%'
      OR root_path LIKE '/private/var/folders/%';

CREATE TEMP TABLE _ph_jobs AS
  SELECT id FROM review_jobs WHERE repo_id IN (SELECT id FROM _ph_repos);

CREATE TEMP TABLE _ph_commits AS
  SELECT id FROM commits WHERE repo_id IN (SELECT id FROM _ph_repos);

-- Preview — what is about to go, and what survives.
SELECT 'TO DELETE repos'       AS marker, count(*) AS n FROM _ph_repos
UNION ALL SELECT 'TO DELETE review_jobs', count(*) FROM _ph_jobs
UNION ALL SELECT 'TO DELETE commits',     count(*) FROM _ph_commits
UNION ALL SELECT 'TO DELETE reviews',     count(*) FROM reviews
            WHERE job_id IN (SELECT id FROM _ph_jobs)
UNION ALL SELECT 'TO DELETE responses',   count(*) FROM responses
            WHERE job_id IN (SELECT id FROM _ph_jobs)
               OR commit_id IN (SELECT id FROM _ph_commits)
UNION ALL SELECT 'KEEPING repos (real)',  count(*) FROM repos
            WHERE id NOT IN (SELECT id FROM _ph_repos);

-- Children first — FK enforcement is off, so nothing does this for us.
DELETE FROM responses
 WHERE job_id    IN (SELECT id FROM _ph_jobs)
    OR commit_id IN (SELECT id FROM _ph_commits);

DELETE FROM reviews     WHERE job_id IN (SELECT id FROM _ph_jobs);
DELETE FROM review_jobs WHERE id     IN (SELECT id FROM _ph_jobs);
DELETE FROM commits     WHERE id     IN (SELECT id FROM _ph_commits);
DELETE FROM repos       WHERE id     IN (SELECT id FROM _ph_repos);

DROP TABLE _ph_repos;
DROP TABLE _ph_jobs;
DROP TABLE _ph_commits;

COMMIT;

-- Verify: all four temp roots gone, and no orphans left behind.
SELECT 'REMAINING ephemeral repos' AS marker, count(*) AS n FROM repos
 WHERE root_path LIKE '/tmp/%' OR root_path LIKE '/private/tmp/%'
    OR root_path LIKE '/var/folders/%' OR root_path LIKE '/private/var/folders/%'
UNION ALL
SELECT 'ORPHAN review_jobs', count(*) FROM review_jobs
 WHERE repo_id NOT IN (SELECT id FROM repos)
UNION ALL
SELECT 'ORPHAN reviews', count(*) FROM reviews
 WHERE job_id NOT IN (SELECT id FROM review_jobs)
UNION ALL
SELECT 'SURVIVING repos', count(*) FROM repos;
