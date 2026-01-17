# /cleanup - Review and Simplify Work

Review the current session's work and identify opportunities to simplify, consolidate, or clean up.

## Purpose

Run this command periodically during longer sessions to:
- Identify redundant or over-engineered code
- Consolidate scattered changes
- Remove temporary debugging code
- Simplify complex solutions
- Clean up documentation

## Review Checklist

### 1. Code Changes Review

```bash
# Show all files changed in this session
git diff --name-only HEAD~5
git diff --stat HEAD~5
```

For each changed file, ask:
- Is this change necessary?
- Can it be simplified?
- Is there duplicated logic that can be extracted?
- Are there temporary fixes that should be made permanent (or removed)?

### 2. Documentation Review

Check for:
- Duplicate instructions across files (AGENTS.md, skills, commands)
- Outdated references
- Instructions that could be consolidated
- Verbose sections that could be shortened

### 3. Configuration Review

Check for:
- Unused entries in `_quarto.yml`, `default.nix`, etc.
- Overly complex workflow configurations
- Redundant CI steps

### 4. Cleanup Actions

After review, suggest:
- Files to consolidate or remove
- Code to simplify
- Documentation to merge
- Dead code to delete

## Output Format

```
## Cleanup Review

### Files Changed This Session
[list of files with brief description]

### Simplification Opportunities
1. [specific suggestion]
2. [specific suggestion]

### Redundancies Found
- [duplicate/redundant item]

### Recommended Actions
- [ ] [action 1]
- [ ] [action 2]

### Questions for User
- [any clarifications needed]
```

## When to Use

- After completing a complex debugging session
- Before ending a long session
- When a feature is complete but feels over-engineered
- After multiple iterative fixes to the same issue
