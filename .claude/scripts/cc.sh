#!/usr/bin/env bash
# cc.sh — Claude Code wrapper that picks --permission-mode based on cwd.
#
# Mode selection:
#   /tmp, /private/tmp                       → bypassPermissions
#   git worktree (git-dir != git-common-dir) → bypassPermissions
#   anything else (main checkout, $HOME)     → default
#
# Usage:
#   alias claude='~/.claude/scripts/cc.sh'
#   claude                  # starts session with the auto-selected mode
#   claude --print-mode     # prints the detected mode and exits (no claude invocation)
#   claude --permission-mode <m> ...  # explicit override always wins
#
# Companion to rule: permission-mode-discipline

set -e

is_worktree() {
  local common gitdir
  common=$(git rev-parse --git-common-dir 2>/dev/null) || return 1
  gitdir=$(git rev-parse --git-dir 2>/dev/null) || return 1
  # Resolve to absolute paths for a stable comparison
  common=$(cd "$common" 2>/dev/null && pwd) || return 1
  gitdir=$(cd "$gitdir" 2>/dev/null && pwd) || return 1
  [ "$common" != "$gitdir" ]
}

select_mode() {
  case "$PWD" in
    /tmp|/tmp/*|/private/tmp|/private/tmp/*) echo "bypassPermissions"; return ;;
  esac
  if is_worktree; then
    echo "bypassPermissions"
  else
    echo "default"
  fi
}

# Honour explicit user override
for arg in "$@"; do
  case "$arg" in
    --permission-mode|--permission-mode=*)
      exec claude "$@"
      ;;
  esac
done

MODE=$(select_mode)

if [ "${1:-}" = "--print-mode" ]; then
  echo "$MODE"
  exit 0
fi

exec claude --permission-mode "$MODE" "$@"
