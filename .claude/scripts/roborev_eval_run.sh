#!/usr/bin/env bash
# roborev_eval_run.sh — golden-fixture regression harness for roborev (llm#1044)
#
# Purpose: roborev is a third-party closed-source review tool. We had zero
# automated evaluation of its review quality. Concretely: gemini-2.5-flash-lite
# (a configurable review agent) silently failed to read the diff on 15.5% of
# its 129 open reviews in this repo (20 of them) -- nobody noticed until a
# human hand-queried ~/.roborev/reviews.db during an unrelated bug (llm#1035).
# Nothing would have caught this on the day the agent/model config changed.
#
# This is the smallest useful slice: a golden diff set + a regression check
# on agent/model swap. Re-run this after ANY change to .roborev.toml
# agent=/model= (globally or per-repo) BEFORE trusting the new config in
# production. See the "Eval Harness" section of the roborev-resolution rule.
#
# Usage:
#   roborev_eval_run.sh [--agent AGENT] [--model MODEL] [--fixtures DIR] [--timeout SECS]
#                       [--runs N] [--config-hash HASH] [--json-out FILE]
#   roborev_eval_run.sh --report CONFIG_HASH [--json-out FILE]
#   roborev_eval_run.sh --selftest
#
#   --runs N            run each fixture N times (default 1). The per-fixture
#                       verdict is PASS only if a strict majority of COMPLETED
#                       attempts passed; if a majority of ALL attempts are
#                       ERROR the fixture is ERROR (indeterminate). A fixture
#                       whose completed attempts disagree is printed FLAKY.
#   --config-hash HASH  fingerprint of the effective reviewer config, stored in
#                       eval_runs.config_hash (the daily email passes its
#                       sha256 fingerprint). Default: "unspecified".
#   --json-out FILE     also write the per-fixture verdicts as JSON.
#   --report HASH       run nothing: print the verdicts of the most recent
#                       stored run for config hash HASH (exit 0/1/3 as below;
#                       3 with n_fixtures=0 means no stored run).
#
# Persistence (llm#816): one eval_runs row per fixture attempt is written to
# the DuckDB at $UNIFIED_DB_PATH (default ~/.claude/logs/unified.duckdb; the
# eval_runs table is created if missing). If `duckdb` ($DUCKDB_BIN) or the DB
# file is absent the write is skipped with a "persistence SKIPPED" line on
# stderr -- the verdicts are still printed.
#
#   --agent AGENT      agent to pass to `roborev review` (codex, claude-code,
#                       gemini, ...). Omit to use the repo's configured
#                       default (.roborev.toml / ~/.roborev/config.toml).
#   --model MODEL       model to pass to `roborev review`. Omit to use the
#                       configured default. NOTE: this repo's global config
#                       pins a per-repo default review model that a brand-new
#                       scratch repo (no .roborev.toml) will NOT inherit --
#                       pass --model explicitly if the bare --agent run
#                       reports "model ... may not exist" (observed live
#                       2026-08-27 with --agent claude-code and no --model).
#   --fixtures DIR      fixtures root (default: sibling
#                       tests/fixtures/roborev_eval/ next to this script)
#   --timeout SECS      per-fixture wall-clock budget for the `roborev
#                       review` call (default: 150)
#   --selftest          test the CLASSIFICATION LOGIC against mocked review
#                       text (no live roborev call, no network). Delegates to
#                       roborev_eval_classify.py selftest.
#
# Per-fixture classification (never conflates an indeterminate result with a
# negative one -- see the checks-must-distinguish-unknown rule):
#   PASS    — review completed; findings matched the fixture's expectations
#   FAIL    — review completed; findings did NOT match expectations
#             (this is the regression the harness exists to catch)
#   ERROR   — roborev review did not complete (nonzero exit, error
#             signature, or the exit-0-but-EMPTY-result silent-failure
#             signature from llm#1035) -- indeterminate about the fixture's
#             code, not a negative finding about it
#   TIMEOUT — exceeded the per-fixture wall-clock budget; NOT a pass
#
# Exit codes (checks-must-distinguish-unknown):
#   0 — all fixtures PASS (or --selftest: all cases PASS)
#   1 — one or more fixtures FAIL (a regression)
#   2 — usage error / roborev binary not found / fixtures dir not found
#   3 — INDETERMINATE: one or more fixtures ERROR/TIMEOUT and none FAIL
#       (previously 1; ERROR is not a negative finding about the reviewer)
#
# Called by:
#   - Manually after changing .roborev.toml agent=/model= (see
#     roborev-resolution rule)
#   - .claude/tests/test_roborev_eval_run.sh (--selftest wrapper)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLASSIFY_PY="$SCRIPT_DIR/roborev_eval_classify.py"
FIXTURES_DIR="$SCRIPT_DIR/../tests/fixtures/roborev_eval"
AGENT=""
MODEL=""
PER_FIXTURE_TIMEOUT=150
SELFTEST=0
RUNS=1
CONFIG_HASH="unspecified"
JSON_OUT=""
REPORT_HASH=""
UNIFIED_DB="${UNIFIED_DB_PATH:-$HOME/.claude/logs/unified.duckdb}"
DUCKDB="${DUCKDB_BIN:-duckdb}"
SCHEMA_SQL="$SCRIPT_DIR/housekeeping_schema_init.sql"

usage() {
  sed -n '2,70p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --agent)       AGENT="$2"; shift 2 ;;
    --model)       MODEL="$2"; shift 2 ;;
    --fixtures)    FIXTURES_DIR="$2"; shift 2 ;;
    --timeout)     PER_FIXTURE_TIMEOUT="$2"; shift 2 ;;
    --runs)        RUNS="$2"; shift 2 ;;
    --config-hash) CONFIG_HASH="$2"; shift 2 ;;
    --json-out)    JSON_OUT="$2"; shift 2 ;;
    --report)      REPORT_HASH="$2"; shift 2 ;;
    --selftest)    SELFTEST=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [ "$SELFTEST" -eq 1 ]; then
  exec python3 "$CLASSIFY_PY" selftest
fi

case "$RUNS" in
  ''|*[!0-9]*) echo "ERROR: --runs must be a positive integer (got '$RUNS')" >&2; exit 2 ;;
esac
if [ "$RUNS" -lt 1 ]; then
  echo "ERROR: --runs must be a positive integer (got '$RUNS')" >&2
  exit 2
fi

# ─── Persistence helpers (llm#816) ───────────────────────────────────────────
# Never silent: every skipped write says why on stderr.
db_available() {
  if ! command -v "$DUCKDB" >/dev/null 2>&1; then
    echo "roborev_eval_run.sh: persistence SKIPPED -- '$DUCKDB' not found on PATH" >&2
    return 1
  fi
  if [ ! -f "$UNIFIED_DB" ]; then
    echo "roborev_eval_run.sh: persistence SKIPPED -- DB file not found: $UNIFIED_DB" >&2
    return 1
  fi
  return 0
}

# Create eval_runs from the schema file (single home for the DDL), idempotent.
ensure_eval_table() {
  local ddl
  ddl="$(sed -n '/^CREATE TABLE IF NOT EXISTS eval_runs/,/^CREATE INDEX IF NOT EXISTS idx_eval_runs/p' "$SCHEMA_SQL")"
  if [ -z "$ddl" ]; then
    echo "roborev_eval_run.sh: persistence SKIPPED -- eval_runs DDL not found in $SCHEMA_SQL" >&2
    return 1
  fi
  "$DUCKDB" -init /dev/null "$UNIFIED_DB" "$ddl" >/dev/null 2>&1 || {
    echo "roborev_eval_run.sh: persistence SKIPPED -- could not create eval_runs in $UNIFIED_DB" >&2
    return 1
  }
}

# --report HASH: no review calls; grade the stored attempts of the latest run.
if [ -n "$REPORT_HASH" ]; then
  report_tsv="$(mktemp /tmp/roborev_eval_report_XXXXXX)"
  : > "$report_tsv"
  if db_available; then
    # Read-only: --report must never create tables in (or otherwise write to)
    # the DB. A missing eval_runs table just means "no stored run yet".
    safe_hash="${REPORT_HASH//\'/\'\'}"
    "$DUCKDB" -init /dev/null -readonly "$UNIFIED_DB" -noheader -separator $'\t' -list "
      SELECT run_id, strftime(run_at, '%Y-%m-%dT%H:%M:%SZ'), harness, fixture, attempt,
             agent, model, config_hash, result, replace(coalesce(reason, ''), chr(9), ' '),
             coalesce(latency_ms::VARCHAR, '')
      FROM eval_runs
      WHERE harness = 'roborev' AND config_hash = '$safe_hash'
        AND run_id = (SELECT run_id FROM eval_runs
                      WHERE harness = 'roborev' AND config_hash = '$safe_hash'
                      ORDER BY run_at DESC LIMIT 1)
      ORDER BY fixture, attempt;" > "$report_tsv" 2>/dev/null || {
        echo "roborev_eval_run.sh: could not read eval_runs from $UNIFIED_DB" >&2
        : > "$report_tsv"
      }
  fi
  set +e
  python3 "$CLASSIFY_PY" aggregate "$report_tsv" "$JSON_OUT" "config_hash=$REPORT_HASH" "source=report"
  report_rc=$?
  set -e
  rm -f "$report_tsv"
  exit "$report_rc"
fi

if ! command -v roborev >/dev/null 2>&1; then
  echo "ERROR: roborev binary not found on PATH" >&2
  exit 2
fi

if [ ! -d "$FIXTURES_DIR" ]; then
  echo "ERROR: fixtures directory not found: $FIXTURES_DIR" >&2
  exit 2
fi

now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }

# ─── Run one fixture ────────────────────────────────────────────────────────
# Prints one line: "<STATUS>|<latency_ms>|<fixture_name>|<reason>"
#   STATUS in {PASS, FAIL, ERROR, TIMEOUT, SKIP}
run_fixture() {
  local fixture_dir="$1"
  local fixture_name
  fixture_name="$(basename "$fixture_dir")"
  local diff_patch="$fixture_dir/diff.patch"
  local expected_json="$fixture_dir/expected.json"
  local baseline_dir="$fixture_dir/baseline"

  if [ ! -f "$diff_patch" ] || [ ! -f "$expected_json" ]; then
    echo "SKIP|0|$fixture_name|missing diff.patch or expected.json"
    return 0
  fi

  local scratch
  scratch="$(mktemp -d /tmp/roborev_eval_XXXXXX)"

  git -C "$scratch" init -q
  git -C "$scratch" config user.email "roborev-eval@localhost"
  git -C "$scratch" config user.name "roborev-eval"

  if [ -d "$baseline_dir" ]; then
    cp -R "$baseline_dir/." "$scratch/"
  else
    printf '# scratch repo for roborev_eval_run.sh fixture %s\n' "$fixture_name" > "$scratch/README.md"
  fi
  git -C "$scratch" add -A
  git -C "$scratch" commit -q -m "baseline for $fixture_name"

  local apply_err="$scratch.apply_err"
  if ! git -C "$scratch" apply "$diff_patch" 2>"$apply_err"; then
    echo "ERROR|0|$fixture_name|diff.patch failed to apply: $(tr '\n' ' ' < "$apply_err")"
    rm -rf "$scratch"
    rm -f "$apply_err"
    return 0
  fi
  rm -f "$apply_err"

  echo "PROGRESS: running roborev review on fixture $fixture_name (agent=${AGENT:-<config-default>} model=${MODEL:-<config-default>}, timeout=${PER_FIXTURE_TIMEOUT}s)" >&2

  local raw_out="$scratch.raw.json"
  local -a args=(review --dirty --local --wait --repo "$scratch")
  [ -n "$AGENT" ] && args+=(--agent "$AGENT")
  [ -n "$MODEL" ] && args+=(--model "$MODEL")

  local t0 t1 latency_ms
  t0="$(now_ms)"
  set +e
  timeout "$PER_FIXTURE_TIMEOUT" roborev "${args[@]}" > "$raw_out" 2>&1
  local rc=$?
  set -e
  t1="$(now_ms)"
  latency_ms=$((t1 - t0))

  if [ "$rc" -eq 124 ]; then
    echo "TIMEOUT|$latency_ms|$fixture_name|exceeded ${PER_FIXTURE_TIMEOUT}s wall-clock budget"
    rm -rf "$scratch"
    rm -f "$raw_out"
    return 0
  fi

  local completed_ok=1
  if [ "$rc" -ne 0 ]; then
    completed_ok=0
  fi
  if grep -q "Error: review failed" "$raw_out" 2>/dev/null; then
    completed_ok=0
  fi

  local result_text_file="$scratch.result.txt"
  if python3 "$CLASSIFY_PY" extract "$raw_out" > "$result_text_file" 2>/dev/null; then
    : # extracted OK (possibly empty text, which is itself meaningful)
  else
    rm -f "$result_text_file" # no terminal result line at all -> file absent -> None
  fi

  # roborev_eval_classify.py's `classify` mode deliberately exits nonzero for
  # any non-PASS status (FAIL/ERROR) so callers can use its exit code
  # directly. Under `set -e`, capturing that via a bare command substitution
  # assignment would abort THIS script the instant a fixture fails or
  # errors -- which is exactly the case this harness exists to report, not
  # to crash on. Guard the capture explicitly.
  local classify_line
  set +e
  if [ -f "$result_text_file" ]; then
    classify_line="$(python3 "$CLASSIFY_PY" classify "$expected_json" "$completed_ok" "$result_text_file")"
  else
    classify_line="$(python3 "$CLASSIFY_PY" classify "$expected_json" "$completed_ok")"
  fi
  set -e
  local status="${classify_line%%|*}"
  local reason="${classify_line#*|}"

  echo "$status|$latency_ms|$fixture_name|$reason"

  rm -rf "$scratch"
  rm -f "$raw_out" "$result_text_file"
  return 0
}

# ─── Main ────────────────────────────────────────────────────────────────────

echo "roborev_eval_run.sh: agent=${AGENT:-<config-default>} model=${MODEL:-<config-default>} timeout=${PER_FIXTURE_TIMEOUT}s runs=${RUNS} config_hash=${CONFIG_HASH}"
echo "fixtures: $FIXTURES_DIR"
echo ""

RUN_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
RUN_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ATTEMPTS_TSV="$(mktemp /tmp/roborev_eval_attempts_XXXXXX)"
trap 'rm -f "$ATTEMPTS_TSV"' EXIT
AGENT_LABEL="${AGENT:-config-default}"
MODEL_LABEL="${MODEL:-config-default}"

n_skip=0

# Sorted, deterministic order; each fixture is attempted RUNS times.
while IFS= read -r fixture_dir; do
  attempt=1
  while [ "$attempt" -le "$RUNS" ]; do
    line="$(run_fixture "$fixture_dir")"
    IFS='|' read -r status latency fname reason <<< "$line"
    if [ "$status" = "SKIP" ]; then
      echo "SKIP $fname: $reason"
      n_skip=$((n_skip + 1))
      break
    fi
    # TIMEOUT is indeterminate: stored and graded as ERROR, reason keeps why.
    result="$status"
    case "$status" in
      PASS|FAIL) ;;
      TIMEOUT) result="ERROR"; reason="TIMEOUT: $reason" ;;
      *) result="ERROR" ;;
    esac
    reason="$(printf '%s' "$reason" | tr '\t\n' '  ')"
    echo "  attempt $attempt/$RUNS: $fname $result ($latency ms) $reason"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$RUN_ID" "$RUN_AT" "roborev" "$fname" "$attempt" "$AGENT_LABEL" "$MODEL_LABEL" \
      "$CONFIG_HASH" "$result" "$reason" "$latency" >> "$ATTEMPTS_TSV"
    attempt=$((attempt + 1))
  done
done < <(find "$FIXTURES_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

# ─── Persist (never silently skipped) ────────────────────────────────────────
persisted="false"
if [ -s "$ATTEMPTS_TSV" ]; then
  if db_available && ensure_eval_table; then
    sql_file="$(mktemp /tmp/roborev_eval_sql_XXXXXX)"
    python3 "$CLASSIFY_PY" insert-sql "$ATTEMPTS_TSV" > "$sql_file"
    if "$DUCKDB" -init /dev/null "$UNIFIED_DB" < "$sql_file" >/dev/null 2>&1; then
      persisted="true"
      echo "persisted: $(wc -l < "$ATTEMPTS_TSV" | tr -d ' ') row(s) to eval_runs in $UNIFIED_DB (run_id=$RUN_ID)"
    else
      echo "roborev_eval_run.sh: persistence SKIPPED -- INSERT into eval_runs failed in $UNIFIED_DB" >&2
    fi
    rm -f "$sql_file"
  fi
fi

# ─── Grade: majority per fixture, overall exit code 0 / 1 / 3 ────────────────
echo ""
set +e
python3 "$CLASSIFY_PY" aggregate "$ATTEMPTS_TSV" "$JSON_OUT" \
  "config_hash=$CONFIG_HASH" "run_id=$RUN_ID" "runs=$RUNS" "persisted=$persisted" "source=run"
overall_rc=$?
set -e
[ "$n_skip" -gt 0 ] && echo "($n_skip fixture(s) skipped: missing diff.patch or expected.json)"
exit "$overall_rc"

