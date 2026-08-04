#!/usr/bin/env bash
# sentinel_log_sweep.sh — pure helper functions for JohnGavin/llm#884 steps 2-3:
#   sweep_stale_sentinels() — delete orphaned session sentinels older than N days
#   rotate_log_file()/rotate_logs() — copy-truncate oversized log files
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
# .bye-requested(.<sid>) / .bye-session-end-refine(.<sid>), written by
# session_stop.sh at every /bye. Nothing ever deletes any of these; they are
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
                -o -name '.bye-session-end-refine*' \) \
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
    *)
      echo "Usage: $0 {sweep <dir> [age_days]|rotate <dir> [threshold_bytes] [keep_lines]} [--apply]" >&2
      exit 64
      ;;
  esac
fi
