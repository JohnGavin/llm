#!/bin/bash
# cleanup_ephemeral_repos.sh — remove phantom ephemeral repos from roborev's DB.
#
# Wrapper for cleanup_ephemeral_repos.sql (llm#923). Exists because that script
# performs a multi-thousand-row DELETE and destructive-ops-guard Part 2 requires
# a recovery trail for any destructive op; a bare `sqlite3 db < file` has none.
#
#   bash cleanup_ephemeral_repos.sh --dry-run   # counts only, no writes
#   bash cleanup_ephemeral_repos.sh --apply     # backup, then delete
#
# ROBOREV_DB overrides the target DB (used by tests).
set -euo pipefail

DB="${ROBOREV_DB:-$HOME/.roborev/reviews.db}"
SQL="$(dirname "$0")/cleanup_ephemeral_repos.sql"
MODE="${1:---dry-run}"

PHANTOM_PRED="root_path LIKE '/tmp/%' OR root_path LIKE '/private/tmp/%' \
 OR root_path LIKE '/var/folders/%' OR root_path LIKE '/private/var/folders/%'"

if [ ! -f "$DB" ]; then
    echo "ERROR: roborev DB not found at $DB" >&2
    exit 1
fi
if [ ! -f "$SQL" ]; then
    echo "ERROR: $SQL not found" >&2
    exit 1
fi

echo "DB: $DB"
echo ""
echo "Phantom rows (would be deleted):"
sqlite3 -header -column "$DB" "
WITH ph AS (SELECT id FROM repos WHERE $PHANTOM_PRED),
     pj AS (SELECT id FROM review_jobs WHERE repo_id IN (SELECT id FROM ph)),
     pc AS (SELECT id FROM commits     WHERE repo_id IN (SELECT id FROM ph))
SELECT 'repos'       AS tbl, count(*) AS n FROM ph
UNION ALL SELECT 'review_jobs', count(*) FROM pj
UNION ALL SELECT 'commits',     count(*) FROM pc
UNION ALL SELECT 'reviews',     count(*) FROM reviews   WHERE job_id IN (SELECT id FROM pj)
UNION ALL SELECT 'responses',   count(*) FROM responses WHERE job_id IN (SELECT id FROM pj)
                                                           OR commit_id IN (SELECT id FROM pc)
UNION ALL SELECT '-- KEEPING repos', count(*) FROM repos WHERE id NOT IN (SELECT id FROM ph);"

case "$MODE" in
    --dry-run)
        echo ""
        echo "DRY RUN — nothing written. Re-run with --apply to delete."
        ;;
    --apply)
        BACKUP="${DB}.$(date +%Y%m%d_%H%M%S).bak"
        cp -a "$DB" "$BACKUP"
        echo ""
        echo "Backup: $BACKUP"
        sqlite3 "$DB" < "$SQL"
        echo ""
        echo "Done. Restore with: cp -a '$BACKUP' '$DB'"
        ;;
    *)
        echo "ERROR: unknown mode '$MODE' (expected --dry-run or --apply)" >&2
        exit 2
        ;;
esac
