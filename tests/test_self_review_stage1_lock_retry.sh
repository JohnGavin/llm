#!/usr/bin/env bash
# llm#1495: self_review_stage1.sh gave up on the first DuckDB "Could not set lock on
# file" error. It now retries a BOUNDED number of times (total sleep < 30 s) and, when
# the lock is still held, exits 3 (INDETERMINATE) with ONE stderr line naming the cause.
#
# A fake duckdb (SELF_REVIEW_DUCK_CMD) and a recording sleep (SELF_REVIEW_SLEEP_CMD)
# stand in, HOME and the lock file are scratch, so nothing real is opened or waited on.
# Bash 3.2 compatible.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
SCRIPT="$ROOT/.claude/scripts/self_review_stage1.sh"
SQL="$ROOT/.claude/scripts/self_review_stage1.sql"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/stage1_lock_test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "ok: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
chk()  { if [ "$2" = "0" ]; then ok "$1"; else fail "$1"; fi; }

H="$WORK/home"; mkdir -p "$H/.claude/logs"
: > "$H/.claude/logs/unified.duckdb"          # only its existence matters to the script
cat > "$WORK/fakeduck" <<'EOF'
#!/bin/bash
# stdin call = the SQL run: fail with the DuckDB lock text (on STDOUT, as in the real
# log) for the first $FAKE_FAIL_N calls, or with $FAKE_FAIL_TEXT; `-c` = the count query.
D="${FAKE_DIR:?}"
for a in "$@"; do [ "$a" = "-c" ] && { echo 7; exit 0; }; done
n=0; [ -f "$D/calls" ] && n="$(cat "$D/calls")"
n=$((n + 1)); echo "$n" > "$D/calls"
cat > /dev/null
if [ -n "${FAKE_FAIL_TEXT:-}" ]; then echo "$FAKE_FAIL_TEXT"; exit 1; fi
if [ "$n" -le "${FAKE_FAIL_N:-0}" ]; then
  echo 'Error: unable to open database "/x/unified.duckdb": IO Error: Could not set lock on file "/x/unified.duckdb": Conflicting lock is held in duckdb (PID 1)'
  exit 1
fi
echo "ok"; exit 0
EOF
cat > "$WORK/fakesleep" <<'EOF'
#!/bin/bash
echo "$1" >> "${FAKE_DIR:?}/sleeps"
EOF
chmod +x "$WORK/fakeduck" "$WORK/fakesleep"

RC=0
run() {   # script-path args... ; env via FAKE_* in the caller
    local s="$1"; shift
    rm -f "$WORK/calls" "$WORK/sleeps"
    ( env -u SELF_REVIEW_DEPTH HOME="$H" FAKE_DIR="$WORK" SELF_REVIEW_DUCK_CMD="$WORK/fakeduck" \
          SELF_REVIEW_SLEEP_CMD="$WORK/fakesleep" SELF_REVIEW_LOCK_FILE="$WORK/lock" \
          bash "$s" "$@" ) > "$WORK/out" 2> "$WORK/err"
    RC=$?
}
calls() { if [ -f "$WORK/calls" ]; then cat "$WORK/calls"; else echo 0; fi; }
total_sleep() { if [ -f "$WORK/sleeps" ]; then awk '{s+=$1} END{print s+0}' "$WORK/sleeps"; else echo 0; fi; }

# ---- A. lock held twice, then free: the write succeeds on the 3rd attempt -----------
FAKE_FAIL_N=2 run "$SCRIPT" --write
chk "A: lock held twice then free -> exit 0" "$RC"
[ "$(calls)" = "3" ]; chk "A: duckdb was tried 3 times" "$?"
[ ! -s "$WORK/err" ]; chk "A: nothing on stderr when the retry succeeded" "$?"

# ---- B. lock held forever: bounded, exit 3, ONE stderr line --------------------------
rm -f "$H/.claude/logs/stamps/self-review-stage1.stamp"   # run A (a success) wrote it
FAKE_FAIL_N=99 run "$SCRIPT" --write
[ "$RC" = "3" ]; chk "B: lock never released -> exit 3 (INDETERMINATE)" "$?"
[ "$(calls)" = "4" ]; chk "B: bounded: exactly 4 attempts, then stop" "$?"
[ "$(wc -l < "$WORK/err" | tr -d ' ')" = "1" ]; chk "B: exactly ONE stderr line" "$?"
grep -q 'lock' "$WORK/err" && grep -q 'unified.duckdb' "$WORK/err"; chk "B: the line names the cause (the write lock on unified.duckdb)" "$?"
[ "$(total_sleep)" -lt 30 ]; chk "B: total sleep is under 30 s (got $(total_sleep))" "$?"
[ ! -f "$WORK/lock" ]; chk "B: the run lock file is released" "$?"
[ ! -f "$H/.claude/logs/stamps/self-review-stage1.stamp" ]; chk "B: no success stamp is written on failure" "$?"

# ---- C. a non-lock failure is NOT retried and keeps its own exit code ----------------
FAKE_FAIL_TEXT='Parser Error: syntax error at or near "SELEC"' run "$SCRIPT" --write
[ "$RC" != "0" ] && [ "$RC" != "3" ]; chk "C: other failures are not turned into exit 0 or 3 (got $RC)" "$?"
[ "$(calls)" = "1" ]; chk "C: other failures are not retried (1 attempt)" "$?"

# ---- D. the default dry-run path retries too -----------------------------------------
FAKE_FAIL_N=1 run "$SCRIPT"
chk "D: dry-run: lock held once then free -> exit 0" "$RC"
[ "$(calls)" = "2" ]; chk "D: dry-run: 2 attempts" "$?"
FAKE_FAIL_N=99 run "$SCRIPT"
[ "$RC" = "3" ] && [ "$(wc -l < "$WORK/err" | tr -d ' ')" = "1" ]; chk "D: dry-run: exhaustion -> exit 3 with one stderr line" "$?"

# ---- E. mutants: the retry and the bound must be load-bearing -------------------------
cp "$SQL" "$WORK/self_review_stage1.sql"
sed 's/grep -q "Could not set lock on file" "\$1"/false/' "$SCRIPT" > "$WORK/mut_noretry.sh"
cmp -s "$SCRIPT" "$WORK/mut_noretry.sh" && fail "E: the no-retry mutation did not change the script"
FAKE_FAIL_N=2 run "$WORK/mut_noretry.sh" --write
[ "$RC" != "0" ] && [ "$(calls)" = "1" ]; chk "E: without the lock check A goes red (no retry, rc=$RC)" "$?"
sed 's/^LOCK_SLEEPS=(.*)/LOCK_SLEEPS=(5 10 15 20 25 30)/' "$SCRIPT" > "$WORK/mut_long.sh"
cmp -s "$SCRIPT" "$WORK/mut_long.sh" && fail "E: the long-sleep mutation did not change the script"
FAKE_FAIL_N=99 run "$WORK/mut_long.sh" --write
[ "$(total_sleep)" -ge 30 ]; chk "E: with long sleeps the under-30 s bound goes red (got $(total_sleep))" "$?"

bash -n "$SCRIPT"; chk "bash -n" "$?"
echo "RESULT: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
