#!/usr/bin/env bash
# repo_visibility_guard.sh — Block a repo becoming PUBLIC unless a fresh,
# clean full-history audit of exactly what would be published is on record.
# Hook: PreToolUse:Bash
# Exit 2 = BLOCK. Exit 0 = allow.
#
# Source: 2026-08-18 incident (JohnGavin/procedural-scenes). A session-handoff
# doc committed a week earlier recorded a disk survey — personal folder names,
# media-library sizes, Time Machine snapshot counts. Harmless while the repo was
# local-only; a disclosure the moment it was made public. Nothing re-evaluated
# the content when the privacy assumption changed.
# Rebuilt 2026-10 (llm#1392, parent llm#1382): the first version scanned history
# with its own small regex, failed OPEN on any error, and could be waved through
# by an environment variable the assistant could set itself.
#
# What it does now
#   * Fast path: a command that cannot be a visibility change returns at once
#     (pure bash substring test on the raw payload; no process is started).
#   * lib/repo_visibility_parse.py decides whether the command makes a repo
#     public: gh repo edit [REPO] --visibility V (flag anywhere, with or without
#     --accept-visibility-change-consequences), gh api repos/O/R with a
#     visibility field or an --input body, gh repo create|new with --public or
#     with NO visibility flag (gh does not default to private), inside bash -c,
#     eval, $(...), xargs, env/sudo and compound lists. A visibility value that
#     is not literally private or internal counts as public.
#   * The target is read from the command, else from the working directory's
#     origin. If it cannot be established, or the target is not the repo in the
#     working directory (there is no local history to audit), the result is
#     INDETERMINATE and BLOCKS.
#   * It allows the change only when .claude/scripts/repo_publish_audit.sh
#     --verify finds a RECORD of a clean full-history scan (private_data_scan.sh,
#     private-term rule included, zero findings) for the current fingerprint of
#     EVERY ref in the clone, made within 24 h (REPO_PUBLISH_AUDIT_MAX_AGE_HOURS).
#     No record, a stale record, a record for other refs, or a record with
#     findings: BLOCK, naming which and the exact command to run the audit.
#   * FAIL CLOSED, for visibility commands only: once a command is a public
#     transition, any error (audit script, ledger, term list, deny-list, parser,
#     python3, timeout, crash) BLOCKS as INDETERMINATE. An error is never
#     permission. Every other Bash command is untouched.
#   * The only override is an owner-created acknowledgement file OUTSIDE the
#     repo: ~/.config/repo_public_ack/<owner>__<repo> (for gh repo create: the
#     name as typed, "/" written "__"), whose whole content is the tip
#     fingerprint being published, so it expires on any new commit. This hook
#     never creates it, and an assistant must not create it either: it is the
#     owner's decision (a publish gate, Class C). REPO_PUBLIC_OK=1 no longer
#     does anything. gh repo create with no --source has no local history; its
#     acknowledgement content is the word no-local-source.
#
# Honest limits: a visibility change in the GitHub web UI or by another client
# is invisible to a local hook; the daily repo_visibility_diff.sh job (llm#1371)
# catches it afterwards and runs the history audit on the repo. A body or a
# command read from a file or a variable is not followed. A forged ledger row
# would pass the record check: the ledger is local and trusted.
#
# Messages and the log never contain matched text, term, path inside the
# history, or a hash that is not already in the owner's hands.
#
# Self-test: bash repo_visibility_guard.sh --selftest
# Full acceptance and falsification: tests/test_repo_visibility_gate.sh

set -uo pipefail

LOG="${HOME}/.claude/logs/repo_visibility_guard.log"
HOOK_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)" || HOOK_DIR=""
PARSER="${REPO_VISIBILITY_PARSER:-${HOOK_DIR}/lib/repo_visibility_parse.py}"
AUDIT_CMD="${REPO_PUBLISH_AUDIT_CMD:-${HOOK_DIR}/../scripts/repo_publish_audit.sh}"
# Test seam only: a hook's environment is the harness's, not the command's.
ACK_DIR="${REPO_PUBLIC_ACK_DIR:-${HOME}/.config/repo_public_ack}"

ARMED=0
# Exit codes other than 0 and 2 are NON-blocking for a hook. Once armed (the
# command is a public transition) any unexpected status becomes a block.
trap '_rc=$?; if [ "${ARMED:-0}" = 1 ] && [ "$_rc" != 0 ] && [ "$_rc" != 2 ]; then exit 2; fi' EXIT

_log() {
  mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$LOG" 2>/dev/null || true
}

_field() { printf '%s\n' "$PARSED" | sed -n "s/^$1=//p" | head -n 1; }

_lower() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }

_origin_key() { # DIR -> owner/name of origin, lowercase
  local url key
  url="$(git -C "$1" remote get-url origin 2>/dev/null)" || return 1
  key="$(printf '%s' "$url" | sed -E 's#\.git/?$##; s#/+$##; s#^.*[:/]([^/:]+/[^/:]+)$#\1#')"
  key="$(_lower "$key")"
  printf '%s' "$key" | grep -qE '^[a-z0-9._-]+/[a-z0-9._-]+$' || return 1
  printf '%s' "$key"
}

_key_hash() { printf '%s' "$1" | shasum -a 256 2>/dev/null | cut -c1-12; }

_block() { # REASON-CODE HEADLINE [DETAIL]
  local code="$1" headline="$2" detail="${3:-}"
  _log "BLOCK reason=${code} kind=${KIND:-?} key=$(_key_hash "${KEY:-}")"
  {
    echo "BLOCKED — ${headline}"
    [ -z "$detail" ] || echo "  ${detail}"
    echo
    echo "Publishing a repo publishes its FULL git history, not just the current tree."
    echo "A visibility change is allowed only when a clean full-history audit of exactly"
    echo "what would be published is on record (made within the last 24 hours), or the"
    echo "owner has acknowledged this exact tip."
    echo
    if [ -n "${DIR:-}" ] && [ -n "${KEY:-}" ]; then
      echo "To run the audit (scans every ref, private-term rule included; records the result):"
      printf '  bash %q --record --repo %q --dir %q\n' "$(_audit_path)" "$KEY" "$DIR"
    fi
    if [ -n "${KEY:-}" ] && [ -n "${TIP:-}" ]; then
      echo
      echo "If the OWNER accepts the history as it is, the owner (not an assistant) creates the"
      echo "acknowledgement for this exact tip; it expires on any new commit:"
      printf '  ! mkdir -p %q && printf %%s %q > %q\n' "$ACK_DIR" "$TIP" "$ACK_DIR/${KEY//\//__}"
      echo "An assistant must never create that file: it is the owner's decision, not a step."
    fi
    echo
    echo "Rule: .claude/rules/repo-visibility-gate.md    Log: $LOG"
  } >&2
  exit 2
}

_audit_path() {
  if [ -f "$AUDIT_CMD" ]; then (cd -P "$(dirname "$AUDIT_CMD")" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$(basename "$AUDIT_CMD")") || printf '%s' "$AUDIT_CMD"
  else printf '%s' "$AUDIT_CMD"; fi
}

_indet() { # DETAIL
  _block INDETERMINATE "INDETERMINATE: could not establish that this repo is safe to make public." "$1. An error is never treated as permission."
}

main() {
  local payload cwd src repo kind top ok name tip res rc result detail ackfile content
  payload="$(cat 2>/dev/null || true)"

  # Fast path: cannot be a visibility change -> allow with no process started.
  case "$payload" in
    *repo*) : ;;
    *) return 0 ;;
  esac
  case "$payload" in
    *visibility*|*public*|*create*|*new*) : ;;
    *) return 0 ;;
  esac

  # A visibility cue is present. Everything below fails closed once armed.
  command -v python3 >/dev/null 2>&1 || { ARMED=1; KIND=unknown; _indet "python3 is not available to read the command"; }
  PARSED=""
  if [ -r "$PARSER" ]; then
    PARSED="$(printf '%s' "$payload" | python3 "$PARSER" 2>/dev/null)" || PARSED=""
  fi
  case "$(_field TRANSITION)" in
    none) return 0 ;;
    public) ARMED=1 ;;
    *) ARMED=1; KIND=unknown; _indet "the command could not be analysed ($(_field NOTE))" ;;
  esac

  KIND="$(_field KIND)"; DIR=""; KEY=""; TIP=""
  repo="$(_lower "$(_field REPO)")"
  src="$(_field SRC)"
  cwd="$(_field CWD)"
  [ -d "$cwd" ] || cwd="$PWD"
  [ "$(_field UNKNOWN)" = "1" ] && _indet "the target repository could not be read from the command"

  case "$KIND" in
    edit|api)
      top="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || _indet "the working directory is not inside a git repository, so there is no local history to audit"
      DIR="$top"
      ok="$(_origin_key "$top")" || _indet "the working directory's repository has no readable origin remote"
      if [ -z "$repo" ]; then
        KEY="$ok"
      else
        KEY="$repo"
        name="${ok#*/}"
        if [ "$repo" != "$ok" ] && [ "$repo" != "$name" ]; then
          _indet "the command targets a repository other than the clone in the working directory; run it from inside a clone of the target"
        fi
        KEY="$ok"
      fi
      ;;
    create)
      KEY="$repo"
      if [ -z "$KEY" ] && [ -n "$src" ]; then
        case "$src" in /*) : ;; *) src="$cwd/$src" ;; esac
        [ -d "$src" ] && KEY="$(_lower "$(basename "$(cd -P "$src" && pwd -P)")")"
      fi
      [ -n "$KEY" ] || _indet "gh repo create names no repository and no usable --source directory"
      if [ -n "$src" ]; then
        case "$src" in /*) : ;; *) src="$cwd/$src" ;; esac
        [ -d "$src" ] || _indet "the --source directory does not exist"
        top="$(git -C "$src" rev-parse --show-toplevel 2>/dev/null)" || _indet "the --source directory is not a git repository"
        DIR="$top"
      fi
      ;;
    *) _indet "unrecognised kind of visibility change" ;;
  esac
  printf '%s' "$KEY" | grep -qE '^[a-z0-9._-]+(/[a-z0-9._-]+)?$' || _indet "the repository name has characters this gate does not accept"

  if [ -n "$DIR" ]; then
    [ -r "$AUDIT_CMD" ] || _indet "the audit script is missing ($AUDIT_CMD)"
    TIP="$(bash "$AUDIT_CMD" --fingerprint --dir "$DIR" 2>/dev/null)" || {
      detail="$(bash "$AUDIT_CMD" --fingerprint --dir "$DIR" 2>/dev/null | sed -n 's/^DETAIL=//p' | head -n 1)"
      _indet "the refs of the repository could not be fingerprinted (${detail:-no detail})"
    }
    printf '%s' "$TIP" | grep -qE '^[0-9a-f]{64}$' || _indet "the ref fingerprint is malformed"
  else
    TIP="no-local-source"
  fi

  # Owner acknowledgement of this exact tip: the only override.
  ackfile="$ACK_DIR/${KEY//\//__}"
  if [ -f "$ackfile" ] && [ ! -L "$ackfile" ]; then
    content="$(tr -d ' \t\r\n' < "$ackfile" 2>/dev/null)"
    if [ -n "$content" ] && [ "$content" = "$TIP" ]; then
      _log "ALLOW reason=owner-ack kind=${KIND} key=$(_key_hash "$KEY")"
      return 0
    fi
  fi

  if [ -z "$DIR" ]; then
    _block NO_LOCAL_SOURCE "this creates a PUBLIC repository and there is no local history to audit (no --source)." \
      "Create it private and make it public after an audit, or have the owner acknowledge it."
  fi

  res="$(bash "$AUDIT_CMD" --verify --repo "$KEY" --dir "$DIR" 2>/dev/null)"; rc=$?
  result="$(printf '%s\n' "$res" | sed -n 's/^RESULT=//p' | head -n 1)"
  detail="$(printf '%s\n' "$res" | sed -n 's/^DETAIL=//p' | head -n 1)"
  case "$rc" in
    0)
      if [ "$result" = "PASS" ]; then
        _log "ALLOW reason=fresh-audit kind=${KIND} key=$(_key_hash "$KEY") tip=${TIP:0:12}"
        return 0
      fi
      _indet "the audit check exited 0 without a PASS result"
      ;;
    1) _block "$result" "this makes a repo PUBLIC and there is no fresh clean audit of its current history (${result})." "$detail" ;;
    *) _indet "${detail:-the audit check failed (exit ${rc})}" ;;
  esac
}

# ─── self-test ──────────────────────────────────────────────────────────────
if [ "${1:-}" = "--selftest" ]; then
  pass=0; fail=0
  st="$(mktemp -d "${TMPDIR:-/tmp}/rvg_selftest.XXXXXX")"
  trap 'rm -rf "$st"' EXIT
  mkdir -p "$st/home" "$st/nogit" "$st/ack"
  _t() { # name, command, expected_exit  (cwd is a non-git dir; no audit is reachable)
    local rc json
    json="$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' "$2" "$st/nogit")"
    printf '%s' "$json" | env HOME="$st/home" REPO_PUBLIC_ACK_DIR="$st/ack" REPO_PUBLIC_OK=1 bash "${BASH_SOURCE[0]}" >/dev/null 2>&1; rc=$?
    if [ "$rc" = "$3" ]; then pass=$((pass+1)); echo "  PASS $1"
    else fail=$((fail+1)); echo "  FAIL $1 (got exit $rc, want $3)"; fi
  }
  echo "repo_visibility_guard selftest (REPO_PUBLIC_OK=1 is set throughout and must change nothing):"
  _t "gh repo create --public blocks"               'gh repo create foo --public' 2
  _t "gh repo create without a visibility flag blocks" 'gh repo create foo' 2
  _t "gh repo edit --visibility public blocks"      'gh repo edit o/r --visibility public' 2
  _t "flag before the repo blocks"                  'gh repo edit --visibility public o/r' 2
  _t "--visibility=public and consequences flag"    'gh repo edit o/r --visibility=public --accept-visibility-change-consequences' 2
  _t "gh api -f visibility=public blocks"           'gh api repos/o/r -X PATCH -f visibility=public' 2
  _t "gh api -F visibility=public blocks"           'gh api -X PATCH repos/o/r -F visibility=public' 2
  _t "inside bash -c blocks"                        'bash -c "gh repo edit o/r --visibility public"' 2
  _t "after cd && blocks"                           'cd /tmp && gh repo edit o/r --visibility public' 2
  _t "unknown visibility value blocks"              'gh repo edit o/r --visibility "$V"' 2
  _t "gh repo create --private allows"              'gh repo create foo --private' 0
  _t "gh repo edit --visibility private allows"     'gh repo edit o/r --visibility private' 0
  _t "gh api visibility=private allows"             'gh api repos/o/r -X PATCH -f visibility=private' 0
  _t "gh repo view allows"                          'gh repo view o/r --json visibility' 0
  _t "unrelated git command allows"                 'git status --short' 0
  _t "unrelated gh command allows"                  'gh pr list' 0
  _t "commit message naming the command allows"     'git commit -m "docs: gh repo edit o/r --visibility public is gated"' 0
  rc=0; printf '%s' 'not json' | env HOME="$st/home" bash "${BASH_SOURCE[0]}" >/dev/null 2>&1 || rc=$?
  if [ "$rc" = 0 ]; then pass=$((pass+1)); echo "  PASS malformed payload without a cue allows"; else fail=$((fail+1)); echo "  FAIL malformed payload without a cue allows"; fi
  rc=0; printf '%s' '{"tool_input":{"command":"gh repo edit o/r --visibility public"}}' | env HOME="$st/home" REPO_PUBLIC_ACK_DIR="$st/ack" REPO_VISIBILITY_PARSER="$st/missing.py" bash "${BASH_SOURCE[0]}" >/dev/null 2>&1 || rc=$?
  if [ "$rc" = 2 ]; then pass=$((pass+1)); echo "  PASS missing parser fails closed"; else fail=$((fail+1)); echo "  FAIL missing parser fails closed (exit $rc)"; fi
  if [ -z "$(ls -A "$st/ack")" ]; then pass=$((pass+1)); echo "  PASS the hook never creates an acknowledgement file"; else fail=$((fail+1)); echo "  FAIL the hook created an acknowledgement file"; fi
  echo "  ---"
  echo "  $pass passed, $fail failed"
  [ "$fail" -eq 0 ] || exit 1
  exit 0
fi

main "$@"
exit $?
