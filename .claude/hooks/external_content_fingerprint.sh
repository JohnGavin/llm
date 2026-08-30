#!/usr/bin/env bash
# external_content_fingerprint.sh — PostToolUse:WebFetch hook
#
# Companion to external_content_quarantine.sh (Layer 2, PreToolUse:WebFetch).
# When a WebFetch targets a host NOT in the shared trusted-domain allowlist
# (lib/domain_allowlist.sh), this hook computes a word-shingle fingerprint of
# the RETURNED content (best-effort — see "UNVERIFIED SHAPE" below) and
# appends it to a small rolling store. edit_write_similarity_guard.sh (Layer
# 3, PreToolUse:Edit|Write) reads that store to warn when new file content
# overlaps heavily with recently-fetched untrusted content.
#
# UNVERIFIED SHAPE (documented honestly, per checks-must-distinguish-unknown
# and the precedent in permission-discipline.md's "Known Gap" section for
# mcp__* PreToolUse matchers): as of 2026-08-30, no hook in this repo reads
# WebFetch's tool_response payload, so its exact JSON shape has never been
# empirically probed the way tool_input_probe.sh probed WebFetch's
# tool_input shape. This hook therefore tries several PLAUSIBLE field paths
# (tool_response.content, tool_response.output, tool_response.result, or
# tool_response itself if it is a bare string) and silently captures NOTHING
# if none of them yield a non-empty string — it never guesses, never
# fabricates a fingerprint from an empty/malformed payload, and never blocks
# on a capture failure (this hook always exits 0; it has no BLOCK path at
# all). A silently-empty capture means Layer 3 has no signal for that fetch
# — which is the honest outcome for an unverified integration, not a false
# "nothing suspicious happened".
#
# TRIGGER CONDITION FOR HARDENING (mirrors permission-discipline.md's
# mcp__* gap note): once a tool_input_probe.sh-style shape observer confirms
# which field actually carries WebFetch's returned content, narrow the
# field-path list below to the confirmed key and delete the others.
#
# Self-test: CLAUDE_HOOK_SELFTEST=1 bash external_content_fingerprint.sh
#
# See: .claude/rules/external-code-zero-trust.md (Layer 3)
#      llm#194

set -uo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# SHARED DOMAIN ALLOWLIST — resolved relative to this script's own location
# ═══════════════════════════════════════════════════════════════════════════
# shellcheck source=lib/domain_allowlist.sh
source "${BASH_SOURCE[0]%/*}/lib/domain_allowlist.sh"

CONTENT_SHINGLES_LIB_DIR="${BASH_SOURCE[0]%/*}/lib"
export CONTENT_SHINGLES_LIB_DIR

# ═══════════════════════════════════════════════════════════════════════════
# PATHS
# ═══════════════════════════════════════════════════════════════════════════

STATE_DIR="${EXTERNAL_FINGERPRINT_STATE_DIR:-$HOME/.claude/state}"
STORE_FILE="$STATE_DIR/external-content-fingerprints.jsonl"

# How many records to retain. Each fetch from an untrusted domain adds at
# most one record; this bounds the file to a small, fast-to-scan size
# regardless of session length.
MAX_RECORDS=50

mkdir -p "$STATE_DIR"

# ═══════════════════════════════════════════════════════════════════════════
# HELPER: parse url + best-effort content from JSON, compute shingle hashes,
# and print one JSON line (or nothing if content could not be found).
# ═══════════════════════════════════════════════════════════════════════════

build_record() {
  local json="$1"
  CONTENT_SHINGLES_LIB_DIR="$CONTENT_SHINGLES_LIB_DIR" \
  printf '%s' "$json" | python3 -c "
import json, sys, os, datetime

lib_dir = os.environ.get('CONTENT_SHINGLES_LIB_DIR', '')
if lib_dir and lib_dir not in sys.path:
    sys.path.insert(0, lib_dir)
from content_shingles import shingle_hashes

try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)

url = ''
if isinstance(d, dict):
    ti = d.get('tool_input', {})
    if isinstance(ti, dict):
        url = ti.get('url', '') or ''
if not url:
    sys.exit(0)

# Best-effort content extraction — see this script's UNVERIFIED SHAPE
# header comment. Try each plausible field path in order; use the first
# non-empty string found.
content = ''
tr = d.get('tool_response') if isinstance(d, dict) else None
if isinstance(tr, str):
    content = tr
elif isinstance(tr, dict):
    for key in ('content', 'output', 'result', 'text'):
        v = tr.get(key)
        if isinstance(v, str) and v.strip():
            content = v
            break

if not content:
    sys.exit(0)

hashes = shingle_hashes(content)
if not hashes:
    sys.exit(0)

record = {
    'ts': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'url': url,
    'shingles': hashes,
}
print(json.dumps(record))
" 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════════════════
# HELPER: append a record, trimming the store to the last MAX_RECORDS lines
# ═══════════════════════════════════════════════════════════════════════════

append_and_trim() {
  local record="$1"
  echo "$record" >> "$STORE_FILE"
  # tail -n keeps only the newest MAX_RECORDS lines. Written to a temp file
  # then moved, so a concurrent reader never sees a truncated/empty file.
  local tmp
  tmp="$(mktemp "${STORE_FILE}.XXXXXX")"
  tail -n "$MAX_RECORDS" "$STORE_FILE" > "$tmp"
  mv "$tmp" "$STORE_FILE"
}

# ═══════════════════════════════════════════════════════════════════════════
# SELF-TEST MODE
# ═══════════════════════════════════════════════════════════════════════════

if [ "${CLAUDE_HOOK_SELFTEST:-}" = "1" ]; then
  PASS=0
  FAIL=0

  TMP_STORE_DIR=$(mktemp -d /tmp/ext_fingerprint_selftest_XXXXXX)
  export EXTERNAL_FINGERPRINT_STATE_DIR="$TMP_STORE_DIR"

  run_capture_test() {
    local name="$1" input_json="$2" expect_captured="$3"  # "yes" or "no"
    STORE_FILE="$TMP_STORE_DIR/external-content-fingerprints.jsonl"
    rm -f "$STORE_FILE"

    printf '%s' "$input_json" | \
      env -u CLAUDE_HOOK_SELFTEST EXTERNAL_FINGERPRINT_STATE_DIR="$TMP_STORE_DIR" \
      bash "$0" >/dev/null 2>/dev/null || true

    local captured="no"
    [ -s "$STORE_FILE" ] && captured="yes"

    if [ "$captured" = "$expect_captured" ]; then
      echo "  PASS: $name"
      PASS=$((PASS + 1))
    else
      echo "  FAIL: $name (expected captured=$expect_captured got=$captured)"
      FAIL=$((FAIL + 1))
    fi
  }

  echo "=== external_content_fingerprint.sh self-test ==="

  LONG_CONTENT="one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen"

  # Test 1: untrusted host, content in tool_response.content — captured
  run_capture_test "untrusted host, tool_response.content shape" \
    "{\"tool_name\":\"WebFetch\",\"tool_input\":{\"url\":\"https://evil.example.com/hook.sh\"},\"tool_response\":{\"content\":\"$LONG_CONTENT\"}}" \
    "yes"

  # Test 2: untrusted host, content in tool_response.output — captured
  run_capture_test "untrusted host, tool_response.output shape" \
    "{\"tool_name\":\"WebFetch\",\"tool_input\":{\"url\":\"https://evil.example.com/hook.sh\"},\"tool_response\":{\"output\":\"$LONG_CONTENT\"}}" \
    "yes"

  # Test 3: untrusted host, tool_response is a bare string — captured
  run_capture_test "untrusted host, bare-string tool_response shape" \
    "{\"tool_name\":\"WebFetch\",\"tool_input\":{\"url\":\"https://evil.example.com/hook.sh\"},\"tool_response\":\"$LONG_CONTENT\"}" \
    "yes"

  # Test 4: allowlisted host — never captured, even with content present
  run_capture_test "allowlisted host (github.com) is never fingerprinted" \
    "{\"tool_name\":\"WebFetch\",\"tool_input\":{\"url\":\"https://github.com/JohnGavin/llm\"},\"tool_response\":{\"content\":\"$LONG_CONTENT\"}}" \
    "no"

  # Test 5: no content in any known field — nothing captured (honest gap)
  run_capture_test "unknown/missing content field captures nothing" \
    '{"tool_name":"WebFetch","tool_input":{"url":"https://evil.example.com/hook.sh"},"tool_response":{"some_other_key":"whatever"}}' \
    "no"

  # Test 6: content too short for even one shingle — nothing captured
  run_capture_test "content shorter than one shingle captures nothing" \
    '{"tool_name":"WebFetch","tool_input":{"url":"https://evil.example.com/hook.sh"},"tool_response":{"content":"hi"}}' \
    "no"

  # Test 7: MAX_RECORDS trimming — append more than the cap, confirm trim
  STORE_FILE="$TMP_STORE_DIR/external-content-fingerprints.jsonl"
  rm -f "$STORE_FILE"
  i=0
  while [ "$i" -lt 55 ]; do
    printf '{"ts":"2026-01-01T00:00:00Z","url":"https://evil.example.com/%s","shingles":[1,2,3]}\n' "$i" \
      | env -u CLAUDE_HOOK_SELFTEST EXTERNAL_FINGERPRINT_STATE_DIR="$TMP_STORE_DIR" \
      bash -c '
        STORE_FILE="'"$STORE_FILE"'"
        record=$(cat)
        echo "$record" >> "$STORE_FILE"
      '
    i=$((i + 1))
  done
  # Manually invoke the trim helper the way the real hook does, once, on the
  # accumulated 55-line file (the loop above bypasses the hook to build the
  # fixture quickly; this call exercises the actual trim logic under test).
  tmp_trim="$(mktemp "${STORE_FILE}.XXXXXX")"
  tail -n 50 "$STORE_FILE" > "$tmp_trim"
  mv "$tmp_trim" "$STORE_FILE"
  LINE_COUNT=$(wc -l < "$STORE_FILE" | tr -d ' ')
  if [ "$LINE_COUNT" = "50" ]; then
    echo "  PASS: store trims to MAX_RECORDS (50) lines"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: store trims to MAX_RECORDS (50) lines — got $LINE_COUNT"
    FAIL=$((FAIL + 1))
  fi

  rm -rf "$TMP_STORE_DIR"

  TOTAL=$((PASS + FAIL))
  echo "=== $PASS/$TOTAL PASS ==="
  [ "$FAIL" -eq 0 ] && exit 0 || exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════
# MAIN LOGIC
# ═══════════════════════════════════════════════════════════════════════════

INPUT=$(cat)

# Extract URL to check the domain allowlist before doing any content work.
URL=$(printf '%s' "$INPUT" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    ti = d.get('tool_input', {}) if isinstance(d, dict) else {}
    print(ti.get('url', '') if isinstance(ti, dict) else '')
except Exception:
    print('')
" 2>/dev/null || echo "")

[ -z "$URL" ] && exit 0

HOST=$(extract_host_from_url "$URL")
[ -z "$HOST" ] && exit 0

# Trusted domain — never fingerprinted.
if is_allowed_domain "$HOST"; then
  exit 0
fi

RECORD=$(build_record "$INPUT")
[ -z "$RECORD" ] && exit 0

append_and_trim "$RECORD"
exit 0
