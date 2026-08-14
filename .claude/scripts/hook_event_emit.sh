#!/usr/bin/env bash
# hook_event_emit.sh — thin, fail-open emitter for hook_events telemetry (llm#950).
#
# WHY SPOOL, NOT A DIRECT DUCKDB WRITE:
#   Hooks fire on every tool call. A `duckdb` CLI write costs ~100ms+ and
#   DuckDB is single-writer -- concurrent hooks (or an open session/dashboard
#   connection) would contend and could wedge sessions. log_session.sh hit
#   exactly this in llm#710 (an exclusive lock held for ~100ms per PostToolUse
#   event starved the ETL's 3x10s retry window). The fix there, reused here:
#   append one JSON line to a spool file (each `>>` is a kernel-atomic write
#   <= PIPE_BUF, no lock needed) and let a separate batch loader
#   (hook_events_load.sh) drain it on an existing schedule when contention is
#   low. DO NOT "simplify" this into a synchronous duckdb write in this file —
#   see log_session.sh's #710 header comment for the incident it would repeat.
#
# Usage:
#   hook_event_emit.sh <hook_name> <event_type> [output_preview]
#   hook_event_emit.sh --selftest
#
# Contract: NEVER throws, NEVER blocks the caller (every internal command is
# guarded), and NEVER makes a credential worse. Callers (e.g. secret_leak_guard.sh)
# MUST pass an already-redacted preview — this script is not a redaction layer,
# it is a second line of defense that additionally hard-truncates to 200 chars
# and strips newlines so one careless caller can't corrupt the JSONL spool.
#
# Spool schema (matches hook_events_staging.jsonl / log_session.sh's `hook`
# case, so the existing loader logic in hook_events_load.sh handles both):
#   {"ts":..., "session_id":..., "hook_name":..., "event_type":..., "output_preview":...}

set -uo pipefail

_resolve_session_id() {
  # Mirrors llmtelemetry_emit.sh's resolution order (llm#273): env var ->
  # the session-scoped file written by log_session.sh at SessionStart ->
  # "unknown". Never blocks; never generates a UUID here (unlike
  # llmtelemetry_emit.sh) because hook_events tolerates a shared "unknown"
  # bucket for the rare case both are absent -- this is a fire-and-forget
  # telemetry signal, not a billing record.
  local sid="${CLAUDE_SESSION_ID:-}"
  if [ -z "$sid" ] && [ -f "$HOME/.claude/logs/.current_session" ]; then
    sid=$(cat "$HOME/.claude/logs/.current_session" 2>/dev/null || echo "")
  fi
  [ -z "$sid" ] && sid="unknown"
  printf '%s' "$sid"
}

_emit() {
  local hook_name="${1:-unknown}" event_type="${2:-unknown}" preview="${3:-}"
  # Resolved fresh on every call (not captured once at script top-level) so
  # that HOOK_EVENTS_SPOOL overrides set between calls (selftest; per-caller
  # isolation) actually take effect.
  local spool="${HOOK_EVENTS_SPOOL:-$HOME/.claude/logs/hook_events_staging.jsonl}"
  local sid ts esc
  sid=$(_resolve_session_id)
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "")
  # Truncate to 200 chars FIRST (defense in depth against an oversized/careless
  # preview), then strip control chars that would break JSONL, then escape
  # backslash/quote for JSON string embedding. Order matters: truncating after
  # escaping could cut mid-escape-sequence and produce invalid JSON.
  esc=$(printf '%s' "$preview" | head -c 200 | tr '\n\r\t' '   ')
  esc=$(printf '%s' "$esc" | sed 's/\\/\\\\/g; s/"/\\"/g')
  mkdir -p "$(dirname "$spool")" 2>/dev/null || true
  { printf '{"ts":"%s","session_id":"%s","hook_name":"%s","event_type":"%s","output_preview":"%s"}\n' \
    "$ts" "$sid" "$hook_name" "$event_type" "$esc" >> "$spool"; } 2>/dev/null || true
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# SELF-TEST MODE
# ═══════════════════════════════════════════════════════════════════════════
if [ "${1:-}" = "--selftest" ]; then
  PASS=0; TOTAL=0
  _ok()   { PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); printf '  PASS  %s\n' "$1"; }
  _fail() { TOTAL=$((TOTAL+1)); printf '  FAIL  %s\n' "$1"; }

  TMPDIR_ST=$(mktemp -d /tmp/hook_event_emit_selftest_XXXXXX)
  trap 'rm -rf "$TMPDIR_ST"' EXIT

  # ── Case 1: emit writes one valid JSON line ─────────────────────────────
  export HOOK_EVENTS_SPOOL="$TMPDIR_ST/spool.jsonl"
  export CLAUDE_SESSION_ID="selftest-session"
  _emit "unit_test_hook" "PreToolUse:blocked" "hello world"
  if [ -f "$HOOK_EVENTS_SPOOL" ] && \
     python3 -c "
import json, sys
line = open(sys.argv[1]).read().strip().splitlines()[-1]
d = json.loads(line)
assert d['hook_name'] == 'unit_test_hook'
assert d['event_type'] == 'PreToolUse:blocked'
assert d['session_id'] == 'selftest-session'
assert d['output_preview'] == 'hello world'
assert 'ts' in d and d['ts']
" "$HOOK_EVENTS_SPOOL" 2>/dev/null; then
    _ok "emit writes valid JSON with expected fields"
  else
    _fail "emit writes valid JSON with expected fields"
  fi

  # ── Case 2: truncation to 200 chars (defense in depth) ──────────────────
  export HOOK_EVENTS_SPOOL="$TMPDIR_ST/spool_trunc.jsonl"
  LONG_PREVIEW=$(python3 -c "print('x' * 500)")
  _emit "unit_test_hook" "PreToolUse:blocked" "$LONG_PREVIEW"
  PREVIEW_LEN=$(python3 -c "
import json
line = open('$HOOK_EVENTS_SPOOL').read().strip().splitlines()[-1]
print(len(json.loads(line)['output_preview']))
" 2>/dev/null || echo -1)
  if [ "$PREVIEW_LEN" -le 200 ] && [ "$PREVIEW_LEN" -gt 0 ]; then
    _ok "output_preview truncated to <=200 chars (got $PREVIEW_LEN)"
  else
    _fail "output_preview truncated to <=200 chars (got $PREVIEW_LEN)"
  fi

  # ── Case 3: a sentinel credential, redacted by the CALLER (secret_leak_guard.sh),
  # never reaches the spool in raw form. This is an integration check against
  # the real redaction pipeline, not a claim that this emitter redacts on its
  # own -- see the header comment. ────────────────────────────────────────
  SCRIPT_DIR_ST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  GUARD="$SCRIPT_DIR_ST/../hooks/secret_leak_guard.sh"
  export HOOK_EVENTS_SPOOL="$TMPDIR_ST/spool_sentinel.jsonl"
  GUARD_LOG_DIR=$(mktemp -d /tmp/hook_event_emit_selftest_guardlog_XXXXXX)
  SENTINEL="ghp_SENTINELDONOTLEAK0123456789AB"
  if [ -f "$GUARD" ]; then
    printf '%s' "{\"tool_input\":{\"command\":\"echo ${SENTINEL}\"}}" \
      | SECRET_GUARD_LOG_DIR="$GUARD_LOG_DIR" bash "$GUARD" >/dev/null 2>&1
    if [ -f "$HOOK_EVENTS_SPOOL" ] && ! grep -q "$SENTINEL" "$HOOK_EVENTS_SPOOL" 2>/dev/null \
       && grep -q "REDACTED" "$HOOK_EVENTS_SPOOL" 2>/dev/null; then
      _ok "planted sentinel credential never reaches the spool (redacted upstream)"
    else
      _fail "planted sentinel credential never reaches the spool (redacted upstream)"
    fi
  else
    _fail "planted sentinel credential never reaches the spool (secret_leak_guard.sh not found at $GUARD)"
  fi
  rm -rf "$GUARD_LOG_DIR"

  # ── Case 4: fail-open when spool dir cannot be created (bad path) ───────
  export HOOK_EVENTS_SPOOL="/nonexistent_root_path_xyz/spool.jsonl"
  RC=0
  _emit "unit_test_hook" "PreToolUse:blocked" "irrelevant" || RC=$?
  if [ "$RC" -eq 0 ]; then
    _ok "emit never fails the caller even when spool path is unwritable"
  else
    _fail "emit never fails the caller even when spool path is unwritable (rc=$RC)"
  fi

  unset HOOK_EVENTS_SPOOL CLAUDE_SESSION_ID
  echo ""
  echo "selftest: $PASS/$TOTAL PASS"
  [ "$PASS" -eq "$TOTAL" ] && exit 0
  exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════
# NORMAL OPERATION
# ═══════════════════════════════════════════════════════════════════════════
_emit "$@"
exit 0
