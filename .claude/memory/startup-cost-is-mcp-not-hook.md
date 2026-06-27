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

**Fix (layer 1, #673):** boot via the GC-rooted drv
(`~/.claude/nix-gcroots/llm-shell.drv`, zero eval) instead of `default.nix`.
Same trap as launchd/cron in nix-operations.md / llm#596. Wrapper:
`~/.claude/scripts/r_btw_mcp_launch.sh` → ~10.5s to ~6.4s.

**Fix (layer 2, #674 / PR #680, 2026-06-25):** "still slow" after #673. The
remaining ~4s was `nix-shell <drv> --run` itself — its per-launch environment
build + shellHook, NOT nix eval (`nix-shell <drv> --run true` ≈ 4s alone). #673
fixed eval and left this untouched, so the fix looked like it "failed." Cure:
capture the dev env ONCE via `nix print-dev-env <drv>` into a cache
(`~/.claude/nix-gcroots/llm-mcp-devenv.sh`, keyed to resolved drv store path
since mtimes are 1970), `source` it, then `exec Rscript` directly — skips
nix-shell per-launch overhead. Warm boot ~6.4s → ~1.7s; verified MCP
initialize + tools/list (22 tools). Fallback chain: cached-env → `nix-shell
<drv>` → `nix-shell default.nix`. Diagnostic that found it:
`time bash -c 'source <(nix print-dev-env <drv>); Rscript -e "cat(1)"'` ≈ 0.6s
vs `nix-shell <drv> --run "Rscript -e cat(1)"` ≈ 6.4s. The ~1.7s btw server
init is now the irreducible floor.
