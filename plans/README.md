# Planning Documents

This folder contains ephemeral planning documents that LLMs work through over multiple sessions as they implement major features.

## Purpose

- **Track multi-session work**: Plans that span multiple Claude sessions
- **Document implementation strategy**: Before diving into code
- **Link to implementation**: Reference `./R/dev/` scripts as work completes
- **Support cleanup**: Prune completed sections during `/cleanup`

## Lifecycle

```
1. CREATE: New plan when starting major feature
   └── plans/PLAN_feature_name.md

2. WORK: Update as implementation progresses
   └── Mark sections complete, add links to R/dev/ scripts

3. LINK: Replace details with script references
   └── "See R/dev/features/auth_flow.R for implementation"

4. ARCHIVE: Move to archive/ when feature complete
   └── archive/plans/PLAN_feature_name.md
```

## Template

```markdown
# PLAN: [Feature Name]

Created: YYYY-MM-DD
Status: [Planning | In Progress | Complete]
Issue: #[number]

## Overview
[Brief description of what we're building]

## Tasks
- [ ] Task 1
  - Implementation: [pending | R/dev/features/task1.R]
- [ ] Task 2
- [x] Task 3 - See R/dev/features/task3.R

## Decisions
- [Date] Decision made: [rationale]

## Sessions
- [Date] Session 1: [what was accomplished]
- [Date] Session 2: [what was accomplished]

## Notes
[Any additional context]
```

## Cleanup Rules

During `/cleanup` or project review:

1. **Completed sections**: Replace verbose details with script links
2. **Stale plans**: Archive if no updates in 2+ weeks
3. **Duplicate content**: Merge overlapping plans
4. **Orphaned plans**: Link to or create GitHub issues

## Naming Convention

- `PLAN_[feature_name].md` - Active feature plans
- `PLAN_[YYYYMMDD]_[topic].md` - Date-prefixed for time-sensitive work
