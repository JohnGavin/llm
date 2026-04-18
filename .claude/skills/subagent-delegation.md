# Subagent Delegation Rules

When and how to use subagents effectively, with automatic model routing.

## Auto-Delegation: Mandatory Triggers

The orchestrator MUST delegate to the specified agent when any trigger matches.
No judgment call needed — if the pattern matches, delegate.

### Haiku tier (`quick-fix`) — MUST delegate instead of doing in opus

| Trigger | Example |
|---------|---------|
| Single-file typo/rename | "fix the typo in R/utils.R" |
| Version bump | "bump to 0.2.1" |
| Add/remove an import or export | "add dplyr to Imports" |
| Swap a string literal | "change 'foo' to 'bar' in line 42" |
| Add a simple comment | "add roxygen for this param" |
| Update a URL or path | "fix the broken link in README" |

**Rule:** If the change touches 1 file, affects < 5 lines, and requires no
reasoning about correctness, use `quick-fix` (haiku).

### Sonnet tier (named agents) — MUST delegate

| Trigger | Agent |
|---------|-------|
| `devtools::test()`, `devtools::check()`, `devtools::document()` | `r-debugger` or Bash with timeout |
| Test/check failure diagnosis | `r-debugger` |
| PR code review | `reviewer` |
| Nix shell won't start, package missing | `nix-env` |
| `tar_make()` failure or pipeline design | `targets-runner` |
| Shinylive/WASM build or browser error | `shinylive-builder` |
| Shiny async/crew/ExtendedTask bug | `shiny-async-debugger` |
| Data validation, pointblank rules | `data-quality-guardian` |
| DuckDB/dbt/SQL pipeline design | `data-engineer` |
| Read-only adversarial review | `critic` |
| Apply fixes from critic report | `fixer` |
| Compile raw/ into wiki/ | `wiki-curator` |

### Opus tier (orchestrator) — keep in main session

| Pattern | Why opus |
|---------|---------|
| Multi-file architectural decisions | Cross-file reasoning |
| Plan creation and approval | User interaction needed |
| Synthesising results from multiple agents | Coordination |
| Ambiguous requirements needing clarification | User dialogue |
| Memory and config file updates | Session-level state |

## Decision Flowchart

```
Is it a direct tool call (Read, ls, grep)?
├─ YES → Do it directly, no agent
└─ NO
   Is it a single-file, < 5 line, no-reasoning edit?
   ├─ YES → quick-fix (haiku)
   └─ NO
      Does it match a named agent trigger above?
      ├─ YES → That agent (sonnet)
      └─ NO
         Is output likely > 20 lines or needs deep analysis?
         ├─ YES → general-purpose (sonnet) or Explore
         └─ NO → Do it directly in opus
```

## Built-in Agents (from Agent tool)

- `general-purpose` — multi-step research, code search
- `Explore` — fast codebase exploration (quick/medium/very thorough)
- `Plan` — architecture and implementation planning
- `claude-code-guide` — Claude Code/SDK documentation

## NEVER Delegate

- `ls`, `cat`, `echo`, `pwd`, file existence checks
- `Read`, `Write`, `Edit` tool calls
- Simple `grep` / `Glob` lookups
- Anything < 3 lines of output

## Key Principles

1. **Context preservation** — agents contain verbose output, return summaries
2. **Parallel when independent** — multiple Agent calls in one message
3. **No delegation chains** — agents don't spawn sub-agents
4. **Check first** — simple checks don't need agents
