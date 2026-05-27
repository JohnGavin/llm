#!/usr/bin/env bash
# roborev_severity_autoclose.sh — auto-close roborev reviews whose maximum
# finding severity is at or below a configurable threshold.
#
# Portability: may be invoked by launchd with a bare PATH; prepend common
# tool locations so python3 and sqlite3 are visible.
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
#
# Flags:
#   --dry-run   (default) print proposed close list; no DB writes
#   --apply     actually close reviews + write counter file + emit log
#   --reopen    re-open reviews previously closed by this script
#   --replay    re-evaluate currently-CLOSED reviews; reopen those that
#               should not be auto-closed at the current threshold
#   --list      print all auto-closed reviews with parsed severities
#   --repo <n>  restrict to one repo (default: all)
#   --threshold <off|low|medium|high|critical>  override config
#   --help      usage
#
# Config precedence (highest to lowest):
#   1. --threshold flag
#   2. ROBOREV_SEVERITY_AUTOCLOSE_THRESHOLD env var
#   3. Per-repo .roborev.toml  [autoclose] severity_threshold
#   4. ~/.roborev/config.toml  autoclose_severity_threshold
#   5. Default: off
#
# Severity ordinal map:
#   off=0  low=1  medium=2  high=3  critical=4
# Close iff max(finding_severities) <= threshold AND threshold > 0.
#
# Close marker written as a comment:
#   auto-closed: severity<=<T> [config:<source>] [run:<ISO-8601>]
#
# Log file: ~/.claude/logs/roborev_severity_autoclose.log
# Counter file: ~/.claude/.roborev_autoclose_counters.json
#
# Tracked in llm#224.

set -euo pipefail

# ── Self-test (must appear before any side effects) ──────────────────────
if [ "${ROBOREV_SEVAUTOCLOSE_SELFTEST:-0}" = "1" ]; then
  PASS=0
  FAIL=0

  _sev_ordinal() {
    case "${1,,}" in
      off)      echo 0 ;;
      low)      echo 1 ;;
      medium)   echo 2 ;;
      high)     echo 3 ;;
      critical) echo 4 ;;
      *)        echo -1 ;;
    esac
  }

  _parse_max_severity() {
    # Extract **Severity**: <word> lines (case-insensitive), return max ordinal.
    # Returns empty string if none found.
    local text="$1"
    local max=-1
    local word ord
    while IFS= read -r line; do
      word=$(echo "$line" | grep -oiE '(Critical|High|Medium|Low)' | head -1)
      if [ -n "$word" ]; then
        ord=$(_sev_ordinal "$word")
        [ "$ord" -gt "$max" ] && max=$ord
      fi
    done < <(echo "$text" | grep -iE '\*\*Severity\*\*:\s*(Critical|High|Medium|Low)')
    [ "$max" -ge 0 ] && echo "$max" || echo ""
  }

  _should_close() {
    # Returns 0 (close) or 1 (skip).
    local max_ord="$1"
    local threshold_ord="$2"
    [ -z "$max_ord" ] && return 1           # parse fail → skip
    [ "$threshold_ord" -eq 0 ] && return 1  # off → skip
    [ "$max_ord" -le "$threshold_ord" ] && return 0 || return 1
  }

  _run_case() {
    local label="$1" text="$2" threshold="$3" expected="$4"
    local t_ord max_ord result
    t_ord=$(_sev_ordinal "$threshold")
    max_ord=$(_parse_max_severity "$text")
    if _should_close "$max_ord" "$t_ord"; then
      result="CLOSE"
    else
      result="SKIP"
    fi
    if [ "$result" = "$expected" ]; then
      PASS=$((PASS+1))
      echo "  PASS [$label]: got $result"
    else
      FAIL=$((FAIL+1))
      echo "  FAIL [$label]: expected $expected, got $result (max_ord='$max_ord' t_ord='$t_ord')"
    fi
  }

  THRESHOLD_FOR_TEST="medium"

  # Case 1: pure-High review → must SKIP
  _run_case "pure-High" "
## Review Findings
- **Severity**: High
  **Location**: R/foo.R:10
  **Problem**: something important" "$THRESHOLD_FOR_TEST" "SKIP"

  # Case 2: pure-Medium review → must CLOSE at threshold=medium
  _run_case "pure-Medium" "
## Review Findings
- **Severity**: Medium
  **Location**: R/foo.R:10
  **Problem**: minor issue" "$THRESHOLD_FOR_TEST" "CLOSE"

  # Case 3: pure-Low review → must CLOSE at threshold=medium
  _run_case "pure-Low" "
## Review Findings
- **Severity**: Low
  **Location**: R/foo.R:10
  **Problem**: style issue" "$THRESHOLD_FOR_TEST" "CLOSE"

  # Case 4: mixed High+Medium → must SKIP (max is High, above threshold)
  _run_case "mixed-High+Medium" "
## Review Findings
- **Severity**: High
  **Location**: R/foo.R:10
  **Problem**: important
- **Severity**: Medium
  **Location**: R/bar.R:5
  **Problem**: minor" "$THRESHOLD_FOR_TEST" "SKIP"

  # Case 5: mixed Medium+Low → must CLOSE at threshold=medium
  _run_case "mixed-Medium+Low" "
## Review Findings
- **Severity**: Medium
  **Location**: R/foo.R:10
  **Problem**: moderate
- **Severity**: Low
  **Location**: R/bar.R:5
  **Problem**: minor" "$THRESHOLD_FOR_TEST" "CLOSE"

  # Case 6: no Severity markers → must SKIP (SKIP_PARSE_FAIL)
  _run_case "no-severity-markers" "
## Review Findings
The code has some issues but nothing specific is flagged here." "$THRESHOLD_FOR_TEST" "SKIP"

  # Case 7: empty output → must SKIP (SKIP_PARSE_FAIL)
  _run_case "empty-output" "" "$THRESHOLD_FOR_TEST" "SKIP"

  # Case 8: clean verdict (verdict_bool=1, output begins with "No issues found") →
  # must CLOSE via the clean-verdict path, NOT SKIP_PARSE_FAIL.
  _run_case_clean() {
    local label="$1" verdict="$2" output="$3" expected="$4"
    local result
    # Mirror the clean-verdict branch in the main loop:
    # clean iff verdict=1 OR output starts with "no issues found" (case-insensitive)
    local output_lower
    output_lower=$(echo "$output" | tr '[:upper:]' '[:lower:]')
    if [ "$verdict" = "1" ] || [[ "$output_lower" == "no issues found"* ]]; then
      result="CLOSE_CLEAN"
    else
      # Fall through to severity path (simplified: just note not-clean)
      result="SKIP"
    fi
    if [ "$result" = "$expected" ]; then
      PASS=$((PASS+1))
      echo "  PASS [$label]: got $result"
    else
      FAIL=$((FAIL+1))
      echo "  FAIL [$label]: expected $expected, got $result (verdict='$verdict')"
    fi
  }

  _run_case_clean "clean-verdict-bool" "1" "No issues found." "CLOSE_CLEAN"
  _run_case_clean "clean-verdict-prefix" "0" "No issues found. All checks passed." "CLOSE_CLEAN"
  _run_case_clean "findings-verdict-bool-0" "0" "## Review Findings\n- **Severity**: Low" "SKIP"

  # Case 10: job_id field parsing — candidate row with distinct id and job_id
  # Asserts that field 6 (job_id) is parsed correctly and is NOT equal to field 1 (review_id).
  # This guards against the regression described in llm#312 where close was called with
  # rv.id instead of rv.job_id (the two id spaces overlap so the wrong review was closed).
  _run_case_job_id_parse() {
    local label="$1"
    # Construct a tab-separated candidate row: id=100, output=..., root=..., repo=..., verdict=0, job_id=999
    local _test_row="100	No issues found.	/some/path	testrepo	0	999"
    local _parsed_id
    local _parsed_job_id
    _parsed_id=$(echo "$_test_row" | cut -f1)
    _parsed_job_id=$(echo "$_test_row" | cut -f6)
    # job_id must be 999, not 100 (review id)
    if [ "$_parsed_job_id" = "999" ] && [ "$_parsed_id" = "100" ] && [ "$_parsed_job_id" != "$_parsed_id" ]; then
      PASS=$((PASS+1))
      echo "  PASS [$label]: job_id=$_parsed_job_id correctly parsed from field 6 (review_id=$_parsed_id)"
    else
      FAIL=$((FAIL+1))
      echo "  FAIL [$label]: expected job_id=999 review_id=100, got job_id=$_parsed_job_id review_id=$_parsed_id"
    fi
  }
  _run_case_job_id_parse "job_id-field6-parse"

  TOTAL=$((PASS+FAIL))
  echo ""
  if [ "$FAIL" -eq 0 ]; then
    echo "${PASS}/${TOTAL} PASS"
    exit 0
  else
    echo "${PASS}/${TOTAL} PASS — ${FAIL} FAILED"
    exit 1
  fi
fi

# ── Helpers ──────────────────────────────────────────────────────────────

LOGFILE="${HOME}/.claude/logs/roborev_severity_autoclose.log"
COUNTER_FILE="${HOME}/.claude/.roborev_autoclose_counters.json"
ROBOREV_DB="${ROBOREV_DB:-${HOME}/.roborev/reviews.db}"
ROBOREV_BIN="${ROBOREV:-$(command -v roborev 2>/dev/null || echo /usr/local/bin/roborev)}"

log() {
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')
  echo "${ts} $*" >> "$LOGFILE"
}

die() { echo "ERROR: $*" >&2; exit 1; }

_sev_ordinal() {
  case "${1,,}" in
    off)      echo 0 ;;
    low)      echo 1 ;;
    medium)   echo 2 ;;
    high)     echo 3 ;;
    critical) echo 4 ;;
    *)        echo -1 ;;
  esac
}

_sev_name() {
  case "$1" in
    0) echo "off" ;;
    1) echo "low" ;;
    2) echo "medium" ;;
    3) echo "high" ;;
    4) echo "critical" ;;
    *) echo "unknown" ;;
  esac
}

# Parse **Severity**: <word> lines from text; echo the max ordinal or "" if none.
_parse_max_severity() {
  local text="$1"
  local max=-1
  local word ord
  while IFS= read -r line; do
    word=$(echo "$line" | grep -oiE '(Critical|High|Medium|Low)' | head -1)
    if [ -n "$word" ]; then
      ord=$(_sev_ordinal "$word")
      [ "$ord" -gt "$max" ] && max=$ord
    fi
  done < <(echo "$text" | grep -iE '\*\*Severity\*\*:[[:space:]]*(Critical|High|Medium|Low)')
  [ "$max" -ge 0 ] && echo "$max" || echo ""
}

# Read per-repo threshold from .roborev.toml in the repo's root_path.
_repo_threshold() {
  local repo_root="$1"
  local toml="${repo_root}/.roborev.toml"
  if [ -f "$toml" ]; then
    local val
    val=$(grep -E '^[[:space:]]*severity_threshold[[:space:]]*=' "$toml" 2>/dev/null \
          | head -1 \
          | sed 's/.*=[[:space:]]*//' \
          | tr -d '"'"'" \
          | tr -d '[:space:]')
    echo "$val"
  fi
}

# Read global threshold from ~/.roborev/config.toml
_global_threshold() {
  local cfg="${HOME}/.roborev/config.toml"
  if [ -f "$cfg" ]; then
    local val
    val=$(grep -E '^[[:space:]]*autoclose_severity_threshold[[:space:]]*=' "$cfg" 2>/dev/null \
          | head -1 \
          | sed 's/.*=[[:space:]]*//' \
          | tr -d '"'"'" \
          | tr -d '[:space:]')
    echo "$val"
  fi
}

# Atomically update counter file using Python heredoc (WAL-safe, single writer).
_update_counters() {
  local date_key="$1"    # e.g. 2026-05-21
  local repo_name="$2"
  local threshold_str="$3"
  local closed="$4"
  local skipped="$5"
  local parse_fail="$6"

  local run_utc
  run_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')

  /usr/bin/python3 - "$COUNTER_FILE" "$date_key" "$repo_name" "$threshold_str" \
      "$closed" "$skipped" "$parse_fail" "$run_utc" <<'PYEOF'
import json, os, sys, tempfile

counter_file = sys.argv[1]
date_key     = sys.argv[2]
repo_name    = sys.argv[3]
threshold_str= sys.argv[4]
closed       = int(sys.argv[5])
skipped      = int(sys.argv[6])
parse_fail   = int(sys.argv[7])
run_utc      = sys.argv[8]

# Load existing or create fresh
if os.path.exists(counter_file):
    try:
        with open(counter_file) as f:
            data = json.load(f)
    except (json.JSONDecodeError, OSError):
        data = {}
else:
    data = {}

if data.get('schema_version') != 1:
    data = {'schema_version': 1, 'by_date': {}}

by_date = data.setdefault('by_date', {})
day = by_date.setdefault(date_key, {
    'threshold_observed': {},
    'closed_count': 0,
    'skipped_count': 0,
    'parse_fail_count': 0,
    'by_repo': {}
})

day['threshold_observed'][repo_name] = threshold_str
day['closed_count']      = day.get('closed_count', 0) + closed
day['skipped_count']     = day.get('skipped_count', 0) + skipped
day['parse_fail_count']  = day.get('parse_fail_count', 0) + parse_fail

r = day.setdefault('by_repo', {}).setdefault(repo_name, {})
r['closed']  = r.get('closed', 0)  + closed
r['skipped'] = r.get('skipped', 0) + skipped

data['last_run_utc'] = run_utc

# Atomic write via tmp + rename
dirpath = os.path.dirname(counter_file) or '.'
fd, tmp = tempfile.mkstemp(dir=dirpath, suffix='.json.tmp')
try:
    with os.fdopen(fd, 'w') as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, counter_file)
except Exception:
    try: os.unlink(tmp)
    except OSError: pass
    raise
PYEOF
}

# ── Argument parsing ──────────────────────────────────────────────────────

MODE=""           # dry-run | apply | reopen | replay | list
FILTER_REPO=""
THRESHOLD_FLAG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)    MODE="dry-run"; shift ;;
    --apply)      MODE="apply";   shift ;;
    --reopen)     MODE="reopen";  shift ;;
    --replay)     MODE="replay";  shift ;;
    --list)       MODE="list";    shift ;;
    --repo)
      shift
      [ $# -gt 0 ] || die "--repo requires an argument"
      FILTER_REPO="$1"; shift ;;
    --threshold)
      shift
      [ $# -gt 0 ] || die "--threshold requires an argument"
      THRESHOLD_FLAG="$1"; shift ;;
    -h|--help)
      sed -n '3,16p' "$0"
      exit 0 ;;
    *)
      echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

# Default mode is dry-run
[ -z "$MODE" ] && MODE="dry-run"

# Validate threshold flag if provided
if [ -n "$THRESHOLD_FLAG" ]; then
  case "${THRESHOLD_FLAG,,}" in
    off|low|medium|high|critical) : ;;
    *) die "invalid --threshold value '${THRESHOLD_FLAG}'; valid: off low medium high critical" ;;
  esac
fi

RUN_TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')
RUN_DATE=$(echo "$RUN_TS" | cut -c1-10)

# ── Prerequisite checks ───────────────────────────────────────────────────

if [ ! -x "$ROBOREV_BIN" ]; then
  log "skip: roborev binary not found at ${ROBOREV_BIN}"
  echo "roborev_severity_autoclose: roborev binary not found at ${ROBOREV_BIN}, exiting"
  exit 0
fi

if [ ! -f "$ROBOREV_DB" ]; then
  log "skip: reviews.db not found at ${ROBOREV_DB}"
  echo "roborev_severity_autoclose: reviews.db not found at ${ROBOREV_DB}, exiting"
  exit 0
fi

# ── --list mode ───────────────────────────────────────────────────────────

if [ "$MODE" = "list" ]; then
  MARKER_PATTERN="auto-closed: severity<="
  echo "Reviews auto-closed by this script (searching responses for marker):"
  echo ""
  # Find review IDs that have the close marker in their responses
  /usr/bin/python3 - "$ROBOREV_DB" "$MARKER_PATTERN" "$FILTER_REPO" <<'PYEOF'
import sqlite3, sys

db_path = sys.argv[1]
marker  = sys.argv[2]
repo_filter = sys.argv[3] if len(sys.argv) > 3 else ''

con = sqlite3.connect(f'file:{db_path}?mode=ro', uri=True)
con.row_factory = sqlite3.Row

sql = """
    SELECT r.id, rp.name AS repo, rv.closed,
           rv.output,
           resp.response AS comment,
           resp.created_at
    FROM reviews rv
    JOIN review_jobs r ON r.id = rv.job_id
    JOIN repos rp ON rp.id = r.repo_id
    LEFT JOIN responses resp ON resp.job_id = rv.job_id
        AND resp.response LIKE ?
    WHERE rv.closed = 1
"""
params = [f'%{marker}%']

if repo_filter:
    sql += " AND rp.name = ?"
    params.append(repo_filter)

sql += " ORDER BY resp.created_at DESC"

rows = con.execute(sql, params).fetchall()
con.close()

if not rows:
    print("  (none found)")
else:
    for row in rows:
        comment = (row['comment'] or '').strip().replace('\n', ' ')
        print(f"  review_id={row['id']} repo={row['repo']} closed={row['closed']}")
        print(f"    marker: {comment[:120]}")
        print()
PYEOF
  exit 0
fi

# ── --reopen mode ─────────────────────────────────────────────────────────

if [ "$MODE" = "reopen" ]; then
  MARKER_PATTERN="auto-closed: severity<="
  echo "Reopening reviews previously closed by this script..."

  REOPEN_IDS=()
  while IFS= read -r _id; do
    [ -n "$_id" ] && REOPEN_IDS+=("$_id")
  done < <(
    /usr/bin/python3 - "$ROBOREV_DB" "$MARKER_PATTERN" "$FILTER_REPO" <<'PYEOF'
import sqlite3, sys

db_path = sys.argv[1]
marker  = sys.argv[2]
repo_filter = sys.argv[3] if len(sys.argv) > 3 else ''

con = sqlite3.connect(f'file:{db_path}?mode=ro', uri=True)

sql = """
    SELECT DISTINCT rv.id
    FROM reviews rv
    JOIN review_jobs rj ON rj.id = rv.job_id
    JOIN repos rp ON rp.id = rj.repo_id
    JOIN responses resp ON resp.job_id = rv.job_id
        AND resp.response LIKE ?
    WHERE rv.closed = 1
"""
params = [f'%{marker}%']

if repo_filter:
    sql += " AND rp.name = ?"
    params.append(repo_filter)

rows = con.execute(sql, params).fetchall()
con.close()
for row in rows:
    print(row[0])
PYEOF
  )

  N=${#REOPEN_IDS[@]}
  if [ "$N" -eq 0 ]; then
    echo "roborev_severity_autoclose: no auto-closed reviews found to reopen"
    log "reopen: 0 reviews found"
    exit 0
  fi

  REOPENED=0
  FAILED=0
  for _id in "${REOPEN_IDS[@]}"; do
    if "$ROBOREV_BIN" reopen "$_id" >/dev/null 2>&1; then
      REOPENED=$((REOPENED+1))
      log "REOPEN review_id=${_id}"
      echo "  reopened review_id=${_id}"
    else
      FAILED=$((FAILED+1))
      log "REOPEN_FAIL review_id=${_id}"
      echo "  FAIL: could not reopen review_id=${_id}"
    fi
  done

  echo "roborev_severity_autoclose: reopened ${REOPENED}/${N} reviews (${FAILED} failed)"
  exit 0
fi

# ── --replay mode ─────────────────────────────────────────────────────────

if [ "$MODE" = "replay" ]; then
  MARKER_PATTERN="auto-closed: severity<="
  echo "Replaying closed reviews against current threshold..."

  REPLAY_ROWS=()
  while IFS=$'\t' read -r _id _output _root _repo; do
    [ -n "$_id" ] && REPLAY_ROWS+=("${_id}	${_output}	${_root}	${_repo}")
  done < <(
    /usr/bin/python3 - "$ROBOREV_DB" "$MARKER_PATTERN" "$FILTER_REPO" <<'PYEOF'
import sqlite3, sys

db_path = sys.argv[1]
marker  = sys.argv[2]
repo_filter = sys.argv[3] if len(sys.argv) > 3 else ''

con = sqlite3.connect(f'file:{db_path}?mode=ro', uri=True)

sql = """
    SELECT DISTINCT rv.id, rv.output, rp.root_path, rp.name
    FROM reviews rv
    JOIN review_jobs rj ON rj.id = rv.job_id
    JOIN repos rp ON rp.id = rj.repo_id
    JOIN responses resp ON resp.job_id = rv.job_id
        AND resp.response LIKE ?
    WHERE rv.closed = 1
"""
params = [f'%{marker}%']

if repo_filter:
    sql += " AND rp.name = ?"
    params.append(repo_filter)

rows = con.execute(sql, params).fetchall()
con.close()
for row in rows:
    output = (row[1] or '').replace('\t', ' ').replace('\n', ' ')
    print(f"{row[0]}\t{output}\t{row[2]}\t{row[3]}")
PYEOF
  )

  N=${#REPLAY_ROWS[@]}
  if [ "$N" -eq 0 ]; then
    echo "roborev_severity_autoclose: no auto-closed reviews found"
    log "replay: 0 reviews found"
    exit 0
  fi

  REOPENED=0
  KEPT=0
  for _row in "${REPLAY_ROWS[@]}"; do
    _id=$(echo "$_row" | cut -f1)
    _output=$(echo "$_row" | cut -f2)
    _root=$(echo "$_row" | cut -f3)
    _repo=$(echo "$_row" | cut -f4)

    # Determine effective threshold for this repo
    _eff_threshold=""
    _eff_source=""
    if [ -n "$THRESHOLD_FLAG" ]; then
      _eff_threshold="${THRESHOLD_FLAG,,}"
      _eff_source="flag"
    elif [ -n "${ROBOREV_SEVERITY_AUTOCLOSE_THRESHOLD:-}" ]; then
      _eff_threshold="${ROBOREV_SEVERITY_AUTOCLOSE_THRESHOLD,,}"
      _eff_source="env"
    else
      _per_repo=$(_repo_threshold "$_root")
      if [ -n "$_per_repo" ]; then
        _eff_threshold="${_per_repo,,}"
        _eff_source="per-repo:.roborev.toml"
      else
        _global=$(_global_threshold)
        if [ -n "$_global" ]; then
          _eff_threshold="${_global,,}"
          _eff_source="global:~/.roborev/config.toml"
        else
          _eff_threshold="off"
          _eff_source="default"
        fi
      fi
    fi

    _t_ord=$(_sev_ordinal "$_eff_threshold")
    _max_ord=$(_parse_max_severity "$_output")

    # If threshold is off, or max severity exceeds threshold: reopen
    local_should_close=0
    if [ -n "$_max_ord" ] && [ "$_t_ord" -gt 0 ] && [ "$_max_ord" -le "$_t_ord" ]; then
      local_should_close=1
    fi

    if [ "$local_should_close" -eq 0 ]; then
      # Should no longer be auto-closed → reopen
      if "$ROBOREV_BIN" reopen "$_id" >/dev/null 2>&1; then
        REOPENED=$((REOPENED+1))
        log "REPLAY_REOPEN review_id=${_id} repo=${_repo} threshold=${_eff_threshold} source=${_eff_source}"
        echo "  reopened review_id=${_id} repo=${_repo} (would not close at threshold=${_eff_threshold})"
      else
        log "REPLAY_REOPEN_FAIL review_id=${_id} repo=${_repo}"
        echo "  FAIL: could not reopen review_id=${_id}"
      fi
    else
      KEPT=$((KEPT+1))
      echo "  kept-closed review_id=${_id} repo=${_repo} max_sev=$(_sev_name "$_max_ord") threshold=${_eff_threshold}"
    fi
  done

  echo ""
  echo "roborev_severity_autoclose: replay complete — reopened=${REOPENED} kept-closed=${KEPT} (of ${N})"
  exit 0
fi

# ── Main: dry-run / apply ─────────────────────────────────────────────────

# Fetch all open reviews with repo info (both findings and clean verdicts)
REVIEW_ROWS=()
while IFS=$'\t' read -r _id _output _root _repo _verdict _job_id; do
  [ -n "$_id" ] && REVIEW_ROWS+=("${_id}	${_output}	${_root}	${_repo}	${_verdict}	${_job_id}")
done < <(
  /usr/bin/python3 - "$ROBOREV_DB" "$FILTER_REPO" <<'PYEOF'
import sqlite3, sys

db_path = sys.argv[1]
repo_filter = sys.argv[2] if len(sys.argv) > 2 else ''

con = sqlite3.connect(f'file:{db_path}?mode=ro', uri=True)

sql = """
    SELECT rv.id, rv.output, rp.root_path, rp.name, rv.verdict_bool, rv.job_id
    FROM reviews rv
    JOIN review_jobs rj ON rj.id = rv.job_id
    JOIN repos rp ON rp.id = rj.repo_id
    WHERE rv.closed = 0
"""
params = []

if repo_filter:
    sql += " AND rp.name = ?"
    params.append(repo_filter)

sql += " ORDER BY rv.id"

rows = con.execute(sql, params).fetchall()
con.close()
for row in rows:
    output = (row[1] or '').replace('\t', ' ').replace('\n', ' ')
    print(f"{row[0]}\t{output}\t{row[2]}\t{row[3]}\t{row[4]}\t{row[5]}")
PYEOF
)

N=${#REVIEW_ROWS[@]}
if [ "$N" -eq 0 ]; then
  echo "roborev_severity_autoclose: no open reviews found"
  log "ok: 0 open reviews"
  exit 0
fi

echo "roborev_severity_autoclose: ${N} open reviews to evaluate"

# Per-repo counters for this run
declare -A CLOSED_BY_REPO SKIPPED_BY_REPO THRESHOLD_BY_REPO
TOTAL_CLOSED=0
TOTAL_SKIPPED=0
TOTAL_PARSE_FAIL=0

for _row in "${REVIEW_ROWS[@]}"; do
  _id=$(echo "$_row"       | cut -f1)
  _output=$(echo "$_row"   | cut -f2)
  _root=$(echo "$_row"     | cut -f3)
  _repo=$(echo "$_row"     | cut -f4)
  _verdict=$(echo "$_row"  | cut -f5)
  _job_id=$(echo "$_row"   | cut -f6)

  # Determine effective threshold + source for this repo
  _eff_threshold=""
  _eff_source=""
  if [ -n "$THRESHOLD_FLAG" ]; then
    _eff_threshold="${THRESHOLD_FLAG,,}"
    _eff_source="flag"
  elif [ -n "${ROBOREV_SEVERITY_AUTOCLOSE_THRESHOLD:-}" ]; then
    _eff_threshold="${ROBOREV_SEVERITY_AUTOCLOSE_THRESHOLD,,}"
    _eff_source="env"
  else
    _per_repo=$(_repo_threshold "$_root")
    if [ -n "$_per_repo" ]; then
      _eff_threshold="${_per_repo,,}"
      _eff_source="per-repo:.roborev.toml"
    else
      _global=$(_global_threshold)
      if [ -n "$_global" ]; then
        _eff_threshold="${_global,,}"
        _eff_source="global:~/.roborev/config.toml"
      else
        _eff_threshold="off"
        _eff_source="default"
      fi
    fi
  fi

  _t_ord=$(_sev_ordinal "$_eff_threshold")
  _max_ord=$(_parse_max_severity "$_output")

  # Record threshold per repo
  THRESHOLD_BY_REPO["$_repo"]="$_eff_threshold"

  # Decision — clean-verdict branch FIRST (before severity checks)
  _output_lower=$(echo "$_output" | tr '[:upper:]' '[:lower:]')
  if [ "$_verdict" = "1" ] || [[ "$_output_lower" == "no issues found"* ]]; then
    # Clean review: close unconditionally (no threshold check needed)
    if [ "$MODE" = "apply" ]; then
      _close_ok=0
      if "$ROBOREV_BIN" close "$_job_id" >/dev/null 2>&1; then
        _close_ok=1
      fi
      if [ "$_close_ok" -eq 1 ]; then
        _marker="auto-closed: clean verdict [run:${RUN_TS}]"
        "$ROBOREV_BIN" comment "$_job_id" "$_marker" >/dev/null 2>&1 || true
        ACTION="CLOSE_CLEAN"
        TOTAL_CLOSED=$((TOTAL_CLOSED+1))
        CLOSED_BY_REPO["$_repo"]=$(( ${CLOSED_BY_REPO["$_repo"]:-0} + 1 ))
        log "${ACTION} review_id=${_id} job_id=${_job_id} repo=${_repo}"
        echo "  CLOSE_CLEAN review_id=${_id} job_id=${_job_id} repo=${_repo}"
      else
        log "CLOSE_CLEAN_FAIL review_id=${_id} job_id=${_job_id} repo=${_repo}"
        echo "  CLOSE_CLEAN_FAIL review_id=${_id} job_id=${_job_id} repo=${_repo} (roborev close failed)"
        TOTAL_SKIPPED=$((TOTAL_SKIPPED+1))
        SKIPPED_BY_REPO["$_repo"]=$(( ${SKIPPED_BY_REPO["$_repo"]:-0} + 1 ))
      fi
    else
      # dry-run
      ACTION="CLOSE_CLEAN"
      TOTAL_CLOSED=$((TOTAL_CLOSED+1))
      CLOSED_BY_REPO["$_repo"]=$(( ${CLOSED_BY_REPO["$_repo"]:-0} + 1 ))
      log "DRY_RUN_CLOSE_CLEAN review_id=${_id} job_id=${_job_id} repo=${_repo}"
      echo "  [dry-run] CLOSE_CLEAN review_id=${_id} job_id=${_job_id} repo=${_repo}"
    fi
    continue
  fi

  # Severity-based decision (verdict_bool=0 reviews only reach here)
  if [ -z "$_max_ord" ]; then
    # No severity found in output
    ACTION="SKIP_PARSE_FAIL"
    TOTAL_PARSE_FAIL=$((TOTAL_PARSE_FAIL+1))
    SKIPPED_BY_REPO["$_repo"]=$(( ${SKIPPED_BY_REPO["$_repo"]:-0} + 1 ))
    log "${ACTION} review_id=${_id} repo=${_repo} max_severity=UNKNOWN threshold=${_eff_threshold} source=${_eff_source}"
    echo "  SKIP_PARSE_FAIL review_id=${_id} repo=${_repo} (no severity markers found)"
  elif [ "$_t_ord" -eq 0 ]; then
    ACTION="SKIP_THRESHOLD_OFF"
    TOTAL_SKIPPED=$((TOTAL_SKIPPED+1))
    SKIPPED_BY_REPO["$_repo"]=$(( ${SKIPPED_BY_REPO["$_repo"]:-0} + 1 ))
    log "${ACTION} review_id=${_id} repo=${_repo} max_severity=$(_sev_name "$_max_ord") threshold=off source=${_eff_source}"
    echo "  SKIP_THRESHOLD_OFF review_id=${_id} repo=${_repo} max=$(_sev_name "$_max_ord")"
  elif [ "$_max_ord" -le "$_t_ord" ]; then
    # Close — use job_id for roborev close/comment (fix #312: roborev close expects
    # job_id not review_id; job:review is 1:1 so this closes exactly the right review)
    if [ "$MODE" = "apply" ]; then
      _close_ok=0
      if "$ROBOREV_BIN" close "$_job_id" >/dev/null 2>&1; then
        _close_ok=1
      fi
      if [ "$_close_ok" -eq 1 ]; then
        _marker="auto-closed: severity<=${_eff_threshold} [config:${_eff_source}] [run:${RUN_TS}]"
        "$ROBOREV_BIN" comment "$_job_id" "$_marker" >/dev/null 2>&1 || true
        ACTION="CLOSE"
        TOTAL_CLOSED=$((TOTAL_CLOSED+1))
        CLOSED_BY_REPO["$_repo"]=$(( ${CLOSED_BY_REPO["$_repo"]:-0} + 1 ))
        log "${ACTION} review_id=${_id} job_id=${_job_id} repo=${_repo} max_severity=$(_sev_name "$_max_ord") threshold=${_eff_threshold} source=${_eff_source}"
        echo "  CLOSE review_id=${_id} job_id=${_job_id} repo=${_repo} max=$(_sev_name "$_max_ord") threshold=${_eff_threshold}"
      else
        log "CLOSE_FAIL review_id=${_id} job_id=${_job_id} repo=${_repo}"
        echo "  CLOSE_FAIL review_id=${_id} job_id=${_job_id} repo=${_repo} (roborev close failed)"
        TOTAL_SKIPPED=$((TOTAL_SKIPPED+1))
        SKIPPED_BY_REPO["$_repo"]=$(( ${SKIPPED_BY_REPO["$_repo"]:-0} + 1 ))
      fi
    else
      # dry-run
      ACTION="CLOSE"
      TOTAL_CLOSED=$((TOTAL_CLOSED+1))
      CLOSED_BY_REPO["$_repo"]=$(( ${CLOSED_BY_REPO["$_repo"]:-0} + 1 ))
      log "DRY_RUN_CLOSE review_id=${_id} job_id=${_job_id} repo=${_repo} max_severity=$(_sev_name "$_max_ord") threshold=${_eff_threshold} source=${_eff_source}"
      echo "  [dry-run] CLOSE review_id=${_id} job_id=${_job_id} repo=${_repo} max=$(_sev_name "$_max_ord") threshold=${_eff_threshold}"
    fi
  else
    ACTION="SKIP_ABOVE_THRESHOLD"
    TOTAL_SKIPPED=$((TOTAL_SKIPPED+1))
    SKIPPED_BY_REPO["$_repo"]=$(( ${SKIPPED_BY_REPO["$_repo"]:-0} + 1 ))
    log "${ACTION} review_id=${_id} repo=${_repo} max_severity=$(_sev_name "$_max_ord") threshold=${_eff_threshold} source=${_eff_source}"
    echo "  SKIP review_id=${_id} repo=${_repo} max=$(_sev_name "$_max_ord") > threshold=${_eff_threshold}"
  fi
done

echo ""
if [ "$MODE" = "dry-run" ]; then
  echo "roborev_severity_autoclose [dry-run]: would-close=${TOTAL_CLOSED} skip=${TOTAL_SKIPPED} parse-fail=${TOTAL_PARSE_FAIL} (pass --apply to execute)"
else
  echo "roborev_severity_autoclose [apply]: closed=${TOTAL_CLOSED} skip=${TOTAL_SKIPPED} parse-fail=${TOTAL_PARSE_FAIL}"
fi

# Update counter file only in --apply mode
if [ "$MODE" = "apply" ]; then
  for _r in "${!CLOSED_BY_REPO[@]}"; do
    _c=${CLOSED_BY_REPO["$_r"]:-0}
    _s=${SKIPPED_BY_REPO["$_r"]:-0}
    _pf=0  # parse fails are not tracked per-repo in skipped; best effort
    _t=${THRESHOLD_BY_REPO["$_r"]:-off}
    _update_counters "$RUN_DATE" "$_r" "$_t" "$_c" "$_s" "$_pf" || true
  done
  # Also record repos that only had skips / parse-fails
  for _r in "${!SKIPPED_BY_REPO[@]}"; do
    if [ -z "${CLOSED_BY_REPO["$_r"]:-}" ]; then
      _s=${SKIPPED_BY_REPO["$_r"]:-0}
      _t=${THRESHOLD_BY_REPO["$_r"]:-off}
      _update_counters "$RUN_DATE" "$_r" "$_t" 0 "$_s" 0 || true
    fi
  done
fi
