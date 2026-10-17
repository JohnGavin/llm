#!/usr/bin/env bash
# run_bounded.sh -- shared "run a command with a time limit" helper (sourced).
# JohnGavin/llm roborev job 14186.
#
# GNU `timeout` is not on a stock macOS PATH (it lives in /opt/homebrew/bin or
# in the nix shell). Calling it bare exits 127 on a PATH without it, which
# callers then misread as "the lookup failed". This helper resolves a wrapper
# at runtime, in order:
#   1. `timeout` on PATH            4. /opt/homebrew/bin, /usr/local/bin
#   2. `gtimeout` on PATH              (timeout, then gtimeout)
#   3. perl `alarm` (perl on PATH or /usr/bin/perl), which survives exec
#
# Usage:  run_bounded SECONDS CMD [ARGS...]
# Exit:   the command's own status; 124 when the limit killed it; 125 when NO
#         bounding mechanism exists. In the 125 case the command is NOT run
#         (an unbounded network lookup inside a hook could hang the session),
#         and a one-line reason is written to stderr. Callers must treat 125 as
#         INDETERMINATE and say why, never as a negative result.
# Test seams (env): RB_SEARCH_DIRS (default "/opt/homebrew/bin /usr/local/bin"),
# RB_PERL_FALLBACK (default /usr/bin/perl).
# Bash 3.2 compatible. Sets no shell options.

_RB_KIND=""   # resolved once: "bin:<path>" | "perl:<path>" | "none"

_rb_resolve() {
  [ -n "$_RB_KIND" ] && return 0
  local c d p
  for c in timeout gtimeout; do
    p="$(command -v "$c" 2>/dev/null)" || p=""
    if [ -n "$p" ] && [ -x "$p" ]; then _RB_KIND="bin:$p"; return 0; fi
  done
  for d in ${RB_SEARCH_DIRS:-/opt/homebrew/bin /usr/local/bin}; do
    for c in timeout gtimeout; do
      if [ -x "$d/$c" ]; then _RB_KIND="bin:$d/$c"; return 0; fi
    done
  done
  p="$(command -v perl 2>/dev/null)" || p=""
  if [ -z "$p" ] && [ -x "${RB_PERL_FALLBACK:-/usr/bin/perl}" ]; then p="${RB_PERL_FALLBACK:-/usr/bin/perl}"; fi
  if [ -n "$p" ] && [ -x "$p" ]; then _RB_KIND="perl:$p"; return 0; fi
  _RB_KIND="none"
}

run_bounded() {
  local secs="$1" rc
  shift
  _rb_resolve
  case "$_RB_KIND" in
    bin:*)
      "${_RB_KIND#bin:}" "$secs" "$@"
      return $?
      ;;
    perl:*)
      "${_RB_KIND#perl:}" -e 'alarm shift @ARGV; exec @ARGV or exit 127' "$secs" "$@"
      rc=$?
      if [ "$rc" -eq 142 ]; then return 124; fi   # killed by SIGALRM
      return "$rc"
      ;;
    *)
      echo "run_bounded: no timeout, gtimeout or perl found; refusing to run an unbounded command (INDETERMINATE)" >&2
      return 125
      ;;
  esac
}
