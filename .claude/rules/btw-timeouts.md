---
paths:
  - "*.R"
  - "_targets.R"
---
# btw MCP Tool Configuration & Timeout Rules

## No Infinite Waits (MANDATORY)

**Blocking indefinitely is STRICTLY FORBIDDEN.** Any operation that could run
longer than ~30 seconds MUST either:

1. **Use a timeout** (Bash `timeout` parameter, or wrap with `timeout` command)
2. **Run in background** (`run_in_background: true`) and check status non-blocking
3. **Delegate to a subagent** (which has its own `max_turns` limit)

## Common Violations (ALL FORBIDDEN)

- `gh run watch` — blocks until CI finishes (10-30+ min)
- `btw_tool_run_r` with long-running code — has NO built-in timeout
- `btw_tool_pkg_check` / `btw_tool_pkg_test` — can run for minutes
- `nix-build` without timeout — can take 30+ min on cache miss
- Any `Bash` call without explicit `timeout` on commands > 30s
- `shiny::runApp()` or `launch_dashboard()` — blocks forever
- Any function that waits for user input or network response

## Correct Patterns

```bash
# WRONG — blocks for 10+ min
gh run watch 12345 --exit-status

# CORRECT — non-blocking status check
gh run view 12345 --json status,conclusion

# WRONG — no timeout on slow build
nix-build default.nix

# CORRECT — delegate to subagent OR use background
Task(subagent_type="Bash", prompt="nix-build default.nix")

# WRONG — btw_tool_run_r with devtools::check()
btw_tool_run_r(code = "devtools::check()")

# CORRECT — delegate to subagent
Task(subagent_type="Bash", model="sonnet", prompt="run devtools::check()")
```

## NEVER Call Directly

- `btw_tool_run_r` for: devtools::test/check/build, gh::gh() API calls, any operation >10 lines output, debugging test failures
- `btw_tool_pkg_*` — Always use appropriate agent

**Exception:** Simple one-liners (<5s), checking values, quick calculations

## btw Tool Subset

**Current subset** (saves ~6k tokens vs all tools):
`btw::btw_tools(c('docs', 'pkg', 'files', 'run', 'env', 'session'))`

| Loaded | Category | Purpose |
|--------|----------|---------|
| Yes | docs | R help pages, vignettes, NEWS |
| Yes | pkg | check, test, document, coverage |
| Yes | files | read, write, list, search |
| Yes | run | execute R code |
| Yes | env | describe data frames, environment |
| Yes | session | platform info, package versions |

## Excluded Categories

| Excluded | Why | Alternative |
|----|----|----|
| git | Use `gert::git_*()` per 9-step workflow | gert R package |
| github | Use `gh::gh()` per 9-step workflow | gh R package |
| agents | Redundant - Task tool has same agents | Task tool subagents |
| cran | Rarely needed for active dev | WebSearch |
| web | Redundant | WebFetch tool |
| ide | Rarely used | - |

**Re-enable if needed:** Edit `~/.claude.json` mcpServers args.
