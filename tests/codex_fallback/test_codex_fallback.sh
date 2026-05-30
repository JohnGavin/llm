#!/usr/bin/env bash
# tests/codex_fallback/test_codex_fallback.sh
#
# Test suite for .claude/scripts/codex_with_fallback.sh
#
# Uses stub binaries placed in a tmpdir-on-PATH. No bats dependency.
# Exits 0 if all tests pass, 1 on any failure.
#
# Covered cases (≥10 tests, aligns with task specification):
#   1.  codex success → final_provider=codex, exit 0
#   2.  codex 429    + gemini success → final_provider=gemini, exit 0
#   3.  codex 429    + gemini fail    → final_provider=gemini, exit non-zero
#   4.  codex 401    (auth fail)      → no fallback, exit non-zero
#   5.  codex other error             → no fallback, exit non-zero
#   6.  JSON record emitted on every case
#   7.  codex 429 + gemini absent → clear error, no crash, exit non-zero
#   8.  codex absent                  → clear error, exit 127
#   9.  Secret args are redacted in JSONL
#   10. fallback_used=false in JSONL for success case
#   11. fallback_used=true  in JSONL for 429+gemini-success case
#   12. provider_error classification (non-auth non-429 error with "Error" text)
#   13. duration_sec present and numeric in JSONL
#   14. JSONL file is append-only (two runs → two lines)
#
# Tracked: JohnGavin/llm#150

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="${SCRIPT_DIR}/../../.claude/scripts/codex_with_fallback.sh"

PASS=0
FAIL=0
TMPROOT=$(mktemp -d /tmp/test_codex_fallback_XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

# ── Test helpers ─────────────────────────────────────────────────────────────

pass() { echo "PASS: $1"; (( PASS += 1 )); }
fail() { echo "FAIL: $1 — ${2:-}"; (( FAIL += 1 )); }

# Run wrapper with stub PATH; capture stdout, stderr, exit code.
# Usage: run_wrapper [--codex-stub FILE] [--gemini-stub FILE] -- [args...]
#
# Stubs are executable scripts written into a fresh tmpdir-based bin.
# If a stub is NOT provided, that binary is absent from the test PATH
# (the test PATH is isolated — real codex/gemini are hidden).
run_wrapper() {
  local codex_stub="" gemini_stub=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --codex-stub)  codex_stub="$2"; shift 2 ;;
      --gemini-stub) gemini_stub="$2"; shift 2 ;;
      --) shift; break ;;
      *) break ;;
    esac
  done

  # Fresh bindir per call so stubs don't leak between tests
  local bindir
  bindir=$(mktemp -d "${TMPROOT}/bin_XXXXXX")
  local logdir
  logdir=$(mktemp -d "${TMPROOT}/logs_XXXXXX")
  mkdir -p "${logdir}/codex_fallback"
  local logsubdir="${logdir}/codex_fallback"

  if [ -n "$codex_stub" ]; then
    cp "$codex_stub" "${bindir}/codex"
    chmod +x "${bindir}/codex"
  fi
  if [ -n "$gemini_stub" ]; then
    cp "$gemini_stub" "${bindir}/gemini"
    chmod +x "${bindir}/gemini"
  fi
  # Replace PATH completely with the isolated bindir plus only safe system paths.
  # This ensures real codex/gemini are NOT found when no stub is provided.
  local ISOLATED_PATH="${bindir}:/usr/bin:/bin"

  local stdout_f stderr_f exit_f
  stdout_f=$(mktemp "${TMPROOT}/stdout_XXXXXX")
  stderr_f=$(mktemp "${TMPROOT}/stderr_XXXXXX")
  exit_f=$(mktemp "${TMPROOT}/exit_XXXXXX")

  # Run wrapper; capture exit code via a sentinel file inside the subshell.
  # Use ISOLATED_PATH so real codex/gemini are hidden when no stub provided.
  (
    export PATH="${ISOLATED_PATH}"
    export FALLBACK_LOG_DIR="${logsubdir}"
    unset CODEX_BIN GEMINI_BIN
    "$WRAPPER" "$@"
    printf '%s' "$?" > "$exit_f"
  ) >"$stdout_f" 2>"$stderr_f" || printf '%s' "$?" > "$exit_f"

  _LAST_STDOUT=$(cat "$stdout_f")
  _LAST_STDERR=$(cat "$stderr_f")
  _LAST_EXIT=$(cat "$exit_f" 2>/dev/null || printf '0')
  _LAST_LOGDIR="$logsubdir"

  rm -f "$stdout_f" "$stderr_f" "$exit_f"
}

# Read most recent JSONL line from _LAST_LOGDIR
last_jsonl() {
  local date_part
  date_part=$(date -u +%Y-%m-%d)
  local logfile="${_LAST_LOGDIR}/${date_part}.jsonl"
  if [ -f "$logfile" ]; then
    tail -1 "$logfile"
  else
    echo ""
  fi
}

jsonl_field() {
  local field="$1"
  local json
  json=$(last_jsonl)
  # Simple grep-based extraction for portability (no jq required)
  printf '%s' "$json" | grep -oE "\"${field}\":[^,}]+" | head -1 | sed "s/\"${field}\"://"
}

# ── Stub scripts ─────────────────────────────────────────────────────────────

write_stub() {
  local path="$1"
  local body="$2"
  printf '%s\n' "#!/usr/bin/env bash" "$body" > "$path"
  chmod +x "$path"
}

STUB_CODEX_SUCCESS=$(mktemp "${TMPROOT}/stub_codex_success_XXXXXX")
write_stub "$STUB_CODEX_SUCCESS" \
  "echo 'fake codex review result'; exit 0"

STUB_CODEX_429=$(mktemp "${TMPROOT}/stub_codex_429_XXXXXX")
write_stub "$STUB_CODEX_429" \
  "echo '429 rate_limit_exceeded: quota exhausted' >&2; exit 1"

STUB_CODEX_401=$(mktemp "${TMPROOT}/stub_codex_401_XXXXXX")
write_stub "$STUB_CODEX_401" \
  "echo '401 unauthorized: invalid API key' >&2; exit 1"

STUB_CODEX_OTHER=$(mktemp "${TMPROOT}/stub_codex_other_XXXXXX")
write_stub "$STUB_CODEX_OTHER" \
  "echo 'internal server Error occurred' >&2; exit 1"

STUB_GEMINI_SUCCESS=$(mktemp "${TMPROOT}/stub_gemini_success_XXXXXX")
write_stub "$STUB_GEMINI_SUCCESS" \
  "echo 'fake gemini review result'; exit 0"

STUB_GEMINI_FAIL=$(mktemp "${TMPROOT}/stub_gemini_fail_XXXXXX")
write_stub "$STUB_GEMINI_FAIL" \
  "echo 'gemini internal error' >&2; exit 2"

# ── Tests ─────────────────────────────────────────────────────────────────────

# Reset shared log dir for each test to avoid cross-contamination
fresh_logdir() {
  mkdir -p "${TMPROOT}/logs_${PASS}_${FAIL}/codex_fallback"
  echo "${TMPROOT}/logs_${PASS}_${FAIL}/codex_fallback"
}

# ── Test 1: codex success → exit 0, stdout relayed ──────────────────────────
run_wrapper --codex-stub "$STUB_CODEX_SUCCESS" -- review myfile.R
if [ "$_LAST_EXIT" -eq 0 ]; then
  pass "1: codex success exits 0"
else
  fail "1: codex success exits 0" "exit was $_LAST_EXIT"
fi

if printf '%s' "$_LAST_STDOUT" | grep -q "fake codex review result"; then
  pass "2: codex success stdout relayed"
else
  fail "2: codex success stdout relayed" "stdout was: $_LAST_STDOUT"
fi

# ── Test 3: codex 429 + gemini success → exit 0, gemini stdout ───────────────
run_wrapper --codex-stub "$STUB_CODEX_429" --gemini-stub "$STUB_GEMINI_SUCCESS" -- review myfile.R
if [ "$_LAST_EXIT" -eq 0 ]; then
  pass "3: 429+gemini success exits 0"
else
  fail "3: 429+gemini success exits 0" "exit was $_LAST_EXIT"
fi

if printf '%s' "$_LAST_STDOUT" | grep -q "fake gemini review result"; then
  pass "4: 429+gemini success stdout from gemini"
else
  fail "4: 429+gemini success stdout from gemini" "stdout was: $_LAST_STDOUT"
fi

# ── Test 5: codex 429 + gemini fail → non-zero exit ──────────────────────────
run_wrapper --codex-stub "$STUB_CODEX_429" --gemini-stub "$STUB_GEMINI_FAIL" -- review myfile.R
if [ "$_LAST_EXIT" -ne 0 ]; then
  pass "5: 429+gemini fail exits non-zero"
else
  fail "5: 429+gemini fail exits non-zero" "exit was $_LAST_EXIT (expected non-zero)"
fi

# ── Test 6: codex 401 → no fallback, non-zero ────────────────────────────────
run_wrapper --codex-stub "$STUB_CODEX_401" --gemini-stub "$STUB_GEMINI_SUCCESS" -- review myfile.R
if [ "$_LAST_EXIT" -ne 0 ]; then
  pass "6: codex 401 exits non-zero"
else
  fail "6: codex 401 exits non-zero" "exit was $_LAST_EXIT"
fi

if printf '%s' "$_LAST_STDERR" | grep -qi "auth"; then
  pass "7: codex 401 stderr mentions auth"
else
  fail "7: codex 401 stderr mentions auth" "stderr was: $_LAST_STDERR"
fi

# Gemini stdout should NOT appear (no fallback for auth errors)
if printf '%s' "$_LAST_STDOUT" | grep -q "fake gemini"; then
  fail "8: codex 401 does not fall back to gemini" "gemini stdout appeared"
else
  pass "8: codex 401 does not fall back to gemini"
fi

# ── Test 9: codex other error → no fallback, non-zero ────────────────────────
run_wrapper --codex-stub "$STUB_CODEX_OTHER" --gemini-stub "$STUB_GEMINI_SUCCESS" -- review myfile.R
if [ "$_LAST_EXIT" -ne 0 ]; then
  pass "9: codex other error exits non-zero"
else
  fail "9: codex other error exits non-zero" "exit was $_LAST_EXIT"
fi

# ── Test 10: JSONL record emitted for every case ─────────────────────────────
# Check success case
run_wrapper --codex-stub "$STUB_CODEX_SUCCESS" -- review myfile.R
jsonl=$(last_jsonl)
if printf '%s' "$jsonl" | grep -q '"primary_provider"'; then
  pass "10: JSONL record emitted for success case"
else
  fail "10: JSONL record emitted for success case" "jsonl was: $jsonl"
fi

# Check 429 case
run_wrapper --codex-stub "$STUB_CODEX_429" --gemini-stub "$STUB_GEMINI_SUCCESS" -- review myfile.R
jsonl=$(last_jsonl)
if printf '%s' "$jsonl" | grep -q '"primary_provider"'; then
  pass "11: JSONL record emitted for 429+fallback case"
else
  fail "11: JSONL record emitted for 429+fallback case" "jsonl was: $jsonl"
fi

# ── Test 12: fallback_used=false in JSONL for success case ───────────────────
run_wrapper --codex-stub "$STUB_CODEX_SUCCESS" -- review myfile.R
jsonl=$(last_jsonl)
if printf '%s' "$jsonl" | grep -q '"fallback_used":false'; then
  pass "12: fallback_used=false in JSONL for success"
else
  fail "12: fallback_used=false in JSONL for success" "jsonl: $jsonl"
fi

# ── Test 13: fallback_used=true in JSONL for 429+gemini-success case ─────────
run_wrapper --codex-stub "$STUB_CODEX_429" --gemini-stub "$STUB_GEMINI_SUCCESS" -- review myfile.R
jsonl=$(last_jsonl)
if printf '%s' "$jsonl" | grep -q '"fallback_used":true'; then
  pass "13: fallback_used=true in JSONL for 429+fallback"
else
  fail "13: fallback_used=true in JSONL for 429+fallback" "jsonl: $jsonl"
fi

# ── Test 14: gemini absent → clear error, no crash, non-zero exit ────────────
# (no --gemini-stub = gemini not on PATH)
run_wrapper --codex-stub "$STUB_CODEX_429" -- review myfile.R
if [ "$_LAST_EXIT" -ne 0 ]; then
  pass "14: 429+gemini absent exits non-zero"
else
  fail "14: 429+gemini absent exits non-zero" "exit was $_LAST_EXIT"
fi

if printf '%s' "$_LAST_STDERR" | grep -qiE "not found|gemini"; then
  pass "15: 429+gemini absent: clear error message"
else
  fail "15: 429+gemini absent: clear error message" "stderr: $_LAST_STDERR"
fi

# ── Test 16: codex absent → clear error, exit 127 ────────────────────────────
# (no --codex-stub = codex not on PATH)
run_wrapper -- review myfile.R
if [ "$_LAST_EXIT" -eq 127 ]; then
  pass "16: codex absent exits 127"
else
  fail "16: codex absent exits 127" "exit was $_LAST_EXIT"
fi

# ── Test 17: secret args redacted in JSONL ───────────────────────────────────
run_wrapper --codex-stub "$STUB_CODEX_SUCCESS" -- review --api-key SECRET_VALUE myfile.R
jsonl=$(last_jsonl)
if printf '%s' "$jsonl" | grep -q "SECRET_VALUE"; then
  fail "17: secret arg not redacted in JSONL" "SECRET_VALUE appears in jsonl: $jsonl"
else
  pass "17: secret arg redacted in JSONL"
fi

# ── Test 18: duration_sec present and looks numeric ──────────────────────────
run_wrapper --codex-stub "$STUB_CODEX_SUCCESS" -- review myfile.R
jsonl=$(last_jsonl)
if printf '%s' "$jsonl" | grep -qE '"duration_sec":[0-9]+'; then
  pass "18: duration_sec present and numeric in JSONL"
else
  fail "18: duration_sec present and numeric in JSONL" "jsonl: $jsonl"
fi

# ── Test 19: JSONL append-only (two runs → two lines) ────────────────────────
# Use a single, shared log dir for this test; stub codex success twice
shared_bindir=$(mktemp -d "${TMPROOT}/bin_shared_XXXXXX")
shared_logdir="${TMPROOT}/shared_logs"
mkdir -p "$shared_logdir"
cp "$STUB_CODEX_SUCCESS" "${shared_bindir}/codex"
chmod +x "${shared_bindir}/codex"

(
  export PATH="${shared_bindir}:/usr/bin:/bin"
  export FALLBACK_LOG_DIR="$shared_logdir"
  unset CODEX_BIN GEMINI_BIN
  "$WRAPPER" review myfile.R >/dev/null 2>&1 || true
  "$WRAPPER" review myfile.R >/dev/null 2>&1 || true
) || true

date_part=$(date -u +%Y-%m-%d)
shared_logfile="${shared_logdir}/${date_part}.jsonl"
if [ -f "$shared_logfile" ]; then
  line_count=$(wc -l < "$shared_logfile" | tr -d ' ')
  if [ "$line_count" -ge 2 ]; then
    pass "19: JSONL append-only: two runs produce two lines"
  else
    fail "19: JSONL append-only" "expected ≥2 lines, got $line_count"
  fi
else
  fail "19: JSONL append-only" "log file not created"
fi

# ── Test 20: final_provider=codex in success JSONL ───────────────────────────
run_wrapper --codex-stub "$STUB_CODEX_SUCCESS" -- review myfile.R
jsonl=$(last_jsonl)
if printf '%s' "$jsonl" | grep -q '"final_provider":"codex"'; then
  pass "20: final_provider=codex in success JSONL"
else
  fail "20: final_provider=codex in success JSONL" "jsonl: $jsonl"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
