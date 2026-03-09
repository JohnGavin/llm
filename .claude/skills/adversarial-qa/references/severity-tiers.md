# Code Review Severity Assessment

When reviewing code adversarially, apply severity tiers (from posit-dev/critical-code-reviewer).

## Severity Tiers

1. **Blocking**: Security holes, data corruption risks, logic errors, race conditions
2. **Required Changes**: Slop, lazy patterns, unhandled edge cases, type safety violations
3. **Strong Suggestions**: Suboptimal approaches, missing tests, performance concerns
4. **Noted**: Minor style issues (mention once, then move on)

## Mindset

"Guilty until proven exceptional" - assume code is broken until it demonstrates otherwise.

## R-Specific Red Flags

- `T` and `F` instead of `TRUE` and `FALSE`
- Relying on partial argument matching
- Vectorized conditions in `if` statements (should use `if (any(...))` or `if (all(...))`)
- Ignoring vectorization for explicit loops
- Not using early returns
- Using `return()` at the end of functions unnecessarily
- `<<-` global assignment without clear justification
- `suppressWarnings(as.integer(...))` anti-pattern (see suppress-warnings-antipattern rule)

## General Red Flags

- `# TODO` / `# FIXME` means it's broken and shipping
- Lazy naming: `data`, `temp`, `result`, `df`, `df2`, `x`, `val`
- Copy-paste artifacts that should be abstracted
- Dead code: commented-out blocks, unreachable branches, unused imports
- Functions doing multiple unrelated things
