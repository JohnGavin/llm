#!/usr/bin/env bash
# roborev_citation_validate.sh — commit-msg hook validator.
#
# Reads $1 (commit message file path, as passed by git commit-msg hook).
# Parses roborev citation patterns and validates each cited ID against the DB.
#
# Citation patterns accepted (case-insensitive):
#   closes roborev #N
#   close  roborev #N
#   fixes  roborev #N
#   fix    roborev #N
#   wontfix roborev #N [reason: ...]
#   Also: roborev#N (no space before #)
#
# Exit codes:
#   0   OK — no citations, or all cited IDs are valid and open
#   1   Cited ID is already closed (or not found in DB)
#   2   Usage error / recursion guard triggered
#
# Fail-open: if DB unavailable, exits 0 (don't block offline commits).
#
# Self-test (direct function calls — NO subprocess of $0):
#   ROBOREV_CITE_SELFTEST=1 bash roborev_citation_validate.sh
#
# Tracked in JohnGavin/llm#163.

set -uo pipefail

# ── Depth guard (defense-in-depth — never fire under normal use) ──────────────
_DEPTH="${_ROBOREV_CITE_DEPTH:-0}"
if [ "$_DEPTH" -gt 2 ]; then
  echo "ERROR: roborev_citation_validate.sh: recursion depth $_DEPTH — aborting" >&2
  exit 2
fi
export _ROBOREV_CITE_DEPTH=$((_DEPTH + 1))

# ── Config ────────────────────────────────────────────────────────────────────
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
PYTHON="${PYTHON:-/usr/bin/python3}"
ROBOREV_DB="${ROBOREV_DB:-$HOME/.roborev/reviews.db}"

# ── Functions (testable directly — no subprocess of $0) ──────────────────────

# Extract roborev IDs from a commit message string.
# Echoes comma-separated list of integer IDs, or empty string if none found.
# Uses Python for the regex to avoid bash regex portability issues.
_extract_citations() {
  local msg="$1"
  "$PYTHON" -c "
import sys, re
msg = sys.argv[1]
pattern = re.compile(
    r'(?:close[sd]?|fix(?:es)?|wontfix)\s+roborev\s*#(\d+)',
    re.IGNORECASE
)
ids = pattern.findall(msg)
print(','.join(ids))
" "$msg" 2>/dev/null || echo ""
}

# Validate one integer ID against the DB.
# Returns:
#   0  ID exists and is open (closed=0), or DB is absent (fail-open)
#   1  ID exists but is already closed
#   2  ID does not exist in DB
_validate_id() {
  local rid="$1"
  local db="$2"

  # Fail-open when DB is absent
  [ -f "$db" ] || return 0

  "$PYTHON" -c "
import sys, sqlite3
rid = int(sys.argv[1])
db_path = sys.argv[2]
try:
    con = sqlite3.connect(f'file:{db_path}?mode=ro', uri=True)
    row = con.execute('SELECT closed FROM reviews WHERE id = ?', (rid,)).fetchone()
    con.close()
    if row is None:
        sys.exit(2)  # ID not found
    elif row[0] == 1:
        sys.exit(1)  # already closed
    else:
        sys.exit(0)  # open — valid citation
except Exception:
    sys.exit(0)  # DB error → fail-open
" "$rid" "$db" 2>/dev/null
}

# ── Main entry (used by commit-msg hook) ──────────────────────────────────────
_main() {
  local msg_file="${1:-}"

  if [ -z "$msg_file" ] || [ ! -f "$msg_file" ]; then
    echo "ERROR: commit message file required" >&2
    return 1
  fi

  local msg
  msg=$(cat "$msg_file")

  local ids
  ids=$(_extract_citations "$msg")

  # No roborev citations — nothing to validate
  [ -z "$ids" ] && return 0

  # Fail-open: Python missing
  if [ ! -x "$PYTHON" ]; then
    return 0
  fi

  local rc=0
  local rid
  local IFS=','
  for rid in $ids; do
    [ -z "$rid" ] && continue
    local v_rc=0
    _validate_id "$rid" "$ROBOREV_DB" || v_rc=$?
    case "$v_rc" in
      0) : ;;  # valid open citation
      1)
        echo "ERROR: roborev #$rid is already closed. Remove the citation or use a different ID." >&2
        rc=1
        ;;
      2)
        echo "ERROR: roborev #$rid not found in DB. Check the ID is correct." >&2
        rc=1
        ;;
      *)
        echo "WARN: unexpected return code $v_rc for roborev #$rid — skipping" >&2
        ;;
    esac
  done

  return $rc
}

# ── Self-test (direct function calls — NO subprocess of $0) ──────────────────
_selftest() {
  local pass=0 fail=0

  _t() {
    local label="$1" expected="$2" got="$3"
    if [ "$got" = "$expected" ]; then
      pass=$((pass+1))
      echo "  PASS [$label]"
    else
      fail=$((fail+1))
      echo "  FAIL [$label]: expected='$expected' got='$got'"
    fi
  }

  # Test _extract_citations — direct function calls, no subprocess of $0
  _t "extract: empty"         "" "$(_extract_citations 'feat: new feature')"
  _t "extract: closes #123"   "123" "$(_extract_citations 'closes roborev #123')"
  _t "extract: fixes #45"     "45" "$(_extract_citations 'fixes roborev #45')"
  _t "extract: fix (no s)"    "7" "$(_extract_citations 'fix roborev #7')"
  _t "extract: close (no s)"  "8" "$(_extract_citations 'close roborev #8')"
  _t "extract: wontfix"       "5" "$(_extract_citations 'wontfix roborev #5 [reason: not applicable]')"
  _t "extract: case-insens"   "99" "$(_extract_citations 'CLOSES ROBOREV #99')"
  _t "extract: no-space #"    "42" "$(_extract_citations 'closes roborev#42')"
  _t "extract: multi"         "10,20" "$(_extract_citations 'fixes roborev #10 and fixes roborev #20')"
  _t "extract: plain text"    "" "$(_extract_citations 'refactor: no citations here')"

  # Test _validate_id — missing DB → fail-open (exit 0)
  local _rc=0
  _validate_id 999 "/tmp/no_such_db_cite_$$" 2>/dev/null || _rc=$?
  _t "validate: missing DB fails open" "0" "$_rc"

  # Test _validate_id with real DB (if present) on a high ID likely not in DB → exit 2 (not found) or 0 (fail-open)
  local _rc2=0
  _validate_id 9999999 "${ROBOREV_DB:-/tmp/no_db}" 2>/dev/null || _rc2=$?
  # Accept 0 (DB missing = fail-open) or 2 (not found) as valid outcomes
  if [ "$_rc2" = "0" ] || [ "$_rc2" = "2" ]; then
    pass=$((pass+1))
    echo "  PASS [validate: high ID is 0 or 2]"
  else
    fail=$((fail+1))
    echo "  FAIL [validate: high ID]: expected 0 or 2, got '$_rc2'"
  fi

  # Test _main with no commit-msg file → error exit
  local _rc3=0
  _main "" 2>/dev/null || _rc3=$?
  _t "_main: no file → error" "1" "$_rc3"

  # Test _main with a commit containing no citations → exit 0
  local _tmpf
  _tmpf=$(mktemp /tmp/test_cite_msg_XXXXXX)
  printf 'refactor: improve logging\n\nNo citations here.\n' > "$_tmpf"
  local _rc4=0
  _main "$_tmpf" 2>/dev/null || _rc4=$?
  _t "_main: no citations → exit 0" "0" "$_rc4"
  rm -f "$_tmpf"

  echo ""
  echo "${pass}/$((pass+fail)) PASS"
  [ "$fail" -eq 0 ] && return 0 || return 1
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
if [ "${ROBOREV_CITE_SELFTEST:-0}" = "1" ]; then
  _selftest
  exit $?
fi

_main "$@"
exit $?
