# Gemini CLI Integration Guide

## Overview

Gemini CLI is integrated for large codebase analysis tasks that would exceed Claude's context limits. While we've created an agent definition, the Task tool doesn't dynamically load custom agents, so Gemini must be invoked directly via Bash commands.

## Setup Status

✅ **Completed:**
1. Gemini CLI available at `/opt/homebrew/bin/gemini`
2. Agent definition created at `.claude/agents/gemini.md`
3. Tested basic functionality

⚠️ **Limitations:**
1. **No Docker/Podman**: Sandbox mode (`--sandbox true`) won't work without container runtime
2. **Not available via Task tool**: Must use Bash tool directly
3. **Local only**: Never available on GitHub CI
4. **Manual invocation**: Can't be delegated as a subagent automatically

## How to Use Gemini

### Direct Invocation Pattern

Since the Task tool doesn't recognize custom agents, use Gemini directly:

```bash
# Basic analysis (without sandbox since Docker not available)
/opt/homebrew/bin/gemini "Your analysis prompt" @R/*.R > /tmp/analysis.md

# Analyze entire directory
/opt/homebrew/bin/gemini "Explain the architecture" @R/ @tests/ > /tmp/architecture.md

# Multiple specific files
/opt/homebrew/bin/gemini "Find security issues" @R/ccusage.R @R/tar_llm_usage.R
```

### Common Use Cases

#### 1. Large Codebase Overview
```bash
# When you need to understand an entire package
cd /Users/johngavin/docs_gh/llm
/opt/homebrew/bin/gemini "Provide comprehensive overview of this R package" @R/ @DESCRIPTION @NAMESPACE > /tmp/overview.md
```

#### 2. Pattern Search Across Many Files
```bash
# Find all uses of a specific pattern
/opt/homebrew/bin/gemini "Find all uses of crew package and async patterns" @R/*.R @tests/*.R > /tmp/async_patterns.md
```

#### 3. Test Coverage Analysis
```bash
# Check which functions lack tests
/opt/homebrew/bin/gemini "Which functions in R/ lack tests in tests/?" @R/ @tests/testthat/ > /tmp/coverage_gaps.md
```

#### 4. Second Opinion on Architecture
```bash
# Get independent review
/opt/homebrew/bin/gemini "Review this architecture for potential issues" @plans/PLAN_*.md > /tmp/architecture_review.md
```

## When to Use Gemini vs Claude

| Scenario | Use Gemini | Use Claude |
|----------|------------|------------|
| Analyze 50+ files | ✅ | ❌ |
| Make code changes | ❌ | ✅ |
| Understand unfamiliar codebase | ✅ | ❌ |
| Interactive debugging | ❌ | ✅ |
| Bulk documentation generation | ✅ | ❌ |
| Git operations | ❌ | ✅ |
| Small file edits | ❌ | ✅ |

## Token Savings Example

Analyzing a typical R package with 30 files:
- **With Claude**: ~50,000 tokens (multiple Read operations)
- **With Gemini**: ~1,000 tokens (read summary from /tmp/)
- **Savings**: ~49,000 tokens (~$0.75 at Claude Opus rates)

## Workflow Integration

### Step 1: Delegate Analysis to Gemini
```bash
# Claude runs this via Bash tool
/opt/homebrew/bin/gemini "Analyze entire codebase for patterns" @R/ > /tmp/analysis.md
```

### Step 2: Read Gemini's Output
```bash
# Claude reads the summary
cat /tmp/analysis.md
```

### Step 3: Act on Insights
```
# Claude uses Edit/Write tools to implement changes based on analysis
```

## Error Handling

### If Gemini Not Available
```bash
if [[ ! -f /opt/homebrew/bin/gemini ]]; then
    echo "ERROR: Gemini CLI not installed"
    echo "Install with: brew install gemini"
    exit 1
fi
```

### If Sandbox Needed
```bash
# Check for Docker
if command -v docker &> /dev/null; then
    gemini --sandbox true "prompt" @files
else
    echo "WARNING: Running without sandbox (Docker not installed)"
    gemini "prompt" @files
fi
```

## Best Practices

1. **Always save output**: Use `> /tmp/filename.md` to capture results
2. **Use timestamps**: Add `$(date +%Y%m%d_%H%M%S)` to filenames
3. **Clean up temp files**: Remove old `/tmp/gemini_*.md` files periodically
4. **Document important findings**: Copy useful analyses to project docs
5. **Verify local environment**: Check you're not on CI before using

## Security Considerations

Since sandbox mode requires Docker (not installed):
- Only analyze trusted code
- Don't use `--yolo` flag
- Don't use `--approval-mode auto_edit`
- Keep analysis read-only
- Make changes through Claude's tools

## Future Improvements

To fully integrate Gemini as a Task subagent would require:
1. Claude to update its Task tool to recognize custom agents
2. Or create a wrapper script that Claude can invoke
3. Or install Docker for sandbox support

## Example Complete Analysis Session

```bash
#!/bin/bash
# Save as: analyze_with_gemini.sh

PROJECT_DIR="/Users/johngavin/docs_gh/llm"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="/tmp/gemini_${TIMESTAMP}"

# Create output directory
mkdir -p "$OUTPUT_DIR"

cd "$PROJECT_DIR"

echo "Starting Gemini analysis at $(date)"

# 1. Architecture overview
/opt/homebrew/bin/gemini "Explain the package architecture" @R/ @DESCRIPTION > "$OUTPUT_DIR/architecture.md"

# 2. Function catalog
/opt/homebrew/bin/gemini "List all exported functions with descriptions" @R/ @NAMESPACE > "$OUTPUT_DIR/functions.md"

# 3. Test coverage
/opt/homebrew/bin/gemini "Which functions lack tests?" @R/ @tests/ > "$OUTPUT_DIR/coverage.md"

# 4. Dependencies
/opt/homebrew/bin/gemini "Analyze package dependencies" @DESCRIPTION @R/ > "$OUTPUT_DIR/dependencies.md"

echo "Analysis complete. Results in: $OUTPUT_DIR"
ls -la "$OUTPUT_DIR"
```

## Conclusion

While Gemini can't be invoked as a Task subagent, it's fully functional via direct Bash commands. Use it for large-scale analysis tasks to save significant Claude tokens, then use Claude's tools for actual code modifications.