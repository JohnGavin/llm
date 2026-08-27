#!/usr/bin/env bash
# indeterminate_precommit.sh — pre-commit gate for check_indeterminate_handling.sh
#
# Blocks a commit that introduces a NEW instance of the swallowed-error
# signature (checks-must-distinguish-unknown, llm#1021). Pre-existing instances
# are recorded in .claude/scripts/.indeterminate-baseline and do not block —
# otherwise this could not be enabled at all without first fixing 45 findings,
# which is how linters end up permanently advisory.
#
# Only fires when the commit actually touches a shell script, so it costs
# nothing on the many commits that do not.
#
# Kill switch: SKIP_INDETERMINATE_CHECK=1 — logged, never silent.
#
# Exit: 0 allow · 1 block
#
# llm#1024

set -uo pipefail

LOG="${HOME}/.claude/logs/indeterminate_precommit.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG"; }

if [ -n "${SKIP_INDETERMINATE_CHECK:-}" ]; then
  echo "indeterminate-check: SKIPPED (SKIP_INDETERMINATE_CHECK=1)"
  log "skipped via kill switch"
  exit 0
fi

# Any staged .sh files?
staged="$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null | grep -E '\.sh$' || true)"
if [ -z "$staged" ]; then
  exit 0
fi

CHECKER="${INDETERMINATE_CHECKER:-$HOME/.claude/scripts/check_indeterminate_handling.sh}"
if [ ! -x "$CHECKER" ]; then
  # Cannot run → say so, do not block. An absent checker must not read as a
  # clean result, which is the very rule this gate enforces.
  echo "indeterminate-check: UNAVAILABLE (checker not executable at $CHECKER) — not blocking" >&2
  log "unavailable checker=$CHECKER"
  exit 0
fi

# Scan THIS repo's staged files, not the checker's own directory.
#
# ~/.claude/scripts is a symlink into the main checkout, so the checker's
# self-derived root always pointed at main — including when this hook ran inside
# a worktree. It scanned main's (baselined) files and passed every worktree
# commit no matter what it contained. Verified: a commit deliberately adding the
# swallowed-status pattern in a worktree was accepted (llm#1028).
#
# Pin the root to the repo being committed, and hand the checker the staged
# paths explicitly.
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$REPO_ROOT" ]; then
  echo "indeterminate-check: UNAVAILABLE (not in a git repo) — not blocking" >&2
  log "unavailable no-repo-root"
  exit 0
fi

_staged_paths=()
while IFS= read -r _f; do
  [ -n "$_f" ] || continue
  [ -f "$REPO_ROOT/$_f" ] && _staged_paths+=("$REPO_ROOT/$_f")
done <<< "$staged"

if [ "${#_staged_paths[@]}" -eq 0 ]; then
  exit 0   # staged shell files are all deletions
fi

out="$(INDETERMINATE_ROOT="$REPO_ROOT" \
       INDETERMINATE_BASELINE="$REPO_ROOT/.claude/scripts/.indeterminate-baseline" \
       "$CHECKER" "${_staged_paths[@]}" 2>&1)"; rc=$?

if [ "$rc" -eq 0 ]; then
  log "pass staged_sh=$(printf '%s\n' "$staged" | grep -c .)"
  exit 0
fi

echo "$out" >&2
echo "" >&2
echo "Commit BLOCKED: new swallowed-error finding(s)." >&2
echo "" >&2
echo "  An error path and a negative-result path must not share an exit — a" >&2
echo "  failure to answer must be distinguishable from a negative answer." >&2
echo "  See .claude/rules/checks-must-distinguish-unknown.md" >&2
echo "" >&2
echo "  Fix: capture the exit status and branch on it." >&2
echo "      out=\$(cmd 2>\"\$err\"); rc=\$?" >&2
echo "      [ \"\$rc\" -ne 0 ] && { log \"INDETERMINATE: ...\"; return 2; }" >&2
echo "" >&2
echo "  If this is genuinely acceptable, say why in the commit and either add a" >&2
echo "  reasoned entry to .claude/scripts/.indeterminate-allowlist, or bypass" >&2
echo "  once with SKIP_INDETERMINATE_CHECK=1." >&2
log "BLOCKED rc=$rc"
exit 1
