#!/usr/bin/env bash
# roborev_verify_closure.sh <commit_sha> <finding_id> [<finding_id>...]
#
# Post-commit verifier for roborev closure citations (Component 4, JohnGavin/llm#353).
#
# SIGNAL ONLY — does NOT auto-close findings, does NOT write to closures table,
# does NOT write to fix_rejected_queue. That is #354's job.  This script produces
# a verdict JSON and exits.
#
# Usage:
#   ~/.claude/scripts/roborev_verify_closure.sh <commit_sha> <finding_id>...
#
# Example:
#   ~/.claude/scripts/roborev_verify_closure.sh abc1234 675 1551 1545
#
# Output (written to ~/.claude/logs/roborev_verify_closure/<commit_sha>.json):
#
#   {
#     "commit_sha": "abc1234",
#     "review_job_id": 5437,
#     "review_verdict_bool": 0,
#     "verdicts": {
#       "675": {
#         "status": "verified-pass",
#         "reason": "review approved and location not re-flagged"
#       },
#       "1551": {
#         "status": "verified-fail",
#         "reason": "location R/plan_regime.R:241 re-flagged in re-review"
#       }
#     },
#     "timestamp": "2026-05-30T17:00:00Z"
#   }
#
# Verdict status values:
#   verified-pass  — re-review approved AND the original finding's location is not
#                    re-flagged in the new review output.
#   verified-fail  — re-review re-flags the same location as the original finding
#                    (the "fix" did not resolve it).
#   inconclusive   — ambiguous: timeout, roborev unavailable, or finding not in DB.
#
# Exit codes:
#   0 = verdict JSON written (or skipped cleanly — fail-open)
#   1 = hard error (unexpected)
#
# Invoked asynchronously (nohup &) by the post-commit hook — must never block.
#
# Log: ~/.claude/logs/roborev_verify_closure.log
# Issue: JohnGavin/llm#353

export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
# Wire codex_with_fallback.sh into roborev's codex calls (#365):
_SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
if [ -x "${_SCRIPT_DIR}/codex_shim/codex" ]; then
  export PATH="${_SCRIPT_DIR}/codex_shim:$PATH"
fi
unset _SCRIPT_DIR

set -uo pipefail

LOGFILE="${HOME}/.claude/logs/roborev_verify_closure.log"
VERDICT_DIR="${HOME}/.claude/logs/roborev_verify_closure"
ROBOREV_DB="${ROBOREV_DB:-${HOME}/.roborev/reviews.db}"
ROBOREV_BIN="${ROBOREV:-$(command -v roborev 2>/dev/null || echo /usr/local/bin/roborev)}"

POLL_TIMEOUT_SECS="${ROBOREV_VERIFY_TIMEOUT:-300}"
POLL_INTERVAL_SECS=5

# ── Logging ───────────────────────────────────────────────────────────────────

log() {
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')
  echo "${ts} $*" >> "$LOGFILE"
}

# ── Self-test ─────────────────────────────────────────────────────────────────

if [ "${SELFTEST:-0}" = "1" ]; then
  PASS=0
  FAIL=0

  _check() {
    local label="$1" result="$2"
    if [ "$result" = "pass" ]; then
      PASS=$((PASS+1))
      echo "  PASS [$label]"
    else
      FAIL=$((FAIL+1))
      echo "  FAIL [$label]: $result"
    fi
  }

  # Test 1: extract job_id from "Enqueued job NNN for ..." line
  JID=$( echo "Enqueued job 5437 for abc1234 (agent: codex)" \
    | /usr/bin/python3 -c "
import sys, re
for line in sys.stdin:
    m = re.search(r'Enqueued job\s+(\d+)', line)
    if m:
        print(m.group(1))
        break
")
  if [ "$JID" = "5437" ]; then
    _check "parse-job-id" "pass"
  else
    _check "parse-job-id" "fail: got '$JID'"
  fi

  # Test 2: location-match helper — finding location appears in review output
  OUTPUT="- **Severity**: Medium\n- **Location**: R/plan_regime.R:241\n- **Problem**: bad thing"
  LOC="R/plan_regime.R:241"
  MATCH=$(/usr/bin/python3 -c "
import sys
output = sys.argv[1]
loc = sys.argv[2]
print('yes' if loc in output else 'no')
" "$OUTPUT" "$LOC")
  if [ "$MATCH" = "yes" ]; then
    _check "location-match-found" "pass"
  else
    _check "location-match-found" "fail: got '$MATCH'"
  fi

  # Test 3: location-match helper — location NOT in output
  OUTPUT2="- **Location**: R/other_file.R:10\n- **Problem**: different thing"
  MATCH2=$(/usr/bin/python3 -c "
import sys
output = sys.argv[1]
loc = sys.argv[2]
print('yes' if loc in output else 'no')
" "$OUTPUT2" "$LOC")
  if [ "$MATCH2" = "no" ]; then
    _check "location-match-absent" "pass"
  else
    _check "location-match-absent" "fail: got '$MATCH2'"
  fi

  # Test 4: verdict JSON structure — python can produce valid JSON
  JSON=$(/usr/bin/python3 -c "
import json
d = {
    'commit_sha': 'abc1234',
    'review_job_id': 5437,
    'review_verdict_bool': 1,
    'verdicts': {
        '675': {'status': 'verified-pass', 'reason': 'review approved and location not re-flagged'}
    },
    'timestamp': '2026-05-30T17:00:00Z'
}
print(json.dumps(d))
")
  STATUS=$(/usr/bin/python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d['verdicts']['675']['status'])" "$JSON")
  if [ "$STATUS" = "verified-pass" ]; then
    _check "verdict-json-structure" "pass"
  else
    _check "verdict-json-structure" "fail: got '$STATUS'"
  fi

  # Test 5: inconclusive when review_verdict_bool is null/None
  STATUS2=$(/usr/bin/python3 -c "
verdict_bool = None
status = 'inconclusive' if verdict_bool is None else ('verified-pass' if verdict_bool == 1 else 'verified-fail')
print(status)
")
  if [ "$STATUS2" = "inconclusive" ]; then
    _check "null-verdict-inconclusive" "pass"
  else
    _check "null-verdict-inconclusive" "fail: got '$STATUS2'"
  fi

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

# ── Argument validation ───────────────────────────────────────────────────────

if [ $# -lt 2 ]; then
  echo "Usage: $0 <commit_sha> <finding_id> [<finding_id>...]" >&2
  echo "  commit_sha: full or abbreviated git commit SHA" >&2
  echo "  finding_id: one or more roborev finding IDs (integers)" >&2
  exit 1
fi

COMMIT_SHA="$1"
shift
FINDING_IDS=("$@")

# Validate finding IDs are integers
for fid in "${FINDING_IDS[@]}"; do
  if ! printf '%s' "$fid" | grep -qE '^[0-9]+$'; then
    echo "ERROR: finding_id must be an integer, got: $fid" >&2
    exit 1
  fi
done

# ── Ensure output directory exists ───────────────────────────────────────────

mkdir -p "$VERDICT_DIR"
mkdir -p "$(dirname "$LOGFILE")"

VERDICT_FILE="${VERDICT_DIR}/${COMMIT_SHA}.json"

log "START: commit=${COMMIT_SHA} finding_ids=$(printf '%s ' "${FINDING_IDS[@]}")"

# ── Fail-open: prerequisites ──────────────────────────────────────────────────

_write_inconclusive() {
  local reason="$1"
  /usr/bin/python3 - "$COMMIT_SHA" "$reason" "${FINDING_IDS[@]}" <<'PY'
import sys, json
from datetime import datetime, timezone

commit_sha  = sys.argv[1]
reason      = sys.argv[2]
finding_ids = sys.argv[3:]

ts = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
verdicts = {}
for fid in finding_ids:
    verdicts[fid] = {"status": "inconclusive", "reason": reason}

out = {
    "commit_sha":          commit_sha,
    "review_job_id":       None,
    "review_verdict_bool": None,
    "verdicts":            verdicts,
    "timestamp":           ts
}
print(json.dumps(out, indent=2))
PY
}

if [ ! -x "$ROBOREV_BIN" ]; then
  log "SKIP: roborev binary not found at ${ROBOREV_BIN}"
  _write_inconclusive "roborev binary not available" > "$VERDICT_FILE"
  echo "roborev_verify_closure: roborev not found — verdict=inconclusive written to ${VERDICT_FILE}" >&2
  exit 0
fi

if [ ! -f "$ROBOREV_DB" ]; then
  log "SKIP: reviews.db not found at ${ROBOREV_DB}"
  _write_inconclusive "reviews.db not found" > "$VERDICT_FILE"
  echo "roborev_verify_closure: reviews.db not found — verdict=inconclusive written to ${VERDICT_FILE}" >&2
  exit 0
fi

# ── Look up each finding's location from DB (for re-flag detection) ───────────
#
# The original review output is stored in reviews.output.  We extract the
# "Location:" line(s) for each finding so we can compare against the new
# review output to detect whether the finding was actually fixed.

FINDING_LOCATIONS=$(/usr/bin/python3 - "$ROBOREV_DB" "${FINDING_IDS[@]}" <<'PY'
import sys, sqlite3, re, json

db_path     = sys.argv[1]
finding_ids = [int(x) for x in sys.argv[2:]]

try:
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=5.0)
    result = {}
    for fid in finding_ids:
        row = conn.execute(
            "SELECT output FROM reviews WHERE id = ?", (fid,)
        ).fetchone()
        if row is None:
            result[str(fid)] = None
        else:
            output = row[0] or ''
            # Extract all Location: lines from the finding output
            locs = re.findall(r'\*\*Location\*\*:\s*`?([^`\n]+)`?', output)
            result[str(fid)] = locs if locs else None
    conn.close()
    print(json.dumps(result))
except Exception as e:
    # On any DB error, return null for all IDs — verifier treats as inconclusive
    result = {str(fid): None for fid in finding_ids}
    print(json.dumps(result))
PY
)

log "INFO: finding_locations=${FINDING_LOCATIONS}"

# ── Trigger roborev re-review on the commit ───────────────────────────────────
#
# roborev review --sha <sha> --wait enqueues, waits for completion, and outputs
# "Enqueued job NNN for <sha> ..." as its first line.  The --wait flag means
# we don't need a separate poll loop for job completion.

log "INFO: triggering re-review for commit=${COMMIT_SHA}"

REVIEW_OUTPUT=""
REVIEW_EXIT=0

if ! REVIEW_OUTPUT=$("$ROBOREV_BIN" review --sha "$COMMIT_SHA" --wait 2>&1); then
  REVIEW_EXIT=$?
  log "WARN: roborev review exited ${REVIEW_EXIT} for commit=${COMMIT_SHA}: ${REVIEW_OUTPUT}"
fi

# Parse job ID from "Enqueued job NNN" line
REVIEW_JOB_ID=$(printf '%s\n' "$REVIEW_OUTPUT" | /usr/bin/python3 -c "
import sys, re
for line in sys.stdin:
    m = re.search(r'Enqueued job\s+(\d+)', line)
    if m:
        print(m.group(1))
        break
")

if [ -z "$REVIEW_JOB_ID" ]; then
  log "WARN: could not parse job_id from roborev output for commit=${COMMIT_SHA}"
  # Fallback: find the most recent review_job for this git_ref in the DB
  REVIEW_JOB_ID=$(/usr/bin/python3 - "$ROBOREV_DB" "$COMMIT_SHA" <<'PY'
import sys, sqlite3

db_path = sys.argv[1]
sha     = sys.argv[2]

try:
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=5.0)
    row = conn.execute(
        """SELECT rj.id FROM review_jobs rj
           WHERE rj.git_ref LIKE ?
           ORDER BY rj.id DESC LIMIT 1""",
        (f"{sha}%",)
    ).fetchone()
    conn.close()
    if row:
        print(row[0])
except Exception:
    pass
PY
  )
fi

if [ -z "$REVIEW_JOB_ID" ]; then
  log "WARN: no job_id found for commit=${COMMIT_SHA}; writing inconclusive"
  _write_inconclusive "could not determine re-review job_id" > "$VERDICT_FILE"
  exit 0
fi

log "INFO: review_job_id=${REVIEW_JOB_ID} for commit=${COMMIT_SHA}"

# ── Read verdict from DB (--wait should have completed it, but poll as safety) ─
#
# We write the review output to a temp file to avoid bash $() stripping content
# (null bytes or trailing newlines from multi-line review text).

_POLL_TMPFILE=$(mktemp)
trap 'rm -f "$_POLL_TMPFILE"' EXIT

ELAPSED=0
VERDICT_BOOL=""
REVIEW_STATUS=""

while [ "$ELAPSED" -lt "$POLL_TIMEOUT_SECS" ]; do
  REVIEW_STATUS=$(/usr/bin/python3 - "$ROBOREV_DB" "$REVIEW_JOB_ID" "$_POLL_TMPFILE" <<'PY'
import sys, sqlite3, json

db_path   = sys.argv[1]
job_id    = int(sys.argv[2])
tmpfile   = sys.argv[3]

try:
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=5.0)
    row = conn.execute(
        """SELECT rj.status, rv.verdict_bool, rv.output
           FROM review_jobs rj
           LEFT JOIN reviews rv ON rv.job_id = rj.id
           WHERE rj.id = ?
           LIMIT 1""",
        (job_id,)
    ).fetchone()
    conn.close()
    if row:
        status  = row[0] or 'unknown'
        verdict = '' if row[1] is None else str(row[1])
        output  = row[2] or ''
        # Write a JSON payload to tmpfile so multi-line output survives
        with open(tmpfile, 'w') as f:
            json.dump({"verdict": verdict, "output": output}, f)
        print(status)
    else:
        print("notfound")
except Exception as e:
    print(f"error")
PY
  )

  case "$REVIEW_STATUS" in
    done|applied)
      # Read verdict and output from tmpfile
      VERDICT_BOOL=$(/usr/bin/python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print(d['verdict'])
" "$_POLL_TMPFILE" 2>/dev/null || true)
      break ;;
    failed|canceled|skipped)
      log "WARN: job_id=${REVIEW_JOB_ID} ended with status=${REVIEW_STATUS}"
      _write_inconclusive "re-review job ended with status=${REVIEW_STATUS}" > "$VERDICT_FILE"
      exit 0 ;;
    running|queued)
      : ;;   # still in flight — keep polling
    notfound)
      log "WARN: job_id=${REVIEW_JOB_ID} not found in DB"
      _write_inconclusive "review_job ${REVIEW_JOB_ID} not found in DB" > "$VERDICT_FILE"
      exit 0 ;;
    *)
      log "WARN: unexpected job status '${REVIEW_STATUS}' for job_id=${REVIEW_JOB_ID}"
      ;;
  esac

  /usr/bin/python3 -c "import time; time.sleep(${POLL_INTERVAL_SECS})"
  ELAPSED=$((ELAPSED + POLL_INTERVAL_SECS))
done

if [ "$REVIEW_STATUS" != "done" ] && [ "$REVIEW_STATUS" != "applied" ]; then
  log "WARN: poll timed out (${POLL_TIMEOUT_SECS}s) for job_id=${REVIEW_JOB_ID}"
  _write_inconclusive "poll timed out after ${POLL_TIMEOUT_SECS}s" > "$VERDICT_FILE"
  exit 0
fi

log "INFO: re-review complete job_id=${REVIEW_JOB_ID} verdict_bool=${VERDICT_BOOL}"

# ── Classify each finding ─────────────────────────────────────────────────────
#
# Rules (from #353 spec):
#   verified-pass:  verdict_bool=1 AND the finding's Location is NOT re-flagged
#                   in the new review output.
#   verified-fail:  the finding's Location IS re-flagged in the new review output
#                   (regardless of overall verdict_bool).
#   inconclusive:   verdict_bool is null/empty, OR the finding was not in DB,
#                   OR the location could not be matched.

/usr/bin/python3 - "$COMMIT_SHA" "$REVIEW_JOB_ID" "$VERDICT_BOOL" \
    "$FINDING_LOCATIONS" "$_POLL_TMPFILE" "$VERDICT_FILE" "${FINDING_IDS[@]}" <<'PY'
import sys, json
from datetime import datetime, timezone

commit_sha       = sys.argv[1]
review_job_id    = int(sys.argv[2]) if sys.argv[2] else None
verdict_bool_raw = sys.argv[3]   # "1", "0", or ""
locs_json        = sys.argv[4]
poll_tmpfile     = sys.argv[5]
verdict_file     = sys.argv[6]
finding_ids      = sys.argv[7:]

# Read new review output from tmpfile (avoids bash $() stripping multi-line content)
try:
    poll_data = json.load(open(poll_tmpfile))
    new_output = poll_data.get("output", "")
except Exception:
    new_output = ""

# Parse overall verdict
if verdict_bool_raw == "1":
    overall_approved = True
elif verdict_bool_raw == "0":
    overall_approved = False
else:
    overall_approved = None  # inconclusive

# Parse per-finding locations from DB lookup
try:
    locs_by_id = json.loads(locs_json)
except Exception:
    locs_by_id = {}

verdicts = {}
for fid in finding_ids:
    locs = locs_by_id.get(fid)   # list of location strings, or None

    if overall_approved is None:
        verdicts[fid] = {
            "status": "inconclusive",
            "reason": "re-review verdict_bool is null — no clear approval or rejection"
        }
        continue

    if locs is None:
        # Finding not found in DB — can't match location, call inconclusive
        verdicts[fid] = {
            "status": "inconclusive",
            "reason": f"finding #{fid} not found in reviews DB; location unknown"
        }
        continue

    # Check whether any of the finding's locations are re-flagged in the new output
    reflagged_locs = [loc for loc in locs if loc and loc in new_output]

    if reflagged_locs:
        verdicts[fid] = {
            "status": "verified-fail",
            "reason": f"location(s) {reflagged_locs!r} re-flagged in re-review output"
        }
    elif overall_approved:
        verdicts[fid] = {
            "status": "verified-pass",
            "reason": "re-review approved and finding location not re-flagged"
        }
    else:
        # Overall rejected, location not directly re-flagged — could be a
        # different finding caused the rejection.  Classify as inconclusive
        # rather than pass, since we can't confirm the specific fix landed.
        verdicts[fid] = {
            "status": "inconclusive",
            "reason": "re-review rejected overall but this finding's location was not directly re-flagged"
        }

ts = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

result = {
    "commit_sha":          commit_sha,
    "review_job_id":       review_job_id,
    "review_verdict_bool": None if overall_approved is None else (1 if overall_approved else 0),
    "verdicts":            verdicts,
    "timestamp":           ts
}

with open(verdict_file, 'w') as f:
    json.dump(result, f, indent=2)
    f.write('\n')

print(f"verdict JSON written to {verdict_file}")
PY

log "DONE: verdict written to ${VERDICT_FILE}"
echo "roborev_verify_closure: verdict written to ${VERDICT_FILE}"
