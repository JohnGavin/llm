# Hooks Automation Guide

## Description

Claude Code hooks allow automatic execution of shell commands before or after specific tool calls. Use hooks for automated linting, type checking, testing, and validation workflows.

## Purpose

Use this skill when:
- Setting up automated quality checks on file changes
- Configuring pre-commit style validation
- Implementing automatic testing after code edits
- Creating custom validation pipelines

## Hook Configuration

### Location

Hooks are configured in `.claude/settings.json` or `.claude/settings.local.json`:

```json
{
  "hooks": {
    "preToolExecution": [
      {
        "matcher": "Edit|Write",
        "command": "echo 'About to modify: $TOOL_INPUT'"
      }
    ],
    "postToolExecution": [
      {
        "matcher": "Edit|Write",
        "command": "./scripts/lint-changed.sh $TOOL_INPUT"
      }
    ]
  }
}
```

### Hook Types

| Hook | Timing | Use Case |
|------|--------|----------|
| `preToolExecution` | Before tool runs | Validation, backups, logging |
| `postToolExecution` | After tool completes | Linting, testing, formatting |

### Matcher Patterns

Matchers use regex to match tool names:

```json
{
  "matcher": "Edit|Write",      // Match Edit OR Write tools
  "matcher": "Edit",            // Match only Edit tool
  "matcher": "Bash",            // Match Bash executions
  "matcher": ".*"               // Match all tools (use sparingly)
}
```

## R Package Development Hooks

### Auto-Format on Edit

```json
{
  "hooks": {
    "postToolExecution": [
      {
        "matcher": "Edit|Write",
        "command": "Rscript -e \"if (grepl('\\\\.R$', '$FILE_PATH')) air::air_format('$FILE_PATH')\""
      }
    ]
  }
}
```

### Auto-Document on R/ Changes

```json
{
  "hooks": {
    "postToolExecution": [
      {
        "matcher": "Edit|Write",
        "command": "if [[ '$FILE_PATH' == R/*.R ]]; then Rscript -e 'devtools::document()'; fi"
      }
    ]
  }
}
```

### Run Tests After Code Changes

```json
{
  "hooks": {
    "postToolExecution": [
      {
        "matcher": "Edit|Write",
        "command": "if [[ '$FILE_PATH' == R/*.R ]]; then Rscript -e 'devtools::test()'; fi"
      }
    ]
  }
}
```

### Lint Check Before Commit

```json
{
  "hooks": {
    "preToolExecution": [
      {
        "matcher": "Bash",
        "command": "if [[ '$TOOL_INPUT' == *'git commit'* ]]; then Rscript -e 'lintr::lint_package()'; fi"
      }
    ]
  }
}
```

## Environment Variables in Hooks

| Variable | Description |
|----------|-------------|
| `$TOOL_INPUT` | JSON-encoded tool parameters |
| `$FILE_PATH` | File path (for Edit/Write/Read tools) |
| `$TOOL_NAME` | Name of the tool being executed |
| `$EXIT_CODE` | Exit code of tool (postToolExecution only) |

## Best Practices

### 1. Keep Hooks Fast

```json
// ✅ GOOD: Quick validation
{
  "matcher": "Edit",
  "command": "head -1 $FILE_PATH | grep -q '^#'"  // Check for header
}

// ❌ BAD: Slow operations
{
  "matcher": "Edit",
  "command": "Rscript -e 'devtools::check()'"  // Too slow for every edit
}
```

### 2. Use Conditional Execution

```bash
# Only run for R files
if [[ "$FILE_PATH" == *.R ]]; then
  Rscript -e "air::air_format('$FILE_PATH')"
fi
```

### 3. Handle Failures Gracefully

```json
{
  "matcher": "Edit",
  "command": "./scripts/validate.sh || echo 'Validation warning (non-blocking)'"
}
```

### 4. Log Hook Activity

```json
{
  "matcher": ".*",
  "command": "echo \"$(date): $TOOL_NAME on $FILE_PATH\" >> .claude/hook.log"
}
```

## Common Hook Patterns

### Backup Before Edit

```json
{
  "hooks": {
    "preToolExecution": [
      {
        "matcher": "Edit|Write",
        "command": "cp '$FILE_PATH' '$FILE_PATH.bak' 2>/dev/null || true"
      }
    ]
  }
}
```

### Notify on Completion

```json
{
  "hooks": {
    "postToolExecution": [
      {
        "matcher": "Bash",
        "command": "if [[ $EXIT_CODE -eq 0 ]]; then echo '✅ Success'; else echo '❌ Failed'; fi"
      }
    ]
  }
}
```

### Git Stage After Format

```json
{
  "hooks": {
    "postToolExecution": [
      {
        "matcher": "Edit",
        "command": "git add '$FILE_PATH' 2>/dev/null || true"
      }
    ]
  }
}
```

## Debugging Hooks

### Test Hook Command Manually

```bash
# Test the exact command
FILE_PATH="R/simulate.R" ./scripts/my-hook.sh
```

### Enable Verbose Logging

```json
{
  "hooks": {
    "postToolExecution": [
      {
        "matcher": ".*",
        "command": "echo \"Hook: $TOOL_NAME $FILE_PATH\" >&2"
      }
    ]
  }
}
```

### Check Hook Configuration

```bash
cat .claude/settings.json | jq '.hooks'
```

## Integration with Workflow

Hooks complement the 9-step workflow:
- **Step 3 (Make changes)**: Auto-format, auto-document
- **Step 4 (Run checks)**: Triggered automatically by hooks
- **Step 6 (Push)**: Pre-push validation

For complete workflow, see: `.claude/skills/r-package-workflow/SKILL.md`

## Log Management for Hooks

Since hooks run frequently (on every file edit/write), they can generate substantial logs. Implement log rotation to prevent unbounded growth:

### Hook Log Rotation Script

Create a wrapper script for hooks that includes rotation:

```bash
#!/bin/bash
# scripts/hook-wrapper.sh

LOG_FILE="inst/logs/hooks.log"
ERROR_LOG="inst/logs/hooks_error.log"

# Log rotation function
rotate_logs() {
    local log_file=$1
    local max_size=5242880  # 5MB
    local keep_count=3

    if [ -f "$log_file" ] && [ $(stat -f%z "$log_file" 2>/dev/null || echo 0) -gt $max_size ]; then
        for i in $(seq 2 -1 1); do
            [ -f "${log_file}.${i}" ] && mv "${log_file}.${i}" "${log_file}.$((i+1))"
        done
        mv "$log_file" "${log_file}.1"
        touch "$log_file"
    fi
}

# Rotate logs before execution
rotate_logs "$LOG_FILE"
rotate_logs "$ERROR_LOG"

# Execute actual hook command
echo "$(date '+%Y-%m-%d %H:%M:%S'): Running hook: $@" >> "$LOG_FILE"
"$@" >> "$LOG_FILE" 2>> "$ERROR_LOG"
```

### Configure Hooks to Use Wrapper

```json
{
  "hooks": {
    "postToolExecution": [
      {
        "matcher": "Edit|Write",
        "command": "./scripts/hook-wrapper.sh styler::style_file('$FILE_PATH')"
      }
    ]
  }
}
```

This ensures:
- Logs stay under 5MB each
- Only 3 old versions are kept
- Disk space is preserved
- Hook execution history is maintained

## Limitations

- Hooks run synchronously (block Claude until complete)
- Complex logic should be in external scripts
- Hooks cannot modify Claude's behavior, only execute side effects
- Failing hooks may interrupt Claude's workflow (design for graceful degradation)
