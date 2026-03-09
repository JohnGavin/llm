# Gemini CLI for Large Codebase Analysis

## Description

This skill covers using the Gemini CLI tool to analyze large codebases or multiple files that might exceed Claude's context limits. Gemini's massive context window makes it ideal for whole-codebase searches and architectural understanding.

## Purpose

Use this skill when:
- Analyzing entire codebases or large directories
- Comparing multiple large files that exceed Claude's context
- Need to understand project-wide patterns or architecture
- Working with files totaling more than 100KB
- Verifying if specific features, patterns, or security measures are implemented
- Checking for coding patterns across the entire codebase
- Claude's context window is insufficient for the task

## Key Principles

### When to Use Gemini vs Claude

**Use Gemini CLI when:**
- Need to analyze an entire R package codebase at once
- Searching for patterns across many files
- Verifying implementation of features across codebase
- Checking architecture consistency
- Large-scale refactoring planning

**Use Claude when:**
- Making focused code changes
- Working within specific files or modules
- Interactive development and testing
- Need tool use (file editing, git operations, etc.)

### Read-Only Analysis

- Gemini CLI is for **analysis and understanding only**
- Use Claude Code for actual code modifications
- No need for `--yolo` flag for read-only operations
- Results inform decisions made in Claude

### Integration with R Development

**Common use cases for R packages:**
- Analyzing package structure and dependencies
- Finding all uses of a specific function across codebase
- Checking implementation patterns (e.g., error handling, logging)
- Understanding how modules interact
- Verifying test coverage patterns

## How It Works

### Basic Gemini CLI Syntax

Use `@` syntax to include files/directories. Paths are relative to where you run the command.

```bash
gemini -p "@src/main.py Explain this file's purpose"    # Single file
gemini -p "@src/ Summarize the architecture"             # Directory
gemini -p "@src/ @tests/ Analyze test coverage"          # Multiple dirs
gemini --all_files -p "Analyze the project structure"    # All files
```

### R Package Analysis

```bash
cd /path/to/package

# Package structure
gemini -p "@R/ @DESCRIPTION @NAMESPACE Explain the package architecture"

# Pattern search
gemini -p "@R/ @tests/ How is error handling implemented? Show examples"

# Feature verification
gemini -p "@R/ @inst/ Has telemetry tracking been implemented?"
```

See [gemini-workflows.md](references/gemini-workflows.md) for comprehensive R package analysis examples including architecture, code quality, dependency, and test coverage queries.

### Using ellmer from R

Call Gemini programmatically via the ellmer R package for reproducible analysis:

```r
library(ellmer)
chat <- chat_google_gemini(model = "gemini-pro",
  system_prompt = "You are analyzing an R package codebase.")
result <- chat$chat("Analyze the R package: architecture, functions, dependencies, tests")
writeLines(result$content, "inst/logs/gemini_package_analysis.txt")
```

See [gemini-workflows.md](references/gemini-workflows.md) for full ellmer and btw integration examples.

## Common Patterns

| Pattern | Use Case | Key Approach |
|---------|----------|--------------|
| Pre-Development | Understand codebase before coding | `@./ Provide high-level summary` then drill into specific areas |
| Feature Verification | Check if something exists | `@R/ @inst/ Is feature X already implemented?` |
| Refactoring Planning | Assess change impact | `@R/ @tests/ Where is function_to_change() used?` |
| btw Integration | Combine Gemini understanding with tidyverse generation | Use ellmer for analysis, btw for code generation |

See [gemini-workflows.md](references/gemini-workflows.md) for detailed pattern examples with full commands.

## Development Workflow Integration

1. **Pre-Development** -- Understand existing code before creating issues
2. **Planning** -- Ask how to structure new features given current architecture
3. **Refactoring** -- Check all usages before changing signatures
4. **Documentation** -- Generate architecture docs, refine in Claude

See [gemini-workflows.md](references/gemini-workflows.md) for step-by-step workflow commands.

## Best Practices

1. **Be specific in prompts** -- Ask targeted questions with file paths, not vague queries
2. **Focus on relevant files** -- Target `@R/plotting.R @R/utils.R` not `@./`
3. **Save analysis results** -- Redirect output: `gemini -p "..." > docs/analysis.md`
4. **Gemini understands, Claude acts** -- Use Gemini for read-only analysis, Claude for modifications
5. **Log for reproducibility** -- Use logger to record queries and results

See [gemini-workflows.md](references/gemini-workflows.md) for best practice examples and troubleshooting.

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Files not found | Check `pwd`; use correct relative paths or absolute paths |
| Response too general | Be very specific; ask for file paths and line numbers |
| Missing context | Include related files: source + utils + tests together |

See [gemini-workflows.md](references/gemini-workflows.md) for detailed troubleshooting with examples.

## File Structure

```
project/
├── inst/logs/           # Gemini analysis logs and results
├── R/setup/             # Gemini analysis R scripts
└── docs/                # Saved architecture analysis
```

## Security Note

**Gemini CLI is read-only for analysis:**
- Safe for exploring codebases
- No `--yolo` flag needed for read operations
- Results inform changes made through Claude Code

**Do NOT use Gemini to:**
- Make actual code changes (use Claude Code)
- Execute code or commands
- Modify files (read-only analysis only)

## Resources

- **Gemini CLI GitHub**: https://github.com/jamubc/gemini-mcp-tool
- **ellmer R package**: https://ellmer.tidyverse.org/reference/chat_google_gemini.html
- **btw R package**: https://cran.r-project.org/web/packages/btw/index.html
- **R package best practices**: https://nrennie.rbind.io/r-pharma-2025-r-packages
- **Reddit discussion**: https://www.reddit.com/r/ChatGPTCoding/comments/1lm3fxq/gemini_cli_is_awesome_but_only_when_you_make/

## Related Skills

- r-package-workflow (use Gemini for understanding, workflow for changes)
- nix-rix-r-environment (analyze nix configurations)
- targets-vignettes (understand pipeline structure)
- project-telemetry (analyze logging patterns)
