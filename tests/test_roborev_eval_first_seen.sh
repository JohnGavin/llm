#!/usr/bin/env bash
# roborev_eval_run.sh --first-seen HASH prints the UTC date of the EARLIEST stored run
# for a config hash (the daily email uses it to show the red golden-eval alert on the
# first day only). Read only. Scratch DuckDB; never touches the real unified.duckdb.
#
# Needs the duckdb CLI. Without it the test exits 3 (INDETERMINATE), not 0.
# Bash 3.2 compatible.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
SCRIPT="$ROOT/.claude/scripts/roborev_eval_run.sh"

if [ -z "$(command -v duckdb || true)" ]; then
    echo "INDETERMINATE: duckdb not found -- --first-seen NOT exercised"
    exit 3
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/eval_first_seen_test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
DB="$WORK/u.duckdb"

PASS=0; FAIL=0
chk() { if [ "$2" = "0" ]; then PASS=$((PASS + 1)); echo "ok: $1"; else FAIL=$((FAIL + 1)); echo "FAIL: $1"; fi; }

duckdb "$DB" "CREATE TABLE eval_runs (run_id TEXT, run_at TIMESTAMPTZ, harness TEXT, fixture TEXT, attempt INTEGER,
  agent TEXT, model TEXT, config_hash TEXT, result TEXT, reason TEXT, latency_ms BIGINT);
INSERT INTO eval_runs VALUES
 ('r1', TIMESTAMPTZ '2026-10-14 03:00:00+00', 'roborev', 'f1', 1, 'a', 'm', 'hashA', 'FAIL', NULL, 1),
 ('r2', TIMESTAMPTZ '2026-10-18 03:00:00+00', 'roborev', 'f1', 1, 'a', 'm', 'hashA', 'FAIL', NULL, 1),
 ('r3', TIMESTAMPTZ '2026-10-20 23:30:00+00', 'roborev', 'f1', 1, 'a', 'm', 'hashB', 'PASS', NULL, 1),
 ('r4', TIMESTAMPTZ '2026-10-01 03:00:00+00', 'other',   'f1', 1, 'a', 'm', 'hashB', 'PASS', NULL, 1);" >/dev/null

run() { UNIFIED_DB_PATH="$DB" bash "$SCRIPT" --first-seen "$1" 2>"$WORK/err"; }

out="$(run hashA)"; rc=$?
chk "earliest of two runs (not the latest)" "$([ "$rc" = 0 ] && [ "$out" = "2026-10-14" ] && echo 0 || echo 1)"
out="$(run hashB)"; rc=$?
chk "another harness's older row does not count; UTC date kept" "$([ "$rc" = 0 ] && [ "$out" = "2026-10-20" ] && echo 0 || echo 1)"
out="$(run hashZ)"; rc=$?
chk "unknown hash: exit 0, no date" "$([ "$rc" = 0 ] && [ -z "$out" ] && echo 0 || echo 1)"
out="$(run "x' OR '1'='1")"; rc=$?
chk "a quote in the hash is escaped, not executed" "$([ "$rc" = 0 ] && [ -z "$out" ] && echo 0 || echo 1)"
out="$(UNIFIED_DB_PATH="$WORK/missing.duckdb" bash "$SCRIPT" --first-seen hashA 2>/dev/null)"; rc=$?
chk "DB missing: exit 3 (INDETERMINATE), never an empty success" "$([ "$rc" = 3 ] && [ -z "$out" ] && echo 0 || echo 1)"
before="$(duckdb -init /dev/null "$DB" -noheader -list "SELECT count(*) FROM eval_runs")"
run hashA >/dev/null
after="$(duckdb -init /dev/null "$DB" -noheader -list "SELECT count(*) FROM eval_runs")"
chk "read only: the row count is unchanged (4)" "$([ "$before" = "$after" ] && [ "$before" = "4" ] && echo 0 || echo 1)"
# FALSIFICATION: a mutant that takes max() instead of min() must give a different answer
sed 's/min(run_at AT TIME ZONE/max(run_at AT TIME ZONE/' "$SCRIPT" > "$WORK/mut.sh"
cp "$ROOT/.claude/scripts/roborev_eval_classify.py" "$WORK/" 2>/dev/null
out="$(UNIFIED_DB_PATH="$DB" bash "$WORK/mut.sh" --first-seen hashA 2>/dev/null)"
chk "mutant (max instead of min) is detected: gives 2026-10-18" "$([ "$out" = "2026-10-18" ] && echo 0 || echo 1)"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
