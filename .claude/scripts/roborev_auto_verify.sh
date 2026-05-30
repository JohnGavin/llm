#!/usr/bin/env bash
# roborev_auto_verify.sh — post-commit auto-verifier (Component 4, JohnGavin/llm#163 Slice 3)
#
# Installed as a post-commit hook via roborev_install_auto_verify_hook.sh.
# NOT auto-installed; operator runs the installer manually.
#
# When a commit message contains "closes/fixes roborev #N" citations, this
# script:
#   1. Parses cited finding IDs from the commit message.
#   2. Triggers a roborev re-review of the commit SHA.
#   3. Polls until the re-review job completes (or times out).
#   4. On approval  → writes to closures table + calls `roborev close <finding_id>`.
#   5. On rejection → writes to fix_rejected_queue for human triage.
#   6. No roborev citations in commit → exits 0 immediately.
#
# Flags:
#   --dry-run   (default) — print what would happen; no DB writes
#   --apply               — actually mutate the DB
#   --commit <SHA>        — override commit SHA (default: HEAD)
#   --repo <name>         — override repo name (default: detected from git remote)
#   --help
#
# Self-test:
#   SELFTEST=1 bash roborev_auto_verify.sh   (exits 0 on success)
#
# Fail-open: if roborev binary or DB is unavailable, exits 0 and logs a warning.
# This ensures the hook never blocks commits.
#
# Exit codes:
#   0 = success (including fail-open cases)
#   1 = internal error (unexpected failure; fail-open protects the commit)
#
# Log: ~/.claude/logs/roborev_auto_verify.log
# Issue: JohnGavin/llm#163

export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
# Wire codex_with_fallback.sh into roborev's codex calls (#365):
_SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
if [ -x "${_SCRIPT_DIR}/codex_shim/codex" ]; then
  export PATH="${_SCRIPT_DIR}/codex_shim:$PATH"
fi
unset _SCRIPT_DIR

set -euo pipefail

LOGFILE="${HOME}/.claude/logs/roborev_auto_verify.log"
ROBOREV_DB="${ROBOREV_DB:-${HOME}/.roborev/reviews.db}"
ROBOREV_BIN="${ROBOREV:-$(command -v roborev 2>/dev/null || echo /usr/local/bin/roborev)}"

# Maximum seconds to poll for a re-review job to complete
POLL_TIMEOUT_SECS=120
POLL_INTERVAL_SECS=5

log() {
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')
  echo "${ts} $*" >> "$LOGFILE"
}

# ── Self-test ──────────────────────────────────────────────────────────────────

if [ "${SELFTEST:-0}" = "1" ]; then
  PASS=0
  FAIL=0

  _check() {
    local label="$1"
    local result="$2"    # "pass" | "fail: <reason>"
    if [ "$result" = "pass" ]; then
      PASS=$((PASS+1))
      echo "  PASS [$label]"
    else
      FAIL=$((FAIL+1))
      echo "  FAIL [$label]: $result"
    fi
  }

  # ── Helper under test: parse_roborev_ids ──────────────────────────────────
  # Extracted here so self-test can call it directly without recursion.

  _parse_ids_from_msg() {
    local msg="$1"
    /usr/bin/python3 - "$msg" <<'PY'
import sys, re

msg = sys.argv[1]

# Patterns:
#   closes roborev #N[,#M...]
#   fixes roborev #N
#   fix roborev #N
#   close roborev #N
#   wontfix roborev #N [reason: ...]
# Handles: with or without space before #; comma or space separated IDs.
CITATION_RE = re.compile(
    r'\b(?:closes?|fixes?|wontfix)\s+roborev\s*#(\d+(?:(?:[\s,]+#?\d+))*)',
    re.IGNORECASE
)

ids = []
for m in CITATION_RE.finditer(msg):
    raw = m.group(1)
    nums = re.findall(r'\d+', raw)
    ids.extend(nums)

# Deduplicate preserving order
seen = set()
unique = []
for x in ids:
    if x not in seen:
        seen.add(x)
        unique.append(x)

print('\n'.join(unique))
PY
  }

  # Case 1: standard "closes roborev #N"
  IDS=$(_parse_ids_from_msg "fix(security): redact token (closes roborev #675)")
  if [ "$IDS" = "675" ]; then
    _check "single-closes" "pass"
  else
    _check "single-closes" "fail: got '$IDS'"
  fi

  # Case 2: multi-ID comma separated
  IDS=$(_parse_ids_from_msg "fix(targets): saveRDS() (closes roborev #1551,#1545,#1536)")
  EXPECTED=$'1551\n1545\n1536'
  if [ "$IDS" = "$EXPECTED" ]; then
    _check "multi-comma" "pass"
  else
    _check "multi-comma" "fail: got '$IDS'"
  fi

  # Case 3: "fixes roborev #N" (alternate verb)
  IDS=$(_parse_ids_from_msg "fix(R): handle NA (fixes roborev #42)")
  if [ "$IDS" = "42" ]; then
    _check "fixes-verb" "pass"
  else
    _check "fixes-verb" "fail: got '$IDS'"
  fi

  # Case 4: "wontfix roborev #N [reason: deprecated]"
  IDS=$(_parse_ids_from_msg "chore(triage): wontfix [reason: deprecated] (wontfix roborev #99)")
  if [ "$IDS" = "99" ]; then
    _check "wontfix-verb" "pass"
  else
    _check "wontfix-verb" "fail: got '$IDS'"
  fi

  # Case 5: no citation → empty output
  IDS=$(_parse_ids_from_msg "docs: routine update to README")
  if [ -z "$IDS" ]; then
    _check "no-citation-empty" "pass"
  else
    _check "no-citation-empty" "fail: got '$IDS'"
  fi

  # Case 6: roborev#N (no space before #)
  IDS=$(_parse_ids_from_msg "fix: thing (closes roborev#123)")
  if [ "$IDS" = "123" ]; then
    _check "no-space-before-hash" "pass"
  else
    _check "no-space-before-hash" "fail: got '$IDS'"
  fi

  # Case 7: case-insensitive verb
  IDS=$(_parse_ids_from_msg "fix: thing (CLOSES ROBOREV #77)")
  if [ "$IDS" = "77" ]; then
    _check "case-insensitive" "pass"
  else
    _check "case-insensitive" "fail: got '$IDS'"
  fi

  # Case 8: space-separated IDs (no comma)
  IDS=$(_parse_ids_from_msg "fix(batch): address queue (closes roborev #10 #11 #12)")
  EXPECTED=$'10\n11\n12'
  if [ "$IDS" = "$EXPECTED" ]; then
    _check "space-separated-ids" "pass"
  else
    _check "space-separated-ids" "fail: got '$IDS'"
  fi

  # Case 9: deduplicate repeated ID
  IDS=$(_parse_ids_from_msg "fix: thing (closes roborev #55,#55)")
  if [ "$IDS" = "55" ]; then
    _check "dedup" "pass"
  else
    _check "dedup" "fail: got '$IDS'"
  fi

  # Case 10: mixed: closes + Refs (Refs should NOT be captured)
  IDS=$(_parse_ids_from_msg "fix: thing (closes roborev #10) Refs #200")
  if [ "$IDS" = "10" ]; then
    _check "refs-ignored" "pass"
  else
    _check "refs-ignored" "fail: got '$IDS'"
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

# ── Usage ──────────────────────────────────────────────────────────────────────

usage() {
  grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \{0,1\}//' | head -40
}

# ── Argument parsing ───────────────────────────────────────────────────────────

MODE="dry-run"
COMMIT_SHA=""
REPO_NAME=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)  MODE="dry-run"; shift ;;
    --apply)    MODE="apply";   shift ;;
    --commit)
      shift
      [ $# -gt 0 ] || { echo "ERROR: --commit requires an argument" >&2; exit 1; }
      COMMIT_SHA="$1"; shift ;;
    --repo)
      shift
      [ $# -gt 0 ] || { echo "ERROR: --repo requires an argument" >&2; exit 1; }
      REPO_NAME="$1"; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "ERROR: unknown argument '$1'" >&2; exit 1 ;;
  esac
done

# ── Fail-open prerequisites ────────────────────────────────────────────────────

# roborev binary required
if [ ! -x "$ROBOREV_BIN" ]; then
  log "SKIP: roborev binary not found at ${ROBOREV_BIN}"
  echo "roborev_auto_verify: roborev binary not found — skipping (fail-open)" >&2
  exit 0
fi

# DB required
if [ ! -f "$ROBOREV_DB" ]; then
  log "SKIP: reviews.db not found at ${ROBOREV_DB}"
  echo "roborev_auto_verify: reviews.db not found — skipping (fail-open)" >&2
  exit 0
fi

# closures table required (migration v2 must have been applied)
TABLE_CHECK=$(/usr/bin/python3 - "$ROBOREV_DB" <<'PY'
import sqlite3, sys
db = sys.argv[1]
try:
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=2.0)
    rows = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('closures','fix_rejected_queue')"
    ).fetchall()
    conn.close()
    names = {r[0] for r in rows}
    if 'closures' in names and 'fix_rejected_queue' in names:
        print("ok")
    else:
        missing = {'closures','fix_rejected_queue'} - names
        print(f"missing:{','.join(missing)}")
except Exception as e:
    print(f"error:{e}")
PY
)

if [ "$TABLE_CHECK" != "ok" ]; then
  log "SKIP: migration_v2 not applied (${TABLE_CHECK})"
  echo "roborev_auto_verify: DB migration v2 not applied (${TABLE_CHECK}) — run roborev_schema_migration_v2.sql first" >&2
  echo "  sqlite3 ~/.roborev/reviews.db < ~/.claude/scripts/roborev_schema_migration_v2.sql" >&2
  exit 0
fi

# ── Resolve commit SHA and message ────────────────────────────────────────────

if [ -z "$COMMIT_SHA" ]; then
  # When invoked as a post-commit hook, HEAD is the commit just made.
  COMMIT_SHA=$(git rev-parse HEAD 2>/dev/null || true)
  if [ -z "$COMMIT_SHA" ]; then
    log "SKIP: could not resolve HEAD SHA"
    echo "roborev_auto_verify: could not resolve HEAD SHA — skipping (fail-open)" >&2
    exit 0
  fi
fi

COMMIT_MSG=$(git log -1 --format=%B "$COMMIT_SHA" 2>/dev/null || true)
if [ -z "$COMMIT_MSG" ]; then
  log "SKIP: empty or unresolvable commit message for SHA=${COMMIT_SHA}"
  exit 0
fi

# ── Parse cited finding IDs from commit message ───────────────────────────────

CITED_IDS=$(/usr/bin/python3 - "$COMMIT_MSG" <<'PY'
import sys, re

msg = sys.argv[1]

CITATION_RE = re.compile(
    r'\b(?:closes?|fixes?|wontfix)\s+roborev\s*#(\d+(?:(?:[\s,]+#?\d+))*)',
    re.IGNORECASE
)

ids = []
for m in CITATION_RE.finditer(msg):
    raw = m.group(1)
    nums = re.findall(r'\d+', raw)
    ids.extend(nums)

seen = set()
unique = []
for x in ids:
    if x not in seen:
        seen.add(x)
        unique.append(x)

print('\n'.join(unique))
PY
)

# No citations → nothing to do
if [ -z "$CITED_IDS" ]; then
  log "PASS: no roborev citations in ${COMMIT_SHA}"
  exit 0
fi

N_IDS=$(printf '%s\n' "$CITED_IDS" | grep -c .)
log "INFO: ${COMMIT_SHA} cites ${N_IDS} finding(s): $(printf '%s' "$CITED_IDS" | tr '\n' ',')"

# ── Detect wontfix pattern (skip re-review) ───────────────────────────────────

IS_WONTFIX=0
if echo "$COMMIT_MSG" | grep -qiE '\bwontfix\s+roborev\s*#'; then
  IS_WONTFIX=1
fi

# ── Extract wontfix reason if present ─────────────────────────────────────────

WONTFIX_REASON=""
if [ "$IS_WONTFIX" -eq 1 ]; then
  WONTFIX_REASON=$(/usr/bin/python3 - "$COMMIT_MSG" <<'PY'
import sys, re
msg = sys.argv[1]
m = re.search(r'\[reason:\s*([^\]]+)\]', msg, re.IGNORECASE)
if m:
    print(m.group(1).strip())
PY
)
fi

# ── Dry-run report (always printed even in --apply) ───────────────────────────

echo "roborev_auto_verify: commit=${COMMIT_SHA}"
echo "  mode     : ${MODE}"
echo "  wontfix  : ${IS_WONTFIX}"
echo "  finding_ids: $(printf '%s' "$CITED_IDS" | tr '\n' ' ')"
[ "$IS_WONTFIX" -eq 1 ] && [ -n "$WONTFIX_REASON" ] && echo "  reason   : ${WONTFIX_REASON}"

if [ "$MODE" = "dry-run" ]; then
  if [ "$IS_WONTFIX" -eq 1 ]; then
    echo "  [dry-run] would write closures rows (type=wontfix) for: $(printf '%s' "$CITED_IDS" | tr '\n' ' ')"
  else
    echo "  [dry-run] would trigger re-review of ${COMMIT_SHA} then close approved IDs"
    echo "  [dry-run] any rejected IDs would go to fix_rejected_queue"
  fi
  echo "  pass --apply to execute"
  exit 0
fi

# ── APPLY MODE ────────────────────────────────────────────────────────────────

# Validate each cited ID exists and is open in DB
VALIDATION_ERRORS=$(/usr/bin/python3 - "$ROBOREV_DB" "$CITED_IDS" <<'PY'
import sys, sqlite3

db_path = sys.argv[1]
ids_raw = sys.argv[2]
ids = [i.strip() for i in ids_raw.splitlines() if i.strip()]

try:
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=2.0)
    cur = conn.cursor()
except Exception as e:
    print(f"DBERR:{e}")
    sys.exit(0)  # fail-open on DB error

errors = []
for id_str in ids:
    cur.execute("SELECT closed FROM reviews WHERE id = ?", (int(id_str),))
    row = cur.fetchone()
    if row is None:
        errors.append(f"NOTFOUND:{id_str}")
    elif row[0] == 1:
        errors.append(f"ALREADYCLOSED:{id_str}")
conn.close()

for e in errors:
    print(e)
PY
)

if echo "$VALIDATION_ERRORS" | grep -qE '^(NOTFOUND|ALREADYCLOSED|DBERR):'; then
  log "WARN: validation errors for ${COMMIT_SHA}: $(printf '%s' "$VALIDATION_ERRORS" | tr '\n' '|')"
  echo "roborev_auto_verify: validation errors — skipping (fail-open):" >&2
  printf '%s\n' "$VALIDATION_ERRORS" >&2
  exit 0
fi

# ── wontfix path: write closures rows, no re-review needed ────────────────────

if [ "$IS_WONTFIX" -eq 1 ]; then
  WRITE_RESULT=$(/usr/bin/python3 - "$ROBOREV_DB" "$CITED_IDS" "$COMMIT_SHA" "$WONTFIX_REASON" <<'PY'
import sys, sqlite3

db_path   = sys.argv[1]
ids_raw   = sys.argv[2]
commit_sha= sys.argv[3]
reason    = sys.argv[4] if len(sys.argv) > 4 else ''

ids = [int(i.strip()) for i in ids_raw.splitlines() if i.strip()]

try:
    conn = sqlite3.connect(db_path, timeout=5.0)
except Exception as e:
    print(f"DBERR:{e}")
    sys.exit(1)

try:
    cur = conn.cursor()
    for fid in ids:
        cur.execute(
            """INSERT INTO closures
               (finding_id, closure_commit_sha, closure_review_job_id, closure_type, closure_reason)
               VALUES (?, ?, NULL, 'wontfix', ?)""",
            (fid, commit_sha, reason or None)
        )
    conn.commit()
    print(f"ok:{len(ids)}")
except Exception as e:
    conn.rollback()
    print(f"ERR:{e}")
    sys.exit(1)
finally:
    conn.close()
PY
  )

  if echo "$WRITE_RESULT" | grep -q '^ok:'; then
    N_WRITTEN=$(echo "$WRITE_RESULT" | grep -oE '[0-9]+')
    log "WONTFIX: wrote ${N_WRITTEN} closures rows for commit=${COMMIT_SHA}"
    echo "roborev_auto_verify: wontfix — wrote ${N_WRITTEN} closures rows"
  else
    log "ERR: wontfix DB write failed: ${WRITE_RESULT}"
    echo "roborev_auto_verify: DB write error — skipping (fail-open)" >&2
  fi

  # Close the findings in roborev itself
  while IFS= read -r fid; do
    [ -z "$fid" ] && continue
    if "$ROBOREV_BIN" close "$fid" >/dev/null 2>&1; then
      log "CLOSED finding_id=${fid} type=wontfix commit=${COMMIT_SHA}"
      echo "  closed finding #${fid} (wontfix)"
    else
      log "CLOSE_FAIL finding_id=${fid} commit=${COMMIT_SHA}"
      echo "  WARN: could not close finding #${fid} via roborev" >&2
    fi
  done <<< "$CITED_IDS"

  exit 0
fi

# ── Approved-fix path: trigger re-review, poll, then close or queue ───────────

# Resolve repo name if not provided
if [ -z "$REPO_NAME" ]; then
  REPO_NAME=$(/usr/bin/python3 - "$ROBOREV_DB" "$COMMIT_SHA" <<'PY'
import sys, sqlite3

db_path   = sys.argv[1]
sha       = sys.argv[2]

try:
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=2.0)
    row = conn.execute(
        """SELECT rp.name FROM commits c
           JOIN repos rp ON rp.id = c.repo_id
           WHERE c.sha = ? LIMIT 1""",
        (sha,)
    ).fetchone()
    conn.close()
    if row:
        print(row[0])
except Exception:
    pass
PY
  )
fi

if [ -z "$REPO_NAME" ]; then
  log "WARN: could not resolve repo name for ${COMMIT_SHA}"
  echo "roborev_auto_verify: could not resolve repo name — use --repo to specify" >&2
  exit 0
fi

log "INFO: triggering re-review for commit=${COMMIT_SHA} repo=${REPO_NAME}"
echo "  triggering re-review for ${COMMIT_SHA} (repo: ${REPO_NAME})"

# Trigger roborev re-review
REVIEW_JOB_ID=""
if ! REVIEW_OUTPUT=$("$ROBOREV_BIN" review --commit "$COMMIT_SHA" 2>&1); then
  log "WARN: roborev review command failed for ${COMMIT_SHA}: ${REVIEW_OUTPUT}"
  echo "roborev_auto_verify: re-review trigger failed — skipping (fail-open)" >&2
  exit 0
fi

# Extract job ID from roborev output (assumes "job_id: NNN" or "job NNN" pattern)
REVIEW_JOB_ID=$(echo "$REVIEW_OUTPUT" | /usr/bin/python3 - <<'PY'
import sys, re
output = sys.stdin.read()
# Try multiple patterns roborev might use
for pat in [r'job[_\s]id[:\s]+(\d+)', r'job\s+(\d+)', r'id[:\s]+(\d+)']:
    m = re.search(pat, output, re.IGNORECASE)
    if m:
        print(m.group(1))
        break
PY
)

if [ -z "$REVIEW_JOB_ID" ]; then
  log "WARN: could not parse job_id from roborev output for ${COMMIT_SHA}"
  echo "roborev_auto_verify: could not parse re-review job_id — will check DB for latest job" >&2
  # Fallback: find the most recent review_job for this commit in the DB
  REVIEW_JOB_ID=$(/usr/bin/python3 - "$ROBOREV_DB" "$COMMIT_SHA" <<'PY'
import sys, sqlite3

db_path = sys.argv[1]
sha     = sys.argv[2]

try:
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=2.0)
    row = conn.execute(
        """SELECT rj.id FROM review_jobs rj
           JOIN commits c ON c.id = rj.commit_id
           WHERE c.sha = ?
           ORDER BY rj.id DESC LIMIT 1""",
        (sha,)
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
  log "WARN: no job_id found for ${COMMIT_SHA}; cannot poll for verdict"
  echo "roborev_auto_verify: no re-review job found for ${COMMIT_SHA} — skipping (fail-open)" >&2
  exit 0
fi

echo "  re-review job_id=${REVIEW_JOB_ID}; polling (max ${POLL_TIMEOUT_SECS}s)"
log "INFO: polling job_id=${REVIEW_JOB_ID} for commit=${COMMIT_SHA}"

# Poll until done/failed/canceled or timeout
ELAPSED=0
VERDICT=""
while [ "$ELAPSED" -lt "$POLL_TIMEOUT_SECS" ]; do
  JOB_STATUS=$(/usr/bin/python3 - "$ROBOREV_DB" "$REVIEW_JOB_ID" <<'PY'
import sys, sqlite3

db_path = sys.argv[1]
job_id  = int(sys.argv[2])

try:
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=2.0)
    row = conn.execute(
        """SELECT rj.status, rv.verdict_bool, rv.output
           FROM review_jobs rj
           LEFT JOIN reviews rv ON rv.job_id = rj.id
           WHERE rj.id = ? LIMIT 1""",
        (job_id,)
    ).fetchone()
    conn.close()
    if row:
        status  = row[0] or 'unknown'
        verdict = row[1]
        output  = (row[2] or '')[:500].replace('\n', ' ')
        print(f"{status}\t{verdict}\t{output}")
    else:
        print("notfound\t\t")
except Exception as e:
    print(f"error\t\t{e}")
PY
  )

  JOB_STATUS_VAL=$(printf '%s' "$JOB_STATUS" | cut -f1)
  VERDICT_BOOL=$(printf '%s' "$JOB_STATUS" | cut -f2)
  JOB_OUTPUT=$(printf '%s' "$JOB_STATUS" | cut -f3-)

  case "$JOB_STATUS_VAL" in
    done|applied)
      VERDICT="$VERDICT_BOOL"
      break ;;
    failed|canceled|skipped)
      log "WARN: job_id=${REVIEW_JOB_ID} ended with status=${JOB_STATUS_VAL}"
      echo "roborev_auto_verify: re-review job ${JOB_STATUS_VAL} — no verdict (fail-open)" >&2
      exit 0 ;;
    running|queued)
      : ;;  # still in progress — keep polling
    *)
      log "WARN: unexpected job status '${JOB_STATUS_VAL}' for job_id=${REVIEW_JOB_ID}"
      ;;
  esac

  /usr/bin/python3 -c "import time; time.sleep(${POLL_INTERVAL_SECS})"
  ELAPSED=$((ELAPSED + POLL_INTERVAL_SECS))
done

if [ -z "$VERDICT" ]; then
  log "WARN: poll timed out after ${POLL_TIMEOUT_SECS}s for job_id=${REVIEW_JOB_ID}"
  echo "roborev_auto_verify: poll timed out — no verdict (fail-open)" >&2
  exit 0
fi

log "INFO: job_id=${REVIEW_JOB_ID} verdict_bool=${VERDICT}"

# ── Verdict: approved (1) → close findings ────────────────────────────────────

if [ "$VERDICT" = "1" ]; then
  echo "  verdict: APPROVED — closing ${N_IDS} finding(s)"
  log "APPROVED: job=${REVIEW_JOB_ID} commit=${COMMIT_SHA} closing $(printf '%s' "$CITED_IDS" | tr '\n' ',')"

  /usr/bin/python3 - "$ROBOREV_DB" "$CITED_IDS" "$COMMIT_SHA" "$REVIEW_JOB_ID" <<'PY'
import sys, sqlite3

db_path   = sys.argv[1]
ids_raw   = sys.argv[2]
commit_sha= sys.argv[3]
job_id    = int(sys.argv[4])

ids = [int(i.strip()) for i in ids_raw.splitlines() if i.strip()]

conn = sqlite3.connect(db_path, timeout=5.0)
try:
    cur = conn.cursor()
    for fid in ids:
        cur.execute(
            """INSERT OR IGNORE INTO closures
               (finding_id, closure_commit_sha, closure_review_job_id, closure_type)
               VALUES (?, ?, ?, 'approved')""",
            (fid, commit_sha, job_id)
        )
    conn.commit()
    print(f"ok: wrote {len(ids)} closures rows")
except Exception as e:
    conn.rollback()
    print(f"ERR: {e}", file=sys.stderr)
finally:
    conn.close()
PY

  while IFS= read -r fid; do
    [ -z "$fid" ] && continue
    if "$ROBOREV_BIN" close "$fid" >/dev/null 2>&1; then
      log "CLOSED finding_id=${fid} type=approved commit=${COMMIT_SHA}"
      echo "  closed finding #${fid}"
    else
      log "CLOSE_FAIL finding_id=${fid} commit=${COMMIT_SHA}"
      echo "  WARN: could not close finding #${fid} via roborev" >&2
    fi
  done <<< "$CITED_IDS"

  exit 0
fi

# ── Verdict: rejected (0) → write to fix_rejected_queue ───────────────────────

echo "  verdict: REJECTED — queuing ${N_IDS} finding(s) for human triage"
log "REJECTED: job=${REVIEW_JOB_ID} commit=${COMMIT_SHA} IDs=$(printf '%s' "$CITED_IDS" | tr '\n' ',')"

IDS_JSON=$(/usr/bin/python3 - "$CITED_IDS" <<'PY'
import sys, json
ids = [int(i.strip()) for i in sys.argv[1].splitlines() if i.strip()]
print(json.dumps(ids))
PY
)

/usr/bin/python3 - "$ROBOREV_DB" "$IDS_JSON" "$COMMIT_SHA" "$REVIEW_JOB_ID" "$JOB_OUTPUT" <<'PY'
import sys, sqlite3

db_path     = sys.argv[1]
ids_json    = sys.argv[2]
commit_sha  = sys.argv[3]
job_id      = int(sys.argv[4])
rejection_s = sys.argv[5][:500]

conn = sqlite3.connect(db_path, timeout=5.0)
try:
    conn.execute(
        """INSERT INTO fix_rejected_queue
           (finding_ids_json, fix_commit_sha, rejection_job_id, rejection_summary)
           VALUES (?, ?, ?, ?)""",
        (ids_json, commit_sha, job_id, rejection_s)
    )
    conn.commit()
    print(f"queued: {ids_json}")
except Exception as e:
    conn.rollback()
    print(f"ERR: {e}", file=sys.stderr)
finally:
    conn.close()
PY

echo "roborev_auto_verify: fix rejected — check fix_rejected_queue for human triage"
echo "  query: SELECT * FROM fix_rejected_queue WHERE resolved=0 ORDER BY attempted_at DESC LIMIT 10;"
exit 0
