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
- Checking for the presence of certain coding patterns across the entire codebase
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

### 1. Basic Gemini CLI Syntax

**Include files and directories with `@` syntax:**

```bash
# Single file
gemini -p "@src/main.py Explain this file's purpose and structure"

# Multiple files
gemini -p "@package.json @src/index.js Analyze the dependencies used"

# Entire directory
gemini -p "@src/ Summarize the architecture of this codebase"

# Multiple directories
gemini -p "@src/ @tests/ Analyze test coverage for the source code"

# Current directory and all subdirectories
gemini -p "@./ Give me an overview of this entire project"

# Or use --all_files flag
gemini --all_files -p "Analyze the project structure and dependencies"
```

**Important:** Paths in `@` syntax are relative to WHERE you run the gemini command.

### 2. R Package Codebase Analysis

**Analyze entire R package:**

```bash
cd /Users/johngavin/docs_gh/claude_rix/random_walk

# Analyze package structure
gemini -p "@R/ @DESCRIPTION @NAMESPACE Explain the package architecture and exported functions"

# Check function usage patterns
gemini -p "@R/ @tests/ How is error handling implemented across this package? Show examples"

# Analyze dependencies
gemini -p "@DESCRIPTION @R/ List all package dependencies and how they're used in the code"
```

**Find specific patterns:**

```bash
# Check logging usage
gemini -p "@R/ Are logger functions used consistently? Show all logging calls"

# Verify targets integration
gemini -p "@R/ @_targets.R How are targets used in this package? List all target definitions"

# Check test coverage patterns
gemini -p "@tests/ @R/ Which R functions lack corresponding tests?"
```

**Verify implementations:**

```bash
# Check if feature is implemented
gemini -p "@R/ @inst/ Has telemetry tracking been implemented? Show relevant files and functions"

# Verify shinylive integration
gemini -p "@vignettes/ @inst/qmd/ Are there any Shinylive dashboards? Show the dashboard code"

# Check async patterns
gemini -p "@R/ Is the crew package used for async workers? Show the implementation"
```

### 3. Integration with ellmer R Package

**Use ellmer to call Gemini from R for reproducibility:**

```r
# R/setup/gemini_analysis.R
library(ellmer)
library(logger)

log_appender(appender_file("inst/logs/gemini_analysis.log"))
log_info("=== Gemini codebase analysis ===")

# Setup Gemini chat
chat <- chat_google_gemini(
  model = "gemini-pro",
  system_prompt = "You are analyzing an R package codebase."
)

# Analyze package structure
result <- chat$chat("
  Analyze the R package at /Users/johngavin/docs_gh/claude_rix/random_walk
  Focus on:
  - Package architecture
  - Key functions and their purposes
  - Dependencies and how they're used
  - Test coverage
  - Documentation quality
")

log_info("Analysis complete")
cat(result$content)

# Save analysis for reference
writeLines(result$content, "inst/logs/gemini_package_analysis.txt")
```

### 4. Common R Package Analysis Tasks

**Architecture understanding:**

```bash
# Overall package structure
gemini -p "@R/ @DESCRIPTION @NAMESPACE @README.md Explain the architecture and purpose of this R package"

# Module interactions
gemini -p "@R/ How do the different R modules interact? Create a dependency graph description"

# Data flow
gemini -p "@R/ @_targets.R Trace the data flow from raw inputs to final outputs"
```

**Code quality checks:**

```bash
# Error handling
gemini -p "@R/ @tests/ Is proper error handling implemented throughout? Show examples of good and bad patterns"

# Documentation coverage
gemini -p "@R/ @man/ Which exported functions lack proper roxygen documentation?"

# Coding standards
gemini -p "@R/ Is the code following tidyverse style guide? Show any violations"
```

**Dependency analysis:**

```bash
# Direct dependencies
gemini -p "@DESCRIPTION @NAMESPACE What packages does this depend on and why?"

# Unused imports
gemini -p "@R/ @NAMESPACE Are there any library() calls for packages not in DESCRIPTION?"

# Heavy dependencies
gemini -p "@DESCRIPTION @R/ Which dependencies are 'heavy' packages that could be replaced with lighter alternatives?"
```

**Test coverage verification:**

```bash
# Overall coverage
gemini -p "@R/ @tests/testthat/ Which functions in R/ lack corresponding tests in tests/testthat/?"

# Test quality
gemini -p "@tests/testthat/ Are the tests comprehensive? Show examples of good and poor test coverage"

# Edge cases
gemini -p "@R/ @tests/ Are edge cases and error conditions properly tested?"
```

## Common Patterns

### Pattern 1: Pre-Development Analysis

**Before starting work, understand the codebase:**

```bash
# Step 1: Get overview
gemini -p "@./ Provide a high-level summary of this R package: purpose, key features, architecture"

# Step 2: Understand specific area
gemini -p "@R/simulation.R @tests/testthat/test-simulation.R Explain how the simulation module works and how it's tested"

# Step 3: Check dependencies
gemini -p "@R/ What R packages are used and for what purpose in each file?"

# Then use Claude Code for actual modifications
```

### Pattern 2: Feature Verification

**Check if something is already implemented:**

```bash
# Check for existing feature
gemini -p "@R/ @inst/ Is there already a function for calculating summary statistics? If so, where?"

# Verify implementation approach
gemini -p "@R/ How is parallel processing currently implemented? Show all relevant code"

# Find similar patterns
gemini -p "@R/ Are there any other functions similar to calculate_metrics()? Show them"
```

### Pattern 3: Refactoring Planning

**Analyze before refactoring:**

```bash
# Find all usages
gemini -p "@R/ @tests/ @vignettes/ Where is the function old_function() used throughout the codebase?"

# Identify dependencies
gemini -p "@R/ What functions depend on module_x? List all call sites"

# Check impact
gemini -p "@R/ @tests/ If I change the signature of process_data(), what other code would need updating?"
```

### Pattern 4: Integration with btw R Package

**Combine with btw for tidyverse code generation:**

```r
# R/setup/analysis_workflow.R
library(ellmer)
library(btw)
library(logger)

# 1. Use Gemini to understand codebase
chat_gemini <- chat_google_gemini()

analysis <- chat_gemini$chat("
  Analyze @R/data_processing.R
  What does this function do and what are its inputs/outputs?
")

log_info("Gemini analysis: {analysis$content}")

# 2. Use btw to generate improved tidyverse code
# Based on Gemini's understanding, generate better implementation
chat_btw <- chat()  # btw chat session

new_code <- chat_btw$chat("
  Rewrite the data processing function as tidyverse code
  that does the following: {analysis$content}
")

log_info("Generated code: {new_code$content}")
```

## File Structure

```
project/
├── inst/
│   └── logs/
│       ├── gemini_analysis.log
│       └── gemini_package_analysis.txt
├── R/
│   └── setup/
│       └── gemini_analysis.R
└── docs/
    └── architecture_analysis.md  # Save Gemini insights
```

## Best Practices

### 1. Be Specific in Prompts

```bash
# Good: Specific question
gemini -p "@R/ @tests/ Which exported functions in R/ lack unit tests in tests/testthat/? List them with file paths"

# Bad: Vague question
gemini -p "@./ Tell me about tests"
```

### 2. Focus Analysis on Relevant Files

```bash
# Good: Target specific areas
gemini -p "@R/plotting.R @R/utils.R How do plotting functions use utility functions?"

# Bad: Include everything unnecessarily
gemini -p "@./ Tell me everything about plotting"
```

### 3. Save Analysis Results

```bash
# Save for documentation
gemini -p "@R/ Explain the package architecture" > docs/architecture_from_gemini.md

# Or in R:
# writeLines(analysis$content, "inst/logs/gemini_analysis_2024-11-16.txt")
```

### 4. Use for Understanding, Claude for Action

```bash
# 1. Gemini: Understand
gemini -p "@R/ Where is error handling implemented?"

# 2. Claude: Modify based on understanding
# Use Claude Code to actually add/modify error handling
```

### 5. Log Analyses for Reproducibility

```r
# R/setup/gemini_analysis.R
library(logger)

log_appender(appender_file("inst/logs/gemini_queries.log"))

log_info("=== Gemini Analysis Session {Sys.Date()} ===")
log_info("Query: Analyze package architecture")
log_info("Files included: R/, DESCRIPTION, NAMESPACE")

# Run analysis...
# Save results...

log_info("Analysis saved to: inst/logs/gemini_package_analysis.txt")
```

## Integration with Development Workflow

### Step 1: Pre-Development Analysis

```bash
# Before creating GitHub issue, understand existing code
cd /Users/johngavin/docs_gh/claude_rix/random_walk

gemini -p "@R/ @tests/ Is feature X already implemented? If so, where?"
# Result informs whether to create issue or use existing code
```

### Step 2: Planning Implementation

```bash
# Understand how to integrate new feature
gemini -p "@R/ How should I structure a new module for feature Y given the current architecture?"
# Use insights to plan implementation in Claude
```

### Step 3: Refactoring Verification

```bash
# Before refactoring, check impact
gemini -p "@R/ @tests/ @vignettes/ Show all uses of function_to_change()"
# Use results to plan safe refactoring in Claude
```

### Step 4: Documentation

```bash
# Generate architecture documentation
gemini -p "@R/ Create a detailed explanation of the package architecture suitable for CONTRIBUTING.md"
# Edit and refine in Claude
```

## Troubleshooting

### Gemini Not Seeing Files

**Problem:** Gemini says files don't exist

**Solution:**
```bash
# Check your current directory
pwd

# Use correct relative paths
cd /Users/johngavin/docs_gh/claude_rix/random_walk
gemini -p "@R/ Analyze these files"

# Or use absolute paths
gemini -p "@/Users/johngavin/docs_gh/claude_rix/random_walk/R/ Analyze"
```

### Response Too General

**Problem:** Gemini gives high-level response instead of specific analysis

**Solution:**
```bash
# Be very specific
gemini -p "@R/simulation.R Line 45-60: Explain this specific code block. Show the exact variable names and function calls"

# Ask for examples
gemini -p "@R/ Show 3 examples of error handling in this codebase with file paths and line numbers"
```

### Missing Context

**Problem:** Analysis lacks context from related files

**Solution:**
```bash
# Include more context
gemini -p "@R/module.R @R/utils.R @tests/testthat/test-module.R Explain how module.R works, including its dependencies"

# Not just:
gemini -p "@R/module.R Explain this"
```

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

## Example Complete Workflow

```bash
# === R Package Analysis Workflow ===

# Step 1: High-level understanding
cd /Users/johngavin/docs_gh/claude_rix/random_walk

gemini -p "@README.md @DESCRIPTION @R/ Provide a comprehensive overview of this R package" > docs/package_overview.md

# Step 2: Architecture analysis
gemini -p "@R/ @_targets.R @vignettes/ Explain the architecture: how do R functions, targets pipeline, and vignettes interact?" > docs/architecture.md

# Step 3: Check specific feature
gemini -p "@R/ @inst/ Is async processing with crew package implemented? Show all related code"

# Step 4: Verify test coverage
gemini -p "@R/ @tests/testthat/ Create a table showing each R file and whether it has corresponding tests"

# Step 5: Document in R for reproducibility
Rscript -e '
library(ellmer)
chat <- chat_google_gemini()
result <- chat$chat("Analyze @R/ for code quality issues")
writeLines(result$content, "inst/logs/gemini_quality_check.txt")
'

# Step 6: Use insights in Claude Code
# Now use Claude Code to make actual improvements based on Gemini insights
```

## Security Note

**Gemini CLI is read-only for analysis:**
- Safe for exploring codebases
- No `--yolo` flag needed for read operations
- Results inform changes made through Claude Code
- Perfect for understanding before modifying

**Do NOT use Gemini to:**
- Make actual code changes (use Claude Code)
- Execute code or commands
- Modify files (read-only analysis only)
