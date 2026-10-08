#!/usr/bin/env bash
# test_roborev_eval_history.sh — tests for roborev_eval_run.sh persistence,
# --runs N majority logic, and exit codes (llm#816).
#
# Hermetic: a stub `roborev` is put first on PATH (no live review, no cost), the
# fixtures are two tiny throwaway ones, and every DuckDB write goes to a temp
# file via UNIFIED_DB_PATH. The live ~/.claude/logs/unified.duckdb is never read
# or written.
#
# Usage: .claude/tests/test_roborev_eval_history.sh
# Exit: 0 if every case passes, 1 otherwise.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL="$TEST_DIR/../scripts/roborev_eval_run.sh"
CLASSIFY="$TEST_DIR/../scripts/roborev_eval_classify.py"

TMP="$(mktemp -d /tmp/t816_history_XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

PASSED=0
FAILED=0
ok()   { PASSED=$((PASSED + 1)); echo "  ok   - $1"; }
nope() { FAILED=$((FAILED + 1)); echo "  FAIL - $1"; }
check_eq() { # name got want
  if [ "$2" = "$3" ]; then ok "$1"; else nope "$1 (got '$2', wanted '$3')"; fi
}
check_has() { # name haystack needle
  if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else nope "$1 (missing '$3' in: $2)"; fi
}
check_lacks() { # name haystack needle
  if printf '%s' "$2" | grep -qF -- "$3"; then nope "$1 (unexpected '$3')"; else ok "$1"; fi
}

# ── Stub roborev: behaviour for call N is line N of $STUB_PLAN ───────────────
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/roborev" <<'STUB'
#!/usr/bin/env bash
n=0
[ -f "$STUB_COUNTER" ] && n="$(cat "$STUB_COUNTER")"
n=$((n + 1))
echo "$n" > "$STUB_COUNTER"
mode="$(sed -n "${n}p" "$STUB_PLAN")"
case "$mode" in
  FIND)  printf '%s\n' '{"type":"result","result":"- **Severity**: High\n- unguarded denominator bug"}' ;;
  NONE)  printf '%s\n' '{"type":"result","result":"No issues found."}' ;;
  EMPTY) printf '%s\n' '{"type":"result","result":""}' ;;
  ERR)   echo "Error: review failed" >&2; exit 1 ;;
  *)     echo "stub: no plan line $n" >&2; exit 1 ;;
esac
STUB
chmod +x "$STUB_BIN/roborev"

# ── Fixtures: bug-expected fixtures with a trivially applicable diff ─────────
make_fixture() { # root name
  local d="$1/$2"
  mkdir -p "$d"
  cat > "$d/diff.patch" <<'PATCH'
diff --git a/x.txt b/x.txt
new file mode 100644
--- /dev/null
+++ b/x.txt
@@ -0,0 +1 @@
+hello
PATCH
  cat > "$d/expected.json" <<'JSON'
{"expect_completion": true, "expect_findings": true, "must_mention_any": ["denominator"]}
JSON
}
FIX1="$TMP/fix1"; make_fixture "$FIX1" "alpha"
FIX2="$TMP/fix2"; make_fixture "$FIX2" "alpha"; make_fixture "$FIX2" "beta"

# run_eval <plan-lines...> -- <eval args...>; sets OUT, RC, DB
run_eval() {
  local plan_file="$TMP/plan.txt"
  : > "$plan_file"
  while [ "$1" != "--" ]; do echo "$1" >> "$plan_file"; shift; done
  shift
  rm -f "$TMP/counter"
  DB="$TMP/unified.duckdb"
  rm -f "$DB"
  duckdb -init /dev/null "$DB" "SELECT 1;" > /dev/null 2>&1
  OUT="$(PATH="$STUB_BIN:$PATH" STUB_PLAN="$plan_file" STUB_COUNTER="$TMP/counter" \
         UNIFIED_DB_PATH="$DB" bash "$EVAL" "$@" 2>"$TMP/stderr.txt")"
  RC=$?
}
q() { duckdb -init /dev/null "$DB" -noheader -list "$1" 2>/dev/null; }

echo "== persistence: one row per fixture attempt, right columns =="
run_eval FIND -- --fixtures "$FIX1" --agent stubagent --model stubmodel --config-hash abc123 --timeout 20
check_eq "single PASS run exits 0" "$RC" "0"
check_eq "one row written" "$(q 'SELECT count(*) FROM eval_runs')" "1"
check_eq "eval_runs columns" \
  "$(q "SELECT string_agg(column_name, ',' ORDER BY ordinal_position) FROM information_schema.columns WHERE table_name='eval_runs'")" \
  "run_id,run_at,harness,fixture,attempt,agent,model,config_hash,result,reason,latency_ms"
check_eq "row values" \
  "$(q "SELECT harness||'|'||fixture||'|'||attempt||'|'||agent||'|'||model||'|'||config_hash||'|'||result FROM eval_runs")" \
  "roborev|alpha|1|stubagent|stubmodel|abc123|PASS"
check_eq "latency recorded (non-negative)" "$(q 'SELECT latency_ms >= 0 FROM eval_runs')" "true"
check_eq "reason recorded" "$(q "SELECT reason <> '' FROM eval_runs")" "true"

echo "== persistence: defaults when agent/model/hash not given =="
run_eval FIND -- --fixtures "$FIX1" --timeout 20
check_eq "defaults recorded" \
  "$(q "SELECT agent||'|'||model||'|'||config_hash FROM eval_runs")" \
  "config-default|config-default|unspecified"

echo "== --runs N: one row per attempt, shared run_id =="
run_eval FIND FIND NONE -- --fixtures "$FIX1" --runs 3 --config-hash h1 --timeout 20
check_eq "three rows" "$(q 'SELECT count(*) FROM eval_runs')" "3"
check_eq "one run_id" "$(q 'SELECT count(DISTINCT run_id) FROM eval_runs')" "1"
check_eq "attempts 1..3" "$(q "SELECT string_agg(attempt::VARCHAR, ',' ORDER BY attempt) FROM eval_runs")" "1,2,3"

echo "== majority: PASS/PASS/FAIL -> PASS + flaky, exit 0 =="
check_eq "exit 0" "$RC" "0"
check_has "verdict PASS" "$OUT" "alpha: PASS"
check_has "flaky printed" "$OUT" "FLAKY"

echo "== majority: ERROR/ERROR/PASS -> ERROR (indeterminate), exit 3 =="
run_eval ERR EMPTY FIND -- --fixtures "$FIX1" --runs 3 --config-hash h2 --timeout 20
check_eq "exit 3" "$RC" "3"
check_has "verdict ERROR" "$OUT" "alpha: ERROR"
check_has "overall INDETERMINATE" "$OUT" "Overall: INDETERMINATE"
check_lacks "not flaky (only one completed attempt)" "$OUT" "FLAKY"

echo "== majority: FAIL/FAIL/PASS -> FAIL + flaky, exit 1 =="
run_eval NONE NONE FIND -- --fixtures "$FIX1" --runs 3 --config-hash h3 --timeout 20
check_eq "exit 1" "$RC" "1"
check_has "verdict FAIL" "$OUT" "alpha: FAIL"
check_has "flaky printed" "$OUT" "FLAKY"

echo "== exit codes: FAIL beats ERROR; ERROR without FAIL is 3 =="
run_eval NONE ERR -- --fixtures "$FIX2" --config-hash h4 --timeout 20
check_eq "FAIL + ERROR -> 1" "$RC" "1"
run_eval FIND ERR -- --fixtures "$FIX2" --config-hash h5 --timeout 20
check_eq "PASS + ERROR -> 3" "$RC" "3"
run_eval FIND FIND -- --fixtures "$FIX2" --config-hash h6 --timeout 20
check_eq "all PASS -> 0" "$RC" "0"

echo "== exit 2: usage =="
run_eval FIND -- --fixtures "$FIX1" --runs 0
check_eq "--runs 0 -> 2" "$RC" "2"
run_eval FIND -- --fixtures "$FIX1" --runs abc
check_eq "--runs abc -> 2" "$RC" "2"

echo "== timeouts and errors are persisted as ERROR, never PASS =="
run_eval ERR -- --fixtures "$FIX1" --config-hash h7 --timeout 20
check_eq "ERR attempt stored as ERROR" "$(q 'SELECT result FROM eval_runs')" "ERROR"

echo "== --json-out and --report (read-back without re-running) =="
JSON="$TMP/out.json"
run_eval FIND FIND NONE -- --fixtures "$FIX1" --runs 3 --config-hash hrep --timeout 20 --json-out "$JSON"
check_eq "json overall" "$(python3 -c "import json;print(json.load(open('$JSON'))['overall'])")" "PASS"
check_eq "json flaky" "$(python3 -c "import json;print(json.load(open('$JSON'))['fixtures'][0]['flaky'])")" "True"
check_eq "json config_hash" "$(python3 -c "import json;print(json.load(open('$JSON'))['config_hash'])")" "hrep"
rm -f "$TMP/counter"
REPORT_OUT="$(PATH="$STUB_BIN:$PATH" STUB_PLAN="$TMP/plan.txt" STUB_COUNTER="$TMP/counter" \
  UNIFIED_DB_PATH="$DB" bash "$EVAL" --report hrep --json-out "$TMP/report.json" 2>&1)"
REPORT_RC=$?
check_eq "--report exits 0 for a stored PASS" "$REPORT_RC" "0"
check_has "--report shows the verdict" "$REPORT_OUT" "alpha: PASS"
check_eq "--report did not call roborev" "$(cat "$TMP/counter" 2>/dev/null || echo 0)" "0"
PATH="$STUB_BIN:$PATH" UNIFIED_DB_PATH="$DB" bash "$EVAL" --report no-such-hash --json-out "$TMP/none.json" > /dev/null 2>&1
check_eq "--report for an unknown hash exits 3" "$?" "3"
check_eq "--report unknown hash has n_fixtures 0" \
  "$(python3 -c "import json;print(json.load(open('$TMP/none.json'))['n_fixtures'])")" "0"

echo "== duckdb absent: skip is logged, results still reported =="
run_eval FIND -- --fixtures "$FIX1" --timeout 20
SKIP_OUT="$(PATH="$STUB_BIN:$PATH" STUB_PLAN="$TMP/plan.txt" STUB_COUNTER="$TMP/counter2" \
  UNIFIED_DB_PATH="$DB" DUCKDB_BIN=duckdb_that_does_not_exist \
  bash "$EVAL" --fixtures "$FIX1" --timeout 20 2>&1)"
SKIP_RC=$?
check_eq "still exits 0" "$SKIP_RC" "0"
check_has "skip is logged, not silent" "$SKIP_OUT" "persistence SKIPPED"
check_has "verdict still printed" "$SKIP_OUT" "alpha: PASS"

echo "== missing DB file: skip is logged =="
NODB_OUT="$(PATH="$STUB_BIN:$PATH" STUB_PLAN="$TMP/plan.txt" STUB_COUNTER="$TMP/counter3" \
  UNIFIED_DB_PATH="$TMP/no_such.duckdb" bash "$EVAL" --fixtures "$FIX1" --timeout 20 2>&1)"
check_has "missing DB skip logged" "$NODB_OUT" "persistence SKIPPED"
[ -e "$TMP/no_such.duckdb" ] && nope "must not create a DB file" || ok "did not create the DB file"

echo "== aggregate / selftest still pass =="
SELF_OUT="$(bash "$EVAL" --selftest 2>&1)"
SELF_RC=$?
check_eq "--selftest exits 0" "$SELF_RC" "0"
check_has "selftest includes majority cases" "$SELF_OUT" "I-pass-pass-fail"

echo ""
echo "Summary: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
