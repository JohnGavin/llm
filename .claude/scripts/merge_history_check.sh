#!/usr/bin/env bash
# .claude/scripts/merge_history_check.sh -- is merging being automated too much? (llm#1471)
#
# Reads merge_events (written by merge_history_sync.sh) and applies named rules
# over the last --days days (merged_at, UTC). Read-only.
#
# Usage: merge_history_check.sh [--db PATH] [--days N] [--json]
#
# Rules:
#   R1 sweep-excluded   a sweep merge whose class is excluded:* (must be 0: a violation)
#   R2 sweep-unverified a sweep merge whose gate_result is not PASS or whose ci_state is
#                       not success (rows where the value is NA / unknown are not counted)
#   R3 sweep-daily-cap  more than DAILY_CAP sweep merges in one UTC day
#   R4 tier2-approval   a tier2:* merge whose approval is not veto-lapsed
#   R5 automation-share sweep merges / all merges over the window above SHARE_THRESHOLD;
#                       only judged with at least MIN_MERGES merges, else reported as
#                       INSUFFICIENT-DATA (which is NOT a pass)
# Then a count of merges by (merge_path, approval, class): the frequency of each
# kind of merge. The last line is a machine-readable summary.
#
# Exit codes (.claude/rules/exit-code-conventions.md):
#   0  every rule evaluated, none alerting
#   1  at least one rule is ALERTING
#   2  usage error
#   3  INDETERMINATE: duckdb missing, DB missing/locked/unreadable, merge_events
#      absent, or no merge ever recorded (silence must not read as clean)
#
# Env (tests): MERGE_HISTORY_DUCKDB (default duckdb), MERGE_HISTORY_LOCK_TRIES
# (default 5), MERGE_HISTORY_LOCK_SLEEP (default 2 s), UNIFIED_DB_PATH.

set -u
export PATH="$PATH:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"

# ---- thresholds: the ONE place they live ----------------------------------------
SHARE_THRESHOLD="0.80"   # R5: alert when sweep merges / all merges exceeds this
MIN_MERGES=5             # R5: fewer merges than this in the window = insufficient data
DAILY_CAP=10             # R3: sweep merges allowed per UTC day (owner raised 5 -> 10, 2026-10-20)

DUCKDB="${MERGE_HISTORY_DUCKDB:-duckdb}"
LOCK_TRIES="${MERGE_HISTORY_LOCK_TRIES:-5}"
LOCK_SLEEP="${MERGE_HISTORY_LOCK_SLEEP:-2}"
case "$LOCK_TRIES" in ""|*[!0-9]*) LOCK_TRIES=5 ;; esac
case "$LOCK_SLEEP" in ""|*[!0-9]*) LOCK_SLEEP=2 ;; esac

usage() { echo "usage: merge_history_check.sh [--db PATH] [--days N] [--json]" >&2; }

DB=""; DAYS=7; JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --db)   if [ $# -lt 2 ]; then usage; exit 2; fi; DB="$2"; shift 2 ;;
    --days) if [ $# -lt 2 ]; then usage; exit 2; fi; DAYS="$2"; shift 2 ;;
    --json) JSON=1; shift ;;
    -h|--help) usage; exit 2 ;;
    *) echo "USAGE-ERROR: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done
case "$DAYS" in ""|*[!0-9]*|0) echo "USAGE-ERROR: --days needs a positive integer" >&2; usage; exit 2 ;; esac
if [ -z "$DB" ]; then DB="${UNIFIED_DB_PATH:-$HOME/.claude/logs/unified.duckdb}"; fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/merge_history_check.XXXXXX")" || { echo "INDETERMINATE: mktemp failed" >&2; exit 3; }
trap 'rm -rf "$TMP"' EXIT

indeterminate() { echo "INDETERMINATE: merge_history_check: $1" >&2; exit 3; }

if ! command -v "$DUCKDB" >/dev/null 2>&1; then
  indeterminate "duckdb is not available ($DUCKDB); merge history was NOT checked"
fi
[ -f "$DB" ] || indeterminate "database not found: $DB"

db_run() {  # SQL ; csv on stdout ; retries only on a lock conflict
  local try=1 rc out
  while :; do
    out="$("$DUCKDB" -init /dev/null -readonly -bail -csv -noheader "$DB" -c "$1" 2>"$TMP/dberr")"
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

WIN="merged_at >= current_timestamp - INTERVAL ($DAYS) DAY"
if ! db_run "
SET TimeZone = 'UTC';
SELECT 'ever', count(*) FROM merge_events
UNION ALL SELECT 'total', count(*) FROM merge_events WHERE $WIN
UNION ALL SELECT 'sweep', count(*) FROM merge_events WHERE $WIN AND merge_path = 'sweep'
UNION ALL SELECT 'owner_verb', count(*) FROM merge_events WHERE $WIN AND merge_path = 'owner-verb'
UNION ALL SELECT 'tier2', count(*) FROM merge_events WHERE $WIN AND merge_path = 'sweep' AND class LIKE 'tier2:%'
UNION ALL SELECT 'r1', count(*) FROM merge_events WHERE $WIN AND merge_path = 'sweep' AND class LIKE 'excluded:%'
UNION ALL SELECT 'r2', count(*) FROM merge_events WHERE $WIN AND merge_path = 'sweep'
   AND (COALESCE(gate_result, 'NA') NOT IN ('PASS', 'NA') OR COALESCE(ci_state, 'NA') NOT IN ('success', 'NA'))
UNION ALL SELECT 'r3', count(*) FROM (
   SELECT CAST(merged_at AT TIME ZONE 'UTC' AS DATE) AS d, count(*) AS c
   FROM merge_events WHERE $WIN AND merge_path = 'sweep' GROUP BY 1 HAVING count(*) > $DAILY_CAP)
UNION ALL SELECT 'r4', count(*) FROM merge_events WHERE $WIN AND class LIKE 'tier2:%' AND approval <> 'veto-lapsed';
" > "$TMP/counts.csv"; then
  if grep -qi 'merge_events' "$TMP/dberr" 2>/dev/null; then
    indeterminate "merge_events is not in $DB (apply housekeeping_schema_init.sql); nothing was checked"
  fi
  indeterminate "could not read $DB: $(head -c 200 "$TMP/dberr" | tr '\n' ' ')"
fi
val() { awk -F, -v k="$1" '$1==k{print $2}' "$TMP/counts.csv"; }
EVER="$(val ever)"; TOTAL="$(val total)"; SWEEP="$(val sweep)"; OWNER="$(val owner_verb)"; T2="$(val tier2)"
R1="$(val r1)"; R2="$(val r2)"; R3="$(val r3)"; R4="$(val r4)"
for v in "$EVER" "$TOTAL" "$SWEEP" "$OWNER" "$T2" "$R1" "$R2" "$R3" "$R4"; do
  case "$v" in ""|*[!0-9]*) indeterminate "unreadable counts from $DB" ;; esac
done
if [ "$EVER" -eq 0 ]; then
  indeterminate "merge_events holds no rows at all; run merge_history_sync.sh (silence is not a clean result)"
fi

if ! db_run "SELECT merge_path, approval, class, count(*) FROM merge_events WHERE $WIN
             GROUP BY ALL ORDER BY 4 DESC, 1, 2, 3;" > "$TMP/groups.csv"; then
  indeterminate "could not read the merge counts: $(head -c 200 "$TMP/dberr" | tr '\n' ' ')"
fi

# R5 share: integer arithmetic in basis points (no floating point in bash)
SHARE_BP=0
if [ "$TOTAL" -gt 0 ]; then SHARE_BP=$(( SWEEP * 10000 / TOTAL )); fi
THR_BP="$(awk -v t="$SHARE_THRESHOLD" 'BEGIN{printf "%d", t * 10000 + 0.5}')"
SHARE_TXT="$(awk -v s="$SWEEP" -v t="$TOTAL" 'BEGIN{if (t > 0) printf "%.2f", s / t; else printf "0.00"}')"

ALERTS=0; INSUFF=0
status_of() { if [ "$1" -gt 0 ]; then echo "ALERT"; else echo "OK"; fi; }
S1="$(status_of "$R1")"; S2="$(status_of "$R2")"; S3="$(status_of "$R3")"; S4="$(status_of "$R4")"
if [ "$TOTAL" -lt "$MIN_MERGES" ]; then
  S5="INSUFFICIENT-DATA"; INSUFF=1
elif [ "$SHARE_BP" -gt "$THR_BP" ]; then
  S5="ALERT"
else
  S5="OK"
fi
for s in "$S1" "$S2" "$S3" "$S4" "$S5"; do
  if [ "$s" = "ALERT" ]; then ALERTS=$((ALERTS + 1)); fi
done

if [ "$JSON" -eq 1 ]; then
  printf '{"days":%s,"total":%s,"owner_verb":%s,"auto":%s,"tier2":%s,"alerts":%s,"rules":{' \
    "$DAYS" "$TOTAL" "$OWNER" "$((SWEEP - T2))" "$T2" "$ALERTS"
  printf '"R1":{"name":"sweep-excluded","status":"%s","n":%s},' "$S1" "$R1"
  printf '"R2":{"name":"sweep-unverified","status":"%s","n":%s},' "$S2" "$R2"
  printf '"R3":{"name":"sweep-daily-cap","status":"%s","n":%s},' "$S3" "$R3"
  printf '"R4":{"name":"tier2-approval","status":"%s","n":%s},' "$S4" "$R4"
  printf '"R5":{"name":"automation-share","status":"%s","share":%s,"threshold":%s,"min_merges":%s}' "$S5" "$SHARE_TXT" "$SHARE_THRESHOLD" "$MIN_MERGES"
  printf '},"groups":['
  first=1
  while IFS=, read -r mp ap cl n; do
    [ -n "$mp" ] || continue
    if [ "$first" -eq 0 ]; then printf ','; fi
    first=0
    printf '{"merge_path":"%s","approval":"%s","class":"%s","n":%s}' "$mp" "$ap" "$cl" "$n"
  done < "$TMP/groups.csv"
  printf ']}\n'
else
  echo "merge history, last $DAYS days: $TOTAL merges (owner-verb $OWNER, sweep $SWEEP of which tier2 $T2)"
  echo "R1 sweep-excluded:   $S1 (n=$R1; a sweep merge of an excluded class is a violation)"
  echo "R2 sweep-unverified: $S2 (n=$R2; sweep merge with gate not PASS or CI not success, unknown values not counted)"
  echo "R3 sweep-daily-cap:  $S3 (days over $DAILY_CAP sweep merges: $R3)"
  echo "R4 tier2-approval:   $S4 (n=$R4; tier2 merge without veto-lapsed approval)"
  if [ "$INSUFF" -eq 1 ]; then
    echo "R5 automation-share: INSUFFICIENT-DATA ($TOTAL merges, need at least $MIN_MERGES; not a pass)"
  else
    echo "R5 automation-share: $S5 (share $SHARE_TXT, threshold $SHARE_THRESHOLD, $TOTAL merges)"
  fi
  echo "merges by (merge_path, approval, class):"
  while IFS=, read -r mp ap cl n; do
    [ -n "$mp" ] || continue
    echo "  $n  $mp  $ap  $cl"
  done < "$TMP/groups.csv"
fi
if [ "$JSON" -eq 0 ]; then
  echo "summary: days=$DAYS total=$TOTAL owner_verb=$OWNER auto=$((SWEEP - T2)) tier2=$T2 alerts=$ALERTS insufficient=$INSUFF"
fi
if [ "$ALERTS" -gt 0 ]; then exit 1; fi
exit 0
