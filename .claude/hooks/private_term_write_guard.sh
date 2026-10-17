#!/usr/bin/env bash
# private_term_write_guard.sh -- Block writing a private term into a PUBLIC repo
# at the moment of the edit (privacy layer L1, JohnGavin/llm#1387, parent #1382).
# Hook: PreToolUse on Edit, Write, MultiEdit and NotebookEdit.
#
# Blocks when ALL of:
#   1. the target file lies inside a git working tree;
#   2. that repo is PUBLIC, or its visibility is UNKNOWN (lookup failed: unknown
#      counts as public, fail closed);
#   3. the NEW content (Edit new_string, Write content, NotebookEdit new_source,
#      MultiEdit edits[].new_string) contains a term of the private-term list,
#      whole-word, case-insensitive (lib/private_terms.sh).
# A private repo, a local-only repo, or a path outside any repo is allowed and
# never needs the list.
#
# INDETERMINATE (checks-must-distinguish-unknown): for a write into a public or
# unknown-visibility repo, a term list that is missing, unreadable, older than 7
# days, lacking its header or the canary term, or whose matcher fails its own
# canary probe is NOT a pass. The write is blocked with the reason and the fix
# (run private_terms_sync.sh). So is a payload that cannot be parsed.
#
# The block message names the rule and line numbers within the new text. It
# never contains the matched term, the line, or the canary.
#
# Exit codes
#   --check mode (used by tests and callers that want the raw verdict):
#       0 pass, 1 finding, 2 usage, 3 INDETERMINATE
#   hook mode (default): 0 allow; 1 and 3 are reported to the harness as a block
#       (permissionDecision:"deny" JSON on stdout, reason on stderr, exit 2,
#       the PreToolUse BLOCK code). 2 is also BLOCK to the harness, which is why
#       the verdict codes are only exposed under --check.
#
# Test seams (env): PRIVATE_TERMS_FILE, PRIVATE_TERMS_MAX_AGE_DAYS,
# PTWG_VISIBILITY_CMD (executable called with the repo root, prints the
# classification; default repo_visibility.sh classify).

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/private_terms.sh
. "$HOOK_DIR/lib/private_terms.sh"
# shellcheck source=lib/run_bounded.sh
. "$HOOK_DIR/lib/run_bounded.sh"

MSG=""
TMPC=""
TMPE=""
trap 'rm -f "$TMPC" "$TMPE"; pt_cleanup' EXIT

_visibility() {
  # $1 = repo root. Prints the classification; a lookup failure prints
  # "unknown", and "indeterminate" when no time-limit mechanism exists at all
  # (run_bounded exit 125), so the block message can say why.
  local out rc
  if [ -n "${PTWG_VISIBILITY_CMD:-}" ]; then
    out="$(run_bounded 12 "$PTWG_VISIBILITY_CMD" "$1" 2>/dev/null)"; rc=$?
  else
    out="$(run_bounded 12 bash "$HOOK_DIR/../scripts/repo_visibility.sh" classify "$1" 2>/dev/null)"; rc=$?
  fi
  if [ "$rc" -eq 125 ]; then printf 'indeterminate'; return 0; fi
  if [ "$rc" -ne 0 ]; then out=""; fi
  out="${out%%$'\n'*}"
  case "$out" in
    public|private|local_only|confidential_by_policy|unknown) printf '%s' "$out" ;;
    *) printf 'unknown' ;;
  esac
}

_repo_top() {
  # $1 = absolute target path (file need not exist). Prints the repo toplevel
  # and returns 0, or returns 1 when the path is not inside a git working tree.
  local d anc top
  d="$(dirname "$1")"
  anc="$d"
  while [ -n "$anc" ] && [ ! -d "$anc" ]; do
    d="$(dirname "$anc")"
    if [ "$d" = "$anc" ]; then break; fi
    anc="$d"
  done
  [ -d "$anc" ] || return 1
  top="$(git -C "$anc" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [ -n "$top" ] || return 1
  case "$1" in
    */.git/*) return 1 ;;
  esac
  printf '%s' "$top"
}

# check_payload PAYLOAD -> 0 pass / 1 finding / 3 INDETERMINATE; text in $MSG
check_payload() {
  local payload="$1" target rc top vis hits lines
  [ -n "$payload" ] || return 0

  TMPC="$(mktemp "${TMPDIR:-/tmp}/private_term_write.XXXXXX")" || {
    MSG="cannot create a temp file; refusing to pass a write into a repo it could not check"
    return 3
  }
  target="$(printf '%s' "$payload" | python3 "$HOOK_DIR/lib/private_term_payload.py" "$TMPC" 2>/dev/null)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    MSG="the hook payload could not be parsed (INDETERMINATE), so the write was not checked"
    return 3
  fi
  [ -n "$target" ] || return 0            # not an Edit/Write/NotebookEdit call
  [ -s "$TMPC" ] || return 0              # nothing new is being written

  top="$(_repo_top "$target")" || return 0 # outside any repo: never needs the list
  vis="$(_visibility "$top")"
  case "$vis" in
    private|local_only|confidential_by_policy) return 0 ;;
  esac

  # pt_prepare must run in this shell (it sets PT_FILE), so capture stderr in a file.
  TMPE="$TMPC.err"
  if ! pt_prepare 2>"$TMPE"; then
    MSG="$(cat "$TMPE" 2>/dev/null)"
    MSG="INDETERMINATE: $MSG. Writes into a public repo are blocked without a fresh term list. Fix: run .claude/scripts/private_terms_sync.sh, then retry."
    return 3
  fi
  hits="$(pt_match < "$TMPC")" || hits=""
  [ -n "$hits" ] || return 0
  lines="$(printf '%s' "$hits" | tr '\n' ',' | sed 's/,$//')"
  if [ "$vis" = "indeterminate" ]; then
    vis="unknown: no timeout, gtimeout or perl on PATH, so the visibility lookup could not be bounded and was not run"
  fi
  MSG="BLOCKED (rule private-term, llm#1387): the new content contains a private term and the target is inside the PUBLIC repo $(basename "$top") (visibility: $vis). Matching line(s) of the new text: $lines. The term is deliberately not shown. Rewrite with a neutral name, move the work to a private repo, or use the alias map (private_aliases.tsv)."
  return 1
}

_deny() {
  # $1 = reason. Emit the harness block: JSON on stdout, reason on stderr, exit 2.
  printf '%s\n' "$1" >&2
  python3 -c 'import json,sys
print(json.dumps({"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":sys.argv[1]}}))' "$1" 2>/dev/null || true
  exit 2
}

main() {
  local mode="hook" payload rc
  case "${1:-}" in
    "") : ;;
    --check) mode="check" ;;
    *) echo "usage: private_term_write_guard.sh [--check]  (payload JSON on stdin)" >&2; exit 2 ;;
  esac
  payload="$(cat 2>/dev/null || true)"
  check_payload "$payload"
  rc=$?
  if [ "$mode" = "check" ]; then
    if [ "$rc" -ne 0 ]; then printf '%s\n' "$MSG" >&2; fi
    exit "$rc"
  fi
  if [ "$rc" -eq 0 ]; then exit 0; fi
  _deny "$MSG"
}

main "$@"
