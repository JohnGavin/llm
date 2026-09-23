#!/usr/bin/env bash
# check_orphan_daemon.sh — detect a self-daemonized process re-parented to init.
#
# Some daemon-backed CLIs auto-start their own daemon from any client
# invocation when none is reachable. The spawned daemon then outlives its
# short-lived parent and is re-parented to init (PPID becomes 1), where it
# keeps running unsupervised — invisible to launchd, unkillable by
# `launchctl`, and often burning CPU indefinitely. This is the exact pattern
# already documented for roborev in `long-running-process-supervision`
# (llm#936) and observed again for `agentsview serve` in llm#1136.
#
# A naive "is X running?" probe does NOT distinguish a deliberate manual
# launch (parented to a normal shell) from this orphan condition. PPID == 1
# is the discriminating signal this script checks for.
#
# Usage:
#   check_orphan_daemon.sh [pattern words...]   # live check (default pattern:
#                                                # "agentsview serve")
#   check_orphan_daemon.sh --selftest           # built-in regression test
#
# Examples:
#   check_orphan_daemon.sh                      # checks for "agentsview serve"
#   check_orphan_daemon.sh agentsview serve      # same, explicit
#   check_orphan_daemon.sh roborev daemon run    # reuse for a different CLI
#
# The pattern is matched as a literal substring against each process's full
# command line (`ps ... args=`), not a regex — words are joined with a
# single space, so "agentsview serve" matches the actual invocation
# "/opt/homebrew/bin/agentsview serve".
#
# Exit codes: 0 = PASS, no orphan found; 1 = FAIL, orphan(s) found (each is
#             printed: pid, ppid, cpu%, elapsed time, cumulative CPU time,
#             full command); 2 = usage error (bad flag, or `ps` missing from
#             PATH — see note below).
#
# No exit 3 (INDETERMINATE) is used. `ps` is a POSIX-mandated utility
# present on every supported platform this repo runs on (macOS, Linux); its
# absence is treated as an environment misconfiguration (usage-error class,
# exit 2) rather than a fourth "could not evaluate" state, per
# `exit-code-conventions`. This is a deliberate choice, not a silent
# omission — see the PR body / commit for the explicit statement required by
# `checks-must-distinguish-unknown`.
#
# This script only DETECTS the condition. It does not kill any process and
# does not identify what spawned the orphan — those are separate, explicitly
# out-of-scope follow-ups (see llm#1136).
#
# Requires: bash 4+, ps (BSD or GNU), mktemp.
# llm#1136

set -uo pipefail

DEFAULT_PATTERN="agentsview serve"

usage() {
  echo "Usage: $(basename "$0") [pattern words...] | --selftest" >&2
  exit 2
}

# ---------------------------------------------------------------------------
# Core detection logic
# ---------------------------------------------------------------------------
# _scan_for_orphans PATTERN FILE
#
# FILE contains ps-shaped lines: whitespace-separated
#   PID PPID PCPU ETIME TIME <rest = full command + args>
# (exactly what `ps -axo pid=,ppid=,pcpu=,etime=,time=,args=` produces).
#
# For every line whose command (the "rest" field) contains PATTERN as a
# literal substring AND whose PPID is exactly "1", prints one "ORPHAN: ..."
# line and increments the global ORPHAN_COUNT. Takes a plain file path
# (never a pipe) specifically so the while-read loop runs in the CURRENT
# shell, not a subshell — a pipe into this function would silently drop the
# ORPHAN_COUNT update once the function returned (classic bash pipeline
# subshell gotcha).
ORPHAN_COUNT=0

_scan_for_orphans() {
  local pattern="$1" file="$2"
  ORPHAN_COUNT=0
  local line pid ppid pcpu etime cputime rest

  while IFS= read -r line; do
    [[ -z "${line// /}" ]] && continue
    read -r pid ppid pcpu etime cputime rest <<<"$line"
    [[ -n "$pid" && -n "$ppid" ]] || continue

    case "$rest" in
      *"$pattern"*) : ;;
      *) continue ;;
    esac

    if [[ "$ppid" == "1" ]]; then
      echo "ORPHAN: pid=$pid ppid=$ppid cpu=${pcpu}% etime=$etime cputime=$cputime cmd=$rest"
      ORPHAN_COUNT=$((ORPHAN_COUNT + 1))
    fi
  done < "$file"
}

# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------
# Cannot safely spawn a REAL orphaned daemon in a test — that requires
# actual setsid/double-fork re-parenting to PID 1, which is invasive and not
# something to do inside an automated selftest. Instead, this feeds the
# detection function synthetic ps-shaped fixture lines directly, covering
# three cases:
#   1. Orphan fixture — matches the pattern AND has PPID=1 → MUST be flagged.
#   2. Manually-launched fixture — matches the pattern but has a normal
#      shell PPID (not 1) → MUST NOT be flagged. This is the case a naive
#      "is X running?" probe would get wrong; it is the whole point of this
#      script.
#   3. Unrelated-PPID1 fixture — has PPID=1 but does NOT match the pattern
#      (e.g. a normal system daemon like launchd's own children) → MUST NOT
#      be flagged. Proves this isn't just "any PPID=1 process".
selftest() {
  local tmp fail=0
  tmp=$(mktemp)
  trap 'rm -f "$tmp"' RETURN

  cat > "$tmp" <<'EOF'
82264 1 106.8 01-16:14:30 1857:25.91 /opt/homebrew/bin/agentsview serve
90123 6789 0.4 00:02:10 0:00.30 /opt/homebrew/bin/agentsview serve
539 1 0.0 03-19:13:27 0:01.64 /usr/libexec/keyboardservicesd
EOF

  _scan_for_orphans "agentsview serve" "$tmp"

  if [[ $ORPHAN_COUNT -eq 1 ]]; then
    echo "selftest PASS 1: exactly 1 orphan detected"
  else
    echo "selftest FAIL 1: expected ORPHAN_COUNT=1, got $ORPHAN_COUNT"
    fail=1
  fi

  local out
  out=$(_scan_for_orphans "agentsview serve" "$tmp")

  if echo "$out" | grep -q "pid=82264"; then
    echo "selftest PASS 2: orphan (PPID=1, matches pattern) correctly flagged"
  else
    echo "selftest FAIL 2: expected pid=82264 in output, got: $out"
    fail=1
  fi

  if echo "$out" | grep -q "pid=90123"; then
    echo "selftest FAIL 3: manually-launched process (PPID=6789, matches pattern) wrongly flagged"
    fail=1
  else
    echo "selftest PASS 3: manually-launched process (matches pattern, normal PPID) correctly NOT flagged"
  fi

  if echo "$out" | grep -q "pid=539"; then
    echo "selftest FAIL 4: unrelated PPID=1 process (no pattern match) wrongly flagged"
    fail=1
  else
    echo "selftest PASS 4: unrelated PPID=1 process (no pattern match) correctly NOT flagged"
  fi

  # Empty input: no crash, ORPHAN_COUNT stays 0
  local empty
  empty=$(mktemp)
  _scan_for_orphans "agentsview serve" "$empty"
  rm -f "$empty"
  if [[ $ORPHAN_COUNT -eq 0 ]]; then
    echo "selftest PASS 5: empty input yields ORPHAN_COUNT=0"
  else
    echo "selftest FAIL 5: expected ORPHAN_COUNT=0 on empty input, got $ORPHAN_COUNT"
    fail=1
  fi

  # Different pattern (reuse for another CLI, e.g. roborev) — same fixture
  # file must NOT match a pattern that isn't present in it.
  _scan_for_orphans "roborev daemon run" "$tmp"
  if [[ $ORPHAN_COUNT -eq 0 ]]; then
    echo "selftest PASS 6: unrelated pattern ('roborev daemon run') matches nothing in the fixture"
  else
    echo "selftest FAIL 6: expected ORPHAN_COUNT=0 for non-matching pattern, got $ORPHAN_COUNT"
    fail=1
  fi

  if [[ $fail -eq 0 ]]; then
    echo "RESULT: all selftest assertions PASS"
  else
    echo "RESULT: selftest FAILED"
  fi
  return $fail
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if [[ $# -gt 0 && ( "$1" == "--selftest" ) ]]; then
  selftest
  exit $?
fi

if [[ $# -gt 0 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
  usage
fi

PATTERN="$DEFAULT_PATTERN"
if [[ $# -gt 0 ]]; then
  PATTERN="$*"
fi

if ! command -v ps >/dev/null 2>&1; then
  echo "check_orphan_daemon: 'ps' not found on PATH — cannot evaluate" >&2
  exit 2
fi

if ! command -v mktemp >/dev/null 2>&1; then
  echo "check_orphan_daemon: 'mktemp' not found on PATH — cannot evaluate" >&2
  exit 2
fi

PS_FILE=$(mktemp)
trap 'rm -f "$PS_FILE"' EXIT

# args= gives the full command line (needed to distinguish "agentsview
# serve" from any other agentsview subcommand); comm= alone truncates to
# just the binary name on some platforms.
ps -axo pid=,ppid=,pcpu=,etime=,time=,args= 2>/dev/null > "$PS_FILE"

echo "check_orphan_daemon: scanning for pattern '$PATTERN' with PPID=1"
echo ""

_scan_for_orphans "$PATTERN" "$PS_FILE"

echo ""
if [[ $ORPHAN_COUNT -gt 0 ]]; then
  echo "RESULT: FAIL — $ORPHAN_COUNT orphan process(es) matching '$PATTERN' with PPID=1"
  exit 1
fi

echo "RESULT: PASS — no orphan process matching '$PATTERN' with PPID=1"
exit 0
