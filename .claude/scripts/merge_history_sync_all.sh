#!/usr/bin/env bash
# .claude/scripts/merge_history_sync_all.sh -- record merged PRs of ALL owner repos (llm#1471).
#
# merge_history_sync.sh records ONE repo. This wrapper lists the owner's repos
# (gh repo list OWNER: not archived, not a fork; the same source the other
# audit scripts use, nothing hand-typed) and calls merge_history_sync.sh
# --repo X --since <N days ago> for each, so merge_events holds every repo and
# merge_history_check.sh --daily can answer "how many merges did I have to
# approve versus how many happened automatically, per day".
#
# Terms: owner-approved = merge_path 'owner-verb' (the owner typed a merge
# verb); automatic = merge_path 'sweep' (the auto-merge sweep merged it, which
# the sync recognises by the `auto-merged` label). Private repos count too;
# only counts, classes and reasons are stored, never titles or paths.
#
# A repo that cannot be inspected is recorded and the loop continues; the run
# exits 3 at the end if any repo failed, or if the repo list was empty or may
# be truncated. It never exits 0 when a repo could not be inspected.
#
# Usage: merge_history_sync_all.sh [--owner NAME] [--days N] [--db PATH] [--dry-run]
#   --owner    default $MERGE_HISTORY_OWNER, else JohnGavin
#   --days     look-back in days (default 14)
#   --db       DuckDB file passed to the per-repo sync (default as the sync)
#   --dry-run  print the repo COUNT only; touches neither the DB nor any repo
#
# Heartbeat: one housekeeping_runs row (task merge_history_sync) at the end so
# the 06:30 email's "latest sync failed" test reflects the whole run, not just
# the last repo. error_text carries counts only, never repo names.
#
# Wired in bin/auto_merge_sweep.sh (--apply), at most once per 6 hours (stamp
# file), after the sweep's own single-repo sync. No new launchd job.
#
# Exit codes (.claude/rules/exit-code-conventions.md):
#   0  every listed repo synced
#   2  usage error
#   3  INDETERMINATE: gh/python3 missing or unauthenticated, repo listing failed,
#      empty or possibly truncated list, or at least one repo failed
#
# Env (tests): MERGE_HISTORY_SYNC (per-repo script), MERGE_HISTORY_DUCKDB,
# MERGE_HISTORY_LIST_LIMIT (default 200), MERGE_HISTORY_OWNER, UNIFIED_DB_PATH.

set -u
export PATH="$PATH:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC="${MERGE_HISTORY_SYNC:-$SCRIPT_DIR/merge_history_sync.sh}"
DUCKDB="${MERGE_HISTORY_DUCKDB:-duckdb}"
LIST_LIMIT="${MERGE_HISTORY_LIST_LIMIT:-200}"
case "$LIST_LIMIT" in ""|*[!0-9]*|0) LIST_LIMIT=200 ;; esac

usage() { echo "usage: merge_history_sync_all.sh [--owner NAME] [--days N] [--db PATH] [--dry-run]" >&2; }

OWNER="${MERGE_HISTORY_OWNER:-JohnGavin}"; DAYS=14; DB=""; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --owner) if [ $# -lt 2 ]; then usage; exit 2; fi; OWNER="$2"; shift 2 ;;
    --days)  if [ $# -lt 2 ]; then usage; exit 2; fi; DAYS="$2"; shift 2 ;;
    --db)    if [ $# -lt 2 ]; then usage; exit 2; fi; DB="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 2 ;;
    *) echo "USAGE-ERROR: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done
case "$DAYS" in ""|*[!0-9]*|0) echo "USAGE-ERROR: --days needs a positive integer" >&2; usage; exit 2 ;; esac
if printf '%s' "$OWNER" | grep -q '[^A-Za-z0-9._-]'; then echo "USAGE-ERROR: --owner has unexpected characters" >&2; exit 2; fi
if [ -z "$DB" ]; then DB="${UNIFIED_DB_PATH:-$HOME/.claude/logs/unified.duckdb}"; fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/merge_history_sync_all.XXXXXX")" || { echo "INDETERMINATE: mktemp failed" >&2; exit 3; }
trap 'rm -rf "$TMP"' EXIT
indeterminate() { echo "INDETERMINATE: merge_history_sync_all: $1" >&2; exit 3; }

command -v gh >/dev/null 2>&1 || indeterminate "gh is not on PATH"
command -v python3 >/dev/null 2>&1 || indeterminate "python3 is not on PATH"
gh auth status >/dev/null 2>&1 || indeterminate "gh is not authenticated"
[ -r "$SYNC" ] || indeterminate "per-repo sync script not readable: $SYNC"

if ! gh repo list "$OWNER" --limit "$LIST_LIMIT" --json nameWithOwner,isArchived,isFork > "$TMP/repos.json" 2>"$TMP/err"; then
  indeterminate "gh repo list failed: $(head -c 200 "$TMP/err" | tr '\n\t' '  ')"
fi
if ! python3 - "$TMP/repos.json" "$LIST_LIMIT" "$TMP/repos.txt" "$TMP/meta" <<'PYEOF'
import json, re, sys
src, limit, out, meta = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
data = json.load(open(src))
ok = re.compile(r"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$")
names = [r["nameWithOwner"] for r in data
         if not r.get("isArchived") and not r.get("isFork") and ok.match(r.get("nameWithOwner", ""))]
open(out, "w").write("".join(n + "\n" for n in names))
open(meta, "w").write("truncated=%d\n" % (1 if len(data) >= limit else 0))
PYEOF
then
  indeterminate "could not parse the repo list"
fi
NREPOS="$(wc -l < "$TMP/repos.txt" | tr -d ' ')"
if [ "$NREPOS" -eq 0 ]; then
  indeterminate "the repo list for $OWNER is empty; 0 repos inspected is not '0 merges'"
fi
TRUNC=0
if grep -q 'truncated=1' "$TMP/meta"; then TRUNC=1; fi

SINCE="$(python3 -c 'import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(days=int(sys.argv[1]))).strftime("%Y-%m-%d"))' "$DAYS")"
[ -n "$SINCE" ] || indeterminate "could not compute the --since date"

if [ "$DRY" -eq 1 ]; then
  echo "merge_history_sync_all: dry-run owner=$OWNER repos=$NREPOS since=$SINCE truncated=$TRUNC"
  exit 0
fi

FAILED=0; OKN=0
while IFS= read -r repo; do
  [ -n "$repo" ] || continue
  bash "$SYNC" --repo "$repo" --since "$SINCE" --db "$DB" >/dev/null 2>"$TMP/sync_err"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    OKN=$((OKN + 1))
  else
    FAILED=$((FAILED + 1))
    echo "FAILED: merge_history_sync_all: $repo (sync exit $rc): $(head -c 160 "$TMP/sync_err" | tr '\n\t' '  ')" >&2
  fi
done < "$TMP/repos.txt"

# one heartbeat for the whole run (counts only, never repo names); started_at is
# "now" so it is the newest merge_history_sync row, which the email reads
STATUS="ok"; ETXT="NULL"
if [ "$FAILED" -gt 0 ] || [ "$TRUNC" -eq 1 ]; then
  STATUS="failed"
  ETXT="'sync_all: $FAILED of $NREPOS repos failed, truncated=$TRUNC'"
fi
HB="$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]')"
if [ -n "$HB" ] && command -v "$DUCKDB" >/dev/null 2>&1 && [ -f "$DB" ]; then
  "$DUCKDB" -init /dev/null -bail "$DB" -c "INSERT INTO housekeeping_runs (id, task, source_script, started_at, ended_at, status, rows_written, error_text)
    VALUES ('$HB', 'merge_history_sync', '$SCRIPT_DIR/merge_history_sync_all.sh', current_timestamp, current_timestamp, '$STATUS', $OKN, $ETXT);" >/dev/null 2>&1 \
    || echo "WARNING: merge_history_sync_all: could not write the heartbeat row" >&2
fi

echo "merge_history_sync_all: owner=$OWNER repos=$NREPOS ok=$OKN failed=$FAILED since=$SINCE truncated=$TRUNC"
if [ "$FAILED" -gt 0 ]; then indeterminate "$FAILED of $NREPOS repos could not be inspected"; fi
if [ "$TRUNC" -eq 1 ]; then indeterminate "the repo list reached the limit ($LIST_LIMIT) and may be truncated"; fi
exit 0
