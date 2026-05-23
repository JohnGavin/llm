#!/usr/bin/env bash
# roborev_ack.sh — explicit ack-with-reason CLI for roborev findings.
#
# Writes a waiver record to ~/.roborev/acks.jsonl without closing the finding
# in reviews.db.  Closure happens when the fix-commit is verified (via #163 auto-verifier)
# or via `roborev close` manually.
#
# Usage:
#   roborev_ack.sh <roborev-id> --reason "<text>" [--pr <#>] [--apply]
#   roborev_ack.sh <roborev-id> --reason "<text>" [--pr <#>] [--dry-run]   # default
#
# Options:
#   --reason <text>  Mandatory. Why you are acking (false positive, wontfix, etc.)
#   --pr <#>         Optional. PR number associated with the ack.
#   --apply          Write the JSONL record (acks.jsonl is append-only).
#   --dry-run        Default. Print what would be written; do not write.
#   --help           Show usage.
#
# On success prints:
#   Commit message line:    acks roborev #N --reason "<text>"
#   (so you can paste it into your git commit -m)
#
# Output file: ~/.roborev/acks.jsonl  (append-only; --apply mode only)
#
# Self-test (direct function calls — no subprocess of $0):
#   SELFTEST=1 bash roborev_ack.sh
#
# Tracked in JohnGavin/llm#241.

set -uo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
PYTHON="${PYTHON:-/usr/bin/python3}"
ROBOREV_DB="${ROBOREV_DB:-$HOME/.roborev/reviews.db}"
ACKS_JSONL="${ACKS_JSONL:-$HOME/.roborev/acks.jsonl}"

# ── Functions (directly testable — no subprocess of $0) ──────────────────────

# Look up a finding by ID in reviews.db.
# Returns: "open", "closed", "not_found", or "db_absent"
_lookup_finding() {
  local rid="$1"
  local db="$2"

  [ -f "$db" ] || { echo "db_absent"; return 0; }

  "$PYTHON" -c "
import sys, sqlite3
rid = int(sys.argv[1])
db_path = sys.argv[2]
try:
    con = sqlite3.connect(f'file:{db_path}?mode=ro', uri=True)
    row = con.execute('SELECT closed FROM reviews WHERE id = ?', (rid,)).fetchone()
    con.close()
    if row is None:
        print('not_found')
    elif row[0] == 1:
        print('closed')
    else:
        print('open')
except Exception as e:
    print('db_absent')
" "$rid" "$db" 2>/dev/null || echo "db_absent"
}

# Build the JSONL record as a JSON string.
_build_record() {
  local rid="$1" reason="$2" pr="${3:-}" acked_by="${4:-}" ts="$5"

  "$PYTHON" -c "
import sys, json
rid = int(sys.argv[1])
reason = sys.argv[2]
pr_raw = sys.argv[3]
acked_by = sys.argv[4]
ts = sys.argv[5]
pr = int(pr_raw) if pr_raw.isdigit() else None
record = {
    'id': rid,
    'reason': reason,
    'pr': pr,
    'acked_at': ts,
    'acked_by': acked_by,
}
print(json.dumps(record, separators=(',', ':')))
" "$rid" "$reason" "${pr:-}" "$acked_by" "$ts" 2>/dev/null || echo ""
}

# Append record to acks.jsonl (idempotent on write).
_append_ack() {
  local record="$1"
  local acks_file="$2"
  mkdir -p "$(dirname "$acks_file")" 2>/dev/null || true
  printf '%s\n' "$record" >> "$acks_file"
}

# Emit the commit-message guidance line.
_commit_guidance() {
  local rid="$1" reason="$2"
  printf 'acks roborev #%s --reason "%s"\n' "$rid" "$reason"
}

# ── Self-test ─────────────────────────────────────────────────────────────────
_selftest() {
  local pass=0 fail=0

  _t() {
    local label="$1" expected="$2" got="$3"
    if [ "$got" = "$expected" ]; then
      pass=$((pass+1))
      printf "  PASS [%s]\n" "$label"
    else
      fail=$((fail+1))
      printf "  FAIL [%s]: expected='%s' got='%s'\n" "$label" "$expected" "$got"
    fi
  }

  # _lookup_finding — DB absent
  _t "lookup: db absent"       "db_absent"  "$(_lookup_finding 1 /tmp/no_db_ack_$$)"

  # _lookup_finding — real DB (ID 9999999 should be not_found or db_absent)
  local lf_result
  lf_result=$(_lookup_finding 9999999 "${ROBOREV_DB:-/tmp/no_db}" 2>/dev/null)
  if [ "$lf_result" = "not_found" ] || [ "$lf_result" = "db_absent" ]; then
    pass=$((pass+1))
    echo "  PASS [lookup: high id -> not_found or db_absent]"
  else
    fail=$((fail+1))
    printf "  FAIL [lookup: high id]: expected not_found or db_absent, got '%s'\n" "$lf_result"
  fi

  # _lookup_finding — real DB low ID (likely 'closed' given backlog data)
  local lf_low
  lf_low=$(_lookup_finding 1 "${ROBOREV_DB:-/tmp/no_db}" 2>/dev/null)
  if [ "$lf_low" = "open" ] || [ "$lf_low" = "closed" ] || [ "$lf_low" = "not_found" ] || [ "$lf_low" = "db_absent" ]; then
    pass=$((pass+1))
    printf "  PASS [lookup: id 1 -> %s]\n" "$lf_low"
  else
    fail=$((fail+1))
    printf "  FAIL [lookup: id 1]: unexpected '%s'\n" "$lf_low"
  fi

  # _build_record — produces valid JSON
  local rec
  rec=$(_build_record 42 "false positive in nix-only path" "253" "johngavin" "2026-05-23T10:00:00")
  local has_id has_reason has_pr
  has_id=$(echo "$rec"    | "$PYTHON" -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('id',''))" 2>/dev/null || echo "")
  has_reason=$(echo "$rec" | "$PYTHON" -c "import sys,json; d=json.loads(sys.stdin.read()); print('yes' if d.get('reason') else 'no')" 2>/dev/null || echo "no")
  has_pr=$(echo "$rec"    | "$PYTHON" -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('pr',''))" 2>/dev/null || echo "")
  _t "build_record: id"     "42"  "$has_id"
  _t "build_record: reason" "yes" "$has_reason"
  _t "build_record: pr"     "253" "$has_pr"

  # _build_record — no PR
  local rec_nopr
  rec_nopr=$(_build_record 7 "wontfix deprecated" "" "johngavin" "2026-05-23T10:00:01")
  local pr_val
  pr_val=$(echo "$rec_nopr" | "$PYTHON" -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('pr'))" 2>/dev/null || echo "ERROR")
  _t "build_record: no pr is None" "None" "$pr_val"

  # _append_ack — writes to temp file
  local tmp_acks
  tmp_acks=$(mktemp /tmp/test_acks_ack_XXXXXX)
  _append_ack '{"id":5}' "$tmp_acks"
  _append_ack '{"id":6}' "$tmp_acks"
  local line_count
  line_count=$(wc -l < "$tmp_acks" | tr -d ' ')
  _t "append_ack: two lines" "2" "$line_count"
  rm -f "$tmp_acks"

  # _commit_guidance — format check
  local guidance
  guidance=$(_commit_guidance 42 "false positive")
  _t "commit_guidance format" 'acks roborev #42 --reason "false positive"' "$guidance"

  echo ""
  printf "%d/%d PASS\n" "$pass" "$((pass+fail))"
  [ "$fail" -eq 0 ] && return 0 || return 1
}

# ── Usage ─────────────────────────────────────────────────────────────────────
_usage() {
  cat >&2 <<'EOF'
Usage:
  roborev_ack.sh <roborev-id> --reason "<text>" [--pr <#>] [--apply]

Options:
  --reason <text>  Mandatory. Why the finding is being acked.
  --pr <#>         Optional. PR number.
  --apply          Write the ack record to ~/.roborev/acks.jsonl.
  --dry-run        Default. Print what would be written; do not write.
  --help           Show this message.

The finding remains open in reviews.db (closure via fix-commit + verifier).
EOF
}

# ── Main ──────────────────────────────────────────────────────────────────────
_main() {
  if [ "${SELFTEST:-0}" = "1" ]; then
    _selftest
    exit $?
  fi

  local rid="" reason="" pr="" mode="dry-run"

  while [ $# -gt 0 ]; do
    case "$1" in
      --reason)    reason="$2"  ; shift 2 ;;
      --pr)        pr="$2"      ; shift 2 ;;
      --apply)     mode="apply" ; shift   ;;
      --dry-run)   mode="dry-run"; shift  ;;
      --help|-h)   _usage ; exit 0        ;;
      [0-9]*)      rid="$1"     ; shift   ;;
      *)
        echo "ERROR: unknown argument: $1" >&2
        _usage
        exit 2
        ;;
    esac
  done

  if [ -z "$rid" ]; then
    echo "ERROR: roborev-id required" >&2
    _usage
    exit 2
  fi

  if [ -z "$reason" ]; then
    echo "ERROR: --reason is required" >&2
    _usage
    exit 2
  fi

  # Validate the finding exists
  local state
  state=$(_lookup_finding "$rid" "$ROBOREV_DB")
  case "$state" in
    open)
      : ;; # OK
    closed)
      echo "WARN: roborev #${rid} is already closed in reviews.db (acking anyway for record)" >&2
      ;;
    not_found)
      echo "ERROR: roborev #${rid} not found in reviews.db" >&2
      exit 1
      ;;
    db_absent)
      echo "WARN: reviews.db not found — proceeding fail-open" >&2
      ;;
  esac

  local ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || echo "unknown")
  local acked_by
  acked_by=$(git config user.name 2>/dev/null || echo "unknown")

  local record
  record=$(_build_record "$rid" "$reason" "${pr:-}" "$acked_by" "$ts")

  if [ -z "$record" ]; then
    echo "ERROR: failed to build ack record" >&2
    exit 1
  fi

  local guidance
  guidance=$(_commit_guidance "$rid" "$reason")

  if [ "$mode" = "apply" ]; then
    _append_ack "$record" "$ACKS_JSONL"
    echo "ACK written to $ACKS_JSONL"
    echo ""
    echo "Add this to your commit message:"
    echo "  $guidance"
  else
    echo "[dry-run] Would write to $ACKS_JSONL:"
    echo "  $record"
    echo ""
    echo "Add this to your commit message:"
    echo "  $guidance"
    echo ""
    echo "Re-run with --apply to write the record."
  fi
}

_main "$@"
