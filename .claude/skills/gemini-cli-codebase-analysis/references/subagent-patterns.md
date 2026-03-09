# Gemini CLI as Subagent for Token Offloading

## Overview

Gemini CLI can be used as a "subagent" to offload work from Claude, reducing Claude token consumption while still completing tasks effectively. This is particularly useful for:
- Large codebase analysis (Gemini has 1M+ token context)
- Bulk file processing
- Second-opinion analysis
- Parallel workstreams

## When to Use Gemini vs Claude

| Task | Gemini | Claude | Why |
|------|--------|--------|-----|
| Analyze 50+ files at once | ✅ | ❌ | Gemini's 1M context handles bulk |
| Code generation in current project | ❌ | ✅ | Claude has project context |
| Summarize large documents | ✅ | ❌ | Token-efficient for read-heavy tasks |
| Interactive debugging | ❌ | ✅ | Claude maintains session state |
| Get second opinion on architecture | ✅ | ✅ | Use both for consensus |
| Search/grep operations | ❌ | ✅ | Claude's tools are faster |
| Explain unfamiliar codebase | ✅ | ❌ | Feed entire codebase to Gemini |

## Invocation Patterns

### From Claude (via Bash tool)

```bash
# Simple prompt with file context
gemini "Explain the architecture of this package" @R/ @DESCRIPTION

# With sandbox mode (safer for untrusted analysis)
gemini --sandbox true "Analyze this code for security issues" @src/

# Resume previous session
gemini --resume

# Auto-approve edits (use cautiously)
gemini --sandbox true --approval-mode "auto_edit" "Refactor this function" @R/utils.R
```

### Recommended Flags for Subagent Use

```bash
gemini \
  --sandbox true \              # Isolate from system
  --approval-mode "auto_edit" \ # Auto-approve safe edits (optional)
  --allowed-mcp-server-names "mcp.example.com" \  # Limit MCP access
  "Your prompt here" @files
```

## Token Offloading Strategies

### Strategy 1: Bulk Analysis Delegation
**Scenario:** Need to understand a large unfamiliar codebase.
**Claude approach:** Multiple rounds of Grep/Read (consumes tokens).
**Gemini approach:** One call with entire codebase.

```bash
# Claude delegates bulk analysis to Gemini
gemini "List all exported functions and their purposes" @R/*.R > /tmp/function_summary.md

# Claude then reads the summary (much smaller)
cat /tmp/function_summary.md
```

### Strategy 2: Parallel Analysis
**Scenario:** Need multiple independent analyses.
**Approach:** Launch Gemini for one, Claude handles another.

```bash
# Background Gemini task
gemini "Analyze test coverage gaps" @tests/ > /tmp/coverage_analysis.md &

# Claude continues with other work...
# Later, read Gemini's output
```

### Strategy 3: Second Opinion
**Scenario:** Uncertain about architectural decision.
**Approach:** Ask Gemini for independent analysis.

```bash
gemini "Review this proposed architecture. What are the risks?" @plans/PLAN_*.md
```

### Strategy 4: Documentation Generation
**Scenario:** Need comprehensive docs from code.
**Approach:** Gemini reads code, generates docs.

```bash
gemini "Generate API documentation in markdown format" @R/*.R > docs/API.md
```

## Integration with Claude Workflow

### As a Task/Subagent Pattern

Claude can invoke Gemini when:
1. Context would exceed comfortable limits
2. Task is read-heavy (analysis, summarization)
3. Second opinion is valuable
4. Parallel work is possible

### Decision Flowchart

```
Is the task read-heavy (analysis/summary)?
├── YES → Consider Gemini
│   └── Does it need current session context?
│       ├── YES → Keep in Claude
│       └── NO → Delegate to Gemini
└── NO → Keep in Claude
```

## Example: Full Codebase Review

```bash
# Step 1: Gemini analyzes entire codebase
gemini --sandbox true "
Analyze this R package and provide:
1. Architecture overview
2. Key functions and their purposes
3. Potential issues or improvements
4. Test coverage assessment
" @R/ @tests/ @DESCRIPTION @NAMESPACE > /tmp/codebase_review.md

# Step 2: Claude reads and acts on the summary
# (Claude reads /tmp/codebase_review.md - much smaller than raw files)
```

## Limitations

- **No shared state:** Gemini doesn't know Claude's conversation history
- **No Claude tools:** Gemini can't use Claude's Edit/Write/etc tools
- **File scope:** Must explicitly pass files via `@path` syntax
- **Approval modes:** `auto_edit` can make changes - use `--sandbox true` for safety

## Cost Comparison

| Model | Input (1M tokens) | Output (1K tokens) |
|-------|-------------------|-------------------|
| Claude Opus | ~$15 | ~$0.075 |
| Gemini 2.0 | Free tier available | Free tier available |

For bulk read-heavy tasks, Gemini can significantly reduce costs.

## MCP Server Integration

If using MCP servers with both Claude and Gemini:

```bash
# Limit Gemini to specific MCP servers
gemini --allowed-mcp-server-names "mcp.internal.example" "Query the database"
```

## Best Practices

1. **Always use `--sandbox true`** when running Gemini as subagent
2. **Capture output to files** for Claude to read later
3. **Be explicit about file scope** - Gemini needs `@path` for each file/dir
4. **Don't duplicate work** - if Claude already read files, don't re-read in Gemini
5. **Use for bulk, not interactive** - Gemini excels at one-shot analysis
