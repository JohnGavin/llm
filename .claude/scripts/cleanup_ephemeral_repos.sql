-- Cleanup script for ~/.roborev/reviews.db — repos table
-- Removes ephemeral /private/tmp/ and /tmp/ entries that inflate the poller's
-- total repo count (observed: 55 repos, 25+ are ephemeral worktree/tmp entries).
--
-- Originated from #217 acceptance criterion 3.
-- Addressed alongside the business-hours poller schedule change.
--
-- USAGE: review carefully, then run interactively:
--   sqlite3 ~/.roborev/reviews.db < ~/.claude/scripts/cleanup_ephemeral_repos.sql
--
-- IDEMPOTENT — safe to run multiple times (DELETE WHERE is a no-op when rows absent).

BEGIN TRANSACTION;

-- Show what will be deleted (dry-run preview)
SELECT 'TO DELETE:' AS marker, id, root_path FROM repos
 WHERE root_path LIKE '/private/tmp/%'
    OR root_path LIKE '/tmp/%';

-- Delete the ephemeral entries
DELETE FROM repos
 WHERE root_path LIKE '/private/tmp/%'
    OR root_path LIKE '/tmp/%';

-- Show how many were removed
SELECT 'DELETED:' AS marker, changes() AS rows_removed;

COMMIT;

-- Verify no ephemeral entries remain
SELECT 'REMAINING /tmp/ entries:' AS marker, COUNT(*) AS n FROM repos
 WHERE root_path LIKE '/private/tmp/%'
    OR root_path LIKE '/tmp/%';

-- Show surviving repos for a sanity check
SELECT 'SURVIVING REPOS:' AS marker, id, root_path FROM repos ORDER BY id;
