#!/usr/bin/env bash
#
# hook-liveness: on-block
#   Emits only from its BLOCK path (untrusted or indeterminate author), so a
#   7-day count of zero in a hook-liveness report is the HEALTHY value on a
#   repo where merges are mostly done by trusted contributors — it does not
#   mean the hook is dead. Same rationale as agent_push_guard.sh's identical
#   header note.
#
# pr_merge_author_guard.sh — PreToolUse:Bash hook
#
# Layer 5 of the external-code-zero-trust defence (llm#194). Blocks
# `gh pr merge` when the PR's author is NOT a trusted contributor — per that
# rule's Forbidden Patterns table: "Merge a PR from a non-CODEOWNERS author
# without line-by-line human review | Line-by-line review is the minimum
# bar; auto-approve is never acceptable."
#
# Trust check (matches external-code-zero-trust.md's trust table):
#   ALLOW if authorAssociation is OWNER, COLLABORATOR, or MEMBER
#   ALLOW if the author's login appears in trusted-contributors.txt
#   BLOCK otherwise (including CONTRIBUTOR, NONE, FIRST_TIME_CONTRIBUTOR,
#         FIRST_TIMER, MANNEQUIN — "borderline" is not auto-mergeable)
#
# FAIL-CLOSED, DELIBERATELY (unlike most guards in this repo): if the PR's
# author association cannot be determined at all — `gh` missing, network
# failure, malformed/empty response, PR not found — this hook BLOCKS rather
# than allowing. This is the opposite of secret_leak_guard.sh's and
# external_content_quarantine.sh's fail-open posture, and that asymmetry is
# deliberate: this is a merge-time security gate (a human is expected to
# take over), not a routine developer-workflow guard where wedging the
# session on a parse hiccup would be the greater cost. Per
# checks-must-distinguish-unknown: "cannot determine" and "found untrusted"
# must not share an exit code from the safe side's perspective — both must
# refuse the merge; only "confirmed trusted" allows it through.
#
# Note: merging via the raw REST API (`gh api repos/.../pulls/N/merge -X
# PUT`) is a SEPARATE, already-blocked surface — destructive_api_guard.sh's
# `gh api .* -X (DELETE|PATCH|PUT)` pattern (destructive-ops-guard.md Part 1)
# blocks it outright with no bypass. This hook targets only the `gh pr
# merge` CLI subcommand shape.
#
# Bypass: EXTERNAL_PR_MERGE_OK=1 gh pr merge ... (mirrors AGENT_PUSH_OK's
# command-string-PREFIX form — shell state from a separate `export` does
# NOT persist between Bash tool calls, so the prefix form is the only one
# that actually works for a real caller; see secret_leak_guard.sh's Defect-1
# comment for the same lesson learned the hard way).
#
# Self-test: CLAUDE_HOOK_SELFTEST=1 bash pr_merge_author_guard.sh
#
# See: .claude/rules/external-code-zero-trust.md (Layer 5)
#      llm#194

set -uo pipefail

STATE_DIR="${PR_MERGE_GUARD_STATE_DIR:-$HOME/.claude/state}"
TRUSTED_FILE="${PR_MERGE_GUARD_TRUSTED_FILE:-${BASH_SOURCE[0]%/*}/../state/trusted-contributors.txt}"
LOG_FILE="${PR_MERGE_GUARD_LOG:-$HOME/.claude/logs/pr_merge_author_guard.log}"
BYPASS_LOG="${PR_MERGE_GUARD_BYPASS_LOG:-$HOME/.claude/logs/pr_merge_author_guard_bypass.log}"

log_blocked() {
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] BLOCKED: $1" >> "$LOG_FILE"
}

log_bypass() {
  mkdir -p "$(dirname "$BYPASS_LOG")"
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] ALLOWED (bypass): $1" >> "$BYPASS_LOG"
}

# ═══════════════════════════════════════════════════════════════════════════
# DETECTION FUNCTIONS (shared between self-test and normal operation)
# ═══════════════════════════════════════════════════════════════════════════

# Only the FIRST physical line of the command is inspected — same rationale
# as agent_push_guard.sh's first_line(): a multi-line command (e.g. a commit
# message heredoc that happens to quote a "gh pr merge ..." example) must
# never be misread as the command itself.
first_line() {
  printf '%s\n' "$1" | head -n1
}

has_bypass() {
  # Command-string PREFIX form only — the only form a real Bash-tool caller
  # can actually express (see header comment for why). Matching MUST be
  # restricted to the leading run of NAME=value assignments (optionally
  # after a leading `env` keyword); a bare substring match anywhere in the
  # command would let `gh pr merge 253 --body "mentions
  # EXTERNAL_PR_MERGE_OK=1 in prose"` bypass the guard via free text that
  # was never actually evaluated as a shell assignment.
  local line stripped prefix
  line=$(first_line "$1")
  stripped=$(echo "$line" | sed -E 's/^[[:space:]]*(env[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*//')
  prefix="${line%"$stripped"}"
  echo "$prefix" | grep -qE '(^|[[:space:]])EXTERNAL_PR_MERGE_OK=1([[:space:]]|$)'
}

is_pr_merge_command() {
  local stripped_cmd
  stripped_cmd=$(first_line "$1" | sed 's/^[[:space:]]*\([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]*\)*//')
  echo "$stripped_cmd" | grep -qE '^gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'
}

# Flags that consume a SEPARATE following token as their value. Anything not
# in this list is assumed to be either a standalone flag (--squash,
# --delete-branch, --admin, --auto) or a `--flag=value` single-token form
# (already skipped whole by the leading `-` check) — this list only needs
# flags gh pr merge actually supports that take a separate-token value.
_TAKES_VALUE_RE='^(-R|--repo|-t|--subject|-b|--body|-m|--body-file|--match-head-commit)$'

# Sets globals _PARSED_REPO and _PARSED_PR_REF.
parse_merge_args() {
  local cmd="$1"
  local after_merge
  after_merge=$(first_line "$cmd" | sed -E 's/^.*gh[[:space:]]+pr[[:space:]]+merge[[:space:]]*//')
  local -a tokens
  read -r -a tokens <<< "$after_merge"
  local repo="" pr_ref="" skip_next=0 tok
  for tok in "${tokens[@]}"; do
    if [ "$skip_next" -eq 1 ]; then
      skip_next=0
      # Only capture the VALUE if the flag that consumed it was -R/--repo.
      continue
    fi
    case "$tok" in
      -R|--repo)
        skip_next=1
        continue
        ;;
      --repo=*)
        repo="${tok#--repo=}"
        continue
        ;;
      -*)
        if echo "$tok" | grep -qE "$_TAKES_VALUE_RE"; then
          skip_next=1
        fi
        continue
        ;;
    esac
    if [ -z "$pr_ref" ]; then
      pr_ref="$tok"
    fi
  done
  # Handle -R/--repo VALUE properly (the loop above skips the value token but
  # does not capture it for the -R/--repo case since we `continue`d before
  # inspecting it). Re-scan with awareness this time.
  local prev=""
  for tok in "${tokens[@]}"; do
    if [ "$prev" = "-R" ] || [ "$prev" = "--repo" ]; then
      repo="$tok"
    fi
    prev="$tok"
  done
  # A full PR URL in the positional slot carries its own repo — extract it
  # and prefer it over any -R/--repo flag (the URL is unambiguous).
  if echo "$pr_ref" | grep -qE 'github\.com/[^/]+/[^/]+/pull/[0-9]+'; then
    repo=$(echo "$pr_ref" | grep -oE '[^/]+/[^/]+(?=/pull/[0-9]+)' 2>/dev/null || true)
    if [ -z "$repo" ]; then
      # BSD grep has no PCRE lookahead; fall back to a portable extraction.
      repo=$(echo "$pr_ref" | sed -E 's#.*github\.com/([^/]+/[^/]+)/pull/[0-9]+.*#\1#')
    fi
    pr_ref=$(echo "$pr_ref" | sed -E 's#.*/pull/([0-9]+).*#\1#')
  fi
  _PARSED_REPO="$repo"
  _PARSED_PR_REF="$pr_ref"
}

# Fetch {"login": ..., "association": ...} for a PR's author.
#
# IMPORTANT (found empirically 2026-08-30 against gh v2.98.0, NOT assumed):
# `gh pr view --json authorAssociation` errors with "Unknown JSON field:
# authorAssociation" on this gh CLI version — `gh pr view --json` simply
# does not expose that field, confirmed against a real merged PR in this
# repo before writing this function this way. The value IS available via
# the REST API: `gh api repos/<owner>/<repo>/pulls/<number>` returns
# `.author_association` and `.user.login` directly. So resolution here is
# two steps: (1) get the PR's plain NUMBER — via `gh pr view <ref> --json
# number` if pr_ref is not already numeric, or by asking `gh repo view`
# for the current repo when repo is not explicit — then (2) hit the REST
# endpoint for that number, which DOES carry author_association.
#
# Overridable for tests via _SELFTEST_GH_API_JSON (mirrors
# agent_push_guard.sh's _SELFTEST_CURRENT_BRANCH injection pattern) so no
# real `gh`/network call is needed to exercise the decision logic.
gh_pr_view_json() {
  local pr_ref="$1" repo="$2"
  if [ -n "${_SELFTEST_GH_API_JSON+x}" ]; then
    printf '%s' "$_SELFTEST_GH_API_JSON"
    return 0
  fi

  if [ -z "$repo" ]; then
    repo=$(timeout 10 gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
  fi
  [ -z "$repo" ] && return 0

  local pr_number="$pr_ref"
  if ! echo "$pr_ref" | grep -qE '^[0-9]+$'; then
    local -a view_args=(pr view)
    [ -n "$pr_ref" ] && view_args+=("$pr_ref")
    view_args+=(-R "$repo" --json number)
    pr_number=$(timeout 10 gh "${view_args[@]}" 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('number', '') if isinstance(d, dict) else '')
except Exception:
    print('')
" 2>/dev/null || echo "")
  fi
  [ -z "$pr_number" ] && return 0

  timeout 10 gh api "repos/$repo/pulls/$pr_number" \
    --jq '{login: .user.login, association: .author_association}' 2>/dev/null || true
}

is_trusted_login() {
  local login="$1"
  [ -z "$login" ] && return 1
  [ -f "$TRUSTED_FILE" ] || return 1
  # Match a whole line, ignoring comments/blank lines, case-sensitive
  # (GitHub logins are case-insensitive in practice but stored consistently
  # in this manifest — exact match avoids accidentally trusting a
  # look-alike login that differs only in case).
  grep -vE '^[[:space:]]*(#|$)' "$TRUSTED_FILE" 2>/dev/null | grep -qxF "$login"
}

# Core decision function. Args: cmd. Returns one of:
#   allow:bypass
#   allow:not-merge
#   allow:trusted-association:<assoc>
#   allow:trusted-login:<login>
#   block:untrusted:<login>:<assoc>
#   block:indeterminate:<reason>
decide() {
  local cmd="$1"

  if has_bypass "$cmd"; then
    echo "allow:bypass"
    return
  fi

  if ! is_pr_merge_command "$cmd"; then
    echo "allow:not-merge"
    return
  fi

  parse_merge_args "$cmd"
  local pr_ref="$_PARSED_PR_REF" repo="$_PARSED_REPO"

  local json
  json=$(gh_pr_view_json "$pr_ref" "$repo")

  if [ -z "$json" ]; then
    echo "block:indeterminate:gh-lookup-failed-or-empty"
    return
  fi

  local login association
  login=$(printf '%s' "$json" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('login', '') if isinstance(d, dict) else '')
except Exception:
    print('')
" 2>/dev/null || echo "")
  association=$(printf '%s' "$json" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('association', '') if isinstance(d, dict) else '')
except Exception:
    print('')
" 2>/dev/null || echo "")

  if [ -z "$login" ] && [ -z "$association" ]; then
    echo "block:indeterminate:unparseable-response"
    return
  fi

  case "$association" in
    OWNER|COLLABORATOR|MEMBER)
      echo "allow:trusted-association:$association"
      return
      ;;
  esac

  if is_trusted_login "$login"; then
    echo "allow:trusted-login:$login"
    return
  fi

  echo "block:untrusted:${login:-unknown}:${association:-UNKNOWN}"
}

# ═══════════════════════════════════════════════════════════════════════════
# SELF-TEST MODE
# ═══════════════════════════════════════════════════════════════════════════

if [ "${CLAUDE_HOOK_SELFTEST:-}" = "1" ]; then
  PASS=0
  FAIL=0

  TMP_DIR=$(mktemp -d /tmp/pr_merge_guard_selftest_XXXXXX)
  TRUSTED_FILE="$TMP_DIR/trusted-contributors.txt"
  cat > "$TRUSTED_FILE" <<'EOF'
# test manifest
JohnGavin
github-actions[bot]
trusted_external_dev
EOF

  check() {
    local n="$1" expected_prefix="$2" cmd="$3"
    local result
    result=$(decide "$cmd")
    local actual_prefix
    actual_prefix=$(echo "$result" | cut -d: -f1)
    if [ "$actual_prefix" = "$expected_prefix" ]; then
      echo "  PASS ($n): $result"
      PASS=$((PASS + 1))
    else
      echo "  FAIL ($n): expected prefix=$expected_prefix got=$result"
      FAIL=$((FAIL + 1))
    fi
  }

  echo "=== pr_merge_author_guard.sh self-test ==="

  # 1: not a merge command → allow
  unset _SELFTEST_GH_API_JSON
  check 1 "allow" "gh pr list --limit 5"

  # 2: not a merge command (gh pr view) → allow
  check 2 "allow" "gh pr view 253"

  # 3: bypass prefix → allow regardless of anything else
  check 3 "allow" "EXTERNAL_PR_MERGE_OK=1 gh pr merge 253 --squash"

  # 4: OWNER association → allow
  _SELFTEST_GH_API_JSON='{"login":"JohnGavin","association":"OWNER"}'
  check 4 "allow" "gh pr merge 253 --squash"

  # 5: MEMBER association → allow
  _SELFTEST_GH_API_JSON='{"login":"some_org_member","association":"MEMBER"}'
  check 5 "allow" "gh pr merge 253 --squash"

  # 6: COLLABORATOR association → allow
  _SELFTEST_GH_API_JSON='{"login":"some_collab","association":"COLLABORATOR"}'
  check 6 "allow" "gh pr merge 253 --squash"

  # 7: NONE association, login NOT in trusted-contributors.txt → block
  _SELFTEST_GH_API_JSON='{"login":"cold_contributor_xyz","association":"NONE"}'
  check 7 "block" "gh pr merge 253 --squash"

  # 8: CONTRIBUTOR association ("borderline") → still block (rule table:
  # "review the PR diff carefully; never auto-copy" — not auto-mergeable)
  _SELFTEST_GH_API_JSON='{"login":"occasional_contributor","association":"CONTRIBUTOR"}'
  check 8 "block" "gh pr merge 253 --squash"

  # 9: NONE association BUT login IS in trusted-contributors.txt → allow
  # (the manifest is authoritative independent of GitHub's own association
  # field — e.g. a trusted external maintainer whose GitHub org membership
  # is private)
  _SELFTEST_GH_API_JSON='{"login":"trusted_external_dev","association":"NONE"}'
  check 9 "allow" "gh pr merge 253 --squash"

  # 10: gh lookup returns empty (network failure / gh missing) → BLOCK
  # (fail-closed, per this hook's header comment)
  _SELFTEST_GH_API_JSON=""
  check 10 "block" "gh pr merge 253 --squash"

  # 11: gh lookup returns unparseable garbage → BLOCK (fail-closed)
  _SELFTEST_GH_API_JSON="not valid json at all"
  check 11 "block" "gh pr merge 253 --squash"

  # 12: PR ref via full URL, untrusted author → block (proves URL parsing
  # does not accidentally bypass the check)
  _SELFTEST_GH_API_JSON='{"login":"cold_contributor_xyz","association":"NONE"}'
  check 12 "block" "gh pr merge https://github.com/JohnGavin/llm/pull/253 --merge"

  # 13: -R/--repo flag present, trusted author → allow (flag parsing does
  # not interfere with the positional PR ref)
  _SELFTEST_GH_API_JSON='{"login":"JohnGavin","association":"OWNER"}'
  check 13 "allow" "gh pr merge 253 -R JohnGavin/llm --squash"

  # 14: no PR ref at all (current branch) → still evaluated; OWNER → allow
  _SELFTEST_GH_API_JSON='{"login":"JohnGavin","association":"OWNER"}'
  check 14 "allow" "gh pr merge --squash"

  # 15: multi-line command whose SECOND line mentions "gh pr merge" (e.g. a
  # commit message quoting an example) must NOT be misread as a real merge
  # command — first-line restriction, same defence as agent_push_guard.sh.
  unset _SELFTEST_GH_API_JSON
  MULTILINE_CMD=$'git commit -m "docs: mention gh pr merge 253 in the changelog"\n# not a real merge'
  check 15 "allow" "$MULTILINE_CMD"

  # 16: bypass prefix does not falsely match mid-command text
  _SELFTEST_GH_API_JSON='{"login":"cold_contributor_xyz","association":"NONE"}'
  check 16 "block" 'gh pr merge 253 --body "mentions EXTERNAL_PR_MERGE_OK=1 in prose"'

  # 17: REAL gh API response, captured live 2026-08-30 from this repo's own
  # PR #1104 (`gh api repos/JohnGavin/llm/pulls/1104 --jq '{login:
  # .user.login, association: .author_association}'` -> exactly this JSON) —
  # a trusted OWNER-authored, already-merged PR. Confirms the decision
  # logic against a real API response shape, not just hand-written fixtures.
  _SELFTEST_GH_API_JSON='{"login":"JohnGavin","association":"OWNER"}'
  check 17 "allow" "gh pr merge 1104 --squash"

  echo ""
  echo "$PASS/$((PASS + FAIL)) PASS"
  rm -rf "$TMP_DIR"
  [ "$FAIL" -eq 0 ] && exit 0 || exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════
# NORMAL HOOK OPERATION
# ═══════════════════════════════════════════════════════════════════════════

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")

if [ -z "$COMMAND" ]; then
  exit 0
fi

DECISION=$(decide "$COMMAND")
ACTION=$(echo "$DECISION" | cut -d: -f1)

if [ "$ACTION" = "allow" ]; then
  REASON=$(echo "$DECISION" | cut -d: -f2)
  if [ "$REASON" = "bypass" ]; then
    log_bypass "$COMMAND"
  fi
  exit 0
fi

# BLOCK path (untrusted or indeterminate)
DISPLAY_CMD="${COMMAND:0:120}"
[ ${#COMMAND} -gt 120 ] && DISPLAY_CMD="${DISPLAY_CMD}..."

REASON=$(echo "$DECISION" | cut -d: -f2)

if [ "$REASON" = "indeterminate" ]; then
  DETAIL=$(echo "$DECISION" | cut -d: -f3)
  cat >&2 <<EOF

╔═════════════════════════════════════════════════════════════════════════════╗
║  BLOCKED — Cannot verify PR author (fail-closed)                            ║
╠═════════════════════════════════════════════════════════════════════════════╣
║                                                                             ║
║  Command:  $DISPLAY_CMD
║  Reason:   $DETAIL
║                                                                             ║
║  This is a merge-time security gate: it will not let a merge through when  ║
║  it cannot confirm the author is trusted. Fix the underlying lookup        ║
║  failure (gh auth, network, PR number) and retry, or review the PR         ║
║  manually and merge from outside this session.                            ║
║                                                                             ║
║  Rule: external-code-zero-trust.md (Layer 5)  |  Issue: llm#194           ║
╚═════════════════════════════════════════════════════════════════════════════╝

EOF
  log_blocked "$COMMAND (indeterminate: $DETAIL)"
  exit 2
fi

LOGIN=$(echo "$DECISION" | cut -d: -f3)
ASSOCIATION=$(echo "$DECISION" | cut -d: -f4)

cat >&2 <<EOF

╔═════════════════════════════════════════════════════════════════════════════╗
║  BLOCKED — PR merge from untrusted author                                   ║
╠═════════════════════════════════════════════════════════════════════════════╣
║                                                                             ║
║  Command:      $DISPLAY_CMD
║  Author:       $LOGIN
║  Association:  $ASSOCIATION
║                                                                             ║
║  Per external-code-zero-trust rule: merging a PR from a non-CODEOWNERS      ║
║  author requires line-by-line human review — auto-approve is never         ║
║  acceptable. Line-by-line review is the minimum bar.                       ║
║                                                                             ║
║  If review is complete and the merge is authorised:                        ║
║    EXTERNAL_PR_MERGE_OK=1 <original command>                              ║
║                                                                             ║
║  To make this author permanently trusted (requires a CODEOWNERS/           ║
║  collaborator entry to justify it):                                       ║
║    add "$LOGIN" to .claude/state/trusted-contributors.txt                 ║
║                                                                             ║
║  Rule: external-code-zero-trust.md (Layer 5)  |  Issue: llm#194           ║
╚═════════════════════════════════════════════════════════════════════════════╝

EOF

log_blocked "$COMMAND (author=$LOGIN association=$ASSOCIATION)"
exit 2
