# Tool Preferences

## Preferred Tools by Task

| Task | Tool |
|------|------|
| Parallel tasks | `mirai::mirai_map()` |
| Worker pools | `crew::crew_controller_local()` |
| SQL on files | `duckdb` |
| Large data I/O | `arrow` |
| Data manipulation | `dplyr` (duckdb/arrow backend) |
| Pipelines | `targets` + `crew` |
| Package API docs | `pkgctx` (via nix run) |
| Errors & Messages | `cli::cli_abort()`, `cli_alert()` |

## Cachix Push Rule

`default.nix` (mkShell) != `package.nix` (buildRPackage). Both required.
Push only THIS project's package. Never push standard R packages.
Run `./push_to_cachix.sh` directly (no user confirmation needed).

- CORRECT: `echo $RESULT | cachix push johngavin` (1 path only)
- WRONG: `cachix push johngavin $RESULT` (pushes entire closure)
- WRONG: `cachix watch-exec` (pushes all new store paths including deps)

## MCP r-btw Tools: MANDATORY Background Execution

**MCP r-btw tools have NO timeout** and will block forever. Long-running R code
MUST use Bash with timeout and background mode:

```bash
# CORRECT: Bash background with timeout
Bash(
  command = "timeout 300 Rscript -e 'devtools::test()' > /tmp/test.txt 2>&1",
  run_in_background = true
)

# WRONG: Direct MCP call (no timeout, blocks forever)
btw_tool_pkg_test()
```

| MCP Tool | Alternative |
|----------|-------------|
| `btw_tool_run_r` | `timeout 60 Rscript -e '...'` (ALWAYS, even short code) |
| `btw_tool_pkg_test` | `timeout 300 Rscript -e 'devtools::test()'` |
| `btw_tool_pkg_check` | `timeout 600 Rscript -e 'devtools::check()'` |
| `btw_tool_pkg_coverage` | `timeout 600 Rscript -e 'covr::package_coverage()'` |
| `btw_tool_pkg_document` | `timeout 120 Rscript -e 'devtools::document()'` |
| `btw_tool_pkg_load_all` | `timeout 60 Rscript -e 'pkgload::load_all()'` |

**Safe MCP tools (read-only, no R execution):**
- `btw_tool_docs_*` - help pages, vignettes
- `btw_tool_files_read/list/search` - file operations
- `btw_tool_env_describe_*` - data inspection (caution: skim may hang)
- `btw_tool_sessioninfo_*` - session queries

See rule: `btw-timeouts.md`

## Common Tasks

| Task | Approach |
|------|----------|
| Package API docs | `nix run github:b-rodrigues/pkgctx` |
| GitHub Actions | Check `.github/workflows/` for examples |
| Debugging R errors | `r-debugger` agent |
| Shiny dashboards | `claude --chrome` then `launch_dashboard()` |
| README requirements | `readme-qmd-standard` skill |
| Agent delegation | `subagent-delegation` skill |
| Long R operations | Bash + timeout + run_in_background (see btw-timeouts rule) |
