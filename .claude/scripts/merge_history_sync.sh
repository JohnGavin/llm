#!/usr/bin/env bash
# .claude/scripts/merge_history_sync.sh -- record merged PRs in merge_events (llm#1471).
#
# Reads merged pull requests from GitHub, classifies each with the SAME logic the
# auto-merge sweep uses (.claude/scripts/lib/merge_classify.sh over
# .claude/state/auto_merge_exclusions.txt and the derived scheduled-script set),
# and upserts one row per (repo, pr_number) into merge_events in unified.duckdb.
# Re-running is idempotent. Never stores titles, bodies, file contents or paths:
# only classes, reasons and counts.
#
# Usage:
#   merge_history_sync.sh [--repo OWNER/NAME] [--since YYYY-MM-DD] [--limit N]
#                         [--db PATH] [--facts FILE] [--refresh]
#   --repo     default: the repo of the current directory (gh repo view)
#   --since    only PRs merged on/after this UTC date; marks rows source=backfill
#              (default --limit becomes 500 when --since is given, else 50)
#   --limit    how many of the most recently merged PRs to look at
#   --db       DuckDB file (default $UNIFIED_DB_PATH, else ~/.claude/logs/unified.duckdb)
#   --facts    TSV (pr, ci_state, gate_result) the sweep knows first-hand; those
#              rows get source=sweep and the given ci_state/gate_result
#   --refresh  re-classify PRs already recorded (default: only new PRs are
#              fetched, which keeps the 30-minute sweep to a handful of API calls)
#
# Heartbeat: housekeeping_runs task merge_history_sync (row 'running' at start,
# updated to ok/failed at exit, rows_written = rows upserted).
#
# Exit codes (.claude/rules/exit-code-conventions.md):
#   0  ran; rows upserted (a PR whose files could not be read is recorded with
#      class 'unknown' and counted in the summary, never as clean)
#   2  usage error
#   3  could not run (gh/duckdb missing or unauthenticated, DB missing or locked
#      past the retries, GitHub listing failed)
#
# Env (tests): MERGE_HISTORY_DUCKDB (binary, default duckdb), MERGE_HISTORY_LOCK_TRIES
# (default 5), MERGE_HISTORY_LOCK_SLEEP (seconds, default 2), MERGE_HISTORY_LIB,
# AUTO_MERGE_REPO_DIR, AUTO_MERGE_EXCLUSIONS, UNIFIED_DB_PATH.

set -u
export PATH="$PATH:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
MC_LIB="${MERGE_HISTORY_LIB:-$SCRIPT_DIR/lib/merge_classify.sh}"
REPO_DIR="${AUTO_MERGE_REPO_DIR:-$ROOT_DIR}"
EXCL_FILE="${AUTO_MERGE_EXCLUSIONS:-$REPO_DIR/.claude/state/auto_merge_exclusions.txt}"
SCHEMA_SQL="$SCRIPT_DIR/housekeeping_schema_init.sql"
DUCKDB="${MERGE_HISTORY_DUCKDB:-duckdb}"
LOCK_TRIES="${MERGE_HISTORY_LOCK_TRIES:-5}"
LOCK_SLEEP="${MERGE_HISTORY_LOCK_SLEEP:-2}"
case "$LOCK_TRIES" in ""|*[!0-9]*) LOCK_TRIES=5 ;; esac
case "$LOCK_SLEEP" in ""|*[!0-9]*) LOCK_SLEEP=2 ;; esac
HK_TASK="merge_history_sync"

usage() {
  echo "usage: merge_history_sync.sh [--repo OWNER/NAME] [--since YYYY-MM-DD] [--limit N] [--db PATH] [--facts FILE] [--refresh]" >&2
}

REPO=""; SINCE=""; LIMIT=""; DB=""; FACTS=""; REFRESH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)  if [ $# -lt 2 ]; then usage; exit 2; fi; REPO="$2"; shift 2 ;;
    --since) if [ $# -lt 2 ]; then usage; exit 2; fi; SINCE="$2"; shift 2 ;;
    --limit) if [ $# -lt 2 ]; then usage; exit 2; fi; LIMIT="$2"; shift 2 ;;
    --db)    if [ $# -lt 2 ]; then usage; exit 2; fi; DB="$2"; shift 2 ;;
    --facts) if [ $# -lt 2 ]; then usage; exit 2; fi; FACTS="$2"; shift 2 ;;
    --refresh) REFRESH=1; shift ;;
    -h|--help) usage; exit 2 ;;
    *) echo "USAGE-ERROR: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done
if [ -n "$SINCE" ]; then
  case "$SINCE" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) echo "USAGE-ERROR: --since needs YYYY-MM-DD" >&2; usage; exit 2 ;;
  esac
fi
if [ -z "$LIMIT" ]; then
  if [ -n "$SINCE" ]; then LIMIT=500; else LIMIT=50; fi
fi
case "$LIMIT" in ""|*[!0-9]*|0) echo "USAGE-ERROR: --limit needs a positive integer" >&2; usage; exit 2 ;; esac
if [ -n "$REPO" ]; then
  case "$REPO" in
    */*) ;;
    *) echo "USAGE-ERROR: --repo needs OWNER/NAME" >&2; usage; exit 2 ;;
  esac
  if printf '%s' "$REPO" | grep -q '[^A-Za-z0-9._/-]'; then
    echo "USAGE-ERROR: --repo has characters outside A-Za-z0-9._/-" >&2; exit 2
  fi
fi
if [ -z "$DB" ]; then DB="${UNIFIED_DB_PATH:-$HOME/.claude/logs/unified.duckdb}"; fi
if [ -n "$FACTS" ] && [ ! -r "$FACTS" ]; then
  echo "USAGE-ERROR: --facts file not readable: $FACTS" >&2; exit 2
fi

TMP=""
HB_ID=""
ERR_TEXT=""
ROWS=0

db_run() {  # SQL ; prints csv rows; retries only on a lock conflict. rc 0 ok.
  local try=1 rc out
  while :; do
    out="$("$DUCKDB" -init /dev/null -bail -csv -noheader "$DB" -c "$1" 2>"$TMP/dberr")"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      if [ -n "$out" ]; then printf '%s\n' "$out"; fi
      return 0
    fi
    if grep -qiE 'lock|conflicting' "$TMP/dberr" && [ "$try" -lt "$LOCK_TRIES" ]; then
      try=$((try + 1)); sleep "$LOCK_SLEEP"; continue
    fi
    return "$rc"
  done
}

dberr_text() { head -c 200 "$TMP/dberr" 2>/dev/null | tr '\n\t\047\042\\' '     '; }

hk_end() {  # $1 status
  [ -n "$HB_ID" ] || return 0
  local et etsql="NULL"
  et="$(printf '%s' "$ERR_TEXT" | tr '\n\t\047\042\\' '     ' | head -c 200)"
  if [ -n "$et" ]; then etsql="'$et'"; fi
  db_run "UPDATE housekeeping_runs SET ended_at = current_timestamp, status = '$1',
            rows_written = $ROWS, error_text = $etsql
          WHERE id = '$HB_ID';" >/dev/null 2>&1 || echo "WARNING: merge_history_sync: could not update the heartbeat row" >&2
}

on_exit() {
  local rc=$?
  if [ -n "$HB_ID" ]; then
    if [ "$rc" -eq 0 ]; then hk_end ok; else hk_end failed; fi
  fi
  if [ -n "$TMP" ]; then rm -rf "$TMP"; fi
}
trap on_exit EXIT

fail3() {  # message -- INDETERMINATE-style failure, exit 3
  ERR_TEXT="$1"
  echo "INDETERMINATE: merge_history_sync: $1" >&2
  exit 3
}

# ---- preconditions ------------------------------------------------------------
TMP="$(mktemp -d "${TMPDIR:-/tmp}/merge_history_sync.XXXXXX")" || { echo "INDETERMINATE: mktemp failed" >&2; exit 3; }
if ! command -v "$DUCKDB" >/dev/null 2>&1; then
  echo "INDETERMINATE: merge_history_sync: duckdb is not available ($DUCKDB); merge history was NOT recorded and no heartbeat could be written" >&2
  exit 3
fi
command -v gh >/dev/null 2>&1 || fail3 "gh is not on PATH"
command -v python3 >/dev/null 2>&1 || fail3 "python3 is not on PATH"
gh auth status >/dev/null 2>&1 || fail3 "gh is not authenticated"
[ -f "$DB" ] || fail3 "database not found: $DB (create it with housekeeping_schema_apply.sh)"
[ -r "$SCHEMA_SQL" ] || fail3 "schema file not readable: $SCHEMA_SQL"
[ -r "$MC_LIB" ] || fail3 "classification library not readable: $MC_LIB"
if [ -z "$REPO" ]; then
  REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)"
  [ -n "$REPO" ] || fail3 "could not resolve the repo; pass --repo OWNER/NAME"
fi
if printf '%s' "$REPO" | grep -q '[^A-Za-z0-9._/-]'; then fail3 "resolved repo name has unexpected characters"; fi

# ---- heartbeat start (also proves the DB is writable before any API work) --------
HB_ID="$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]')"
if [ -z "$HB_ID" ]; then fail3 "uuidgen failed"; fi
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if ! db_run "INSERT INTO housekeeping_runs (id, task, source_script, started_at, status, rows_written)
             VALUES ('$HB_ID', '$HK_TASK', '$SCRIPT_DIR/merge_history_sync.sh', TIMESTAMPTZ '$NOW', 'running', 0);" >/dev/null; then
  HB_ID=""
  fail3 "could not write the heartbeat row to $DB: $(dberr_text)"
fi

# ---- ensure the table, learn which PRs are already recorded -------------------------
sed -n '/^-- BEGIN merge_events DDL/,/^-- END merge_events DDL/p' "$SCHEMA_SQL" > "$TMP/ddl.sql"
if ! grep -q 'CREATE TABLE IF NOT EXISTS merge_events' "$TMP/ddl.sql"; then fail3 "merge_events DDL not found in the schema file"; fi
DDL="$(cat "$TMP/ddl.sql")"
if ! db_run "$DDL
SELECT pr_number FROM merge_events WHERE repo = '$REPO';" > "$TMP/existing.txt"; then
  fail3 "could not read merge_events: $(dberr_text)"
fi

# ---- GitHub: merged PRs --------------------------------------------------------------
if ! gh pr list --repo "$REPO" --state merged --limit "$LIMIT" \
     --json number,mergedAt,labels,body,headRefOid,additions,deletions,changedFiles,statusCheckRollup \
     > "$TMP/list.json" 2>"$TMP/ghlist.err"; then
  fail3 "gh pr list failed for $REPO"
fi

: > "$TMP/prs.tsv"
if ! python3 - "$TMP/list.json" "$TMP/existing.txt" "${FACTS:-}" "$SINCE" "$REFRESH" "$TMP/prs.tsv" <<'PYEOF'
import json, re, sys
lst, existing_f, facts_f, since, refresh, out = sys.argv[1:7]
existing = set(l.strip() for l in open(existing_f) if l.strip())
facts = {}
if facts_f:
    for l in open(facts_f):
        p = l.rstrip("\n").split("\t")
        if len(p) >= 3 and p[0]:
            facts[p[0]] = (p[1], p[2])
trailer = re.compile(r"^Tier-2-Class:[ \t]*([A-Za-z0-9_-]+)[ \t]*\r?$", re.M)
rows = []
for p in json.load(open(lst)):
    n = str(p["number"])
    merged = p.get("mergedAt") or ""
    if not merged:
        continue
    if since and merged[:10] < since:
        continue
    if n in existing and refresh != "1" and n not in facts:
        continue
    roll = p.get("statusCheckRollup") or []
    ci = "NA"
    if roll:
        ci = "success"
        for c in roll:
            if c.get("__typename") == "StatusContext":
                ok = c.get("state") == "SUCCESS"
            else:
                ok = c.get("status") == "COMPLETED" and c.get("conclusion") == "SUCCESS"
            if not ok:
                ci = "failure"
    gate = "NA"
    if n in facts:
        ci, gate = facts[n]
        source = "sweep"
    else:
        source = "backfill" if since else "sync"
    m = trailer.search(p.get("body") or "")
    t2 = m.group(1).lower() if m else "-"
    labels = " ".join(l.get("name", "").replace(" ", "_") for l in (p.get("labels") or [])) or "-"
    rows.append("\t".join([n, merged, labels, p.get("headRefOid") or "", str(p.get("additions", 0)),
                           str(p.get("deletions", 0)), str(p.get("changedFiles", 0)), ci, gate, source, t2]))
open(out, "w").write("\n".join(rows) + ("\n" if rows else ""))
PYEOF
then
  fail3 "could not parse the merged PR list"
fi
LISTED="$(wc -l < "$TMP/prs.tsv" | tr -d ' ')"

# ---- classify each PR -----------------------------------------------------------------
MC_TMP="$TMP"
. "$MC_LIB"
mc_load "$REPO_DIR" "$EXCL_FILE"
RECORDED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
: > "$TMP/rows.tsv"
UNKNOWN=0
while IFS="$(printf '\t')" read -r n merged labels head adds dels changed ci gate source t2; do
  [ -n "$n" ] || continue
  ff="$TMP/files_$n"; fr="$TMP/filesraw_$n"
  fetched=1
  if ! gh api "repos/$REPO/pulls/$n/files" --paginate \
       --jq '.[] | [.filename, (.previous_filename // ""), .additions, .deletions] | @tsv' > "$fr" 2>/dev/null; then
    fetched=0
  fi
  awk -F'\t' 'NF>=1 && $1!=""{print $1} NF>=2 && $2!=""{print $2}' "$fr" > "$ff" 2>/dev/null
  nlisted="$(awk -F'\t' 'NF>=1 && $1!=""{c++} END{print c+0}' "$fr" 2>/dev/null)"
  mc_classify_merged "$ff" "$labels" "$t2"
  if [ "$fetched" -eq 0 ] || [ ! -s "$ff" ] || [ "${changed:-0}" -gt "${nlisted:-0}" ]; then
    # the diff could not be read in full: unknown, never "clean"
    MC_CLASS="unknown"
    if [ "$MC_MERGE_PATH" = "sweep" ]; then MC_APPROVAL="none"; fi
  fi
  case "$MC_CLASS" in unknown) UNKNOWN=$((UNKNOWN + 1)) ;; esac
  haslabel="false"; if [ "$MC_MERGE_PATH" = "sweep" ]; then haslabel="true"; fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$REPO" "$n" "$merged" "$MC_MERGE_PATH" "$MC_APPROVAL" "$MC_CLASS" "$MC_REASONS" \
    "$changed" "$adds" "$dels" "$ci" "$gate" "$haslabel" "$head" "$source" "$RECORDED" >> "$TMP/rows.tsv"
done < "$TMP/prs.tsv"

# ---- one short write ------------------------------------------------------------------------
NROWS="$(wc -l < "$TMP/rows.tsv" | tr -d ' ')"
if [ "$NROWS" -gt 0 ]; then
  if ! db_run "
INSERT INTO merge_events
SELECT repo, pr_number, merged_at, merge_path, approval, class, excluded_reasons,
       files_changed, additions, deletions, ci_state, gate_result, auto_merged_label,
       head_sha, source, recorded_at
FROM read_csv('$TMP/rows.tsv', delim='\t', header=false, quote='', nullstr='',
  columns={'repo':'VARCHAR','pr_number':'INTEGER','merged_at':'TIMESTAMPTZ','merge_path':'VARCHAR',
           'approval':'VARCHAR','class':'VARCHAR','excluded_reasons':'VARCHAR','files_changed':'INTEGER',
           'additions':'INTEGER','deletions':'INTEGER','ci_state':'VARCHAR','gate_result':'VARCHAR',
           'auto_merged_label':'BOOLEAN','head_sha':'VARCHAR','source':'VARCHAR','recorded_at':'TIMESTAMPTZ'})
ON CONFLICT (repo, pr_number) DO UPDATE SET
  merged_at = EXCLUDED.merged_at, merge_path = EXCLUDED.merge_path, approval = EXCLUDED.approval,
  class = EXCLUDED.class, excluded_reasons = EXCLUDED.excluded_reasons,
  files_changed = EXCLUDED.files_changed, additions = EXCLUDED.additions, deletions = EXCLUDED.deletions,
  ci_state = CASE WHEN EXCLUDED.ci_state = 'NA' THEN merge_events.ci_state ELSE EXCLUDED.ci_state END,
  gate_result = CASE WHEN EXCLUDED.gate_result = 'NA' THEN merge_events.gate_result ELSE EXCLUDED.gate_result END,
  auto_merged_label = EXCLUDED.auto_merged_label, head_sha = EXCLUDED.head_sha,
  source = CASE WHEN merge_events.source = 'sweep' THEN 'sweep' ELSE EXCLUDED.source END,
  recorded_at = EXCLUDED.recorded_at;" >/dev/null; then
    fail3 "could not upsert merge_events: $(dberr_text)"
  fi
fi
ROWS="$NROWS"
echo "merge_history_sync: repo=$REPO listed=$LISTED upserted=$NROWS unknown=$UNKNOWN"
if [ "$UNKNOWN" -gt 0 ]; then
  echo "WARNING: merge_history_sync: $UNKNOWN PR(s) recorded as class unknown (file list or exclusion data unreadable)" >&2
fi
exit 0
