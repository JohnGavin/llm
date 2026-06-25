---
name: startup-cost-is-mcp-not-hook
description: "Slow Claude Code startup is usually the r-btw MCP server's nix-shell eval, not the session_init hook"
metadata: 
  node_type: memory
  type: project
  originSessionId: e535c923-1a3c-4ece-b1de-4022c883237f
---

When Claude Code "takes >10s to start", the dominant cost is almost always the
**r-btw MCP server boot**, not the `session_init.sh` SessionStart hook.

Measured 2026-06-25: session_init hook = 3.5s (after #657 cut it from 17.6s);
the r-btw MCP server = ~10s every launch because `~/.claude.json` booted it with
`nix-shell /…/llm/default.nix --run Rscript …`, which re-evaluates the nixpkgs
flake on every launch (8.75s repeatable; first run network-fetches flakehub
nixpkgs-weekly). The harness blocks on MCP startup to enumerate btw tools.

**Diagnostic order:** time the MCP command FIRST (`nix-shell default.nix --run
"Rscript -e 'cat(1)'"`), then the hooks. #657 optimized the hook and left the
real bottleneck untouched — fixing the wrong thing looks like the fix "failed".

**Fix:** boot via the GC-rooted drv (`~/.claude/nix-gcroots/llm-shell.drv`, zero
eval) instead of `default.nix`. Same trap as launchd/cron in nix-operations.md /
llm#596. Wrapper: `~/.claude/scripts/r_btw_mcp_launch.sh` (PR #673) → ~10.5s to
~6.2s. The ~1.8s btw server init is irreducible. Activation = repoint the r-btw
`command` in `~/.claude.json` after #673 merges.
