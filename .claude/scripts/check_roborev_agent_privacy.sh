#!/bin/bash
# NOT `#!/usr/bin/env bash` — see secret_exposure_scan.sh for the TCC rationale
# (llm#1036). /bin/bash is Apple-signed; Homebrew's is ad-hoc signed and its TCC
# grant cannot bind, so anything it touches re-prompts forever.
#
# check_roborev_agent_privacy.sh — assert no PRIVATE repo routes its diffs to a
# third-party review agent.
#
# WHY THIS EXISTS (llm#1035, llm#1046)
# -----------------------------------
# llm/.roborev.toml carried a comment asserting "GLOBAL default_agent stays
# 'claude-code' so private repos never route to gemini — public-only opt-in".
# The global was deliberately changed to gemini on 2026-07-05; the comment was
# not. For seven weeks it read as an assurance and nothing re-asked the
# question, while four LOCAL-ONLY repos — mycare (health), premortem and eis6
# (money), travel — sent every commit diff to a free-tier model.
#
# public-private-repo-boundary.md says of itself: "This rule is documentation.
# It is not a control ... If you find yourself relying on this file to prevent
# a leak, the enforcement is missing and that is the bug to fix." Replacing one
# comment with a better comment does not fix that. This script is the control.
#
# EXIT CODES (checks-must-distinguish-unknown)
#   0  ran; every private repo routes to an allowed agent
#   1  ran; at least one private repo routes to a disallowed agent
#   2  could NOT run, or could not classify at least one repo — never read as 0
#
# A repo is PRIVATE if it has no git remote at all (local-only, the most
# sensitive case) or `gh repo view` reports visibility PRIVATE. If `gh` cannot
# answer, the repo is INDETERMINATE — never assumed public.

set -uo pipefail

DB="${ROBOREV_DB:-$HOME/.roborev/reviews.db}"
ROBOREV_BIN="${ROBOREV_BIN:-$(command -v roborev || echo /usr/local/bin/roborev)}"
GH_BIN="${GH_BIN:-$(command -v gh || true)}"
SQLITE="${SQLITE:-$(command -v sqlite3 || true)}"

# Agents that may see a private repo's diff. Deliberately an ALLOW-list, not a
# deny-list of known-bad agents: a deny-list is fail-open, and every new agent
# added upstream would default to permitted (feedback_default-permit-is-fail-open).
ALLOWED_AGENTS="${ALLOWED_AGENTS:-claude-code}"

CHECKED=0; CLEAR=0; FINDINGS=0; INDETERMINATE=0
FINDING_LINES=""; INDET_LINES=""

_is_allowed() {
  local a="$1" x
  for x in $ALLOWED_AGENTS; do [ "$a" = "$x" ] && return 0; done
  return 1
}

# Classify visibility. Echoes: private | public | unknown:<reason>
_visibility() {
  local repo="$1" url vis rc=0
  url="$(git -C "$repo" remote get-url origin 2>/dev/null)" || url=""
  if [ -z "$url" ]; then
    echo "private"          # local-only: no remote at all
    return 0
  fi
  if [ -z "$GH_BIN" ]; then
    echo "unknown:gh-not-installed"; return 0
  fi
  local slug
  slug="$(basename "$(dirname "$url")")/$(basename "$url" .git)"
  slug="${slug##*:}"
  vis="$(env -u GH_TOKEN "$GH_BIN" repo view "$slug" --json visibility --jq .visibility 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$vis" ]; then
    echo "unknown:gh-lookup-failed:$slug"; return 0
  fi
  case "$vis" in
    PRIVATE|INTERNAL) echo "private" ;;
    PUBLIC)           echo "public" ;;
    *)                echo "unknown:unexpected-visibility:$vis" ;;
  esac
}

# Effective review agent for a repo. Echoes agent name, or unknown:<reason>.
#
# CRITICAL: "not set in local config" is NOT unknown — it means the repo
# INHERITS the global default, which is the dangerous case this whole script
# exists for. An earlier version of this function returned unknown there, so a
# private repo with no pin (the exact llm#1035 condition) was reported as
# indeterminate rather than as a finding: the check hid the very state it was
# written to catch. Resolve the inherited value explicitly instead.
_effective_agent() {
  local repo="$1" out err rc=0
  [ -x "$ROBOREV_BIN" ] || { echo "unknown:roborev-not-executable"; return 0; }
  err="$(mktemp)"
  out="$(cd "$repo" 2>/dev/null && "$ROBOREV_BIN" config get agent 2>"$err" | tail -1)" || rc=$?
  if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
    rm -f "$err"; echo "$out"; return 0
  fi
  # Unset locally -> fall back to the global default and judge THAT.
  if grep -qi 'not set in local config' "$err" 2>/dev/null; then
    rm -f "$err"
    local g grc=0
    g="$("$ROBOREV_BIN" config get default_agent 2>/dev/null | tail -1)" || grc=$?
    if [ "$grc" -ne 0 ] || [ -z "$g" ]; then
      echo "unknown:global-default-unreadable"; return 0
    fi
    echo "$g"; return 0
  fi
  rm -f "$err"
  echo "unknown:config-get-failed"; return 0
}

_scan() {
  if [ -z "$SQLITE" ]; then
    echo "check_roborev_agent_privacy: INDETERMINATE — sqlite3 not found" >&2
    return 2
  fi
  if [ ! -f "$DB" ]; then
    echo "check_roborev_agent_privacy: INDETERMINATE — roborev DB not found at $DB" >&2
    return 2
  fi

  local rows
  rows="$("$SQLITE" "$DB" "SELECT DISTINCT root_path FROM repos
            WHERE root_path NOT LIKE '/tmp%'
              AND root_path NOT LIKE '/private/tmp%'
              AND root_path NOT LIKE '%/.claude/worktrees/%'
              AND root_path NOT LIKE '%/worktrees/%';" 2>/dev/null)" || {
    echo "check_roborev_agent_privacy: INDETERMINATE — could not read repos table" >&2
    return 2
  }
  if [ -z "$rows" ]; then
    echo "check_roborev_agent_privacy: INDETERMINATE — repos table returned no rows" >&2
    return 2
  fi

  local repo vis agent
  while IFS= read -r repo; do
    [ -z "$repo" ] && continue
    [ -d "$repo/.git" ] || continue     # gone or not a checkout — not a finding
    CHECKED=$((CHECKED + 1))
    vis="$(_visibility "$repo")"
    case "$vis" in
      unknown:*)
        INDETERMINATE=$((INDETERMINATE + 1))
        INDET_LINES="${INDET_LINES}  ? $(basename "$repo") — visibility ${vis#unknown:}"$'\n'
        continue ;;
      public)
        CLEAR=$((CLEAR + 1)); continue ;;
    esac
    agent="$(_effective_agent "$repo")"
    case "$agent" in
      unknown:*)
        INDETERMINATE=$((INDETERMINATE + 1))
        INDET_LINES="${INDET_LINES}  ? $(basename "$repo") — PRIVATE, agent ${agent#unknown:}"$'\n'
        continue ;;
    esac
    if _is_allowed "$agent"; then
      CLEAR=$((CLEAR + 1))
    else
      FINDINGS=$((FINDINGS + 1))
      FINDING_LINES="${FINDING_LINES}  x $(basename "$repo") — PRIVATE but routes to '${agent}'"$'\n'
    fi
  done <<< "$rows"

  echo "check_roborev_agent_privacy: checked=$CHECKED clear=$CLEAR findings=$FINDINGS indeterminate=$INDETERMINATE"
  [ -n "$FINDING_LINES" ] && printf '%s' "$FINDING_LINES"
  [ -n "$INDET_LINES" ]   && printf '%s' "$INDET_LINES"
  if [ "$FINDINGS" -gt 0 ]; then
    echo "  -> pin 'agent = ${ALLOWED_AGENTS%% *}' in each repo's .roborev.toml"
    return 1
  fi
  # Indeterminate alone is NOT a pass: it means the check could not answer.
  [ "$INDETERMINATE" -gt 0 ] && return 2
  return 0
}

_selftest() {
  local pass=0 fail=0
  _t() { # name expected actual
    if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  PASS $1"
    else fail=$((fail+1)); echo "  FAIL $1 (got '$3' want '$2')"; fi
  }
  echo "check_roborev_agent_privacy selftest:"

  _t "allowlist accepts claude-code" 0 "$(_is_allowed claude-code; echo $?)"
  _t "allowlist rejects gemini"      1 "$(_is_allowed gemini; echo $?)"
  _t "allowlist rejects codex"       1 "$(_is_allowed codex; echo $?)"
  # An agent nobody has classified must be REJECTED, not permitted. This is the
  # allow-list vs deny-list distinction — a deny-list would pass this.
  _t "allowlist rejects unknown future agent" 1 "$(_is_allowed brand-new-agent-2027; echo $?)"

  local tmp; tmp="$(mktemp -d)"
  git -C "$tmp" init -q 2>/dev/null
  _t "no remote classifies as private" "private" "$(_visibility "$tmp")"

  # gh absent must yield unknown, never "public".
  _t "gh absent yields unknown, not public" "unknown:gh-not-installed" \
     "$(cd "$tmp" && git remote add origin https://github.com/x/y.git 2>/dev/null; GH_BIN="" _visibility "$tmp")"

  # roborev absent must yield unknown, never a default agent.
  _t "roborev absent yields unknown agent" "unknown:roborev-not-executable" \
     "$(ROBOREV_BIN=/nonexistent/roborev _effective_agent "$tmp")"

  # An UNSET local agent must resolve to the global default and be JUDGED,
  # never reported as unknown — that was the original bug in this function.
  _t "unset local agent is not 'unknown'" 0 \
     "$(a="$(_effective_agent "$tmp")"; case "$a" in unknown:*) echo 1;; *) echo 0;; esac)"

  # A missing DB must exit 2, never 0.
  local rc=0; ( DB=/nonexistent/reviews.db _scan >/dev/null 2>&1 ) || rc=$?
  _t "missing DB exits 2 (not 0)" 2 "$rc"

  # And must not print the word "clear" as though it had checked anything.
  local out; out="$( DB=/nonexistent/reviews.db _scan 2>&1 || true )"
  _t "missing DB says INDETERMINATE" 1 "$(printf '%s' "$out" | grep -c INDETERMINATE)"

  rm -rf "$tmp"
  echo "  ---"
  echo "  $pass passed, $fail failed"
  [ "$fail" -eq 0 ] || return 1
  return 0
}

case "${1:-}" in
  --selftest) _selftest; exit $? ;;
  -h|--help)  sed -n '2,40p' "$0"; exit 0 ;;
  *)          _scan; exit $? ;;
esac
