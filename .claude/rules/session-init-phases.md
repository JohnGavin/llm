# Rule: session_init.sh Phase Inventory

## When This Applies

When adding, removing, or renumbering phases in `.claude/hooks/session_init.sh`.
Update this table in the same commit.

## Phase Inventory

| Phase | Label | What it does | Output behaviour |
|-------|-------|--------------|-----------------|
| 1 | Environment | Nix shell presence check | One line: `Nix Shell: active/WARNING` |
| 1b | Permission Mode | Workspace kind vs settings.json defaultMode | One line: `Permission Mode: ok/WARN` |
| 1c | Project Environment Class | Reads `Environment:` from `.claude/CLAUDE.md` | One line: `Environment: <val>` |
| 1d | Cross-Project Scope | Reads cross-project authority from `.claude/CLAUDE.md` | One line: `project-scope: …` |
| 2 | Mapping Validation | Skills/Rules/Commands/Hooks/Memory consistency | Summary line + warnings |
| 3 | Size Audit | Line counts for CLAUDE.md, MEMORY.md, dir summaries | Per-file lines + WARN/FAIL |
| 4 | Skill Token Audit | Skills dir line counts vs 500-line limit | Summary + per-skill WARN |
| 5 | ctx.yaml Cache Audit | Dependency ctx cache freshness (via Rscript) | `ctx:N_ok/N_other/N_miss` |
| 6 | R-universe Build Status | Checks johngavin.r-universe.dev/api/packages | `R-universe: N OK, N failed` |
| 7 | Worktree Context | Detects worktree session, stale agent/git worktrees | Contextual output + warnings |
| 7f | Worktree Auto-GC | Auto-removes agent worktrees where PID-dead AND lock-age >14d (current project only). Skipped if `CLAUDE_SESSION_INIT_WORKTREE_GC=0`. Logs to `~/.claude/logs/session_init_worktree_gc.log`. Never exits non-zero. | Silent when N=0; one line `Worktree GC: removed N stale (>14d, PID-dead)` when N>0 |
| 7g | Branch Harvest on Fork | Audits unmerged `feat/*` branches for SESSION_INTERRUPTED OR (SURFACE_TOUCHED AND STALE). Skipped if `CLAUDE_BRANCH_HARVEST=0`. Per-branch silence via `git notes --ref=harvest`. Logs to `~/.claude/logs/branch_harvest.log`. 5s timeout, fail-open. | Silent when no findings; one `branch-harvest: N branches flagged` block per finding when N>0. See `branch-harvest-on-fork` rule. |
| 8 | roborev Review Status | Daemon status + high-severity finding counts | `roborev:Nhigh/Ntotal` |
| 8b | roborev-autoclose Visibility | Reads autoclose counter JSON for today/week stats | `roborev-autoclose: threshold=…` |
| 9 | Weekly Burn Rate | Calls `burn_rate_check.sh compact` | `burn:<level>` |
| 10 | Orphan crew Workers | Kills crew workers with no controller | Kills + WARN count |
| 11 | AGENTS.md Audit | Drift detection via `agents_md_audit.sh` | Silent OK or DRIFT warning |
| 11b | Quarto Contrast Wiring | Checks `_quarto.yml` post-render dark-contrast hook | WARN if missing |
| 11c | roborev Hook Coverage | Scans roborev DB repos for missing post-commit hooks | WARN list if any missing |
| 11d | launchd Plist Rebootstrap | Re-bootstraps known unloaded launchd plists | INFO list if re-bootstrapped |
| 12 | Session Log | Logs session start to unified DuckDB | Silent (infrastructure) |
| 13 | Braindump Sweep | Surfaces unprocessed braindumps from DuckDB | ACTION block if any; stale warning |
| 13b | Pending Skillify | Processes pending skillify from previous session | Silent if none |
| 13c | Dated GH Issues | Surfaces `[YYYY-MM-DD]`-titled issues past due | `=== Dated issues ===` block if any |
| 13d | roborev Backlog Banner | Open count + addressed rate from roborev DB | `roborev-backlog: open=N …` |
| 14a | T-lang Closure-Rebuild | Warns if `flake.nix` missing closure-rebuild marker | WARN block if any projects affected |
| 14b | CI-Failure Issues | Counts open GitHub issues labeled `ci-failure` | One line if N>=1; silent if N=0 |
| 14 | Session-Start SHA | Records HEAD SHA for session-end roborev refine | Silent (infrastructure) |

## Adding a New Phase

1. Pick a slot that does not conflict with existing phases (use letter suffixes for insertions).
2. Add the block to `session_init.sh` in the correct position.
3. Add a row to this table in the same commit.
4. If the phase makes network calls, add a 5-second timeout and `2>/dev/null || true` fail-open.

## Related

- `.claude/hooks/session_init.sh` — the hook
- `.claude/hooks/session_init_phase14b_selftest.sh` — selftest for Phase 14b
- `btw-timeouts` rule — MCP timeout discipline (separate from session_init timeouts)
- JohnGavin/llm#387 — Phase 14b origin issue
