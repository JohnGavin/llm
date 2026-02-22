# Subagent Delegation Rules

Detailed guidance on when and how to use subagents effectively.

## Available Agents

### Built-in (from Task tool)
- `general-purpose` - Multi-step research and execution
- `Explore` - Fast codebase exploration (use thoroughness: "quick"/"medium"/"very thorough")
- `Plan` - Fast codebase exploration
- `claude-code-guide` - Claude Code/SDK documentation
- `statusline-setup` - Configure status line settings

### Custom R Package Development
- `planner` (opus/16k) - Architecture, design decisions
- `verbose-runner` (sonnet/4k) - Tests, builds, checks
- `quick-fix` (haiku/1k) - Simple edits < 5 lines
- `r-debugger` (sonnet/8k) - Debug test/check failures
- `reviewer` (sonnet/8k) - Code review
- `nix-env` (sonnet/8k) - Nix environment issues
- `targets-runner` (sonnet/8k) - Targets pipeline debugging
- `shinylive-builder` (sonnet/8k) - WASM compilation

## Delegation Decision Tree

```
Is it a simple check (file exists, symlink status)?
├─ YES → Use direct tools (ls, cat, Read)
└─ NO → Continue...
   │
   Will output be > 10 lines?
   ├─ YES → Delegate to agent
   └─ NO → Continue...
      │
      Is it R package build/test/check?
      ├─ YES → verbose-runner
      └─ NO → Continue...
         │
         Needs complex reasoning?
         ├─ YES → planner
         └─ NO → Do it directly
```

## Common Patterns

### ALWAYS Delegate
- `devtools::check()` → verbose-runner
- `devtools::test()` → verbose-runner
- `devtools::build()` → verbose-runner
- `btw_tool_pkg_*` → appropriate agent
- `btw_tool_run_r` with complex code → verbose-runner
- Debugging failures → r-debugger
- Architecture decisions → planner
- Code review → reviewer

### NEVER Delegate
- `ls`, `cat`, `echo`, `pwd`
- `Read`, `Write`, `Edit` tools
- Simple `grep` or `find`
- Checking if file/symlink exists
- Reading < 10 lines
- Simple one-liners

## Wrong vs Right Examples

```r
# WRONG - Delegating simple checks
Task("Check symlink", "Run ls -la to verify symlink")  # ❌

# RIGHT - Direct execution
Bash("ls -la proj")  # ✅

# WRONG - Direct btw tool for builds
mcp__r-btw__btw_tool_run_r("devtools::check()")  # ❌

# RIGHT - Delegate verbose operations
Task(subagent_type="verbose-runner",
     prompt="Run devtools::check()")  # ✅

# WRONG - Wrong agent for task
Task(subagent_type="quick-fix",
     prompt="Debug test failures and fix")  # ❌

# RIGHT - Appropriate agent
Task(subagent_type="r-debugger",
     prompt="Debug test failures")  # ✅
```

## Key Principles

1. **Context preservation** - Agents contain verbose output, return summaries
2. **Model efficiency** - Use haiku for simple, opus for complex
3. **Avoid delegation chains** - Don't delegate from delegated agents
4. **Check first, delegate second** - Simple checks don't need agents
5. **Solve blockers, don't skip steps** - If a tool isn't on PATH, use `nix-shell -p <tool>` instead of declaring the step impossible
6. **Parallelize from the start** - Don't wait to be asked; launch independent agents (document+test+check, tar_make, QA) concurrently at Step 4

## Context Forking Pattern

When spawning subagents, use `run_in_background: true` to **fork context** and prevent bloating the orchestrator conversation with verbose output.

### Why Fork Context?

| Approach | Orchestrator Context | Performance |
|----------|---------------------|-------------|
| Inline (default) | Grows with agent output | Can hit context limits |
| Background fork | Only summary returned | Stays lean |

### When to Fork

```python
# FORK - Long running, verbose output
Task(
  subagent_type="verbose-runner",
  prompt="Run full test suite and check",
  run_in_background=True  # Returns summary only
)

# FORK - Multiple parallel tasks
Task(subagent_type="r-debugger", prompt="Fix test A", run_in_background=True)
Task(subagent_type="r-debugger", prompt="Fix test B", run_in_background=True)
# Later: TaskOutput to collect results

# INLINE - Need immediate result for next step
Task(
  subagent_type="Explore",
  prompt="Find the config file location"
  # No background - need result immediately
)
```

### Background Task Workflow

```python
# 1. Launch background tasks
task1 = Task(
  subagent_type="verbose-runner",
  prompt="Run tests",
  run_in_background=True
)
# Returns immediately with task_id

task2 = Task(
  subagent_type="verbose-runner",
  prompt="Run check",
  run_in_background=True
)

# 2. Continue with other work while they run
# ...

# 3. Collect results when needed
result1 = TaskOutput(task_id=task1.id, block=True)
result2 = TaskOutput(task_id=task2.id, block=True)
```

### Context-Heavy Operations (Always Fork)

- `devtools::check()` - 100+ lines output
- `tar_make()` - Progress updates
- Full test suite - Many test results
- Coverage analysis - Per-file reports
- Any operation expecting > 50 lines

### Orchestrator Pattern

For multi-step workflows:

```python
# Orchestrator stays lean by forking heavy work
def pr_pass_loop():
    while True:
        # Fork: Run checks in background
        check_task = Task(
          subagent_type="verbose-runner",
          prompt="Run gh pr checks and report status",
          run_in_background=True
        )
        result = TaskOutput(task_id=check_task.id, block=True)

        if "all passed" in result:
            break

        # Fork: Fix issues in background
        fix_task = Task(
          subagent_type="r-debugger",
          prompt=f"Fix these failures: {result.failures}",
          run_in_background=True
        )
        TaskOutput(task_id=fix_task.id, block=True)
```

## Red Flags (You're Over-Delegating)

- Using agents for `ls`, `cat`, or file existence checks
- Delegating < 5 line tasks to verbose-runner
- Using planner for simple decisions
- Chaining multiple agents for one task
- Using agents to read files or check paths

## Red Flags (You're Under-Forking)

- Orchestrator context growing past 50k tokens
- Full test/check output visible in main conversation
- Hitting context limits mid-workflow
- Slow response times due to context size