#!/usr/bin/env bash
# cc.sh — Claude Code wrapper with permission-mode + budget-aware model selection
#
# Permission mode selection:
#   /tmp, /private/tmp                       → bypassPermissions
#   git worktree (git-dir != git-common-dir) → bypassPermissions
#   anything else (main checkout, $HOME)     → default
#
# Budget-aware model selection (unless --model explicitly provided):
#   BURN >= 90%: Auto-spawn sonnet session in worktree
#   BURN >= 70%: Use sonnet model
#   BURN <  70%: Use opus model
#
# Usage:
#   alias cc='~/.claude/scripts/cc.sh'
#   cc                      # starts session with auto-selected mode + model
#   cc --print-mode         # prints the detected mode and exits
#   cc --model opus         # explicit model override (bypasses budget check)
#   cc --permission-mode <m> ...  # explicit permission override
#
# Companion rules: permission-mode-discipline, auto-delegation

set -e

is_worktree() {
  local common gitdir
  common=$(git rev-parse --git-common-dir 2>/dev/null) || return 1
  gitdir=$(git rev-parse --git-dir 2>/dev/null) || return 1
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

get_burn_rate() {
  local script="$HOME/.claude/scripts/burn_rate_check.sh"
  if [[ -x "$script" ]]; then
    "$script" --percent-only 2>/dev/null || echo "0"
  else
    echo "0"
  fi
}

# Check for explicit overrides
HAS_MODEL_OVERRIDE=false
HAS_PERMISSION_OVERRIDE=false
for arg in "$@"; do
  case "$arg" in
    --model|--model=*) HAS_MODEL_OVERRIDE=true ;;
    --permission-mode|--permission-mode=*) HAS_PERMISSION_OVERRIDE=true ;;
  esac
done

# Print mode and exit if requested
if [ "${1:-}" = "--print-mode" ]; then
  echo "Permission: $(select_mode)"
  echo "Burn rate: $(get_burn_rate)%"
  exit 0
fi

# Build argument list
ARGS=()

# Add permission mode unless overridden
if ! $HAS_PERMISSION_OVERRIDE; then
  MODE=$(select_mode)
  ARGS+=(--permission-mode "$MODE")
fi

# Add model unless overridden
if ! $HAS_MODEL_OVERRIDE; then
  BURN=$(get_burn_rate)

  if [[ "$BURN" -ge 90 ]]; then
    # CRITICAL: Auto-spawn worktree with sonnet
    REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")

    if [[ -n "$REPO_ROOT" ]] && ! is_worktree; then
      REPO_NAME=$(basename "$REPO_ROOT")
      WORKTREE="${REPO_ROOT}/../${REPO_NAME}-sonnet"

      if [[ ! -d "$WORKTREE" ]]; then
        BRANCH_NAME="sonnet-$(date +%m%d)"
        echo "🔥 BURN CRITICAL ($BURN%) — creating worktree at $WORKTREE"
        git worktree add "$WORKTREE" -b "$BRANCH_NAME" 2>/dev/null || \
          git worktree add "$WORKTREE" "$BRANCH_NAME" 2>/dev/null || \
          git worktree add "$WORKTREE" HEAD
      else
        echo "🔥 BURN CRITICAL ($BURN%) — using existing worktree at $WORKTREE"
      fi

      echo "Starting sonnet session in worktree..."
      echo "To return to main checkout: cd $REPO_ROOT"
      echo ""

      cd "$WORKTREE"
      # Re-select mode for worktree (will be bypassPermissions)
      ARGS=(--permission-mode "$(select_mode)" --model sonnet)
    else
      echo "🔥 BURN CRITICAL ($BURN%) — using sonnet"
      ARGS+=(--model sonnet)
    fi

  elif [[ "$BURN" -ge 70 ]]; then
    echo "⚠️  BURN WARNING ($BURN%) — using sonnet"
    ARGS+=(--model sonnet)
  fi
  # else: default to opus (no --model flag needed, it's the default)
fi

exec ~/.local/bin/claude "${ARGS[@]}" "$@"
