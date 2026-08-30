#!/usr/bin/env bash
#
# hook-liveness: on-warn
#   This hook has NO block path — it only ever WARNS (exit 0, stderr message
#   + log line) or allows silently. A 7-day count of zero WARNs is a healthy
#   value on a repo with no recent quarantined WebFetch activity; it does not
#   mean the hook is dead. See secret_leak_guard.sh's identical header note
#   for why this declaration lives here rather than in a list kept by a
#   report script.
#
# edit_write_similarity_guard.sh — PreToolUse:Edit|Write hook
#
# Layer 3 of the external-code-zero-trust defence (llm#194). Detects the
# "WebFetch a URL then Edit/Write the result verbatim into the codebase"
# anti-pattern named in that rule's Forbidden Patterns table: compares the
# NEW content of an Edit (new_string) or Write (content) call against
# recently-fingerprinted content fetched from a non-allowlisted domain
# (external_content_fingerprint.sh, Layer 3's companion PostToolUse:WebFetch
# hook). Above a similarity threshold, this hook WARNS — it prints a stderr
# message and logs the event — but never blocks.
#
# WHY WARN, NOT BLOCK (deliberate, not a placeholder)
# -----------------------------------------------------
# The rule's own Decision Tree only forbids VERBATIM copying; reading
# external content for IDEAS and re-implementing from scratch is explicitly
# endorsed. A similarity heuristic (word-shingle Jaccard overlap — see
# lib/content_shingles.py) cannot distinguish "copied verbatim" from
# "independently reached the same idiomatic phrasing" with the precision a
# hard BLOCK gate requires, and a false-positive block on ordinary
# paraphrased/re-implemented code would be actively harmful — it would
# either wedge legitimate work or train the operator to route around the
# guard. Precision is favoured over recall here: this hook exists to
# surface a signal for human judgement, not to make the call itself. See
# JohnGavin/llm#194.
#
# THIS HOOK NEVER BLOCKS: its only exit code is 0. A WARN is a stderr
# message + a log line, nothing else.
#
# Self-test: CLAUDE_HOOK_SELFTEST=1 bash edit_write_similarity_guard.sh
#
# See: .claude/rules/external-code-zero-trust.md (Layer 3)
#      llm#194

set -uo pipefail

CONTENT_SHINGLES_LIB_DIR="${BASH_SOURCE[0]%/*}/lib"
export CONTENT_SHINGLES_LIB_DIR

# ═══════════════════════════════════════════════════════════════════════════
# PATHS + CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════

STATE_DIR="${EXTERNAL_FINGERPRINT_STATE_DIR:-$HOME/.claude/state}"
STORE_FILE="$STATE_DIR/external-content-fingerprints.jsonl"
LOG_FILE="${SIMILARITY_GUARD_LOG:-$HOME/.claude/logs/edit_write_similarity_guard.log}"

# Only compare against fingerprint records newer than this many minutes.
# A fetch from hours/days ago is unlikely to be the source of a "just
# copied it in" edit, and excluding stale records keeps the comparison
# relevant to the session actually in progress.
MAX_AGE_MINUTES="${SIMILARITY_GUARD_MAX_AGE_MINUTES:-30}"

# Jaccard overlap threshold above which a WARN fires. 0.5 means "at least
# half of the new content's word-shingles also appear in the fetched
# content's shingle set" — high enough that ordinary shared idioms (common
# imports, common phrasing) do not trigger it, low enough to catch a
# paste of even a modified excerpt, not just an exact full-file copy.
SIMILARITY_THRESHOLD="${SIMILARITY_GUARD_THRESHOLD:-0.5}"

# ═══════════════════════════════════════════════════════════════════════════
# HELPER: run the comparison in a single python3 process
# ═══════════════════════════════════════════════════════════════════════════
# Args (via env, to avoid shell-quoting a large content blob onto argv):
#   SIM_NEW_CONTENT   - the Edit/Write new content
#   SIM_STORE_FILE    - path to the fingerprint JSONL store
#   SIM_MAX_AGE_MIN   - max age in minutes
#   SIM_THRESHOLD     - overlap threshold
# Prints one line: "WARN <url> <overlap>" or "OK" (no match / nothing to compare).

compare_content() {
  SIM_NEW_CONTENT="$1" \
  SIM_STORE_FILE="$STORE_FILE" \
  SIM_MAX_AGE_MIN="$MAX_AGE_MINUTES" \
  SIM_THRESHOLD="$SIMILARITY_THRESHOLD" \
  CONTENT_SHINGLES_LIB_DIR="$CONTENT_SHINGLES_LIB_DIR" \
  python3 -c "
import json, sys, os, datetime

lib_dir = os.environ.get('CONTENT_SHINGLES_LIB_DIR', '')
if lib_dir and lib_dir not in sys.path:
    sys.path.insert(0, lib_dir)
from content_shingles import shingle_hashes, jaccard_overlap

new_content = os.environ.get('SIM_NEW_CONTENT', '')
store_path = os.environ.get('SIM_STORE_FILE', '')
max_age_min = float(os.environ.get('SIM_MAX_AGE_MIN', '30'))
threshold = float(os.environ.get('SIM_THRESHOLD', '0.5'))

new_hashes = shingle_hashes(new_content)
if not new_hashes:
    print('OK')
    sys.exit(0)

if not os.path.isfile(store_path):
    print('OK')
    sys.exit(0)

now = datetime.datetime.now(datetime.timezone.utc)
best_overlap = 0.0
best_url = ''

try:
    with open(store_path, 'r') as fh:
        lines = fh.readlines()
except Exception:
    print('OK')
    sys.exit(0)

for line in lines:
    line = line.strip()
    if not line:
        continue
    try:
        rec = json.loads(line)
    except Exception:
        continue
    ts_str = rec.get('ts', '')
    try:
        ts = datetime.datetime.strptime(ts_str, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc)
    except Exception:
        continue
    age_min = (now - ts).total_seconds() / 60.0
    if age_min > max_age_min:
        continue
    shingles = rec.get('shingles', [])
    if not shingles:
        continue
    overlap = jaccard_overlap(new_hashes, shingles)
    if overlap > best_overlap:
        best_overlap = overlap
        best_url = rec.get('url', '(unknown url)')

if best_overlap >= threshold:
    print('WARN %s %.3f' % (best_url, best_overlap))
else:
    print('OK')
" 2>/dev/null || echo "OK"
}

log_warn() {
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] WARN file=$1 url=$2 overlap=$3" >> "$LOG_FILE"
}

# ═══════════════════════════════════════════════════════════════════════════
# SELF-TEST MODE
# ═══════════════════════════════════════════════════════════════════════════

if [ "${CLAUDE_HOOK_SELFTEST:-}" = "1" ]; then
  PASS=0
  FAIL=0

  TMP_DIR=$(mktemp -d /tmp/similarity_guard_selftest_XXXXXX)
  STORE_FILE="$TMP_DIR/external-content-fingerprints.jsonl"
  LOG_FILE="$TMP_DIR/similarity_guard.log"

  # Fixture: a fake "recently fetched" record from an untrusted URL, built
  # via the SAME shingle library the real fingerprint-capture hook uses —
  # this simulates what external_content_fingerprint.sh would have written,
  # without needing a real WebFetch call.
  FETCHED_TEXT="function processPayment(amount, currency) { validateAmount(amount); return chargeCard(amount, currency, getMerchantId()); } function validateAmount(amount) { if (amount <= 0) throw new Error('invalid amount'); }"

  NOW_TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  RECORD=$(SIM_TEXT="$FETCHED_TEXT" CONTENT_SHINGLES_LIB_DIR="$CONTENT_SHINGLES_LIB_DIR" python3 -c "
import json, os, sys
lib_dir = os.environ.get('CONTENT_SHINGLES_LIB_DIR', '')
if lib_dir and lib_dir not in sys.path:
    sys.path.insert(0, lib_dir)
from content_shingles import shingle_hashes
text = os.environ.get('SIM_TEXT', '')
print(json.dumps({'ts': '$NOW_TS', 'url': 'https://landing-ianymu.vercel.app/audit/payment.js', 'shingles': shingle_hashes(text)}))
")
  echo "$RECORD" > "$STORE_FILE"

  echo "=== edit_write_similarity_guard.sh self-test ==="

  # Test 1: near-identical content (same text, trivially reformatted onto
  # multiple lines) → WARN. Uses $'...' ANSI-C quoting so \n becomes a REAL
  # newline (whitespace) here, matching how it is embedded into the test 7
  # JSON fixture below — a literal backslash-n would not word-split the
  # same way normalize_text() splits on real whitespace, which is exactly
  # the bug this comment is here to prevent reintroducing.
  NEAR_IDENTICAL=$'function processPayment(amount, currency) {\n  validateAmount(amount);\n  return chargeCard(amount, currency, getMerchantId());\n}\nfunction validateAmount(amount) {\n  if (amount <= 0) throw new Error(\'invalid amount\');\n}'
  RESULT=$(compare_content "$NEAR_IDENTICAL")
  if echo "$RESULT" | grep -q '^WARN'; then
    echo "  PASS: near-identical content triggers WARN ($RESULT)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: near-identical content did not trigger WARN (got: $RESULT)"
    FAIL=$((FAIL + 1))
  fi

  # Test 2: genuinely different content → OK (no false positive)
  DIFFERENT_CONTENT="This is a completely unrelated R function that computes a rolling mean over a numeric vector using a sliding window and returns a tibble with the smoothed series attached as a new column."
  RESULT=$(compare_content "$DIFFERENT_CONTENT")
  if [ "$RESULT" = "OK" ]; then
    echo "  PASS: unrelated content does not trigger WARN"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: unrelated content incorrectly triggered ($RESULT)"
    FAIL=$((FAIL + 1))
  fi

  # Test 3: content too short to shingle → OK (no crash, no false WARN)
  RESULT=$(compare_content "short")
  if [ "$RESULT" = "OK" ]; then
    echo "  PASS: too-short content returns OK"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: too-short content did not return OK (got: $RESULT)"
    FAIL=$((FAIL + 1))
  fi

  # Test 4: empty store file → OK. compare_content() reads the global
  # STORE_FILE variable at call time, so temporarily overriding it here
  # exercises the "empty store" path without touching the fixture store
  # used by tests 1-3.
  EMPTY_STORE="$TMP_DIR/empty-store.jsonl"
  : > "$EMPTY_STORE"
  OLD_STORE_FILE="$STORE_FILE"
  STORE_FILE="$EMPTY_STORE"
  RESULT=$(compare_content "$NEAR_IDENTICAL")
  STORE_FILE="$OLD_STORE_FILE"
  if [ "$RESULT" = "OK" ]; then
    echo "  PASS: empty fingerprint store returns OK"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: empty fingerprint store did not return OK (got: $RESULT)"
    FAIL=$((FAIL + 1))
  fi

  # Test 5: missing store file (path does not exist) → OK, no crash
  OLD_STORE_FILE="$STORE_FILE"
  STORE_FILE="$TMP_DIR/does-not-exist.jsonl"
  RESULT=$(compare_content "$NEAR_IDENTICAL")
  STORE_FILE="$OLD_STORE_FILE"
  if [ "$RESULT" = "OK" ]; then
    echo "  PASS: missing fingerprint store file returns OK (no crash)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: missing fingerprint store file did not return OK (got: $RESULT)"
    FAIL=$((FAIL + 1))
  fi

  # Test 6: stale record (older than MAX_AGE_MINUTES) → OK, not compared
  STALE_TS="2020-01-01T00:00:00Z"
  STALE_RECORD=$(SIM_TEXT="$FETCHED_TEXT" CONTENT_SHINGLES_LIB_DIR="$CONTENT_SHINGLES_LIB_DIR" python3 -c "
import json, os, sys
lib_dir = os.environ.get('CONTENT_SHINGLES_LIB_DIR', '')
if lib_dir and lib_dir not in sys.path:
    sys.path.insert(0, lib_dir)
from content_shingles import shingle_hashes
text = os.environ.get('SIM_TEXT', '')
print(json.dumps({'ts': '$STALE_TS', 'url': 'https://landing-ianymu.vercel.app/audit/payment.js', 'shingles': shingle_hashes(text)}))
")
  STALE_STORE="$TMP_DIR/stale-store.jsonl"
  echo "$STALE_RECORD" > "$STALE_STORE"
  OLD_STORE_FILE="$STORE_FILE"
  STORE_FILE="$STALE_STORE"
  RESULT=$(compare_content "$NEAR_IDENTICAL")
  STORE_FILE="$OLD_STORE_FILE"
  if [ "$RESULT" = "OK" ]; then
    echo "  PASS: stale (>MAX_AGE_MINUTES) record is excluded from comparison"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: stale record was incorrectly compared (got: $RESULT)"
    FAIL=$((FAIL + 1))
  fi

  # Test 7: end-to-end via main-logic JSON (Edit shape, new_string) → WARN
  # logged and printed to stderr, exit code always 0 (never blocks).
  EDIT_JSON=$(python3 -c "
import json
print(json.dumps({
    'tool_name': 'Edit',
    'tool_input': {'file_path': '/tmp/payment.js', 'old_string': 'x', 'new_string': '''$NEAR_IDENTICAL'''}
}))
")
  STDERR_OUT=$(printf '%s' "$EDIT_JSON" | \
    env -u CLAUDE_HOOK_SELFTEST SIMILARITY_GUARD_LOG="$LOG_FILE" \
    EXTERNAL_FINGERPRINT_STATE_DIR="$TMP_DIR" \
    bash "$0" 2>&1 1>/dev/null)
  RC=$?
  if [ "$RC" -eq 0 ] && echo "$STDERR_OUT" | grep -qi 'similarity\|WARN'; then
    echo "  PASS: end-to-end Edit JSON produces a WARN and exits 0"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: end-to-end Edit JSON did not warn as expected (rc=$RC, stderr='$STDERR_OUT')"
    FAIL=$((FAIL + 1))
  fi

  # Test 8: end-to-end Write JSON (content field) with unrelated content →
  # no WARN, exit 0.
  WRITE_JSON=$(python3 -c "
import json
print(json.dumps({
    'tool_name': 'Write',
    'tool_input': {'file_path': '/tmp/unrelated.R', 'content': '''$DIFFERENT_CONTENT'''}
}))
")
  STDERR_OUT=$(printf '%s' "$WRITE_JSON" | \
    env -u CLAUDE_HOOK_SELFTEST SIMILARITY_GUARD_LOG="$LOG_FILE" \
    EXTERNAL_FINGERPRINT_STATE_DIR="$TMP_DIR" \
    bash "$0" 2>&1 1>/dev/null)
  RC=$?
  if [ "$RC" -eq 0 ] && ! echo "$STDERR_OUT" | grep -qi 'WARN'; then
    echo "  PASS: end-to-end unrelated Write JSON produces no WARN"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: end-to-end unrelated Write JSON incorrectly warned (rc=$RC, stderr='$STDERR_OUT')"
    FAIL=$((FAIL + 1))
  fi

  rm -rf "$TMP_DIR"

  TOTAL=$((PASS + FAIL))
  echo "=== $PASS/$TOTAL PASS ==="
  [ "$FAIL" -eq 0 ] && exit 0 || exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════
# MAIN LOGIC — always exits 0 (WARN or silent allow, never BLOCK)
# ═══════════════════════════════════════════════════════════════════════════

INPUT=$(cat)

TOOL_NAME=$(printf '%s' "$INPUT" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('tool_name', '') if isinstance(d, dict) else '')
except Exception:
    print('')
" 2>/dev/null || echo "")

FILE_PATH=$(printf '%s' "$INPUT" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    ti = d.get('tool_input', {}) if isinstance(d, dict) else {}
    print(ti.get('file_path', '') if isinstance(ti, dict) else '')
except Exception:
    print('')
" 2>/dev/null || echo "")

# Content field depends on tool: Write uses .content, Edit uses .new_string
# (same field-name convention already used by phi-scan-hook.sh in this repo).
NEW_CONTENT=$(printf '%s' "$INPUT" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    ti = d.get('tool_input', {}) if isinstance(d, dict) else {}
    if not isinstance(ti, dict):
        print('')
    else:
        v = ti.get('content', '')
        if not v:
            v = ti.get('new_string', '')
        print(v or '')
except Exception:
    print('')
" 2>/dev/null || echo "")

[ -z "$NEW_CONTENT" ] && exit 0

RESULT=$(compare_content "$NEW_CONTENT")

if echo "$RESULT" | grep -q '^WARN'; then
  WARN_URL=$(echo "$RESULT" | awk '{print $2}')
  WARN_OVERLAP=$(echo "$RESULT" | awk '{print $3}')
  cat >&2 <<EOF

WARNING (edit_write_similarity_guard, Layer 3): new content for
'${FILE_PATH:-<unknown file>}' overlaps ${WARN_OVERLAP} (Jaccard, word-shingles)
with content recently fetched from a non-allowlisted domain:

  $WARN_URL

Per external-code-zero-trust rule: if you are re-implementing an idea from
that content, re-implement it from scratch — do not copy it verbatim. If
this is a false positive (independently-written code that happens to share
common idioms), no action is needed; this is advisory only.

Log: $LOG_FILE

EOF
  log_warn "${FILE_PATH:-<unknown file>}" "$WARN_URL" "$WARN_OVERLAP"
fi

exit 0
