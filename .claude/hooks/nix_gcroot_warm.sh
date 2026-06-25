#!/usr/bin/env bash
# nix_gcroot_warm.sh — PostToolUse hook (Bash|Edit|Write). When llm's default.nix
# becomes newer than the GC-rooted drv stamp, fire nix_gcroot_refresh.sh in the
# background so the NEXT session's r-btw MCP boot enters a pre-warmed drv (zero
# eval) instead of paying ~10s re-instantiation inline. Idempotent, non-blocking.
# Follow-up to #673 / #674 (Option B). See nix-operations.md and the
# startup-cost-is-mcp-not-hook memory.
#
# Env overrides (for tests): NIX_GCROOT_WARM_NIX_FILE, NIX_GCROOT_WARM_STAMP,
# NIX_GCROOT_WARM_REFRESH, NIX_GCROOT_WARM_DRYRUN=1 (print intent, do not spawn).
set -euo pipefail

NIX_FILE="${NIX_GCROOT_WARM_NIX_FILE:-/Users/johngavin/docs_gh/llm/default.nix}"
STAMP="${NIX_GCROOT_WARM_STAMP:-${HOME}/.claude/nix-gcroots/llm-shell.drv.stamp}"
REFRESH="${NIX_GCROOT_WARM_REFRESH:-${HOME}/.claude/scripts/nix_gcroot_refresh.sh}"

# Hooks receive JSON on stdin; we never read it, so we never block on it.

[ -f "$NIX_FILE" ] || exit 0
[ -x "$REFRESH" ] || exit 0

# Fresh? stamp exists AND default.nix is NOT newer than it -> nothing to do.
if [ -e "$STAMP" ] && [ ! "$NIX_FILE" -nt "$STAMP" ]; then
    exit 0
fi

# Stale (or no stamp yet): warm in the background. Never block the tool call.
if [ "${NIX_GCROOT_WARM_DRYRUN:-0}" = "1" ]; then
    echo "nix_gcroot_warm: would refresh $NIX_FILE"
    exit 0
fi
nohup "$REFRESH" "$NIX_FILE" >/dev/null 2>&1 &
exit 0
