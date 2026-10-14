#!/usr/bin/env bash
# test_session_init_phase10_1427.sh — llm#1427: session_init.sh Phase 10 must
# not abort silently (rc=1, no stderr) on a ps/grep self-match, the orphan
# count must be a single integer, and an errexit abort must name its line.
#
# Root cause under test: `ps | grep -q crew_worker` matched grep's own argv;
# the unguarded `orphan_pids=$(ps | grep crew_worker | grep -v grep | awk ...)`
# then returned 1 (grep -v filtered everything) and, under
# `set -euo pipefail`, killed the hook with nothing on stderr.
#
# Hermetic: the Phase 10 block is extracted from the hook text and run in a
# fresh strict shell with a stub `ps` (via PS_BIN) and a stub `xargs`, so no
# process is ever killed.
#
# Falsification: OLD_HOOK=<pre-fix copy of session_init.sh> bash this-script
# must FAIL group 1 (stateful stub) and group 4 (count expression, trap).

set -uo pipefail

WT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="${HOOK:-$WT/.claude/hooks/session_init.sh}"
ITER="${ITER:-200}"

PASS=0
FAIL=0
assert() {
  if [ "$2" = "$3" ]; then
    echo "  PASS: $1"; PASS=$((PASS + 1))
  else
    echo "  FAIL: $1"; echo "        expected: [$3]"; echo "        got:      [$2]"
    FAIL=$((FAIL + 1))
  fi
}

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

# Extract Phase 10 (from its header to the Phase 11 header).
extract() {
  sed -n '/^# Phase 10: Kill orphan crew workers/,/^# Phase 11:/p' "$1" | sed '$d'
}
extract "$HOOK" > "$T/phase10_raw.sh"
if [ ! -s "$T/phase10_raw.sh" ]; then
  echo "FATAL: could not extract Phase 10 from $HOOK"; exit 2
fi
# Old code hard-codes /bin/ps; route it through PS_BIN so the stub applies.
sed 's#/bin/ps#${PS_BIN}#g' "$T/phase10_raw.sh" > "$T/phase10.sh"

# xargs stub: record what would be killed, never kill.
cat > "$T/bin/xargs" <<EOF
#!/usr/bin/env bash
cat >> "$T/killed.txt"
EOF
chmod +x "$T/bin/xargs"

# Stateful ps stub (models the self-match race): call 1 lists a grep that
# mentions crew_worker; call 2 lists no controller; later calls list only the
# grep line, which `grep -v grep` filters to nothing.
cat > "$T/bin/ps_race" <<EOF
#!/usr/bin/env bash
n=\$(cat "$T/count" 2>/dev/null || echo 0); n=\$((n + 1)); echo \$n > "$T/count"
case \$n in
  1) echo "  10 1:00 grep -q crew_worker" ;;
  2) echo "ps -eo command" ;;
  *) echo "  11 grep crew_worker" ;;
esac
exit 0
EOF
chmod +x "$T/bin/ps_race"

# ps stub with no crew worker anywhere.
cat > "$T/bin/ps_none" <<'EOF'
#!/usr/bin/env bash
echo "    PID COMMAND"
echo "      1 /sbin/launchd"
echo "    501 /usr/bin/ssh-agent"
exit 0
EOF
chmod +x "$T/bin/ps_none"

# ps stub with N real crew workers and no tar_make controller.
cat > "$T/bin/ps_workers" <<'EOF'
#!/usr/bin/env bash
echo "    PID COMMAND"
echo "      1 /sbin/launchd"
echo "   4242 R --no-echo -e crew::crew_worker(settings = x)"
if [ "${STUB_WORKERS:-1}" -ge 2 ]; then
  echo "   4243 R --no-echo -e crew::crew_worker(settings = y)"
fi
exit 0
EOF
chmod +x "$T/bin/ps_workers"

# Run the extracted block in a fresh strict shell. Prints rc; stderr to file.
run_block() { # $1 = ps stub, $2 = stderr file ; prints orphan_count then rc
  : > "$T/killed.txt"; rm -f "$T/count"
  env PATH="$T/bin:$PATH" PS_BIN="$1" bash -c '
    set -euo pipefail
    WARNINGS=""
    source "'"$T"'/phase10.sh"
    printf "COUNT=[%s]\n" "$orphan_count"
  ' > "$T/out.txt" 2> "$2"
  echo $?
}

echo ""
echo "=== Group 1: self-match race (stateful stub) must not abort the hook ==="
rc=$(run_block "$T/bin/ps_race" "$T/err1.txt")
assert "race stub: block exits 0 (old code: rc=1, silent)" "$rc" "0"
assert "race stub: nothing on stderr" "$(cat "$T/err1.txt")" ""

echo ""
echo "=== Group 2: no crew worker, $ITER iterations, strict shell ==="
bad=0
for _ in $(seq 1 "$ITER"); do
  rc=$(run_block "$T/bin/ps_none" "$T/err2.txt")
  [ "$rc" = "0" ] || bad=$((bad + 1))
done
assert "no worker: aborts over $ITER iterations" "$bad" "0"
assert "no worker: COUNT is single integer 0" "$(cat "$T/out.txt")" "COUNT=[0]"
assert "no worker: nothing killed" "$(cat "$T/killed.txt")" ""

echo ""
echo "=== Group 2b: real /bin/ps, no PS_BIN override, $ITER iterations ==="
bad=0
for _ in $(seq 1 "$ITER"); do
  : > "$T/killed.txt"
  env -u PS_BIN PATH="$T/bin:$PATH" bash -c '
    set -euo pipefail
    WARNINGS=""
    source "'"$T"'/phase10_raw.sh"
  ' >/dev/null 2>&1 || bad=$((bad + 1))
done
if /bin/ps -eo command | grep -q "[c]rew_worker"; then
  echo "  SKIP: a real crew_worker is running; real-ps iteration check not meaningful"
else
  assert "real ps: aborts over $ITER iterations" "$bad" "0"
fi

echo ""
echo "=== Group 3: fake crew workers, no controller: count is one integer ==="
rc=$(STUB_WORKERS=1 run_block "$T/bin/ps_workers" "$T/err3.txt")
assert "1 worker: rc 0" "$rc" "0"
assert "1 worker: COUNT=[1]" "$(cat "$T/out.txt")" "COUNT=[1]"
assert "1 worker: would kill pid 4242" "$(tr -d ' \n' < "$T/killed.txt")" "4242"
assert "1 worker: nothing on stderr" "$(cat "$T/err3.txt")" ""
rc=$(STUB_WORKERS=2 run_block "$T/bin/ps_workers" "$T/err3.txt")
assert "2 workers: COUNT=[2]" "$(cat "$T/out.txt")" "COUNT=[2]"

echo ""
echo "=== Group 4: count expression and ERR trap ==="
# The old expression, evaluated on an empty match set, yields two lines.
old_count=$(printf '%s\n' "" | grep -c '[0-9]' || echo 0)
new_count=$(printf '%s\n' "" | grep -c '[0-9]' || true)
assert "old count expression on no match is two lines (the 0\\n0 bug)" "$(printf '%s' "$old_count" | tr '\n' '|')" "0|0"
assert "new count expression on no match is a single 0" "$new_count" "0"

grep -n "^trap '.*aborted at line" "$HOOK" > "$T/trapline.txt" || true
assert "hook declares an ERR trap" "$(grep -c "ERR$" "$T/trapline.txt")" "1"
trap_ln=$(cut -d: -f1 < "$T/trapline.txt" | head -1)
first_phase=$(grep -n '^# ── Phase 1:' "$HOOK" | head -1 | cut -d: -f1 || true)
if [ -n "$trap_ln" ] && [ -n "$first_phase" ] && [ "$trap_ln" -lt "$first_phase" ]; then
  assert "trap is installed before Phase 1" "yes" "yes"
else
  assert "trap is installed before Phase 1" "trap=${trap_ln:-none} phase1=${first_phase:-none}" "yes"
fi
sed -n "s/^trap '\(.*\)' ERR\$/\1/p" "$HOOK" | head -1 > "$T/trapbody.txt"
{
  echo '#!/usr/bin/env bash'
  echo 'set -euo pipefail'
  echo "trap '$(cat "$T/trapbody.txt")' ERR"
  echo 'x=$(true | grep nomatch)'
  echo 'echo "not reached"'
} > "$T/forced.sh"
bash "$T/forced.sh" > "$T/forced_out.txt" 2> "$T/forced_err.txt"
forced_rc=$?
assert "forced failure still exits non-zero (behaviour unchanged)" "$forced_rc" "1"
assert "forced failure stderr names the line" "$(cat "$T/forced_err.txt")" "session_init.sh: aborted at line 4"
{
  echo '#!/usr/bin/env bash'
  echo 'set -euo pipefail'
  echo "trap '$(cat "$T/trapbody.txt")' ERR"
  echo 'x=$(true | grep nomatch) || true'
  echo 'if false; then :; fi'
  echo 'false || true'
  echo 'y=$(echo a | grep -c b || true)'
  echo 'echo done'
} > "$T/guarded.sh"
bash "$T/guarded.sh" > "$T/guarded_out.txt" 2> "$T/guarded_err.txt"
assert "guarded failures: exit 0" "$?" "0"
assert "guarded failures: trap stays silent" "$(cat "$T/guarded_err.txt")" ""

echo ""
echo "=== Group 5: syntax ==="
bash -n "$HOOK"
assert "bash -n hook" "$?" "0"

echo ""
echo "RESULTS: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
