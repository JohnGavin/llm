#!/usr/bin/env bash
# lib_signal_process_guard.sh — shared helpers for signal_notes_sync.sh and
# signal_braindump_handler.sh.
#
# Origin (llm#937 / llm#957): a `signal-cli receive` process from 19 Aug
# 20:28 was found still running on 21 Aug, holding the signal-cli config
# lock. Every sync since blocked on that lock. Root causes:
#   1. `timeout 30 signal-cli ... receive` cannot kill signal-cli. `timeout`
#      without `-k` sends SIGTERM once and returns even if the child ignores
#      it. signal-cli logs "Shutdown - Received SIGTERM signal, shutting
#      down ..." and then does NOT exit — the wrapper exits, the child (and
#      the lock) survives forever.
#   2. Neither script passed signal-cli's own `-t/--timeout`.
#   3. Multiple consumers contend for one config lock (daemon +
#      signal_notes_sync.sh + signal_braindump_handler.sh); a direct
#      `receive` while the daemon holds the lock deadlocks.
#
# This file provides:
#   _bounded_kill <timeout_secs> <kill_grace_secs> <cmd...>
#     A timeout wrapper that TRULY escalates to SIGKILL, unlike bare
#     `timeout N cmd`.
#   _signal_cli_already_running <pattern>
#     A pre-flight guard: refuse to start a second `receive` if one is
#     already running. Never kills it automatically — killing mid-`receive`
#     can consume-and-discard messages server-side.
#
# Source this file; do not execute it directly.

# _bounded_kill <timeout_secs> <kill_grace_secs> <cmd...>
#
# Plain `timeout N cmd` (no -k) sends SIGTERM once and returns even if the
# child ignores it and keeps running — this is how a wedged signal-cli
# `receive` held the config lock for ~40 hours. `-k <grace>` (or the
# pure-shell fallback below) is what actually guarantees the process is
# gone by the time this function returns.
_bounded_kill() {
  local secs="$1" grace="$2"
  shift 2
  local timeout_bin
  timeout_bin=$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)
  if [ -n "$timeout_bin" ]; then
    # GNU coreutils timeout/gtimeout: -k <grace> sends SIGKILL if the
    # command is still alive <grace> seconds after the initial SIGTERM.
    # This branch CAN truly SIGKILL — that is exactly what -k is for.
    "$timeout_bin" -k "$grace" "$secs" "$@"
    return $?
  fi
  # No GNU timeout/gtimeout on PATH (e.g. bare macOS under launchd's minimal
  # PATH, which is /usr/bin:/bin:/usr/sbin:/sbin). Pure-shell
  # SIGTERM-then-SIGKILL escalation, adapted from the fallback pattern in
  # roborev_agent_health.sh's _timeout(). This branch ALSO truly SIGKILLs —
  # it is not a weaker substitute for the GNU-timeout branch above.
  "$@" &
  local pid=$!
  (
    sleep "$secs"
    kill -TERM "$pid" 2>/dev/null
    sleep "$grace"
    kill -KILL "$pid" 2>/dev/null
  ) &
  local watchdog=$!
  local rc=0
  wait "$pid" 2>/dev/null || rc=$?
  kill "$watchdog" 2>/dev/null
  wait "$watchdog" 2>/dev/null
  # Normalise forced-termination exit codes (143=SIGTERM, 137=SIGKILL) to
  # GNU timeout's 124 convention so callers can treat both branches the same.
  if [ "$rc" -eq 143 ] || [ "$rc" -eq 137 ]; then
    return 124
  fi
  return "$rc"
}

# _signal_cli_already_running [pattern]
#
# Returns 0 (true, "match found") if a process matching <pattern> is
# already running; 1 otherwise. Defaults to matching any signal-cli
# `receive` invocation. Never kills anything — callers must refuse to start
# and log clearly instead (killing mid-`receive` can consume-and-discard
# messages server-side).
#
# PGREP_BIN is overridable for tests (point it at a fake pgrep that reads
# from a fixture process table instead of the live process list).
_signal_cli_already_running() {
  local pattern="${1:-signal-cli.*receive}"
  local pgrep_bin="${PGREP_BIN:-pgrep}"
  command -v "$pgrep_bin" >/dev/null 2>&1 || return 1
  "$pgrep_bin" -f "$pattern" >/dev/null 2>&1
}

# _signal_daemon_listening [port]
#
# Returns 0 (true) if a process is listening on <port> (default 7583, the
# signal-cli daemon's port). LSOF_BIN is overridable for tests (point it at
# a fake lsof so the daemon-up/daemon-down branches can be exercised
# deterministically, without binding the real port or depending on whether
# the live signal-cli daemon happens to be running on this machine).
_signal_daemon_listening() {
  local port="${1:-7583}"
  local lsof_bin="${LSOF_BIN:-/usr/sbin/lsof}"
  command -v "$lsof_bin" >/dev/null 2>&1 || return 1
  "$lsof_bin" -i ":$port" -sTCP:LISTEN >/dev/null 2>&1
}
