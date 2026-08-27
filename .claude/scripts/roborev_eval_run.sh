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
#   roborev_eval_run.sh --selftest
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
# Exit codes:
#   0 — all fixtures PASS (or --selftest: all cases PASS)
#   1 — one or more fixtures FAIL, ERROR, or TIMEOUT
#   2 — usage error / roborev binary not found / fixtures dir not found
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

usage() {
  sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --agent)    AGENT="$2"; shift 2 ;;
    --model)    MODEL="$2"; shift 2 ;;
    --fixtures) FIXTURES_DIR="$2"; shift 2 ;;
    --timeout)  PER_FIXTURE_TIMEOUT="$2"; shift 2 ;;
    --selftest) SELFTEST=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [ "$SELFTEST" -eq 1 ]; then
  exec python3 "$CLASSIFY_PY" selftest
fi

if ! command -v roborev >/dev/null 2>&1; then
  echo "ERROR: roborev binary not found on PATH" >&2
  exit 2
fi

if [ ! -d "$FIXTURES_DIR" ]; then
  echo "ERROR: fixtures directory not found: $FIXTURES_DIR" >&2
  exit 2
fi

# ─── Run one fixture ────────────────────────────────────────────────────────
# Prints one line: "<STATUS>|<fixture_name>|<reason>"
#   STATUS in {PASS, FAIL, ERROR, TIMEOUT, SKIP}
run_fixture() {
  local fixture_dir="$1"
  local fixture_name
  fixture_name="$(basename "$fixture_dir")"
  local diff_patch="$fixture_dir/diff.patch"
  local expected_json="$fixture_dir/expected.json"
  local baseline_dir="$fixture_dir/baseline"

  if [ ! -f "$diff_patch" ] || [ ! -f "$expected_json" ]; then
    echo "SKIP|$fixture_name|missing diff.patch or expected.json"
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
    echo "ERROR|$fixture_name|diff.patch failed to apply: $(tr '\n' ' ' < "$apply_err")"
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

  set +e
  timeout "$PER_FIXTURE_TIMEOUT" roborev "${args[@]}" > "$raw_out" 2>&1
  local rc=$?
  set -e

  if [ "$rc" -eq 124 ]; then
    echo "TIMEOUT|$fixture_name|exceeded ${PER_FIXTURE_TIMEOUT}s wall-clock budget"
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

  echo "$status|$fixture_name|$reason"

  rm -rf "$scratch"
  rm -f "$raw_out" "$result_text_file"
  return 0
}

# ─── Main ────────────────────────────────────────────────────────────────────

echo "roborev_eval_run.sh: agent=${AGENT:-<config-default>} model=${MODEL:-<config-default>} timeout=${PER_FIXTURE_TIMEOUT}s"
echo "fixtures: $FIXTURES_DIR"
echo ""

n_pass=0
n_fail=0
n_error=0
n_timeout=0
n_skip=0

# Sorted, deterministic order
while IFS= read -r fixture_dir; do
  line="$(run_fixture "$fixture_dir")"
  echo "$line"
  status="${line%%|*}"
  case "$status" in
    PASS)    n_pass=$((n_pass + 1)) ;;
    FAIL)    n_fail=$((n_fail + 1)) ;;
    ERROR)   n_error=$((n_error + 1)) ;;
    TIMEOUT) n_timeout=$((n_timeout + 1)) ;;
    SKIP)    n_skip=$((n_skip + 1)) ;;
    *)       n_error=$((n_error + 1)) ;;
  esac
done < <(find "$FIXTURES_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

n_total=$((n_pass + n_fail + n_error + n_timeout))

echo ""
echo "Summary: $n_pass/$n_total PASS ($n_fail FAIL, $n_error ERROR, $n_timeout TIMEOUT, $n_skip SKIP)"

if [ "$n_fail" -gt 0 ] || [ "$n_error" -gt 0 ] || [ "$n_timeout" -gt 0 ]; then
  exit 1
fi
exit 0
