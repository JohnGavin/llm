---
name: cc-startup-hang-npx-timeout
description: "cc startup hangs after \"Switched to worktree\" = unbounded npx ccusage in burn_rate_check (GNU timeout absent on macOS)"
metadata: 
  node_type: memory
  type: project
  originSessionId: 4edf2ca8-4c7c-43d8-8eca-73de94efd730
---

If `cc` (`.claude/scripts/cc.sh`) HANGS right after printing `Switched to worktree: …`
and before Claude's UI appears, the cause is the **burn-rate check**, not the harness.

Chain: `cc.sh` → `get_burn_rate()` (runs BEFORE `exec claude`) → `burn_rate_check.sh
--percent-only` → `npx ccusage daily …`. That npx call was wrapped in
`${TIMEOUT_CMD:+$TIMEOUT_CMD 30}`, but `TIMEOUT_CMD = command -v timeout || command -v
gtimeout` is **empty on stock macOS** (no GNU coreutils), so the wrapper expands to
NOTHING and npx runs **unbounded**. On an npx cache-miss it blocks on a network fetch or
the interactive "Ok to proceed? (y)" install prompt → hangs forever. `|| echo 0` only
catches a non-zero exit, not a hang.

Immediate unblock (prime the npx cache so it stops prompting/fetching):
`npx --yes ccusage --version`  (or `brew install coreutils` to get `gtimeout`).

Durable fix (llm#716, 2026-07-03): portable timeout that falls back to **perl**
(`perl -e 'alarm shift @ARGV; exec @ARGV' <secs> <cmd>`) when GNU timeout is absent, plus
`npx --yes` and `</dev/null` on the fetch so it can never prompt, plus a defensive
`_cc_bounded 15` around `get_burn_rate` in cc.sh.

General lesson: any macOS/launchd script that wraps a slow command in `${TIMEOUT_CMD:+…}`
has NO timeout when GNU `timeout` is missing — use a perl-`alarm` fallback. Ties to
[[startup-cost-is-mcp-not-hook]] (a *different* slow-start cause: r-btw MCP nix eval).
