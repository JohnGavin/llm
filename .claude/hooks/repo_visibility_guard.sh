#!/usr/bin/env bash
# repo_visibility_guard.sh — Block a repo becoming PUBLIC until its full git
# history has been audited for private information.
# Hook: PreToolUse:Bash
# Exit 2 = BLOCK. Exit 0 = allow.
#
# Source: 2026-08-18 incident (JohnGavin/procedural-scenes). A session-handoff
# doc committed a week earlier recorded a disk survey — personal folder names
# ("100GOPRO … personal irreplaceable footage"), media-library sizes, Time
# Machine snapshot counts, local model caches. That was harmless while the repo
# was local-only with no remote. It became a disclosure the moment the repo was
# made public. NOTHING re-evaluated the content when the privacy assumption
# changed; it was caught only because the assistant happened to grep first.
#
# The gap this closes: no existing hook fires on a private -> public
# transition. secret_leak_guard.sh targets command-substitution credential
# splicing; artifact_secret_guard.sh covers Artifacts. Neither looks at git
# history — and history is published in full regardless of what HEAD says.
#
# Design notes:
#   * Blocks the TRANSITION, not the audit. Once the history has been reviewed,
#     re-run with REPO_PUBLIC_OK=1 to proceed.
#   * Scans ALL reachable history, not just HEAD — the incident content was in
#     an older commit and absent from the working tree.
#   * Reports PRIVACY patterns only. Credential shapes stay owned by
#     secret_leak_guard.sh / lib/cred_patterns.py; duplicating them here would
#     recreate the drift risk llm#958 was raised to fix.
#   * Bounded: byte cap + timeout, so it cannot wedge a session on a big repo.
#   * Fail-open on any internal error. A broken guard must never block work
#     that has nothing to do with visibility.
#
# Self-test: bash repo_visibility_guard.sh --selftest

set -uo pipefail

LOG="${HOME}/.claude/logs/repo_visibility_guard.log"
MAX_BYTES="${REPO_VISIBILITY_SCAN_BYTES:-8000000}"   # cap history read at ~8 MB
SCAN_TIMEOUT="${REPO_VISIBILITY_SCAN_TIMEOUT:-20}"   # seconds

# Privacy (not credential) patterns: machine/personal reconnaissance that has no
# business in a public repo. One ERE per line.
PRIVACY_ERE='/Users/[a-zA-Z0-9._-]+|/home/[a-zA-Z0-9._-]+|~/Downloads|~/Desktop|~/Documents|\.Trash|Time Machine|tmutil|Library/Application Support|irreplaceable|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'

_is_public_transition() {
  # Pure-bash fast path: bail immediately unless the command could plausibly
  # flip visibility, so this hook costs ~0 for every other Bash call.
  local cmd="$1"
  case "$cmd" in
    *"gh repo create"*|*"gh repo edit"*|*visibility*|*"--public"*) : ;;
    *) return 1 ;;
  esac
  # Confirm it is actually a PUBLIC transition, not e.g. --private.
  [[ "$cmd" == *"gh repo create"* && "$cmd" == *"--public"* ]] && return 0
  [[ "$cmd" == *"gh repo edit"* && "$cmd" == *"--visibility"* && "$cmd" == *public* ]] && return 0
  [[ "$cmd" == *"visibility=public"* ]] && return 0   # gh api -f visibility=public
  return 1
}

_scan_history() {
  # One "match" per line, deduped. Bounded and timeout-guarded. Silent if this
  # is not a git repo. `git log --all -p` is the surface that actually gets
  # published — every reachable commit on every ref, not the working tree.
  #
  # --no-ext-diff (2026-08-22, JohnGavin/llm#997): this repo configures
  # difftastic as diff.external, both globally and per-repo. `git log -p`
  # generates its patch output through the same diff machinery as `git
  # diff`, so it is a candidate for the same class of failure #997 found —
  # a content-scanning check silently seeing less than the real diff/patch
  # contains, or reformatted text a raw-substring grep does not expect.
  # Empirically verified when this fix was written: on this repo's git
  # version, `git log --all -p` output was BYTE-IDENTICAL with and without
  # --no-ext-diff (this specific invocation was not actually vacuous) — but
  # #997's own recommendation #1 is to add --no-ext-diff to any future
  # content-scanning of diff output regardless, since the safety margin
  # costs nothing and the difftastic version/config on a future machine is
  # not guaranteed to render the same way. Belt-and-braces, not a fix for an
  # observed live bug in THIS invocation.
  local repo_root
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || return 0
  [ -n "$repo_root" ] || return 0
  timeout "$SCAN_TIMEOUT" git -C "$repo_root" log --all -p --no-color --no-ext-diff 2>/dev/null \
    | head -c "$MAX_BYTES" \
    | grep -aoE "$PRIVACY_ERE" 2>/dev/null \
    | sort -u | head -25
}

main() {
  local payload cmd
  payload="$(cat 2>/dev/null || true)"
  cmd="$(printf '%s' "$payload" | python3 -c \
    'import sys,json
try:
    d=json.load(sys.stdin)
except Exception:
    print(""); raise SystemExit
print((d.get("tool_input") or {}).get("command") or d.get("command") or "")' 2>/dev/null || true)"
  [ -n "$cmd" ] || exit 0

  _is_public_transition "$cmd" || exit 0

  mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [ "${REPO_PUBLIC_OK:-0}" = "1" ]; then
    printf '%s bypass REPO_PUBLIC_OK=1 cmd=%s\n' "$ts" "${cmd:0:200}" >> "$LOG" 2>/dev/null || true
    exit 0
  fi

  local hits; hits="$(_scan_history 2>/dev/null || true)"
  printf '%s BLOCK cmd=%s hits=%s\n' "$ts" "${cmd:0:200}" \
    "$(printf '%s' "$hits" | tr '\n' ',')" >> "$LOG" 2>/dev/null || true

  {
    echo "BLOCKED — this makes a repo PUBLIC and its history has not been audited."
    echo
    echo "Publishing a repo publishes its FULL git history, not just the current"
    echo "tree. Content that was harmless while the repo was private (machine"
    echo "notes, disk surveys, session-handoff docs, personal paths) becomes"
    echo "permanently disclosed and indexable."
    echo
    if [ -n "$hits" ]; then
      echo "Privacy-pattern matches in reachable history:"
      printf '%s\n' "$hits" | sed 's/^/  - /'
    else
      echo "No privacy-pattern matches in the scanned window (bounded at"
      echo "${MAX_BYTES} bytes / ${SCAN_TIMEOUT}s). Absence of known-bad patterns is"
      echo "NOT proof the history is clean."
    fi
    echo
    echo "Before approving:"
    echo "  1. git log --all -p | less     # read what would actually be published"
    echo "  2. Choose: squash to a clean orphan commit, scrub with git filter-repo,"
    echo "     or publish it private instead."
    echo "  3. Check METADATA too — author/committer emails are published"
    echo "     regardless of file content:  git log --all --format='%ae' | sort -u"
    echo
    echo "Then re-run with the audit acknowledged:"
    echo "  REPO_PUBLIC_OK=1 <your command>"
    echo
    echo "Rule: .claude/rules/repo-visibility-gate.md    Log: $LOG"
  } >&2

  exit 2
}

# ─── self-test ──────────────────────────────────────────────────────────────
if [ "${1:-}" = "--selftest" ]; then
  pass=0; fail=0
  _t() { # name, json, expected_exit
    local rc
    printf '%s' "$2" | REPO_PUBLIC_OK=0 bash "${BASH_SOURCE[0]}" >/dev/null 2>&1; rc=$?
    if [ "$rc" = "$3" ]; then pass=$((pass+1)); echo "  PASS $1"
    else fail=$((fail+1)); echo "  FAIL $1 (got exit $rc, want $3)"; fi
  }
  echo "repo_visibility_guard selftest:"
  _t "gh repo create --public blocks"           '{"tool_input":{"command":"gh repo create foo --public"}}' 2
  _t "gh repo edit --visibility public blocks"  '{"tool_input":{"command":"gh repo edit o/r --visibility public"}}' 2
  _t "gh api visibility=public blocks"          '{"tool_input":{"command":"gh api repos/o/r -X PATCH -f visibility=public"}}' 2
  _t "gh repo create --private allows"          '{"tool_input":{"command":"gh repo create foo --private"}}' 0
  _t "gh repo edit --visibility private allows" '{"tool_input":{"command":"gh repo edit o/r --visibility private"}}' 0
  _t "unrelated git command allows"             '{"tool_input":{"command":"git status --short"}}' 0
  _t "unrelated gh command allows"              '{"tool_input":{"command":"gh pr list"}}' 0
  _t "empty payload allows"                     '{}' 0
  _t "malformed payload allows"                 'not json' 0
  # bypass must ALLOW an otherwise-blocked command
  printf '%s' '{"tool_input":{"command":"gh repo create foo --public"}}' \
    | REPO_PUBLIC_OK=1 bash "${BASH_SOURCE[0]}" >/dev/null 2>&1
  if [ $? -eq 0 ]; then pass=$((pass+1)); echo "  PASS REPO_PUBLIC_OK=1 bypass allows"
  else fail=$((fail+1)); echo "  FAIL REPO_PUBLIC_OK=1 bypass allows"; fi
  echo "  ---"
  echo "  $pass passed, $fail failed"
  [ "$fail" -eq 0 ] || exit 1
  exit 0
fi

# Fail-open on any unexpected error: never wedge a session.
main "$@" || exit 0
