#!/usr/bin/env bash
# sentinel_log_sweep.sh — pure helper functions for JohnGavin/llm#884 steps 2-4:
#   sweep_stale_sentinels() — delete orphaned session sentinels older than N days
#   rotate_log_file()/rotate_logs() — copy-truncate oversized log files
#   sweep_claude_json_tmp() — delete orphaned ~/.claude.json.tmp.<pid>.<hash>
#                             atomic-write temporaries whose PID is not alive
#
# Sourced by worktree_gc.sh (the existing daily housekeeping job, per the
# housekeeping-framework rule) so these run for real once a day, gated by the
# SAME --apply flag as worktree removal (dry-run by default; only the
# launchd-scheduled invocation passes --apply). This file has NO top-level
# side effects when sourced — `source sentinel_log_sweep.sh` only defines
# functions, so tests can source it directly against a fixture directory
# without ever touching the real ~/.claude/.
#
# Tracks: JohnGavin/llm#884

# ── Sentinel sweep (Finding 2) ────────────────────────────────────────────────
# session_init.sh writes ~/.claude/.session_start_sha_<slug> at every session
# start, keyed by PROJECT SLUG (not session id) — two concurrent sessions on
# the same project share one file, so deleting it on consume (in
# session_end_refine.sh) would break the other session. Same story for
# .bye-requested(.<sid>) / .bye-session-stop(.<sid>) / .bye-session-end-refine(.<sid>),
# written by /bye at every session end (llm#913: each Stop-chain consumer —
# llmtelemetry_emit.sh, session_stop.sh, the session-end-refine block — owns
# its own dedicated sentinel basename so they don't compete for one token).
# Nothing ever deletes any of these; they are
# fully re-derivable state (session_init.sh recreates them every session
# start), so an AGE-BASED sweep is the safe cleanup — anything untouched for
# the threshold is orphaned regardless of "consumed" status.
#
# args: dir age_days [dry_run=0]
# Sets global SENTINELS_SWEPT to the count removed (or, in dry-run, the count
# that would be removed). Never fails the caller — internal errors are
# swallowed and treated as "0 swept".
sweep_stale_sentinels() {
  local _dir="$1" _age_days="$2" _dry="${3:-0}"
  SENTINELS_SWEPT=0
  [ -d "$_dir" ] || return 0

  local _f _count=0
  while IFS= read -r -d '' _f; do
    if [ "$_dry" = "1" ]; then
      _count=$(( _count + 1 ))
    elif rm -f -- "$_f" 2>/dev/null; then
      _count=$(( _count + 1 ))
    fi
  done < <(find "$_dir" -maxdepth 1 -type f \
             \( -name '.session_start_sha_*' -o -name '.bye-requested*' \
                -o -name '.bye-session-stop*' -o -name '.bye-session-end-refine*' \) \
             -mtime "+${_age_days}" -print0 2>/dev/null || true)

  SENTINELS_SWEPT=$_count
  return 0
}

# ── Log rotation (Finding 3) ──────────────────────────────────────────────────
# Size-based, not age-based — the llm#884 audit found 0 logs older than 30
# days (everything is actively written), so the only lever is truncate-to-
# tail. Copy-truncate IN PLACE (never mv/rename): `cat tmp > path` truncates
# the existing inode's contents rather than swapping the inode, so a writer
# that already has the file open (append mode) keeps a valid file descriptor
# pointing at the same (now-truncated) file. DuckDB files are matched by
# extension and skipped unconditionally — never touch logs/*.duckdb.

# args: path threshold_bytes keep_lines [dry_run=0]
# Sets global _ROTATED_ONE to 1 if the file was (or, in dry-run, would be)
# rotated, 0 otherwise.
rotate_log_file() {
  local _path="$1" _threshold="$2" _keep_lines="$3" _dry="${4:-0}"
  _ROTATED_ONE=0
  [ -f "$_path" ] || return 0
  case "$_path" in
    *.duckdb) return 0 ;;
  esac

  local _size
  _size=$(wc -c < "$_path" 2>/dev/null | tr -d '[:space:]')
  [ -z "$_size" ] && _size=0
  [ "$_size" -le "$_threshold" ] && return 0

  if [ "$_dry" = "1" ]; then
    _ROTATED_ONE=1
    return 0
  fi

  local _tmp
  _tmp=$(mktemp "${_path}.XXXXXX.tmp" 2>/dev/null) || return 0
  if ! tail -n "$_keep_lines" "$_path" > "$_tmp" 2>/dev/null; then
    rm -f "$_tmp"
    return 0
  fi

  # Keep exactly one prior generation (overwrites any earlier .1).
  cp -f "$_path" "${_path}.1" 2>/dev/null || true

  # Copy-truncate IN PLACE — see header comment. Never mv/rename here.
  if cat "$_tmp" > "$_path" 2>/dev/null; then
    rm -f "$_tmp"
    _ROTATED_ONE=1
  else
    rm -f "$_tmp"
  fi
  return 0
}

# args: dir threshold_bytes keep_lines [dry_run=0] [logger_fn]
# logger_fn, if given, is called as: "$logger_fn" "<message>" once per file
# that was (or would be) rotated — lets the caller reuse its own log()
# implementation instead of this file owning any logging/output policy.
# Sets global LOGS_ROTATED to the count rotated (or would-rotate in dry-run).
rotate_logs() {
  local _dir="$1" _threshold="$2" _keep_lines="$3" _dry="${4:-0}" _logger_fn="${5:-}"
  LOGS_ROTATED=0
  [ -d "$_dir" ] || return 0

  local _f _count=0
  while IFS= read -r -d '' _f; do
    rotate_log_file "$_f" "$_threshold" "$_keep_lines" "$_dry"
    if [ "${_ROTATED_ONE:-0}" = "1" ]; then
      _count=$(( _count + 1 ))
      if [ -n "$_logger_fn" ]; then
        if [ "$_dry" = "1" ]; then
          "$_logger_fn" "[log-rotate-dryrun] $_f exceeds threshold — would truncate to last ${_keep_lines} lines"
        else
          "$_logger_fn" "[log-rotate] $_f truncated to last ${_keep_lines} lines (prior generation: ${_f}.1)"
        fi
      fi
    fi
  done < <(find "$_dir" -maxdepth 1 -type f \
             \( -name '*.log' -o -name '*.err' -o -name '*.out' \) \
             -print0 2>/dev/null || true)

  LOGS_ROTATED=$_count
  return 0
}

# ── claude.json.tmp sweep (Finding 4) ─────────────────────────────────────────
# Claude Code writes ~/.claude.json by temp-file-then-rename
# (.claude.json.tmp.<pid>.<hash>); a crash or kill between the write and the
# rename leaves the temp behind permanently — nothing else ever cleans it up.
# Deleting purely by pattern match would be unsafe: a write genuinely in
# progress right now is also named .claude.json.tmp.<pid>.<hash>, and would
# look identical to an orphan by name alone. So this checks PID liveness
# (`kill -0`) before deleting anything — a temp file is swept only when the
# PID embedded in its own name is NOT currently running.
#
# Known limitation (documented, not silently assumed away): PID liveness is a
# heuristic, not a proof the CURRENT holder of that PID is unrelated — PIDs
# are reused by the OS over time, so in the rare case a new, unrelated process
# is assigned the exact same PID before this sweep runs, an orphan would be
# skipped as "still live" (a false negative — the safe direction to be wrong
# in; it never deletes a file a live process might still be writing to it
# just leaves debris one more cycle for the next run to catch once that PID
# frees up again).
#
# A filename whose PID segment doesn't parse as a plain positive integer is
# NOT swept either — an unparseable name is an indeterminate result, not a
# green light to delete (checks-must-distinguish-unknown): it is logged and
# left alone rather than guessed about.
#
# args: home_dir [dry_run=0]
# Sets global CLAUDE_JSON_TMP_SWEPT to the count removed (or, in dry-run, the
# count that would be removed) and CLAUDE_JSON_TMP_SKIPPED_LIVE to the count
# left alone because their PID is still running. Never fails the caller.
sweep_claude_json_tmp() {
  local _home="$1" _dry="${2:-0}"
  CLAUDE_JSON_TMP_SWEPT=0
  CLAUDE_JSON_TMP_SKIPPED_LIVE=0
  [ -d "$_home" ] || return 0

  local _f _base _rest _pid _count=0 _skipped=0
  while IFS= read -r -d '' _f; do
    _base="${_f##*/}"
    # Expect: .claude.json.tmp.<pid>.<hash>
    _rest="${_base#.claude.json.tmp.}"
    _pid="${_rest%%.*}"
    case "$_pid" in
      ''|*[!0-9]*)
        # PID segment doesn't parse — indeterminate, leave it alone.
        continue
        ;;
    esac
    if kill -0 "$_pid" 2>/dev/null; then
      _skipped=$(( _skipped + 1 ))
      continue
    fi
    if [ "$_dry" = "1" ]; then
      _count=$(( _count + 1 ))
    elif rm -f -- "$_f" 2>/dev/null; then
      _count=$(( _count + 1 ))
    fi
  done < <(find "$_home" -maxdepth 1 -type f -name '.claude.json.tmp.*' -print0 2>/dev/null || true)

  CLAUDE_JSON_TMP_SWEPT=$_count
  CLAUDE_JSON_TMP_SKIPPED_LIVE=$_skipped
  return 0
}

# ── Standalone CLI (only runs when executed directly, never when sourced) ────
# Dry-run by default, matching worktree_gc.sh's own UX; --apply performs the
# real operation. Lets the helper be exercised/debugged without going through
# worktree_gc.sh.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -euo pipefail
  _cli_apply=0
  _cli_args=()
  for _a in "$@"; do
    if [ "$_a" = "--apply" ]; then
      _cli_apply=1
    else
      _cli_args+=("$_a")
    fi
  done
  _cli_dry=$(( 1 - _cli_apply ))

  case "${_cli_args[0]:-}" in
    sweep)
      sweep_stale_sentinels "${_cli_args[1]:?dir required}" "${_cli_args[2]:-7}" "$_cli_dry"
      echo "swept=$SENTINELS_SWEPT dry_run=$_cli_dry"
      ;;
    rotate)
      rotate_logs "${_cli_args[1]:?dir required}" "${_cli_args[2]:-10485760}" "${_cli_args[3]:-2000}" "$_cli_dry"
      echo "rotated=$LOGS_ROTATED dry_run=$_cli_dry"
      ;;
    sweep-claude-json-tmp)
      sweep_claude_json_tmp "${_cli_args[1]:?home dir required}" "$_cli_dry"
      echo "swept=$CLAUDE_JSON_TMP_SWEPT skipped_live=$CLAUDE_JSON_TMP_SKIPPED_LIVE dry_run=$_cli_dry"
      ;;
    *)
      echo "Usage: $0 {sweep <dir> [age_days]|rotate <dir> [threshold_bytes] [keep_lines]|sweep-claude-json-tmp <home_dir>} [--apply]" >&2
      exit 64
      ;;
  esac
fi
