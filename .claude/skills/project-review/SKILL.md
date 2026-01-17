# Project Review and Technical Debt Assessment

## Description

Systematic methodology for reviewing R projects to identify technical debt, simplification opportunities, and areas for cleanup. This skill provides a prioritized approach to maintaining code quality over time.

## Purpose

Use this skill when:
- A major feature is complete and you want to consolidate
- The project feels "messy" or over-engineered
- Before a release or major refactor
- Periodically (every few weeks of active development)
- When `/cleanup` command suggests deeper review is needed

## Why a Skill vs Command

This is a **skill** (not command) because:
- Provides methodology Claude can internalize and apply proactively
- Represents a way of thinking, not just running scripts
- Can be referenced during development, not just on-demand
- Informs decisions across the entire session

## Review Framework

### Level 1: Quick Cleanup (5-10 min)

The `/cleanup` command handles this. Use for:
- End-of-session tidying
- After debugging sessions
- Quick scan for obvious issues

### Level 2: Technical Debt Scan (30 min)

Systematic review of common debt patterns:

#### 1. Code Redundancy
```r
# Find duplicate code patterns
# Look for:
# - Copy-pasted functions
# - Similar logic in multiple places
# - Functions that should be generalized
```

**Prioritization:** High impact if the code is touched frequently

#### 2. Configuration Sprawl
```yaml
# Check for:
# - Unused entries in _quarto.yml, DESCRIPTION, default.nix
# - Redundant CI workflow steps
# - Duplicate environment variables
```

**Prioritization:** High if causing CI slowness or confusion

#### 3. Documentation Drift
```markdown
# Look for:
# - Instructions that no longer match reality
# - Duplicate instructions across files
# - Verbose sections that could be consolidated
# - References to removed features
```

**Prioritization:** High if onboarding is affected

#### 4. Dependency Bloat
```r
# Check for:
# - Packages in DESCRIPTION/default.nix not actually used
# - Heavy dependencies for minor functionality
# - Outdated package versions
```

**Prioritization:** High if affecting build times or security

#### 5. Test Coverage Gaps
```r
# Identify:
# - Critical code paths without tests
# - Tests that don't test real behavior
# - Flaky tests that should be fixed or removed
```

**Prioritization:** High for business-critical code

### Level 3: Architectural Review (1-2 hours)

Deep analysis for major refactors:

#### Project Structure
- Is the folder structure intuitive?
- Are related files grouped together?
- Is there a clear separation of concerns?

#### Workflow Patterns
- Are there workflow anti-patterns (e.g., Nix for web tools)?
- Are CI/CD pipelines efficient?
- Is the development loop fast?

#### Abstractions
- Are there premature abstractions?
- Are there missing abstractions for repeated patterns?
- Is the API surface minimal and intuitive?

## Prioritization Matrix

| Issue Type | Frequency | Severity | Priority |
|------------|-----------|----------|----------|
| Blocking bug | - | High | P0 |
| CI slowness | Daily | Medium | P1 |
| Code duplication (hot path) | Weekly | Medium | P1 |
| Documentation drift | Monthly | Low | P2 |
| Code duplication (cold path) | Rare | Low | P3 |
| Style inconsistency | - | Low | P4 |

## Output Template

```markdown
## Project Review: [Date]

### Summary
- Overall health: [Good/Fair/Needs Attention]
- Files reviewed: [count]
- Issues found: [count by priority]

### P0 - Critical
[None or list]

### P1 - High Priority
1. [Issue] - [File/Location]
   - Impact: [description]
   - Fix: [suggested action]

### P2 - Medium Priority
[list]

### P3 - Low Priority (When Time Permits)
[list]

### Recommended Actions
1. [ ] [Specific actionable task]
2. [ ] [Specific actionable task]

### Technical Debt Trend
- [Better/Same/Worse] than last review
- Key improvements: [list]
- New concerns: [list]
```

## Anti-Patterns to Avoid

### 1. Perfectionism
Don't try to fix everything at once. Prioritize ruthlessly.

### 2. Premature Optimization
Code that "might" be used differently someday doesn't need abstraction today.

### 3. Refactoring Without Tests
Don't refactor critical code without test coverage first.

### 4. Bikeshedding
Don't spend time on style issues when there are functional problems.

## Integration Points

- **/cleanup command**: Quick session cleanup
- **verification-before-completion skill**: Ensure fixes are verified
- **systematic-debugging skill**: For investigating identified issues
- **architecture-planning skill**: For major refactors

## When to Escalate

Create GitHub issues for:
- Anything that can't be fixed in the current session
- Patterns that need team discussion
- Technical debt that requires significant refactoring

## Example Review Output

```markdown
## Project Review: 2026-01-17

### Summary
- Overall health: Fair
- Files reviewed: 47
- Issues found: 2 P1, 5 P2, 8 P3

### P1 - High Priority
1. **Quarto workflow complexity** - `.github/workflows/quarto-publish.yaml`
   - Impact: 6+ iterations to get right, fragile setup
   - Fix: Document the pattern in CI skill (DONE)

2. **LLM section disabled** - `vignettes/telemetry.qmd`
   - Impact: Feature not working
   - Fix: Re-enable now that root cause fixed (DONE)

### P2 - Medium Priority
1. Verbose commit history for single issue
2. Sound hooks in settings.local.json not in gitignore

### Recommended Actions
1. [x] Re-enable LLM section
2. [ ] Consider squashing debug commits
3. [ ] Add settings.local.json to .gitignore
```

## Related Skills

- architecture-planning (for major refactors)
- systematic-debugging (for investigating issues)
- verification-before-completion (for confirming fixes)
- code-review-workflow (for PR review)
