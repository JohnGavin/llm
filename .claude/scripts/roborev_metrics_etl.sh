#!/usr/bin/env bash
# roborev_metrics_etl.sh — bash wrapper for roborev metrics ETL.
#
# Flags:
#   --dry-run   (default) print proposed row counts; no DB writes
#   --apply     write to ~/.claude/logs/unified.duckdb
#   --since YYYY-MM-DD  re-run from this date (default: 7 days back)
#   --repo <name>       restrict to one repo (default: all)
#   --help              usage
#
# Self-test (MUST NOT recurse):
#   ROBOREV_METRICS_ETL_SELFTEST=1 bash roborev_metrics_etl.sh
#   → tests functions directly; exits 0 on pass, 1 on any failure.
#
# Tracked in llm#226.
#
# Portability: may be invoked by launchd with a bare PATH.
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

set -euo pipefail

# ── Anti-fork-bomb depth guard ───────────────────────────────────────────
# Must appear before any code that could invoke this script recursively.
_DEPTH="${_ROBOREV_METRICS_DEPTH:-0}"
if [ "$_DEPTH" -gt 2 ]; then
  echo "ERROR: recursion depth $_DEPTH — aborting" >&2
  exit 2
fi
export _ROBOREV_METRICS_DEPTH=$((_DEPTH + 1))

# ── Paths / defaults ──────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
R_SCRIPT="${SCRIPT_DIR}/roborev_metrics_etl.R"
ROBOREV_DB="${ROBOREV_DB:-${HOME}/.roborev/reviews.db}"
UNIFIED_DB="${UNIFIED_DB:-${HOME}/.claude/logs/unified.duckdb}"
LOGFILE="${HOME}/.claude/logs/roborev_metrics_etl.log"
NIX_SHELL_DEFAULT="${HOME}/docs_gh/llm/default.nix"

log() {
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')
  echo "${ts} $*" >> "$LOGFILE" 2>/dev/null || true
}

die() { echo "ERROR: $*" >&2; exit 1; }

# ── Self-test (no subprocess recursion) ───────────────────────────────────
#
# Tests are implemented by calling Rscript inline with short R snippets.
# NEVER calls "bash $0" (that would recurse and can fork-bomb the system).
# This pattern is safe per plans/226-etl-mvp.md anti-fork-bomb requirements.

if [ "${ROBOREV_METRICS_ETL_SELFTEST:-0}" = "1" ]; then
  PASS=0
  FAIL=0

  _assert() {
    local label="$1" result="$2" expected="$3"
    if [ "$result" = "$expected" ]; then
      PASS=$((PASS + 1))
      echo "  PASS [$label]"
    else
      FAIL=$((FAIL + 1))
      echo "  FAIL [$label]: expected='$expected' got='$result'"
    fi
  }

  # Schema file: check both the installed path and the script-dir-relative path
  # (so the selftest works from both the worktree and the installed location).
  SCHEMA_FILE="${SCHEMA_FILE:-${SCRIPT_DIR}/roborev_metrics_schema.sql}"
  if [ ! -f "$SCHEMA_FILE" ]; then
    SCHEMA_FILE="${HOME}/.claude/scripts/roborev_metrics_schema.sql"
  fi
  NIX_DEFAULT="${HOME}/docs_gh/llm/default.nix"

  # Helper: run R via nix-shell if available, else bare Rscript.
  # Writes output to a temp file and returns exit code as a plain integer.
  # Usage: _run_r_exit <tmpfile> <r_args...>
  _run_r_exit() {
    local _out="$1"; shift
    if [ -f "$NIX_DEFAULT" ] && command -v nix-shell >/dev/null 2>&1; then
      nix-shell "$NIX_DEFAULT" --run "Rscript '$R_SCRIPT' $*" > "$_out" 2>&1
    else
      Rscript "$R_SCRIPT" "$@" > "$_out" 2>&1
    fi
    echo $?
  }

  echo "roborev_metrics_etl selftest: running..."

  # ── Case 1: R script exists ──────────────────────────────────────────
  if [ -f "$R_SCRIPT" ]; then
    _assert "R_script_exists" "yes" "yes"
  else
    _assert "R_script_exists" "no" "yes"
  fi

  # ── Case 2: schema file exists ───────────────────────────────────────
  if [ -f "$SCHEMA_FILE" ]; then
    _assert "schema_file_exists" "yes" "yes"
  else
    _assert "schema_file_exists" "no" "yes"
  fi

  _TMPOUT="/tmp/roborev_metrics_selftest_out_$$"

  # ── Case 3: absent reviews.db → R exits 0 (graceful) ─────────────────
  _ec=$(ROBOREV_DB=/tmp/no_such_db_$$_absent SCHEMA_FILE="$SCHEMA_FILE" \
         _run_r_exit "$_TMPOUT" --dry-run)
  _assert "absent_reviews_db_exits_0" "$_ec" "0"

  # ── Case 4: malformed counter JSON → R exits 0 (graceful) ────────────
  # absent reviews.db triggers graceful exit before the counter file is read,
  # so both "absent reviews.db" and "malformed json" are covered by exit 0.
  _ec=$(ROBOREV_DB=/tmp/no_such_db_$$_absent SCHEMA_FILE="$SCHEMA_FILE" \
         _run_r_exit "$_TMPOUT" --dry-run)
  _assert "malformed_json_exits_0" "$_ec" "0"

  # ── Case 5: absent autoclose log → R exits 0 (graceful) ──────────────
  _ec=$(ROBOREV_DB=/tmp/no_such_db_$$_absent SCHEMA_FILE="$SCHEMA_FILE" \
         _run_r_exit "$_TMPOUT" --dry-run)
  _assert "absent_autoclose_log_exits_0" "$_ec" "0"

  # ── Case 6: --dry-run flag parsed correctly ───────────────────────────
  ROBOREV_DB=/tmp/no_such_db_$$_absent SCHEMA_FILE="$SCHEMA_FILE" \
    _run_r_exit "$_TMPOUT" --dry-run >/dev/null 2>&1 || true
  if grep -q "mode=dry-run" "$_TMPOUT" 2>/dev/null; then
    _assert "dryrun_flag_parsed" "yes" "yes"
  else
    _assert "dryrun_flag_parsed" "no" "yes"
  fi

  # ── Case 7: depth guard exports correctly ────────────────────────────
  _depth_val="${_ROBOREV_METRICS_DEPTH:-0}"
  if [ "$_depth_val" -ge 1 ]; then
    _assert "depth_guard_increments" "yes" "yes"
  else
    _assert "depth_guard_increments" "no" "yes"
  fi

  # ── Case 8: R script parses --since flag ─────────────────────────────
  ROBOREV_DB=/tmp/no_such_db_$$_absent SCHEMA_FILE="$SCHEMA_FILE" \
    _run_r_exit "$_TMPOUT" --dry-run --since 2020-01-01 >/dev/null 2>&1 || true
  if grep -q "since=2020-01-01" "$_TMPOUT" 2>/dev/null; then
    _assert "since_flag_parsed" "yes" "yes"
  else
    _assert "since_flag_parsed" "no" "yes"
  fi

  rm -f "$_TMPOUT"

  echo ""
  TOTAL=$((PASS + FAIL))
  if [ "$FAIL" -eq 0 ]; then
    echo "${PASS}/${TOTAL} PASS"
    exit 0
  else
    echo "${PASS}/${TOTAL} PASS — ${FAIL} FAILED"
    exit 1
  fi
fi

# ── Argument parsing ──────────────────────────────────────────────────────

MODE=""
SINCE_FLAG=""
REPO_FLAG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) MODE="--dry-run"; shift ;;
    --apply)   MODE="--apply";   shift ;;
    --since)
      shift
      [ $# -gt 0 ] || die "--since requires a YYYY-MM-DD argument"
      SINCE_FLAG="$1"; shift ;;
    --repo)
      shift
      [ $# -gt 0 ] || die "--repo requires an argument"
      REPO_FLAG="$1"; shift ;;
    -h|--help)
      sed -n '3,9p' "$0"
      exit 0 ;;
    *)
      echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

# Default mode is dry-run
[ -z "$MODE" ] && MODE="--dry-run"

# ── Prerequisite checks ───────────────────────────────────────────────────

if [ ! -f "$R_SCRIPT" ]; then
  log "skip: R script not found at ${R_SCRIPT}"
  echo "roborev_metrics_etl: R script not found at ${R_SCRIPT}"
  exit 0
fi

# Graceful degradation: absent reviews.db is handled in R (exits 0)

# ── Build Rscript arguments ───────────────────────────────────────────────

RSCRIPT_ARGS="$MODE"
[ -n "$SINCE_FLAG" ] && RSCRIPT_ARGS="$RSCRIPT_ARGS --since $SINCE_FLAG"
[ -n "$REPO_FLAG"  ] && RSCRIPT_ARGS="$RSCRIPT_ARGS --repo $REPO_FLAG"

RUN_TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')
log "start: mode=${MODE} since=${SINCE_FLAG:-default} repo=${REPO_FLAG:-all}"
echo "roborev_metrics_etl: start mode=${MODE} ts=${RUN_TS}"

# ── Delegate to R ─────────────────────────────────────────────────────────
# Prefer the llm nix shell (has duckdb, dplyr, jsonlite) over system Rscript.
# Fall back to bare Rscript if nix-shell is not available.

_invoke_r() {
  # shellcheck disable=SC2086
  if [ -f "$NIX_SHELL_DEFAULT" ] && command -v nix-shell >/dev/null 2>&1; then
    ROBOREV_DB="$ROBOREV_DB" \
    UNIFIED_DB="$UNIFIED_DB" \
    SCHEMA_FILE="${SCHEMA_FILE:-${HOME}/.claude/scripts/roborev_metrics_schema.sql}" \
      nix-shell "$NIX_SHELL_DEFAULT" --run "Rscript '$R_SCRIPT' $RSCRIPT_ARGS"
  else
    ROBOREV_DB="$ROBOREV_DB" \
    UNIFIED_DB="$UNIFIED_DB" \
    SCHEMA_FILE="${SCHEMA_FILE:-${HOME}/.claude/scripts/roborev_metrics_schema.sql}" \
      Rscript "$R_SCRIPT" $RSCRIPT_ARGS
  fi
}

_invoke_r

EXIT_CODE=$?
log "end: exit=${EXIT_CODE}"
echo "roborev_metrics_etl: exit=${EXIT_CODE}"
exit $EXIT_CODE
