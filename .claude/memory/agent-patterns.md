# Agent Delegation Patterns

## Common Agents

| Agent | Model | Use For |
|-------|-------|---------|
| `quick-fix` | haiku | Typos, renames, version bumps, syntax fixes |
| `general-purpose` | opus/sonnet/haiku | General tasks (match model to complexity) |
| `critic` | sonnet | Read-only adversarial review |
| `fixer` | sonnet | Apply fixes from critic reports |
| `r-debugger` | sonnet | R CMD check/test failures |
| `reviewer` | sonnet | Code reviews |
| `nix-env` | sonnet | Nix shell issues |
| `targets-runner` | sonnet | Pipeline debugging |
| `shinylive-builder` | sonnet | WASM builds |
| `shiny-async-debugger` | sonnet | Async/crew/ExtendedTask debugging |
| `data-engineer` | sonnet | Pipeline building (dbt/DuckDB) |
| `data-quality-guardian` | sonnet | Data validation (pointblank) |
| `wiki-curator` | sonnet | Knowledge base compilation |
| `claude-code-guide` | sonnet | Claude Code documentation lookup |

## Model Selection Guide

| Task Type | Model | Cost | Examples |
|-----------|-------|------|----------|
| Simple queries | `haiku` | $ | File checks, curl, grep, counting |
| Moderate work | `sonnet` | $$ | Tests, debugging, analysis |
| Complex reasoning | `opus` | $$$ | Architecture, planning, multi-file |

## Mandatory Rules

1. **Match model to complexity** - haiku for simple, sonnet for moderate, opus for complex
2. **Run independent tasks in parallel** - multiple Task calls in one message
3. **Delegate when output > 10 lines** OR complex reasoning needed
4. **Never delegate** simple file checks, one-line commands, reading files

## btw Tool Delegation (CRITICAL)

**NEVER call directly:**
- btw_tool_run_r for: devtools::test/check/build, gh::gh() API calls, >10 lines output
- btw_tool_pkg_* - Always use appropriate agent
- Any function that waits for input or hangs (shiny::runApp, launch_dashboard)

**Exception:** Simple one-liners (<5s), checking values, quick calculations

## Common Mistakes

- Using opus for simple tasks (wastes tokens)
- Using btw tools directly for builds/tests (always delegate)
- Using wrong agent for task (haiku for complex verification)
- Running independent tasks sequentially instead of parallel
- Using agents to check symlinks (just use ls -la)

For full rules: invoke `subagent-delegation` skill

## Automation Workflows

### --effort Level Selection

Match effort to task complexity to optimize speed and cost:

```bash
# Simple file checks (haiku-level work)
claude --model haiku --effort low "grep for TODOs"

# Standard debugging
claude --model sonnet --effort medium "fix test failure"

# Complex refactoring
claude --model sonnet --effort high "refactor authentication"

# Architecture decisions
claude --effort xhigh "design new data pipeline"
```

**Agent integration:**
```json
{
  "agents": {
    "quick-fix": {"model": "haiku", "effort": "low"},
    "r-debugger": {"model": "sonnet", "effort": "medium"},
    "reviewer": {"model": "sonnet", "effort": "high"}
  }
}
```

### --bare Mode (CI/Scripts)

Use for automated environments where hooks would interfere:

```bash
# CI pipeline check
claude --bare --print --model haiku "run tests and report status"

# Container environment (no keychain)
docker run -e ANTHROPIC_API_KEY claude --bare --print "validate config"

# Minimal reproducible example
claude --bare --system-prompt "You are a helpful assistant" "hello"
```

**When to use:**
- CI/CD pipelines
- Containerized environments
- Batch processing scripts
- Debugging hook issues

**Trade-offs:**
- ✓ Faster startup (no hook/plugin loading)
- ✓ Reproducible (no environment-dependent config)
- ✗ No auto-formatting (PostToolUse hooks disabled)
- ✗ No session persistence (unless explicit --settings)

### --remote-control (Mobile Monitoring)

Monitor long-running tasks from phone:

```bash
# Start monitored session
claude --remote-control "nightly-build"

# Session runs on laptop, accessible from mobile app
# Check progress, approve PRs, view logs from anywhere
```

**Use cases:**
| Scenario | Benefit |
|----------|---------|
| Pipeline running overnight | Check completion from home |
| PR review needed | Approve from phone while traveling |
| Build status check | Monitor without SSH |
| Agent approval | Authorize destructive ops remotely |

### Scheduled Automation (Workaround)

Since `/loop` and `/schedule` are not available, use system schedulers:

**launchd pattern (macOS):**
```xml
<!-- ~/.claude/launchd/hourly_ctx_check.plist -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.claude.hourly-ctx-check</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/claude</string>
        <string>--bare</string>
        <string>--print</string>
        <string>--model</string>
        <string>haiku</string>
        <string>/check</string>
    </array>
    <key>StartInterval</key>
    <integer>3600</integer>
    <key>StandardOutPath</key>
    <string>/tmp/claude-ctx-check.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/claude-ctx-check.err</string>
</dict>
</plist>
```

Load with: `launchctl load ~/Library/LaunchAgents/hourly_ctx_check.plist`

**cron pattern (Linux):**
```bash
# Daily worktree cleanup at 9 AM
0 9 * * * cd ~/docs_gh/llm && claude --bare --print --model haiku "/cleanup-worktrees" >> /tmp/cleanup.log 2>&1

# Hourly PR status check (weekdays only) — now handled by pr_status_pulse.sh + launchd instead
```

**Existing implementations:**
- `~/.claude/launchd/config_pulse.plist` — daily config drift check
- `~/.claude/launchd/knowledge_pulse.plist` — hourly wiki health check

### Side Queries (Workaround)

Since `/btw` is not available, use separate terminal window or `--resume`:

**Pattern 1: Parallel session**
```bash
# Terminal 1: main work
claude "start long pipeline"

# Terminal 2: side query (doesn't pollute main history)
claude --print --model haiku "what's the status of the pipeline?"
```

**Pattern 2: Named sessions**
```bash
# Start main session with name
claude --name "main-work" "build package"

# In another terminal: query without interfering
claude --print "check progress on main-work session"
```

**Pattern 3: --brief mode**
```bash
# Enable SendUserMessage tool for agents to ask questions
claude --brief --agent r-debugger "debug test failure"
# Agent can use SendUserMessage("Status: 3/10 tests passing") without interrupting
```

## Burn Rate Awareness

When `~/.claude/scripts/burn_rate_check.sh` reports high usage:

| Severity | Action |
|----------|--------|
| WARN (>70%) | Use `--effort low` for simple tasks; delegate to haiku agents |
| CRITICAL (>85%) | Switch to `--model haiku` for all work; use `--bare` to skip overhead |

**Cost optimization:**
```bash
# Instead of:
claude --model sonnet "check if file exists"

# Use:
claude --model haiku --effort low --bare "check if file exists"
```

## Related Documentation

- `~/.claude/docs/automation-features.md` — Full feature availability matrix
- `.claude/test_loop_schedule.md` — Validation test plan
- Global CLAUDE.md — Agent configuration table
- `~/.claude/hooks/` — Hook automation examples
