---
name: deploy-gap-stale-main-checkout
description: "A merged fix that \"isn't live\" usually means the local main checkout is behind origin/main — cron auto-pull is jammed by a dirty tree"
metadata: 
  node_type: memory
  type: project
  originSessionId: 9d8b949e-7377-4517-9e94-553043bfe76b
---

When a fix is confirmed merged to `origin/main` but its effect never appears (e.g. roborev daily email still shows the old `n/a` p50 after #765 merged), the cause is almost always: **the local main checkout `~/docs_gh/llm` is behind `origin/main`, and every launchd cron runs scripts from that stale checkout.** Merged ≠ deployed.

**Diagnose:** `git -C ~/docs_gh/llm rev-list --count HEAD..origin/main` (>0 = stale). `git -C ~/docs_gh/llm status -sb` shows `[behind N]`.

**Root cause (#510, reopened 2026-07-11):** #513 added `git merge --ff-only origin/main` to each cron wrapper, but `--ff-only` aborts on a dirty tree, the abort is swallowed by `2>/dev/null`, and the cron runs stale code with only a silent WARN. The tree is ~always dirty because orchestrator sessions leave uncommitted `.claude/memory/*.md` edits (allowed by the `auto-delegation` bounded exceptions). So the deploy silently freezes.

**Manual unjam:** back up untracked files → `git -C ~/docs_gh/llm stash push --include-untracked` → `git -C … merge --ff-only origin/main` → `stash pop` → resolve `MEMORY.md` conflict keeping both entries → drop stash. See [[MEMORY]].

**Durable fix:** attempt #3 (dirty-tolerant auto-stash pull helper + deploy-staleness banner in the daily email + `launchd_health_events` freshness note) tracked on #510. Related false-positive: the overnight "N failed cron jobs" reads a stale `launchd_health_events` table (sole weekly writer) — verify against `launchctl print gui/$(id -u)/<label>` `last exit code` before trusting it ("N failed can lie", cf. [[roborev-gemini-dead-silent-failure]]).
