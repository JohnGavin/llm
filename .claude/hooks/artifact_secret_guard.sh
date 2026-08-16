#!/usr/bin/env bash
# artifact_secret_guard.sh — content guard on `Artifact` publishes: reads the
# file about to be published and blocks if it contains a literal credential.
# Hook: PreToolUse:Artifact
#
# Source: llm#960 Part 3. `Artifact` publishes a page to a hosted claude.ai
# URL other people can read — the closest analogue this project has to the
# 2026-08-11 secret-splice incident that secret-leak-prevention.md exists to
# prevent, and until this guard nothing inspected what left the machine
# through it. This mirrors Rule 5 of secret_leak_guard.sh (`gh --body-file
# <path>` CONTENTS inspection) pointed at a different input source
# (`tool_input.file_path` instead of a `--body-file` argument) — same
# CRED_PATTERNS catalogue, same fail-open contract, same no-bypass policy.
#
# What is already established (do not re-derive):
#   - A PreToolUse hook DOES fire for the Artifact matcher (proven by live
#     tool_input_probe.sh rows — see secret-leak-prevention.md's "ANSWERED
#     2026-08-14" section).
#   - tool_input carries a `file_path` string, and the file exists on disk at
#     hook time (a real publish on 2026-08-16 produced
#     `keys=[description=string:147,favicon=string:1,file_path=string:153,
#     file_path_exists=True]`). tool_input carries NO page content, so
#     reading the file named by file_path is the only way to inspect it.
#
# What is NOT established (see "BLOCK MECHANISM" below): whether the exit-2
# BLOCK mechanism (proven for Bash) also blocks a non-Bash tool call. This
# guard uses the mechanism Claude Code's own docs describe as the general
# PreToolUse contract for ALL tools (not just Bash) — see below — because
# that is the one with documented support; exit 2 for Bash-only guards is a
# narrower, Bash-specific description. State plainly in any report using
# this guard whether a real Artifact publish confirmed the block.
#
# Runs ALONGSIDE tool_input_probe.sh (not a replacement — see settings.json's
# comment on the Artifact matcher for why both stay wired).
#
# Self-test: bash artifact_secret_guard.sh --selftest
#
# Rule: .claude/rules/secret-leak-prevention.md
#   (## Egress-Matcher Feasibility Probe, llm#960 Part 3)

set -uo pipefail

# Resolve sibling scripts relative to THIS script's own location, not a
# hardcoded ~/.claude/... path — ~/.claude/hooks/ and ~/.claude/scripts/ are
# symlinks into the main checkout in production, so a hardcoded path would
# silently point at the main checkout's copy even under worktree-isolated
# testing. Same rationale as HOOK_EVENT_EMIT_SCRIPT in secret_leak_guard.sh
# and tool_input_probe.sh.
export HOOK_EVENT_EMIT_SCRIPT="${BASH_SOURCE[0]%/*}/../scripts/hook_event_emit.sh"
export CRED_PATTERNS_LIB_DIR="${BASH_SOURCE[0]%/*}/lib"

PY_CODE=$(cat <<'PYEOF'
import sys, json, os, re, datetime, subprocess

# CRED_PATTERNS is imported from the single shared definition in
# lib/cred_patterns.py (llm#960 Part 3) — NEVER redefined here. A second
# copy would recreate the exact drift risk llm#958 was raised and fixed for
# (secret_leak_guard.sh's own header carries the same warning). See
# CRED_PATTERNS_LIB_DIR (set above, before this heredoc is captured).
_CRED_LIB_DIR = os.environ.get('CRED_PATTERNS_LIB_DIR', '')
if _CRED_LIB_DIR and _CRED_LIB_DIR not in sys.path:
    sys.path.insert(0, _CRED_LIB_DIR)
try:
    from cred_patterns import CRED_PATTERNS
except Exception:
    # Fail-open: a missing/unreadable shared lib must never crash the hook
    # or wedge a publish. This silently disables the guard rather than
    # reintroducing a second copy of the pattern list here.
    CRED_PATTERNS = []

LOG_DIR = os.environ.get('ARTIFACT_GUARD_LOG_DIR') or os.path.expanduser('~/.claude/logs')
LOG_FILE = os.path.join(LOG_DIR, 'artifact_secret_guard.log')

# Same cap Rule 5 uses (256 KiB) — a real artifact HTML/markdown file is
# never anywhere near this size for the credential to hide past; the cap
# exists so a huge file can never stall a publish.
FILE_READ_CAP = 262144


def _utc_ts():
    return datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def _append(path, line):
    try:
        os.makedirs(LOG_DIR, exist_ok=True)
        with open(path, 'a') as fh:
            fh.write(line + '\n')
    except Exception:
        pass  # logging must never block a publish


def log_block(file_path, line_num, desc):
    _append(LOG_FILE, '%s\tfile=%s\tline=%d\t%s' % (_utc_ts(), file_path, line_num, desc))


def emit_hook_event(event_type, preview):
    # Fire-and-forget telemetry (llm#950 pattern) — NEVER allowed to affect
    # the block decision, so every failure mode here is swallowed locally.
    try:
        script = os.environ.get('HOOK_EVENT_EMIT_SCRIPT', '') \
            or os.path.expanduser('~/.claude/scripts/hook_event_emit.sh')
        if script and os.path.exists(script):
            subprocess.run(
                ['bash', script, 'artifact_secret_guard', event_type, preview],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=2,
            )
    except Exception:
        pass


def deny(file_path, line_num, desc):
    # BLOCK MECHANISM: exit 0 + a JSON permissionDecision:"deny" body on
    # stdout. This is the mechanism documented for PreToolUse across ALL
    # tools (not just Bash) — see this script's header. Whether the
    # Bash-proven exit-2 mechanism ALSO works for Artifact is unverified; if
    # this JSON form turns out not to block in practice, that is the signal
    # to switch to exit 2 (or emit both).
    #
    # NEVER include the matched value — file, line number, and the
    # credential DESCRIPTION only (mirrors secret_leak_guard.sh's redaction
    # discipline; there is nothing here to redact because the value itself
    # is never read into a variable in the first place, only matched).
    reason = (
        'BLOCKED (artifact_secret_guard): credential-shaped content in %s at line %d: %s. '
        'Remove the credential from the file before publishing it as an Artifact -- there is '
        'no bypass for this rule (mirrors secret_leak_guard.sh Rules 4/5: a spliced credential '
        'is a spliced credential regardless of which tool publishes it). '
        'Log: %s' % (file_path, line_num, desc, LOG_FILE)
    )
    log_block(file_path, line_num, desc)
    emit_hook_event('PreToolUse:blocked', 'file=%s line=%d desc=%s' % (file_path, line_num, desc))
    output = {
        'hookSpecificOutput': {
            'hookEventName': 'PreToolUse',
            'permissionDecision': 'deny',
            'permissionDecisionReason': reason,
        }
    }
    sys.stdout.write(json.dumps(output))
    sys.exit(0)


def main():
    raw = sys.stdin.read()
    try:
        data = json.loads(raw)
    except Exception:
        return  # fail open: malformed JSON must never block or crash
    if not isinstance(data, dict):
        return
    tool_input = data.get('tool_input')
    if not isinstance(tool_input, dict):
        return
    file_path = tool_input.get('file_path')
    if not file_path or not isinstance(file_path, str):
        return  # fail open: nothing to inspect

    content = None
    try:
        path = os.path.expanduser(file_path)
        if os.path.isfile(path):
            with open(path, 'r', errors='replace') as fh:
                content = fh.read(FILE_READ_CAP)
    except Exception:
        # Fail OPEN: missing/unreadable/directory/permission-denied must
        # never crash the hook or block a publish that has nothing to do
        # with this guard's own I/O failure.
        content = None
    if not content:
        return

    if not CRED_PATTERNS:
        return  # shared lib unavailable — fail open, see the import above

    for line_num, line in enumerate(content.splitlines(), start=1):
        for pat, desc in CRED_PATTERNS:
            if re.search(pat, line):
                deny(file_path, line_num, desc)
                return  # unreachable (deny() calls sys.exit), kept for clarity


try:
    main()
except SystemExit:
    raise
except Exception:
    pass  # fail-open: any unhandled internal error allows the publish
sys.exit(0)
PYEOF
)

run_guard() {
  # $1 = raw stdin JSON. Writes any deny JSON to real stdout (Claude Code
  # reads it there); otherwise stdout stays empty and the publish proceeds.
  printf '%s' "$1" | python3 -c "$PY_CODE"
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# SELF-TEST MODE
# ═══════════════════════════════════════════════════════════════════════════
if [ "${1:-}" = "--selftest" ]; then
  TMP_DIR=$(mktemp -d /tmp/artifact_secret_guard_selftest_XXXXXX)
  export ARTIFACT_GUARD_LOG_DIR="$TMP_DIR/logs"
  export HOOK_EVENTS_SPOOL="$TMP_DIR/hook_events_staging.jsonl"

  TOTAL=0
  PASS=0

  _payload_for_file() {
    python3 -c 'import json, sys; print(json.dumps({"tool_input": {"file_path": sys.argv[1], "title": "t", "favicon": "x"}}))' "$1"
  }

  _case_block() {
    local desc="$1" file_path="$2"
    TOTAL=$((TOTAL + 1))
    local payload out
    payload=$(_payload_for_file "$file_path")
    out=$(run_guard "$payload")
    if printf '%s' "$out" | grep -q '"permissionDecision": *"deny"' 2>/dev/null \
       || printf '%s' "$out" | grep -q '"permissionDecision":"deny"' 2>/dev/null; then
      PASS=$((PASS + 1))
      printf 'PASS  [BLOCK] %s\n' "$desc"
    else
      printf 'FAIL  [want=BLOCK got=ALLOW] %s\n' "$desc"
      printf '      stdout: %s\n' "$out"
    fi
  }

  _case_allow() {
    local desc="$1" file_path="$2"
    TOTAL=$((TOTAL + 1))
    local payload out
    payload=$(_payload_for_file "$file_path")
    out=$(run_guard "$payload")
    if [ -z "$out" ]; then
      PASS=$((PASS + 1))
      printf 'PASS  [ALLOW] %s\n' "$desc"
    else
      printf 'FAIL  [want=ALLOW got=BLOCK] %s\n' "$desc"
      printf '      stdout: %s\n' "$out"
    fi
  }

  # ── MUST BLOCK ──────────────────────────────────────────────────────────
  printf '<html><body>\nHere is my token: ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123\n</body></html>\n' \
    > "$TMP_DIR/with_cred.html"
  _case_block "published file contains a literal ghp_ credential" "$TMP_DIR/with_cred.html"

  printf '<html><body>\nAnthropic key: sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n</body></html>\n' \
    > "$TMP_DIR/with_sk_ant.html"
  _case_block "published file contains a literal sk-ant- credential" "$TMP_DIR/with_sk_ant.html"

  printf 'line1\nline2\nline3\nAKIAIOSFODNN7EXAMPLE\nline5\n' > "$TMP_DIR/with_aws.html"
  _case_block "credential on a non-first line is still found (line number tracked)" "$TMP_DIR/with_aws.html"

  # ── MUST ALLOW (regression guards — over-blocking is a real cost) ───────
  printf '<html><body>\n<h1>My dashboard</h1>\n<p>No secrets here.</p>\n</body></html>\n' \
    > "$TMP_DIR/clean.html"
  _case_allow "clean published file, no credential shapes" "$TMP_DIR/clean.html"

  _case_allow "missing file_path target — fail open, no block" "$TMP_DIR/does_not_exist_xyz.html"

  _case_allow "file_path points at a directory — fail open, no block" "$TMP_DIR"

  printf 'ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123\n' > "$TMP_DIR/unreadable.html"
  chmod 000 "$TMP_DIR/unreadable.html"
  _case_allow "file_path points at an unreadable file — fail open, no block" "$TMP_DIR/unreadable.html"
  chmod 644 "$TMP_DIR/unreadable.html"

  # ── Malformed / absent-key inputs never crash or block ───────────────────
  TOTAL=$((TOTAL + 1))
  OUT=$(printf '%s' '{not valid json' | python3 -c "$PY_CODE" 2>/dev/null)
  if [ -z "$OUT" ]; then
    PASS=$((PASS + 1))
    printf 'PASS  [ALLOW] malformed JSON on stdin does not block or crash\n'
  else
    printf 'FAIL  [want=ALLOW got=%s] malformed JSON on stdin does not block or crash\n' "$OUT"
  fi

  TOTAL=$((TOTAL + 1))
  PAYLOAD_NOFP=$(python3 -c 'import json; print(json.dumps({"tool_input": {"title": "t"}}))')
  OUT=$(run_guard "$PAYLOAD_NOFP")
  if [ -z "$OUT" ]; then
    PASS=$((PASS + 1))
    printf 'PASS  [ALLOW] tool_input with no file_path key does not block\n'
  else
    printf 'FAIL  [want=ALLOW got=%s] tool_input with no file_path key does not block\n' "$OUT"
  fi

  TOTAL=$((TOTAL + 1))
  PAYLOAD_NUMFP=$(python3 -c 'import json; print(json.dumps({"tool_input": {"file_path": 12345}}))')
  OUT=$(run_guard "$PAYLOAD_NUMFP")
  if [ -z "$OUT" ]; then
    PASS=$((PASS + 1))
    printf 'PASS  [ALLOW] non-string file_path does not block or crash\n'
  else
    printf 'FAIL  [want=ALLOW got=%s] non-string file_path does not block or crash\n' "$OUT"
  fi

  # ── Never leak the matched value into the deny reason or the log ─────────
  TOTAL=$((TOTAL + 1))
  SENTINEL="ghp_SENTINELDONOTLEAK0123456789AB"
  printf '%s\n' "$SENTINEL" > "$TMP_DIR/sentinel.html"
  PAYLOAD_SENTINEL=$(_payload_for_file "$TMP_DIR/sentinel.html")
  OUT=$(run_guard "$PAYLOAD_SENTINEL")
  if printf '%s' "$OUT" | grep -q '"permissionDecision":"deny"\|"permissionDecision": *"deny"' \
     && ! printf '%s' "$OUT" | grep -q "$SENTINEL" \
     && [ -f "$ARTIFACT_GUARD_LOG_DIR/artifact_secret_guard.log" ] \
     && ! grep -q "$SENTINEL" "$ARTIFACT_GUARD_LOG_DIR/artifact_secret_guard.log"; then
    PASS=$((PASS + 1))
    printf 'PASS  [BLOCK] sentinel credential value never appears in deny reason or log\n'
  else
    printf 'FAIL  [BLOCK] sentinel credential value never appears in deny reason or log\n'
    printf '      stdout: %s\n' "$OUT"
  fi

  # ── llm#958-style dedup guard: CRED_PATTERNS entries must be defined in ──
  # exactly ONE file under .claude/hooks/** — mirrors rotate_secret.sh's
  # "each CONSUMERS_* name defined exactly once" check (llm#958) applied to
  # this catalogue instead of the consumer map. Uses one of the more
  # distinctive pattern literals (the ghp_ regex) as the marker: it should
  # appear in lib/cred_patterns.py and NOWHERE else under .claude/hooks/**.
  # THIS test script's own source necessarily quotes that same literal (as
  # the search needle) and the string is split across two shell variables so
  # the concatenated marker text is never adjacent in this file's own bytes
  # — it is built at runtime, not present as one contiguous literal here —
  # so this file does not trip its own check; __pycache__/*.pyc (bytecode
  # cache, gitignored, never a source-of-truth copy) is pruned explicitly.
  HOOKS_DIR="${BASH_SOURCE[0]%/*}"
  _ghp_prefix='ghp_'
  _ghp_suffix='[A-Za-z0-9]{20,}'
  MARKER_TEXT="${_ghp_prefix}${_ghp_suffix}"
  TOTAL=$((TOTAL + 1))
  DUP_FILES=$(find "$HOOKS_DIR" -type f \( -name '*.sh' -o -name '*.py' \) \
      ! -path '*/__pycache__/*' 2>/dev/null \
      | xargs grep -lF -- "$MARKER_TEXT" 2>/dev/null)
  DUP_COUNT=$(printf '%s\n' "$DUP_FILES" | grep -c . 2>/dev/null || echo 0)
  if [ "$DUP_COUNT" = "1" ]; then
    PASS=$((PASS + 1))
    printf 'PASS  [1 FILE ] CRED_PATTERNS entries defined in exactly one file under .claude/hooks/** (%s)\n' "$DUP_FILES"
  else
    printf 'FAIL  [want=1 got=%s] CRED_PATTERNS entries defined in exactly one file under .claude/hooks/**\n' "$DUP_COUNT"
    printf '%s\n' "$DUP_FILES"
  fi

  TOTAL=$((TOTAL + 1))
  MARKER_COUNT=$(grep -rl 'secret-exposure-scan: pattern-definitions' "$HOOKS_DIR/lib" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$MARKER_COUNT" -ge 1 ]; then
    PASS=$((PASS + 1))
    printf 'PASS  [MARKER] lib/cred_patterns.py carries the secret-exposure-scan self-reference marker\n'
  else
    printf 'FAIL  [MARKER] lib/cred_patterns.py carries the secret-exposure-scan self-reference marker\n'
  fi

  rm -rf "$TMP_DIR"

  echo ""
  echo "selftest: $PASS/$TOTAL PASS"
  [ "$PASS" -eq "$TOTAL" ] && exit 0
  exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════
# NORMAL HOOK OPERATION
# ═══════════════════════════════════════════════════════════════════════════
INPUT=$(cat)
run_guard "$INPUT"
exit 0
