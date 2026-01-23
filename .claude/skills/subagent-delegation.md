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

## Red Flags (You're Over-Delegating)

- Using agents for `ls`, `cat`, or file existence checks
- Delegating < 5 line tasks to verbose-runner
- Using planner for simple decisions
- Chaining multiple agents for one task
- Using agents to read files or check paths