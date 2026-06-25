#!/usr/bin/env bash
# r_btw_mcp_launch.sh — launch the r-btw MCP server via a GC-rooted nix drv to
# avoid the ~8s nixpkgs re-evaluation that `nix-shell default.nix` pays on EVERY
# Claude Code startup. The MCP boot is the dominant session-start cost; #657
# only fixed the session_init.sh hook. See nix-operations.md memory + llm#596.
#
# Strategy: ask nix_gcroot_refresh.sh for a fresh-or-fallback drv path (instant
# when default.nix is unchanged; re-instantiates only after an edit), then enter
# via that drv (zero eval, zero network). Falls back to default.nix if no usable
# drv exists, so the server always starts.
set -euo pipefail

NIX_FILE="/Users/johngavin/docs_gh/llm/default.nix"
REFRESH="${HOME}/.claude/scripts/nix_gcroot_refresh.sh"
NIX_SHELL="/nix/var/nix/profiles/default/bin/nix-shell"

TARGET="$NIX_FILE"
if [ -x "$REFRESH" ]; then
    DRV="$("$REFRESH" "$NIX_FILE" 2>/dev/null | tail -1 || true)"
    if [ -n "${DRV:-}" ] && [ -e "$DRV" ]; then
        TARGET="$DRV"
    fi
fi

RCODE='btw::btw_mcp_server(tools = btw::btw_tools(c("docs", "pkg", "files", "run", "env", "session")))'
exec "$NIX_SHELL" "$TARGET" --run "Rscript -e '$RCODE'"
