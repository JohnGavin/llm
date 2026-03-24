---
paths:
  - "**"
---
# btw MCP Tool Timeout Rules (GLOBAL — ALL PROJECTS)

## CRITICAL: MCP r-btw Tools Have NO Timeout

The `mcp__r-btw__*` tools have **NO built-in timeout** and will block indefinitely.
There is NO way to cancel a stuck MCP tool call — the entire session hangs.
This rule applies to ALL projects, ALL file types, ALL contexts.

## MANDATORY: ALL R Execution via Bash with Timeout

**ALL R code execution MUST use Bash with `timeout` command. No exceptions.**

```bash
# CORRECT: Every R execution goes through Bash with timeout
Bash(command = "timeout 60 Rscript -e 'pkgload::load_all(); my_function()' 2>&1")

# CORRECT: Long operations in background
Bash(
  command = "timeout 300 Rscript -e 'devtools::test()' > /tmp/test_output.txt 2>&1",
  run_in_background = true
)
```

**Timeout guidelines:**
| Operation | Timeout | Background? |
|-----------|---------|-------------|
| Load package / quick calc | 60s | No |
| Single test file | 120s | No |
| devtools::document() | 120s | No |
| devtools::test() (all) | 300s | Yes |
| pkgdown::build_article() | 300s | Yes |
| devtools::check() | 600s | Yes |
| tar_make() | 1800s | Yes |

## FORBIDDEN: Direct MCP r-btw Calls That Execute R Code

**NEVER call these MCP tools directly — they WILL hang:**

| Tool | Why Forbidden | Bash Alternative |
|------|---------------|------------------|
| `btw_tool_run_r` | No timeout, blocks forever | `timeout 60 Rscript -e '...'` |
| `btw_tool_pkg_test` | Can run 5+ minutes | `timeout 300 Rscript -e 'devtools::test()'` |
| `btw_tool_pkg_check` | Can run 10+ minutes | `timeout 600 Rscript -e 'devtools::check()'` |
| `btw_tool_pkg_coverage` | Can run 10+ minutes | `timeout 600 Rscript -e 'covr::...()'` |
| `btw_tool_pkg_document` | Can hang on roxygen | `timeout 120 Rscript -e 'devtools::document()'` |
| `btw_tool_pkg_load_all` | Can hang on compilation | `timeout 60 Rscript -e 'pkgload::load_all()'` |

## ALLOWED: Read-Only MCP Tools (No R Execution)

These tools query metadata only and do NOT execute arbitrary R code:

| Tool | Safe? | Why |
|------|-------|-----|
| `btw_tool_docs_help_page` | Yes | Reads cached help |
| `btw_tool_docs_package_news` | Yes | Reads NEWS file |
| `btw_tool_docs_available_vignettes` | Yes | Lists vignettes |
| `btw_tool_docs_vignette` | Yes | Reads vignette text |
| `btw_tool_docs_package_help_topics` | Yes | Lists help topics |
| `btw_tool_files_list` | Yes | Lists files |
| `btw_tool_files_read` | Yes | Reads file content |
| `btw_tool_files_search` | Yes | Searches code |
| `btw_tool_sessioninfo_*` | Yes | Session metadata |
| `btw_tool_env_describe_environment` | Yes | Lists objects |
| `btw_tool_env_describe_data_frame` | Caution | May execute `skim()` |
| `list_r_sessions` | Yes | Lists sessions |
| `select_r_session` | Yes | Selects session |

## Correct Patterns

### Pattern 1: Quick R Execution (Foreground)

```bash
Bash(
  command = "timeout 60 Rscript -e 'pkgload::load_all(quiet=TRUE); atomic_risks()' 2>&1",
  timeout = 90000,
  description = "Load package and run quick query"
)
```

### Pattern 2: Tests/Check (Background)

```bash
Bash(
  command = "timeout 300 Rscript -e 'devtools::test()' > /tmp/test_out.txt 2>&1",
  run_in_background = true,
  description = "Run all tests with 5min timeout"
)
# Check results later:
Bash(command = "cat /tmp/test_out.txt")
```

### Pattern 3: Delegate to Agent

```
Task(subagent_type = "r-debugger", prompt = "Run tests and report failures")
```

## Red Flags — STOP Immediately

1. **Calling `btw_tool_run_r`** for ANY code → STOP, use Bash instead
2. **Calling `btw_tool_pkg_test/check/coverage/document/load_all`** → STOP, use Bash
3. **MCP tool running >60 seconds** → Cannot cancel, session is stuck
4. **Multiple btw_tool_run_r calls in sequence** → Pattern violation, switch to Bash

## btw Tool Subset

**Current subset:** `btw::btw_tools(c('docs', 'pkg', 'files', 'run', 'env', 'session'))`

Of these, only `docs`, `files`, `env` (read-only), and `session` are safe for direct MCP calls.
The `pkg` and `run` categories MUST go through Bash with timeout.
