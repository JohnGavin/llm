#!/usr/bin/env bash
# r_btw_mcp_launch.sh — launch the r-btw MCP server with minimal startup cost.
#
# History of the bottleneck:
#   * Original: `nix-shell default.nix --run Rscript …` re-evaluated nixpkgs on
#     every launch (~10s). #673 switched to a GC-rooted drv (~6.4s).
#   * Remaining cost was `nix-shell <drv> --run` itself: per-launch environment
#     build + shellHook (~4s), NOT nix evaluation.
#
# This version captures the dev environment ONCE via `nix print-dev-env` (cached,
# keyed to the drv store path) and sources it, then execs Rscript directly —
# skipping nix-shell's per-launch overhead. Measured ~6.4s → ~1.5s warm.
#
# Correctness: `nix print-dev-env <drv>` runs the shellHook and emits all env
# vars (PATH, R_LIBS_SITE, the R interpreter, etc.); the cached output is keyed
# to the resolved drv so a default.nix edit (new drv) auto-regenerates it. Falls
# back to nix-shell entry, then to default.nix, so the server always starts.
# See nix-operations.md memory, llm#596 (store mtime is always 1970 — invalidate
# by drv identity, not mtime) and llm#674.
set -euo pipefail

NIX_FILE="/Users/johngavin/docs_gh/llm/default.nix"
REFRESH="${HOME}/.claude/scripts/nix_gcroot_refresh.sh"
NIX_SHELL="/nix/var/nix/profiles/default/bin/nix-shell"
NIX_BIN="/nix/var/nix/profiles/default/bin/nix"
ENV_CACHE="${HOME}/.claude/nix-gcroots/llm-mcp-devenv.sh"
RCODE='btw::btw_mcp_server(tools = btw::btw_tools(c("docs", "pkg", "files", "run", "env", "session")))'

# 1. Resolve a GC-rooted drv (instant when default.nix unchanged).
TARGET="$NIX_FILE"
if [ -x "$REFRESH" ]; then
    DRV="$("$REFRESH" "$NIX_FILE" 2>/dev/null | tail -1 || true)"
    if [ -n "${DRV:-}" ] && [ -e "$DRV" ]; then
        TARGET="$DRV"
    fi
fi

# 2. Fast path: source a cached dev-env, then exec R directly (no nix-shell).
if [ "$TARGET" != "$NIX_FILE" ]; then
    # Identify the drv by its resolved store path (mtimes are unreliable: 1970).
    DRV_ID="$(readlink "$TARGET" 2>/dev/null || echo "$TARGET")"
    NEED_REGEN=1
    if [ -s "$ENV_CACHE" ] && head -1 "$ENV_CACHE" | grep -qxF "# drv:${DRV_ID}"; then
        NEED_REGEN=0
    fi
    if [ "$NEED_REGEN" = 1 ]; then
        if { printf '# drv:%s\n' "$DRV_ID"; "$NIX_BIN" print-dev-env "$TARGET" 2>/dev/null; } > "${ENV_CACHE}.tmp"; then
            mv "${ENV_CACHE}.tmp" "$ENV_CACHE"
        else
            rm -f "${ENV_CACHE}.tmp"
        fi
    fi
    if [ -s "$ENV_CACHE" ]; then
        set +e
        # shellcheck disable=SC1090
        source "$ENV_CACHE" >/dev/null 2>&1
        src_rc=$?
        set -e
        if [ "$src_rc" -eq 0 ] && command -v Rscript >/dev/null 2>&1; then
            exec Rscript -e "$RCODE"
        fi
    fi
fi

# 3. Fallback: original nix-shell entry (drv if available, else default.nix).
exec "$NIX_SHELL" "$TARGET" --run "Rscript -e '$RCODE'"
