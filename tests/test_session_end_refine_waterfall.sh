#!/usr/bin/env bash
# tests/test_session_end_refine_waterfall.sh — Refs llm#1123
#
# session_end_refine.sh must use the roborev config default agent (gemini)
# first and fall back to `--agent claude-code --model sonnet` ONLY when the
# first attempt failed for an availability reason. A stub roborev (no real
# refine is ever run) replays canned output + exit codes per call.
#
# Failure strings in fixtures are taken from the real
# ~/.claude/logs/session_end_refine.log.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/.claude/scripts/session_end_refine.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok   - $1"; }
nok()  { FAIL=$((FAIL+1)); echo "FAIL - $1"; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/refine_wf_XXXXXX")
trap 'rm -rf "$TMP"' EXIT

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

# Test repo (needs a remote, or the #1296 guard blocks it as local-only).
REPO="$TMP/proj"
git init -q "$REPO"
git -C "$REPO" remote add origin https://example.invalid/proj.git
git -C "$REPO" commit -q --allow-empty -m init
SHA=$(git -C "$REPO" rev-parse HEAD)

FAKE_HOME="$TMP/home"
mkdir -p "$FAKE_HOME/.claude/logs"
echo "$SHA" > "$FAKE_HOME/.claude/.session_start_sha_proj"
LOG="$FAKE_HOME/.claude/logs/session_end_refine.log"

# Stub roborev: call N prints $SC/outN and exits $SC/rcN; args -> $SC/callsN.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/roborev" <<'STUB'
#!/usr/bin/env bash
n=$(cat "$SC/count" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$SC/count"
echo "$*" > "$SC/calls$n"
[ -f "$SC/out$n" ] && cat "$SC/out$n"
exit "$(cat "$SC/rc$n" 2>/dev/null || echo 0)"
STUB
chmod +x "$TMP/bin/roborev"

# run_case NAME OUT1 RC1 [OUT2 RC2]; env of the caller passes through.
run_case() {
  SC="$TMP/sc_$1"; rm -rf "$SC"; mkdir -p "$SC"; export SC
  printf '%s\n' "$2" > "$SC/out1"; echo "$3" > "$SC/rc1"
  printf '%s\n' "${4:-}" > "$SC/out2"; echo "${5:-0}" > "$SC/rc2"
  : > "$LOG"
  ( cd "$REPO" && HOME="$FAKE_HOME" SESSION_END_REFINE_ROBOREV="$TMP/bin/roborev" \
      bash "$SCRIPT" ) >/dev/null 2>&1
  CALLS=$(cat "$SC/count" 2>/dev/null || echo 0)
}

export SESSION_END_REFINE_GEMINI_BIN=sh   # an executable that certainly exists

# (a) attempt 1 succeeds -> exactly one call, no --agent / --model
run_case a "All reviews passed! Branch is ready." 0
[ "$CALLS" = "1" ] && ok "(a) one call" || nok "(a) one call (got $CALLS)"
if grep -qE -- '--agent|--model' "$SC/calls1" 2>/dev/null; then
  nok "(a) attempt 1 must not pass --agent/--model: $(cat "$SC/calls1")"
else ok "(a) attempt 1 has no --agent/--model"; fi

# (b) quota error on attempt 1 -> second call with claude-code/sonnet
run_case b 'Agent error: gemini failed: exit status 1 (TerminalQuotaError: RESOURCE_EXHAUSTED 429 quota)' 1 "All reviews passed!" 0
[ "$CALLS" = "2" ] && ok "(b) two calls" || nok "(b) two calls (got $CALLS)"
grep -q -- '--agent claude-code --model sonnet' "$SC/calls2" 2>/dev/null \
  && ok "(b) attempt 2 uses claude-code/sonnet" || nok "(b) attempt 2 args: $(cat "$SC/calls2" 2>/dev/null)"
grep -q 'attempt=2' "$LOG" && ok "(b) log records attempt 2" || nok "(b) log lacks attempt=2"

# (b2) real-log strings that are availability failures
for s in \
  'Error: branch review failed: job 9102 failed: agent: gemini failed: exit status 41 (parse error: no valid stream-json events parsed from output)' \
  'Error: failed to enqueue branch review: ... no review agent available: no configured agent available' \
  'Agent error: codex failed: exit status 1 (parse error: codex stream reported failure: Reconnecting... 2/5 (unexpected status 401 Unauthorized' \
  'When using Gemini API, you must specify the GEMINI_API_KEY environment variable.'; do
  run_case b2 "$s"$'\nError: max iterations (3) reached without all reviews passing' 1 "ok" 0
  [ "$CALLS" = "2" ] && ok "(b2) falls back on: ${s:0:60}" || nok "(b2) no fallback on: ${s:0:60}"
done

# (c) non-availability failures -> no second call
for s in \
  'Error: working tree not clean - commit or stash your changes first' \
  'Error: --since "abc" is not an ancestor of HEAD' \
  'Error: max iterations (3) reached without all reviews passing'; do
  run_case c "$s" 1 "should not run" 0
  [ "$CALLS" = "1" ] && ok "(c) no fallback on: ${s:0:60}" || nok "(c) fell back on: ${s:0:60}"
done

# (d) unknown failure: no fallback by default, fallback with the toggle
run_case d "something nobody has ever seen" 1 "ok" 0
[ "$CALLS" = "1" ] && ok "(d) unknown -> no fallback" || nok "(d) unknown fell back (got $CALLS)"
grep -q 'INDETERMINATE' "$LOG" && ok "(d) logged INDETERMINATE" || nok "(d) no INDETERMINATE in log"
SESSION_END_REFINE_FALLBACK_ON_UNKNOWN=1 run_case d2 "something nobody has ever seen" 1 "ok" 0
[ "$CALLS" = "2" ] && ok "(d) toggle -> fallback" || nok "(d) toggle did not fall back (got $CALLS)"

# (e) gemini absent -> straight to claude-code, one call, logged
SESSION_END_REFINE_GEMINI_BIN=definitely-not-a-binary-xyz run_case e "ok" 0
[ "$CALLS" = "1" ] && ok "(e) one call" || nok "(e) calls=$CALLS"
grep -q -- '--agent claude-code --model sonnet' "$SC/calls1" 2>/dev/null \
  && ok "(e) goes straight to claude-code" || nok "(e) args: $(cat "$SC/calls1" 2>/dev/null)"
grep -q 'gemini-absent' "$LOG" && ok "(e) logged gemini-absent" || nok "(e) no gemini-absent in log"

# (f) dry-run prints both planned attempts and never calls roborev
SC="$TMP/sc_f"; mkdir -p "$SC"; export SC; rm -f "$SC/count"
OUT=$( cd "$REPO" && HOME="$FAKE_HOME" SESSION_END_REFINE_DRYRUN=1 \
  SESSION_END_REFINE_ROBOREV="$TMP/bin/roborev" bash "$SCRIPT" 2>&1 )
echo "$OUT" | grep -q 'attempt 1' && echo "$OUT" | grep -q 'attempt 2' \
  && ok "(f) dry-run lists both attempts" || nok "(f) dry-run output: $OUT"
echo "$OUT" | grep -q 'codex' && nok "(f) dry-run still mentions codex" || ok "(f) no codex"
[ ! -f "$SC/count" ] && ok "(f) dry-run made no roborev call" || nok "(f) dry-run called roborev"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
