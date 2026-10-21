#!/usr/bin/env bash
# llm#1494: bin/publish_roborev_data.sh exited 1 and its own output never said why, so
# the overnight email could only show "publish_roborev_data.sh failed (exit=1)". It now
# writes ONE stderr line (<= 160 chars) naming the failing step and exit code, and
# never anything from the review snapshot it was publishing.
#
# HOME is scratch, the lock file is overridden, no network or real repo is touched
# (the "telemetry repo" is an empty directory with a bare .git directory).
# Bash 3.2 compatible.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
SCRIPT="$ROOT/bin/publish_roborev_data.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/publish_reason_test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "ok: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
chk()  { if [ "$2" = "0" ]; then ok "$1"; else fail "$1"; fi; }

MARK="REVIEWTEXT_MARKER_5521"
RC=0
fresh_home() {
    rm -rf "$WORK/home"; mkdir -p "$WORK/home/.claude/logs" "$WORK/home/docs_gh"
}
run() {   # script env-assignments...
    local s="$1"; shift
    # GIT_CEILING_DIRECTORIES: the fake repo is not a repo, so git must not walk up into a real one
    ( env HOME="$WORK/home" PUBLISH_ROBOREV_LOCK_FILE="$WORK/lock" GIT_CEILING_DIRECTORIES="$WORK" "$@" bash "$s" ) > "$WORK/out" 2> "$WORK/err"
    RC=$?
}
errlines() { wc -l < "$WORK/err" | tr -d ' '; }

# ---- A. telemetry repo missing ---------------------------------------------------
fresh_home
run "$SCRIPT"
[ "$RC" = "1" ]; chk "A: still exits 1" "$?"
[ "$(errlines)" = "1" ]; chk "A: exactly ONE stderr line" "$?"
grep -q 'step=verify-repo exit=1' "$WORK/err"; chk "A: it names the step and the exit code" "$?"
[ "$(awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }' "$WORK/err")" -le 160 ]; chk "A: capped at 160 characters" "$?"

# ---- B. source directory missing ---------------------------------------------------
fresh_home; mkdir -p "$WORK/home/docs_gh/llmtelemetry/.git"
run "$SCRIPT" ROBOREV_DAILY_DIR="$WORK/home/nope"
[ "$RC" = "1" ] && [ "$(errlines)" = "1" ] && grep -q 'step=source-dir exit=1' "$WORK/err"; chk "B: missing source dir -> one line, step=source-dir" "$?"

# ---- C. no snapshot ---------------------------------------------------------------------
mkdir -p "$WORK/home/snap"
run "$SCRIPT" ROBOREV_DAILY_DIR="$WORK/home/snap"
[ "$RC" = "1" ] && [ "$(errlines)" = "1" ] && grep -q 'step=find-snapshot exit=1' "$WORK/err"; chk "C: empty source dir -> one line, step=find-snapshot" "$?"

# ---- D. git fetch fails (not a git repo); the real exit code is reported, no content -----
printf '{"note":"%s"}\n' "$MARK" > "$WORK/home/snap/2026-10-21.json"
run "$SCRIPT" ROBOREV_DAILY_DIR="$WORK/home/snap"
[ "$RC" = "1" ]; chk "D: a failed fetch still exits 1" "$?"
[ "$(errlines)" = "1" ] && grep -qE 'step=git-fetch exit=[0-9]+' "$WORK/err"; chk "D: one line naming step=git-fetch and git's exit code" "$?"
! grep -q "$MARK" "$WORK/err" "$WORK/out"; chk "D: no snapshot (review) content on stderr or stdout" "$?"
! grep -q "$MARK" "$WORK/home/.claude/logs/publish_roborev_data.log"; chk "D: none in the script's own log either" "$?"
grep -q 'step=git-fetch' "$WORK/home/.claude/logs/publish_roborev_data.log"; chk "D: the reason is also in the script's own log" "$?"

# ---- E. the success-shaped paths are untouched --------------------------------------------
run "$SCRIPT" DRYRUN=1
[ "$RC" = "0" ] && [ ! -s "$WORK/err" ]; chk "E: DRYRUN=1 still exits 0 with nothing on stderr" "$?"
fresh_home; mkdir -p "$WORK/home/docs_gh/llmtelemetry/.git"
run "$SCRIPT" DRYRUN=1
[ "$RC" = "0" ] && [ ! -s "$WORK/err" ]; chk "E: DRYRUN=1 with a repo present still exits 0, no stderr" "$?"

# ---- F. mutant: without the reason line the checks must go red ----------------------------
sed 's/^  local msg=.*/  local msg=""/' "$SCRIPT" > "$WORK/mut.sh"
cmp -s "$SCRIPT" "$WORK/mut.sh" && fail "F: the mutation did not change the script"
fresh_home
run "$WORK/mut.sh"
! grep -q 'step=verify-repo exit=1' "$WORK/err"; chk "F: with the message removed A goes red (no step in stderr)" "$?"

bash -n "$SCRIPT"; chk "bash -n" "$?"
echo "RESULT: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
