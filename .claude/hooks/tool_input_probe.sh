#!/usr/bin/env bash
#
# hook-liveness: every-call
#   Read by the hook-liveness section of send_overnight_self_review_email.R
#   (llm#1017). a probe: emits one row per invocation, so a
#   7-day count of zero in that report is a genuine alert: the hook should have emitted on every invocation.
#   Declared here rather than in a list kept by the report, so it stays true
#   when this file changes -- the same reason rules carry their own `paths:`.
# tool_input_probe.sh — records the SHAPE of tool_input (never its values)
# for hook matchers under investigation (llm#960 Part 3).
# Hook: PreToolUse:Artifact, PreToolUse:WebFetch (and any future matcher
# where we first need to know what tool_input carries before designing a
# real content-inspecting guard for it).
#
# Usage: tool_input_probe.sh <hook_name>
#   Reads the hook JSON on stdin, extracts tool_input, and emits ONE
#   hook_events row (via hook_event_emit.sh) whose preview is a compact
#   summary of tool_input's shape: sorted key names, each key's JSON type,
#   and — for strings — its LENGTH. Nothing else. `file_path` gets one extra
#   bit: whether the path it names exists on disk (the path STRING itself is
#   recorded — a path is not a credential — but nothing the path points at is
#   ever read).
#
# THE ONE RULE THIS FILE EXISTS TO ENFORCE: never record a value, a
# substring of a value, or file contents. This probe was written because of
# a credential-leak incident (see secret-leak-prevention.md); it must not
# become one. See --selftest case 4 for the sentinel-value proof.
#
# Contract: NEVER blocks (always exit 0, on every path — malformed JSON,
# absent python3, unreadable stdin, an emitter that fails). NEVER writes to
# stdout (a PreToolUse hook's stdout can perturb the harness protocol; all
# output goes to the hook_events spool via hook_event_emit.sh). This runs
# before a user-visible action (an Artifact publish); a probe that can wedge
# that action is unacceptable.
#
# Self-test: bash tool_input_probe.sh --selftest
#
# Rule: .claude/rules/secret-leak-prevention.md
#   (## Egress-Matcher Feasibility Probe, llm#960 Part 3)

set -uo pipefail

# Resolve hook_event_emit.sh relative to THIS script's own location, not a
# hardcoded ~/.claude/scripts/... path. ~/.claude/hooks/ and
# ~/.claude/scripts/ are symlinks into the main checkout in production, so a
# hardcoded expanduser path would silently point at the main checkout's copy
# even when this script is under test inside a worktree — the exact
# rationale documented in secret_leak_guard.sh (llm#950). Pure parameter
# expansion, no `cd`/`pwd` subshell.
export HOOK_EVENT_EMIT_SCRIPT="${BASH_SOURCE[0]%/*}/../scripts/hook_event_emit.sh"

# ─── Shape extraction, in one python3 process ───────────────────────────────
# Reads the hook JSON on stdin, walks tool_input's top-level keys (sorted),
# and prints a single-line, field-boundary-safe preview: "key=type[:length]"
# per key, joined by commas, wrapped in "keys=[...]". Never touches a value.
# Truncation happens by DROPPING whole trailing fields once a budget is hit
# (never by cutting a field in half), so the caller's hard 200-char
# truncation in hook_event_emit.sh never lands mid-field.
PY_CODE=$(cat <<'PYEOF'
import sys, json, os

def type_name(v):
    # Order matters: bool is a subclass of int in Python, so it must be
    # checked before the int/float branch or every bool would report as
    # "number".
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "bool"
    if isinstance(v, str):
        return "string:%d" % len(v)
    if isinstance(v, (int, float)):
        return "number"
    if isinstance(v, list):
        return "array:%d" % len(v)
    if isinstance(v, dict):
        return "object:%d" % len(v)
    return "unknown"


def main():
    raw = sys.stdin.read()
    try:
        data = json.loads(raw)
    except Exception:
        return
    if not isinstance(data, dict):
        return
    tool_input = data.get('tool_input')
    if not isinstance(tool_input, dict):
        sys.stdout.write("keys=(none)")
        return

    entries = []
    for k in sorted(tool_input.keys()):
        entries.append("%s=%s" % (k, type_name(tool_input[k])))

    # file_path: the one key we want more than shape for — does the path it
    # names exist on disk? The path STRING is fine to record (not a
    # credential); nothing it points at is ever opened or read.
    fp = tool_input.get('file_path')
    if isinstance(fp, str):
        try:
            exists = os.path.exists(os.path.expanduser(fp))
        except Exception:
            exists = False
        entries.append("file_path_exists=%s" % exists)

    # Budget the preview well under hook_event_emit.sh's 200-char hard
    # truncation so nothing is silently cut mid-field. Drop whole trailing
    # entries rather than truncating the joined string.
    MAX_LEN = 190
    prefix, suffix = "keys=[", "]"
    budget = MAX_LEN - len(prefix) - len(suffix)
    kept = []
    used = 0
    dropped = False
    for e in entries:
        add = len(e) + (1 if kept else 0)  # +1 for the joining comma
        if used + add > budget:
            dropped = True
            break
        kept.append(e)
        used += add
    body = ",".join(kept)
    if dropped:
        body += ",..." if kept else "..."
    sys.stdout.write(prefix + body + suffix)


try:
    main()
except Exception:
    pass  # fail-open: any unhandled internal error records nothing
PYEOF
)

_run_probe() {
  # $1 = hook_name, stdin = the hook JSON. Never touches real stdout;
  # everything goes to the hook_events spool via hook_event_emit.sh.
  local hook_name="${1:-tool_input_probe}"
  local preview=""
  if command -v python3 >/dev/null 2>&1; then
    preview=$(python3 -c "$PY_CODE" 2>/dev/null) || preview=""
  fi
  if [ -n "$preview" ]; then
    local script="${HOOK_EVENT_EMIT_SCRIPT:-}"
    if [ -n "$script" ] && [ -f "$script" ]; then
      bash "$script" "$hook_name" "PreToolUse:fired" "$preview" >/dev/null 2>&1 || true
    fi
  fi
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# SELF-TEST MODE
# ═══════════════════════════════════════════════════════════════════════════
if [ "${1:-}" = "--selftest" ]; then
  PASS=0; TOTAL=0
  _ok()   { PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); printf '  PASS  %s\n' "$1"; }
  _fail() { TOTAL=$((TOTAL+1)); printf '  FAIL  %s\n' "$1"; }

  TMPDIR_ST=$(mktemp -d /tmp/tool_input_probe_selftest_XXXXXX)
  trap 'rm -rf "$TMPDIR_ST"' EXIT
  export CLAUDE_SESSION_ID="selftest-session"
  SELF="${BASH_SOURCE[0]}"

  # ── Case 1: realistic Artifact payload ───────────────────────────────────
  export HOOK_EVENTS_SPOOL="$TMPDIR_ST/spool1.jsonl"
  PAYLOAD1=$(python3 -c 'import json; print(json.dumps({
      "tool_name": "Artifact",
      "tool_input": {
          "file_path": "/tmp/foo.html",
          "title": "Foo",
          "favicon": "chart",
          "description": "A test artifact"
      }
  }))')
  RC=0
  printf '%s' "$PAYLOAD1" | bash "$SELF" artifact_probe || RC=$?
  if [ "$RC" -eq 0 ] && [ -f "$HOOK_EVENTS_SPOOL" ] \
     && grep -q "artifact_probe" "$HOOK_EVENTS_SPOOL" \
     && grep -q "file_path=string" "$HOOK_EVENTS_SPOOL"; then
    _ok "realistic Artifact payload emits a row with key shapes, exit 0"
  else
    _fail "realistic Artifact payload emits a row with key shapes, exit 0"
  fi

  # ── Case 2: nested object (e.g. capabilities) recorded as object:N, ─────
  # never expanded into its own keys/values.
  export HOOK_EVENTS_SPOOL="$TMPDIR_ST/spool2.jsonl"
  PAYLOAD2=$(python3 -c 'import json; print(json.dumps({
      "tool_name": "Artifact",
      "tool_input": {
          "file_path": "/tmp/bar.html",
          "capabilities": {"live_data": {"nested": "value"}}
      }
  }))')
  RC=0
  printf '%s' "$PAYLOAD2" | bash "$SELF" artifact_probe || RC=$?
  if [ "$RC" -eq 0 ] && [ -f "$HOOK_EVENTS_SPOOL" ] \
     && grep -q "capabilities=object:1" "$HOOK_EVENTS_SPOOL" \
     && ! grep -q "live_data" "$HOOK_EVENTS_SPOOL" \
     && ! grep -q "nested" "$HOOK_EVENTS_SPOOL"; then
    _ok "nested object recorded as object:N, contents never expanded"
  else
    _fail "nested object recorded as object:N, contents never expanded"
  fi

  # ── Case 3: malformed JSON must still exit 0 (no block, no crash) ───────
  export HOOK_EVENTS_SPOOL="$TMPDIR_ST/spool3.jsonl"
  RC=0
  printf '{not valid json' | bash "$SELF" artifact_probe || RC=$?
  if [ "$RC" -eq 0 ]; then
    _ok "malformed JSON on stdin does not block (exit 0)"
  else
    _fail "malformed JSON on stdin does not block (exit 0)"
  fi

  # ── Case 4: THE critical case — a sentinel VALUE placed in the payload ──
  # must never appear anywhere in the emitted row. This is the no-values
  # rule proven, not asserted.
  export HOOK_EVENTS_SPOOL="$TMPDIR_ST/spool4.jsonl"
  SENTINEL="SENTINEL_DO_NOT_LEAK_9f8e7d6c5b4a"
  PAYLOAD4=$(python3 -c 'import json, sys
print(json.dumps({
    "tool_name": "Artifact",
    "tool_input": {
        "file_path": "/tmp/baz.html",
        "title": sys.argv[1],
        "description": sys.argv[1],
        "url": "https://example.com/" + sys.argv[1]
    }
}))' "$SENTINEL")
  RC=0
  printf '%s' "$PAYLOAD4" | bash "$SELF" artifact_probe || RC=$?
  if [ "$RC" -eq 0 ] && [ -f "$HOOK_EVENTS_SPOOL" ] \
     && ! grep -q "$SENTINEL" "$HOOK_EVENTS_SPOOL" \
     && grep -q "title=string" "$HOOK_EVENTS_SPOOL" \
     && grep -q "url=string" "$HOOK_EVENTS_SPOOL"; then
    _ok "sentinel VALUE never reaches the emitted row (key+type+length only)"
  else
    _fail "sentinel VALUE never reaches the emitted row (key+type+length only)"
  fi

  # ── Case 5: absent python3 still fails open (exit 0, no row) ────────────
  # A bare PATH override would also take out `cat`/`bash` themselves (the
  # script's own PY_CODE heredoc capture uses `cat`, same established
  # pattern as secret_leak_guard.sh), which would test "shell utilities
  # missing" rather than "python3 missing". Build a minimal PATH that keeps
  # every OTHER utility the script needs (bash, cat, and friends) but
  # deliberately omits python3, so this case isolates exactly the condition
  # named in the fixer brief.
  FAKE_BIN="$TMPDIR_ST/fakebin"
  mkdir -p "$FAKE_BIN"
  for c in bash cat sh grep sed head mktemp dirname basename; do
    real_c=$(command -v "$c" 2>/dev/null) || continue
    ln -sf "$real_c" "$FAKE_BIN/$c"
  done
  export HOOK_EVENTS_SPOOL="$TMPDIR_ST/spool5.jsonl"
  PAYLOAD5=$(python3 -c 'import json; print(json.dumps({"tool_name": "Artifact", "tool_input": {"file_path": "/tmp/x.html"}}))')
  RC=0
  printf '%s' "$PAYLOAD5" | PATH="$FAKE_BIN" "$FAKE_BIN/bash" "$SELF" artifact_probe || RC=$?
  if [ "$RC" -eq 0 ] && { [ ! -f "$HOOK_EVENTS_SPOOL" ] || ! grep -q "artifact_probe" "$HOOK_EVENTS_SPOOL"; }; then
    _ok "python3 unavailable (PATH without it) still exits 0, no row emitted"
  else
    _fail "python3 unavailable (PATH without it) still exits 0, no row emitted"
  fi

  # ── Case 6: file_path existence check works, records a boolean only ─────
  export HOOK_EVENTS_SPOOL="$TMPDIR_ST/spool6.jsonl"
  REAL_FILE="$TMPDIR_ST/exists.html"
  echo "hi" > "$REAL_FILE"
  PAYLOAD6=$(python3 -c 'import json, sys; print(json.dumps({"tool_name": "Artifact", "tool_input": {"file_path": sys.argv[1]}}))' "$REAL_FILE")
  RC=0
  printf '%s' "$PAYLOAD6" | bash "$SELF" artifact_probe || RC=$?
  if [ "$RC" -eq 0 ] && [ -f "$HOOK_EVENTS_SPOOL" ] \
     && grep -q "file_path_exists=True" "$HOOK_EVENTS_SPOOL"; then
    _ok "file_path existence correctly detected as True for a real file"
  else
    _fail "file_path existence correctly detected as True for a real file"
  fi

  # ── Case 7: missing file_path target records False, not an error ───────
  export HOOK_EVENTS_SPOOL="$TMPDIR_ST/spool7.jsonl"
  PAYLOAD7=$(python3 -c 'import json; print(json.dumps({"tool_name": "Artifact", "tool_input": {"file_path": "/tmp/definitely_does_not_exist_xyz_12345.html"}}))')
  RC=0
  printf '%s' "$PAYLOAD7" | bash "$SELF" artifact_probe || RC=$?
  if [ "$RC" -eq 0 ] && [ -f "$HOOK_EVENTS_SPOOL" ] \
     && grep -q "file_path_exists=False" "$HOOK_EVENTS_SPOOL"; then
    _ok "missing file_path target records False, no crash"
  else
    _fail "missing file_path target records False, no crash"
  fi

  unset HOOK_EVENTS_SPOOL CLAUDE_SESSION_ID
  echo ""
  echo "selftest: $PASS/$TOTAL PASS"
  [ "$PASS" -eq "$TOTAL" ] && exit 0
  exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════
# NORMAL HOOK OPERATION
# ═══════════════════════════════════════════════════════════════════════════
_run_probe "${1:-tool_input_probe}"
exit 0
