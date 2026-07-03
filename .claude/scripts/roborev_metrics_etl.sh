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
    # Use absolute path for nix-shell: launchd PATH does not resolve command -v
    # reliably inside the launchd sandbox even when the binary is in PATH.
    local _NIX_SHELL_BIN="/nix/var/nix/profiles/default/bin/nix-shell"
    if [ -f "$NIX_DEFAULT" ] && [ -x "$_NIX_SHELL_BIN" ]; then
      "$_NIX_SHELL_BIN" "$NIX_DEFAULT" --run "Rscript '$R_SCRIPT' $*" > "$_out" 2>&1
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

  # ── Case 9: parse_token_usage — empty/NULL input → NA ────────────────
  _tok_result=$(Rscript -e '
    parse_token_usage <- function(json_text) {
      empty <- list(tokens_in = NA_integer_, tokens_out = NA_integer_)
      if (is.na(json_text) || !nzchar(json_text)) return(empty)
      tryCatch({
        parsed <- jsonlite::fromJSON(json_text, simplifyVector = TRUE)
        `%||%` <- function(a, b) if (!is.null(a)) a else b
        tok_in  <- parsed$input_tokens %||% parsed$prompt_tokens %||%
                   parsed$inputTokens  %||% NA_integer_
        tok_out <- parsed$output_tokens %||% parsed$completion_tokens %||%
                   parsed$outputTokens %||% NA_integer_
        list(
          tokens_in  = if (is.null(tok_in)  || is.na(tok_in))  NA_integer_ else as.integer(tok_in),
          tokens_out = if (is.null(tok_out) || is.na(tok_out)) NA_integer_ else as.integer(tok_out)
        )
      }, error = function(e) empty)
    }
    r1 <- parse_token_usage(NA_character_)
    r2 <- parse_token_usage("")
    r3 <- parse_token_usage("not-json{{{{")
    ok <- is.na(r1$tokens_in) && is.na(r2$tokens_in) && is.na(r3$tokens_in)
    cat(if (ok) "yes" else "no")
  ' 2>/dev/null)
  _assert "parse_token_usage_null_na" "$_tok_result" "yes"

  # ── Case 10: parse_token_usage — valid JSON → integers ────────────────
  _tok_result2=$(Rscript -e '
    `%||%` <- function(a, b) if (!is.null(a)) a else b
    parse_token_usage <- function(json_text) {
      empty <- list(tokens_in = NA_integer_, tokens_out = NA_integer_)
      if (is.na(json_text) || !nzchar(json_text)) return(empty)
      tryCatch({
        parsed <- jsonlite::fromJSON(json_text, simplifyVector = TRUE)
        tok_in  <- parsed$input_tokens %||% parsed$prompt_tokens %||% parsed$inputTokens  %||% NA_integer_
        tok_out <- parsed$output_tokens %||% parsed$completion_tokens %||% parsed$outputTokens %||% NA_integer_
        list(
          tokens_in  = if (is.null(tok_in)  || is.na(tok_in))  NA_integer_ else as.integer(tok_in),
          tokens_out = if (is.null(tok_out) || is.na(tok_out)) NA_integer_ else as.integer(tok_out)
        )
      }, error = function(e) empty)
    }
    r <- parse_token_usage("{\"input_tokens\":100,\"output_tokens\":50}")
    cat(if (r$tokens_in == 100L && r$tokens_out == 50L) "yes" else "no")
  ' 2>/dev/null)
  _assert "parse_token_usage_valid_json" "$_tok_result2" "yes"

  # ── Case 11: build_threshold_changes — absent counter → empty df ──────
  _tc_result=$(Rscript -e '
    `%||%` <- function(a, b) if (!is.null(a)) a else b
    build_threshold_changes <- function(counter_data, since_date) {
      empty_df <- data.frame(
        changed_at_utc = as.POSIXct(character()),
        repo = character(), old_threshold = character(),
        new_threshold = character(), source = character(), actor = character(),
        stringsAsFactors = FALSE
      )
      if (length(counter_data) == 0L) return(empty_df)
      empty_df
    }
    r <- build_threshold_changes(list(), Sys.Date())
    cat(if (nrow(r) == 0L) "yes" else "no")
  ' 2>/dev/null)
  _assert "threshold_changes_empty_counter" "$_tc_result" "yes"

  # ── Case 12: parse_poll_log — absent file → empty list ────────────────
  _pl_result=$(Rscript -e '
    `%||%` <- function(a, b) if (!is.null(a)) a else b
    parse_poll_log <- function(path, since_date) {
      result <- list()
      if (!file.exists(path)) return(result)
      result
    }
    r <- parse_poll_log("/tmp/no_such_poll_log_$$_absent", Sys.Date())
    cat(if (length(r) == 0L) "yes" else "no")
  ' 2>/dev/null)
  _assert "parse_poll_log_absent_file" "$_pl_result" "yes"

  # ── Case 13: dry-run output includes all 5 table lines (real DB) ──────
  # When reviews.db is present, verify all 5 roborev_* tables appear in output.
  # When absent, verify graceful skip message appears (not a fatal error).
  _real_db="${ROBOREV_DB:-${HOME}/.roborev/reviews.db}"
  if [ -f "$_real_db" ]; then
    SCHEMA_FILE="$SCHEMA_FILE" _run_r_exit "$_TMPOUT" --dry-run >/dev/null 2>&1 || true
    _has_five=$(grep -c "roborev_" "$_TMPOUT" 2>/dev/null || echo "0")
    if [ "$_has_five" -ge 5 ]; then
      _assert "dry_run_shows_5_tables" "yes" "yes"
    else
      _assert "dry_run_shows_5_tables" "no" "yes"
    fi
  else
    # No real DB: verify graceful exit (SKIP line in output)
    _ec=$(ROBOREV_DB=/tmp/no_such_db_$$_absent SCHEMA_FILE="$SCHEMA_FILE" \
           _run_r_exit "$_TMPOUT" --dry-run)
    if grep -q "SKIP" "$_TMPOUT" 2>/dev/null; then
      _assert "dry_run_shows_5_tables" "yes" "yes"
    else
      _assert "dry_run_shows_5_tables" "no" "yes"
    fi
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
  # Use absolute path for nix-shell: launchd PATH does not resolve `command -v`
  # reliably even when /nix/var/nix/profiles/default/bin is in PATH (#511).
  local _NIX_SHELL_BIN="/nix/var/nix/profiles/default/bin/nix-shell"
  # shellcheck disable=SC2086
  if [ -f "$NIX_SHELL_DEFAULT" ] && [ -x "$_NIX_SHELL_BIN" ]; then
    ROBOREV_DB="$ROBOREV_DB" \
    UNIFIED_DB="$UNIFIED_DB" \
    SCHEMA_FILE="${SCHEMA_FILE:-${HOME}/.claude/scripts/roborev_metrics_schema.sql}" \
      "$_NIX_SHELL_BIN" "$NIX_SHELL_DEFAULT" --run "Rscript '$R_SCRIPT' $RSCRIPT_ARGS"
  else
    ROBOREV_DB="$ROBOREV_DB" \
    UNIFIED_DB="$UNIFIED_DB" \
    SCHEMA_FILE="${SCHEMA_FILE:-${HOME}/.claude/scripts/roborev_metrics_schema.sql}" \
      Rscript "$R_SCRIPT" $RSCRIPT_ARGS
  fi
}

_invoke_r

ROBOREV_EXIT=$?
log "roborev ETL end: exit=${ROBOREV_EXIT}"

# ── Import hook_events from JSONL staging (#710 durable fix) ─────────────────
# log_session.sh no longer calls the duckdb CLI in the `hook` case (which held
# an exclusive write lock on unified.duckdb for ~100ms on every PostToolUse).
# Instead it appends one JSON line per event to hook_events_staging.jsonl.
# We import that file here, at a time when Claude sessions are typically quiet
# (02:00 launchd run) and duckdb contention is low.
# Non-fatal: if the import fails (e.g. contention at the 08:00 daily-email run),
# events accumulate in the staging file and are imported on the next ETL cycle.
HOOK_STAGING="${HOME}/.claude/logs/hook_events_staging.jsonl"
if [ -f "${HOOK_STAGING}" ] && [ -s "${HOOK_STAGING}" ]; then
  log "hook_events_import: start"
  # Atomic hand-off: rename the staging file so new hook events during this
  # import go to a fresh staging file rather than being imported mid-read.
  _HOOK_IMPORT="${HOME}/.claude/logs/hook_events_import_$(date +%s).jsonl"
  mv "${HOOK_STAGING}" "${_HOOK_IMPORT}" 2>/dev/null || true
  if [ -f "${_HOOK_IMPORT}" ]; then
    duckdb -init /dev/null "${UNIFIED_DB}" -c "
      INSERT INTO hook_events (session_id, hook_name, event_type, output_preview, fired_at)
      SELECT
        session_id,
        hook_name,
        event_type,
        output_preview,
        CAST(ts AS TIMESTAMP) AS fired_at
      FROM read_json(
        '${_HOOK_IMPORT}',
        format        = 'newline_delimited',
        columns       = {ts: 'VARCHAR', session_id: 'VARCHAR',
                         hook_name: 'VARCHAR', event_type: 'VARCHAR',
                         output_preview: 'VARCHAR'},
        ignore_errors = true
      )
      WHERE session_id IS NOT NULL;
    " 2>/dev/null || log "hook_events_import: duckdb insert failed (non-fatal)"
    rm -f "${_HOOK_IMPORT}" 2>/dev/null || true
    log "hook_events_import: end"
  fi
else
  log "hook_events_import: SKIP (no pending events in staging)"
fi

# ── Skill usage ETL (merged here so both ETL steps share one GC-root refresh
#    and skill_usage rows are captured by the 03:00 unified.duckdb backup) ──
SKILL_ETL_SCRIPT="${SCRIPT_DIR}/skill_usage_etl.sh"
if [ -x "$SKILL_ETL_SCRIPT" ]; then
  log "skill_usage_etl: start"
  "$SKILL_ETL_SCRIPT" "$MODE" >> "$LOGFILE" 2>&1 || true
  log "skill_usage_etl: end"
else
  log "skill_usage_etl: SKIP (script not found or not executable: ${SKILL_ETL_SCRIPT})"
fi

EXIT_CODE=$ROBOREV_EXIT
log "end: exit=${EXIT_CODE}"

# Stamp for cron_catchup.sh catch-up detection (only on success)
if [ "${EXIT_CODE}" -eq 0 ]; then
  mkdir -p "${HOME}/.claude/logs/stamps"
  date -u +%Y-%m-%dT%H:%M:%SZ > "${HOME}/.claude/logs/stamps/roborev-metrics-etl.stamp"
fi

echo "roborev_metrics_etl: exit=${EXIT_CODE}"
exit $EXIT_CODE
