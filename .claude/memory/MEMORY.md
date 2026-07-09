# Project Memory Index

One hook line per topic; full detail lives in the linked file. Keep under ~140 lines.

## Architecture (see architecture.md)
- Two-tier Nix shell (dev + project shells); _targets.R orchestrates plans from R/tar_plans/ only

## MCP r-btw: NEVER Call Directly (see btw-timeouts rule)
- ALL R via `Bash("timeout N Rscript -e ...")`; never btw_tool_run_r/pkg_test/check/document/load_all; docs/files/session tools safe

## Agent Patterns (see agent-patterns.md)
- haiku=$ / sonnet=$$ / opus=$$$; delegate long btw_tool_pkg_* + run_r to subagents; run independent tasks in parallel

## CI Strategy (see ci-strategy.md)
- Public repos: any GH Actions OK; private: Nix-only Linux, conserve minutes; pkgdown built locally (bslib breaks in Nix)

## Nix Operations (see nix-operations.md)
- Segfaults = R-version mismatch or nested-shell R_LIBS_SITE contamination; never install.packages() in Nix; add pkgs via DESCRIPTION→default.R→re-enter; launchd/cron uses GC-rooted drv not default.nix (llm#596)

## Shinylive (see shinylive-issues.md)
- Munsell/ggplot2 error → use plotly; webr::install("munsell") before ggplot2; always test in real browser (F12)

## btw MCP Tools (see btw-timeouts rule)
- Subset docs/pkg/files/run/env/session; excluded git (gert), github (gh::gh()), agents, cran, web, ide

## pkgctx (see llm-package-context skill)
- `nix run github:b-rodrigues/pkgctx -- r . --compact`; central cache ~/docs_gh/proj/data/llm/content/inst/ctx/external/

## Tool Preferences (see tool-preferences.md)
- Preferred: mirai, crew, duckdb, arrow, dplyr, targets, pkgctx, cli; cachix push only this pkg never deps

## Performance Patterns (see r-vectorization-patterns.md)
- 10-100x speedup for entity loops: matrices not lists, padded grid, batch RNG, cbind indexing

## Session Conventions
- Commit with gert (not bash git); append CHANGELOG.md at /bye; CURRENT_WORK.md is ephemeral

## Safe Deletion (see feedback_safe-deletion.md)
- NEVER delete untracked >1MB without size/age/diff/user-approval (origin: 522MB worktree loss 2026-03-27)

## NEVER Edit default.nix Directly (see feedback_never-edit-default-nix.md)
- default.nix is rix-generated from default.R; edit DESCRIPTION→default.R; manual edits get overwritten

## Nix Shell Portability (see feedback_nix-shell-portability.md)
- GNU not BSD utils: no `grep -oP`, `sed -i ''`, `stat -f`; prefer Edit tool over sed; cachix via ./push_to_cachix.sh

## Worktree Location (see rules/worktree-location.md)
- New worktrees under ~/docs_gh/worktrees/<project>/<branch>/ (llm#582); use cc-worktree.sh; legacy ~/worktrees/ read-only

## Never `cd && git` (see feedback_no-compound-cd.md)
- `cd dir && git` triggers unbypassed approval prompt; always `git -C <dir>` (see git-no-compound-cd rule)

## Editing Symlinked Config (see feedback_symlink-edit-vs-mv.md)
- ~/.claude/settings.json symlinks to repo; use Edit/`>` redirect, never `mv` (replaces symlink with regular file)

## Knowledge Base Discipline (see feedback_knowledge-base-discipline.md)
- Hub at ~/docs_gh/llm/knowledge/ LOCAL-only never push; raw/ append-only, wiki/ needs `## Sources` + `[[topic]]`; wiki-curator compiles, critic validates

## GitHub Pages User Sites (see feedback_github-pages-user-sites.md)
- username.github.io serves from default branch NOT gh-pages; output-dir: docs, commit docs/ to master; quarto publish gh-pages fails for user sites

## Delegation Under Pressure (see feedback_delegation-under-pressure.md)
- After FIRST fix in a CI-fail→fix loop, delegate subsequent fixes to fixer/quick-fix (6 opus edits ≈$30 vs sonnet ≈$3)

## Parallel Model Allocation (see feedback_parallel-model-allocation.md)
- Cheapest sufficient model per task; dispatch independent tasks in parallel (one message, multiple Agent uses); even 1-line edits → quick-fix

## Cross-Project Scope (see cross-project-scope rule)
- Only llm sessions work across projects (llm#190); others own-tree-only, may file issues but not edit/dispatch/roborev elsewhere

## Roborev Session-End Automation (2026-05-20)
- session_stop.sh fires session_end_refine.sh in bg (timeout 120s, max-iter 3, min-severity high); opt-out SKIP_SESSION_END_REFINE=1

## Config Migration (2026-03-09)
- Rules/scripts/CLAUDE.md git-backed via symlinks; CLAUDE.md→AGENTS.md merged; /hi→/session-start symlink

## Verify External Claims (see feedback_verify-external-claims.md)
- Read an external tool's source/docs BEFORE asserting its internals; label unverified; use `gh api .../contents` when WebFetch blocked (origin: msgvault 2026-06-18)

## Adopt Before Build (see feedback_adopt-before-build.md)
- Before estimating a build, check stack primitives + maintained tools first; DuckDB ships fts+vss, RRF≈15 lines SQL (origin: over-scoped DuckDB+RRF 2026-06-18)

## Hook ENOENT = Deleted CWD (see hook-cwd-deletion.md)
- `ENOENT posix_spawn /bin/sh` on every hook = session cwd deleted; recover by relaunch via cc.sh from a real dir; never run from /tmp/ephemeral (llm#647)

## Stale PTY-Spare 100% CPU (see stale-pty-spare-cpu.md)
- Orphaned old-version bg-pty-host/bg-spare daemons busy-loop 100% CPU after harness upgrade; kill any whose version != running claude (2026-06-23)

## macOS Downloads TCC Block (see macos-downloads-tcc-block.md)
- Bash CANNOT read ~/Downloads (macOS TCC, persists w/ sandbox off); mv/cp fail, ls/stat mislead; hand user a `! mv` command (llm#670)

## Startup Cost = MCP, Not Hook (see startup-cost-is-mcp-not-hook.md)
- Slow start = r-btw MCP nix-shell eval (~10s), not session_init.sh; fix = GC-rooted drv boot (r_btw_mcp_launch.sh, #673) (2026-06-25)

## roborev Silent Failure (see roborev-gemini-dead-silent-failure.md)
- "0 failed" can lie: read overview.failed + failures.errors not verdicts.failed (0 when reviews crash); gemini dead → config codex/claude-code + daemon restart; #679 consistency check open (2026-06-25)

## npm Global Install in Nix Shell (see npm-global-in-nix-shell.md)
- `npm install -g` fails (read-only store prefix) + root-owned ~/.npm; use `--prefix ~/.npm-global --cache /tmp/<pkg>-cache <pkg>@<ver>`; model downloads → ~/.cache (GBs) (qmd #686, 2026-06-27)

## Destructive-FS Guard Blocks rm (see destructive-guard-blocks-rm.md)
- Guard denies `rm -rf ~/...` even WITH user confirmation (not bypassed in worktrees); don't retry — hand user `! rm`, verify w/ du/ls (2026-06-27)

## Symlink Worktree-Escape (see config-pulse-symlink-worktree-escape.md)
- A repo file that symlinks into ANOTHER repo (e.g. llm `.claude/scripts/config_pulse.sh` → llmtelemetry) lets a worktree agent's edit follow the link out of its sandbox and push to the other repo's main (#517 Pattern 2, real 2026-06-28). Memory is NOT a reliable guard — needs a PreToolUse realpath hook (#517) + de-symlinking known traps

## Hook "No stderr output" = pipefail abort (see hook-pipefail-no-stderr.md)
- SessionStart "Failed with non-blocking status code: No stderr output" = unguarded `var=$(...|grep...)` under `set -euo pipefail`; grep miss → exit 1 aborts hook silently; fix `|| true` (session_init.sh:847, llm#695, 2026-06-29)

## ellmer Can't Use Max Subscription (see ellmer-cannot-use-max-subscription.md)
- ellmer 0.4.0 has NO OAuth/`chat_claude_code()`; uses pay-per-token ANTHROPIC_API_KEY only; Anthropic blocked 3rd-party Max-sub use 2026-04-04; fund a key, then chat_claude() (#696, 2026-06-30)

## cc Startup Hang = npx/burn-rate no timeout (see cc-startup-hang-npx-timeout.md)
- `cc` hangs after "Switched to worktree" = unbounded `npx ccusage` in burn_rate_check (GNU timeout absent on macOS → `${TIMEOUT_CMD:+…}` empty); unblock `npx --yes ccusage --version`; fix = perl-alarm fallback + npx --yes + </dev/null (#716, 2026-07-03)

## Embed Issue/PR Links on Merge (see feedback_embed-issue-link-on-merge.md)
- When reporting a merge/PR/issue action, embed a clickable link (`[#750](url)`) never a bare `#750`; codified in pr-shipping-discipline rule (#751, 2026-07-08)
