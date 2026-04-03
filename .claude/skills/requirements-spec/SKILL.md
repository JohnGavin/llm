---
name: requirements-spec
description: Use when planning complex tasks involving 5+ files or 3+ modules to create a MUST/SHOULD/MAY requirements specification that catches ambiguity before coding begins. Triggers: requirements, spec, complex task, scope definition, ambiguity.
argument-hint: "[task description]"
---
# Requirements Specification

Create a structured requirements document before planning complex tasks. Reduces mid-plan pivots by clarifying scope upfront.

## When to Use

- Tasks involving 5+ files or 3+ modules
- Ambiguous requests where scope is unclear
- Multi-session work that needs a durable reference
- Before `architecture-planning` for complex features

## Workflow

### Step 1: Clarifying Questions (3-5 max)

Ask the user 3-5 targeted questions to resolve ambiguity:
- What is the primary goal? (one sentence)
- What are the acceptance criteria? (how do we know it's done?)
- What is out of scope? (what should we NOT do?)
- Are there existing patterns to follow? (reference implementations?)
- What is the timeline/priority? (blocking release, nice-to-have?)

### Step 2: Create Specification

Save to `quality_reports/specs/YYYY-MM-DD_description.md`:

```markdown
# Requirements: [Task Name]
**Date:** [YYYY-MM-DD]
**Issue:** #[number] (if applicable)
**Status:** DRAFT | APPROVED | SUPERSEDED

## Goal
[One sentence summary]

## Requirements

### MUST have (non-negotiable)
- [ ] [requirement 1]
- [ ] [requirement 2]

### SHOULD have (preferred)
- [ ] [requirement 1]

### MAY have (optional enhancements)
- [ ] [requirement 1]

### Out of scope
- [explicitly excluded item 1]

## Clarity Status

| Aspect | Status | Notes |
|--------|--------|-------|
| Data format | CLEAR | JSON from API |
| Error handling | ASSUMED | cli::cli_abort() per convention |
| Performance | BLOCKED | Need to know data volume |

## Dependencies
- Packages: [list any new packages needed]
- Files: [key files to create/modify]
- External: [APIs, data sources]

## Acceptance Criteria
1. `devtools::test()` passes with 0 failures
2. `devtools::check()` passes with 0 errors/warnings/notes
3. [domain-specific criteria]
```

### Step 3: Get Approval

Present the spec to the user. Wait for:
- "approved" → proceed to `architecture-planning`
- "revise [section]" → update and re-present
- "blocked on [X]" → note as BLOCKED, ask for resolution

### Step 4: Link to Plan

After approval, reference the spec in the architecture plan:
```markdown
**Spec:** quality_reports/specs/2026-03-18_feature-name.md (APPROVED)
```

## Integration

- Feeds into `architecture-planning` rule (Step 0 of workflow)
- Feeds into `orchestrator-protocol` rule (provides acceptance criteria)
- Referenced by `quality-gates` skill (acceptance criteria = verification)

## When NOT to Use

- Simple bug fixes (1-2 files)
- Documentation-only changes
- Config/rule updates
- Tasks where scope is already crystal clear
