# /focus - Refresh Context and Reset Focus

Clear mental clutter and reload current state. Use when:
- Context feels cluttered after long work
- Returning after a break
- Starting new task mid-session
- Before important decisions

## Steps

1. Summarize current plans
2. Check open PRs and their CI status
3. Check git status and recent commits
4. Read CURRENT_WORK.md
5. Provide focused summary of what to work on next

## Implementation

### 1. Read Active Plans

```bash
# List current plans
ls -la plans/PLAN_*.md 2>/dev/null || echo "No plans found"
```

For each plan file found, read and extract:
- Plan title
- Current status (which steps completed)
- Next action

### 2. Check Open PRs

```bash
# My open PRs with CI status
gh pr list --author @me --json number,title,headRefName,statusCheckRollup --jq '.[] | "PR #\(.number): \(.title) [\(.headRefName)] - CI: \(.statusCheckRollup | if . then (.[0].conclusion // "pending") else "none" end)"'
```

### 3. Git Status Summary

```bash
# Current state
git status --short
git log --oneline -3
echo "Branch: $(git branch --show-current)"
```

### 4. Current Work File

```bash
cat .claude/CURRENT_WORK.md 2>/dev/null || echo "No CURRENT_WORK.md"
```

### 5. GitHub Issues (if no active PR)

```bash
gh issue list --assignee @me --limit 5
```

## Output Format

```
## Focus Summary

### Active Plans
- PLAN_001_feature.md: Step 3 of 5 (implementing X)
- PLAN_002_bugfix.md: Completed

### Open PRs
- PR #123: Add feature X [branch-name] - CI: success
- PR #124: Fix bug Y [fix-bug] - CI: failure (needs attention)

### Git State
- Branch: feature/add-x
- Status: 2 modified, 1 staged
- Last commit: abc1234 "feat: Add X component"

### Current Work
[Contents of CURRENT_WORK.md]

---

## Recommended Focus

**Priority 1**: [Most important next action based on above]
**Priority 2**: [Secondary task]

Ready to proceed with Priority 1?
```

## When to Use

- **Start of resumed session** - after `/session-start`
- **After completing a task** - to reorient
- **When feeling lost** - context overload
- **Before switching tasks** - ensure clean handoff
