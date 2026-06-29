#!/usr/bin/env bash
# worktree_symlink_guard.sh — PreToolUse:Edit|Write realpath boundary check
# Hook: PreToolUse (Edit, Write)
# Exit 2 = BLOCK (realpath escapes worktree sandbox). Exit 0 = ALLOW.
#
# Blocks writes where the target's realpath lands in a DIFFERENT git repository
# from the one the original path lives under. This catches symlinks (or symlinked
# directories) that silently route writes outside the acting agent's worktree —
# the Pattern 2 sandbox escape from llm#517, confirmed exploited 2026-06-28.
#
# FAIL-OPEN: any ambiguity → exit 0 (ALLOW). A bug here must never block all edits.
#   - realpath can't be resolved → ALLOW
#   - git rev-parse fails (not a git repo, e.g. /tmp) → ALLOW
#   - CLAUDE_ALLOW_CROSS_REPO_WRITE=1 → ALLOW (deliberate cross-repo dispatch)
#
# Self-test: CLAUDE_HOOK_SELFTEST=1 bash worktree_symlink_guard.sh
#
# Sources: llm#692 (implementation), llm#517 (Pattern 2), agent-identity-and-task-scopes rule

set -euo pipefail

# ─── Helpers ─────────────────────────────────────────────────────────────────

# Resolve all symlinks to get the canonical path.
# Tries: realpath, readlink -f, python3 fallback.
# If the target doesn't exist yet (new Write), tries resolving the parent dir
# then appending the basename.  Returns empty string on total failure.
_resolve_realpath() {
  local p="$1"
  local result=""

  # Try direct resolution first (works for existing paths and macOS 13+).
  if command -v realpath >/dev/null 2>&1; then
    result=$(realpath "$p" 2>/dev/null) && { echo "$result"; return; }
  fi
  if command -v readlink >/dev/null 2>&1; then
    result=$(readlink -f "$p" 2>/dev/null) && { echo "$result"; return; }
  fi

  # File might not exist yet (Write to new file). Resolve the parent instead.
  local parent basename_p
  parent=$(dirname "$p")
  basename_p=$(basename "$p")

  if command -v realpath >/dev/null 2>&1; then
    result=$(realpath "$parent" 2>/dev/null) && { echo "${result}/${basename_p}"; return; }
  fi
  if command -v readlink >/dev/null 2>&1; then
    result=$(readlink -f "$parent" 2>/dev/null) && { echo "${result}/${basename_p}"; return; }
  fi

  # Last resort: python3 os.path.realpath.
  if command -v python3 >/dev/null 2>&1; then
    result=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$p" 2>/dev/null) \
      && { echo "$result"; return; }
  fi

  # Total failure — caller treats empty as "can't resolve" → fail-open.
  echo ""
}

# ─── Self-test harness (CLAUDE_HOOK_SELFTEST=1) ──────────────────────────────
if [ "${CLAUDE_HOOK_SELFTEST:-0}" = "1" ]; then
  PASS=0; FAIL=0; TOTAL=5
  HOOK_PATH="$0"

  # Run hook in a subprocess with synthetic JSON input.
  # Returns "block" (exit 2) or "allow" (exit 0).
  _check_hook() {
    local file_path="$1"
    local extra_env="${2:-}"       # e.g. "CLAUDE_ALLOW_CROSS_REPO_WRITE=1"
    local tmpjson rc
    tmpjson=$(mktemp /tmp/wsg_selftest_XXXXXX.json)
    printf '{"tool_name": "Edit", "tool_input": {"file_path": "%s"}}' "$file_path" > "$tmpjson"
    rc=0
    env CLAUDE_HOOK_SELFTEST=0 $extra_env bash "$HOOK_PATH" < "$tmpjson" >/dev/null 2>&1 || rc=$?
    rm -f "$tmpjson"
    [ "$rc" = "2" ] && echo "block" || echo "allow"
  }

  _ok()   { PASS=$((PASS+1)); printf '  %d/%d PASS  %s\n' "$PASS" "$TOTAL" "$*"; }
  _fail() { FAIL=$((FAIL+1)); printf '  %d/%d FAIL  %s\n' "$((PASS+FAIL))" "$TOTAL" "$*"; }

  # Build a fixture with two independent git repos and one linked worktree.
  FIX=$(mktemp -d /tmp/wsg_fix_XXXXXX)
  trap 'rm -rf "$FIX"' EXIT

  # repo_a: the "safe" worktree — where the agent believes it is.
  git init -q "$FIX/repo_a"
  git -C "$FIX/repo_a" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

  # repo_b: a different repo — the "outside" target.
  git init -q "$FIX/repo_b"
  git -C "$FIX/repo_b" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  echo "external content" > "$FIX/repo_b/external.sh"

  # Put a real file inside repo_a.
  echo "internal content" > "$FIX/repo_a/internal.R"

  # Case 1: symlink whose realpath escapes the worktree → BLOCKED.
  # <repo_a>/escape_link.sh → <repo_b>/external.sh
  ln -s "$FIX/repo_b/external.sh" "$FIX/repo_a/escape_link.sh"
  r=$(_check_hook "$FIX/repo_a/escape_link.sh")
  if [ "$r" = "block" ]; then _ok "symlink escaping to external repo → block"
  else _fail "symlink escaping to external repo — expected block, got $r"; fi

  # Case 2: normal in-worktree file → ALLOWED.
  r=$(_check_hook "$FIX/repo_a/internal.R")
  if [ "$r" = "allow" ]; then _ok "normal in-worktree file → allow"
  else _fail "normal in-worktree file — expected allow, got $r"; fi

  # Case 3: symlink whose realpath stays inside the same repo → ALLOWED.
  # <repo_a>/intra_link.R → <repo_a>/internal.R  (different name, same repo)
  ln -s "$FIX/repo_a/internal.R" "$FIX/repo_a/intra_link.R"
  r=$(_check_hook "$FIX/repo_a/intra_link.R")
  if [ "$r" = "allow" ]; then _ok "symlink staying inside repo → allow"
  else _fail "symlink staying inside repo — expected allow, got $r"; fi

  # Case 4: CLAUDE_ALLOW_CROSS_REPO_WRITE=1 + external realpath → ALLOWED.
  r=$(_check_hook "$FIX/repo_a/escape_link.sh" "CLAUDE_ALLOW_CROSS_REPO_WRITE=1")
  if [ "$r" = "allow" ]; then _ok "CLAUDE_ALLOW_CROSS_REPO_WRITE=1 override → allow"
  else _fail "CLAUDE_ALLOW_CROSS_REPO_WRITE=1 override — expected allow, got $r"; fi

  # Case 5: non-git path (/tmp/scratch) → ALLOWED (fail-open).
  r=$(_check_hook "/tmp/not_a_git_repo_wsg_test/foo.txt")
  if [ "$r" = "allow" ]; then _ok "non-git path → allow (fail-open)"
  else _fail "non-git path — expected allow (fail-open), got $r"; fi

  printf '\nworktree_symlink_guard selftest: %d/%d PASS\n' "$PASS" "$TOTAL"
  [ "$FAIL" -eq 0 ] && exit 0 || exit 1
fi

# ─── Main hook logic ─────────────────────────────────────────────────────────

# Opt-out: deliberate cross-repo dispatch (the $WORKTREE_PATH pattern in auto-delegation).
if [ "${CLAUDE_ALLOW_CROSS_REPO_WRITE:-0}" = "1" ]; then
  exit 0
fi

# Parse file_path from stdin JSON (same contract as file_protection.sh).
INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | sed -n 's/.*"file_path":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
[ -z "$FILE_PATH" ] && exit 0  # fail-open: no path in input

# Resolve the realpath of the target file.
REAL_PATH=$(_resolve_realpath "$FILE_PATH")
[ -z "$REAL_PATH" ] && exit 0  # fail-open: can't determine canonical path

# Get the git worktree root via the ORIGINAL (unresolved) target directory.
# Using the original directory ensures we discover the worktree the agent
# *believes* the path belongs to, regardless of where symlinks point.
TARGET_DIR=$(dirname "$FILE_PATH")
WORKTREE_ROOT=$(git -C "$TARGET_DIR" rev-parse --show-toplevel 2>/dev/null) || exit 0
# fail-open if: git not found, not inside a git repo, or any other git error.

# Normalise: strip trailing slash for prefix comparison.
WORKTREE_ROOT="${WORKTREE_ROOT%/}"

# Check whether the resolved realpath is inside the worktree root.
case "$REAL_PATH" in
  "$WORKTREE_ROOT"|"$WORKTREE_ROOT"/*)
    exit 0  # ALLOW: realpath stays inside the worktree (or IS the root).
    ;;
  *)
    # Realpath escapes the worktree boundary → BLOCK.
    {
      echo "BLOCKED (worktree_symlink_guard): write would escape the worktree sandbox."
      echo "  Requested path : $FILE_PATH"
      echo "  Resolved path  : $REAL_PATH"
      echo "  Worktree root  : $WORKTREE_ROOT"
      echo ""
      echo "  The target (or an ancestor directory) is a symlink whose realpath"
      echo "  lands outside this worktree. The bytes would be written to a different"
      echo "  repository, bypassing PR review."
      echo ""
      echo "  To allow a deliberate cross-repo write (e.g. the \$WORKTREE_PATH"
      echo "  pattern from auto-delegation), set:"
      echo "    CLAUDE_ALLOW_CROSS_REPO_WRITE=1"
      echo ""
      echo "  See: agent-identity-and-task-scopes rule, llm#692, llm#517."
    } >&2
    exit 2
    ;;
esac
