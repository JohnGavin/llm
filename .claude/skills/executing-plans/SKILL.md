# Executing Implementation Plans

## Description

Load a plan, execute tasks in batches with checkpoints, and report progress. This skill ensures systematic execution with verification at each step.

## Purpose

Use this skill when:
- You have a written implementation plan (from `writing-plans`)
- Implementing a multi-task feature
- Want structured progress with checkpoints
- Need to pause/resume work across sessions

## The Execution Process

```
┌─────────────────────────────────────────────────────────────┐
│  1. LOAD: Read plan file, create TodoWrite                 │
│  2. REVIEW: Check for questions/concerns                   │
│  3. BATCH: Execute 3 tasks                                 │
│  4. VERIFY: Run verification for each task                 │
│  5. REPORT: Show progress, ask "Ready to continue?"        │
│  6. REPEAT: Next batch until complete                      │
│  7. FINISH: Run full devtools::check(), prepare PR         │
└─────────────────────────────────────────────────────────────┘
```

## Step-by-Step Execution

### Step 1: Load and Review Plan

```r
# Read the plan
plan_file <- "docs/plans/2024-01-15-add-validation.md"

# Create TodoWrite from plan tasks
# Extract all "### Task N:" headings
```

**Before starting, verify:**
- [ ] In correct nix-shell (`echo $IN_NIX_SHELL`)
- [ ] On correct branch (`gert::git_branch()`)
- [ ] Clean working directory (`gert::git_status()`)
- [ ] Plan dependencies met (check DESCRIPTION)

### Step 2: Execute Batch (Default: 3 Tasks)

For each task in batch:

```r
# 1. Mark task as in_progress in TodoWrite
# 2. Follow task instructions exactly
# 3. Run verification command from plan
# 4. Apply verification-before-completion skill
# 5. Mark task as completed
# 6. Commit if plan specifies
```

### Step 3: Report After Each Batch

```markdown
## Batch 1 Complete (Tasks 1-3)

### Task 1: Create test file ✅
- Created: tests/testthat/test-validate_input.R
- Verification: file.exists() = TRUE

### Task 2: Write failing test ✅
- Modified: test-validate_input.R
- Verification: devtools::test_active_file()
  - Output: "Error: could not find function" (expected RED)

### Task 3: Create function skeleton ✅
- Created: R/validate_input.R
- Verification: devtools::load_all() succeeded

**Commits made:** 2
**Ready for feedback.** Continue with Tasks 4-6?
```

### Step 4: Handle Feedback

Based on user response:
- **"Continue"** → Execute next batch
- **"Stop"** → Commit WIP, update CURRENT_WORK.md
- **"Change X"** → Apply change, re-verify, continue
- **"Skip task N"** → Mark skipped, document reason

### Step 5: Complete Execution

After all tasks:

```r
# Final verification (verification-before-completion skill)
devtools::document()
devtools::test()
devtools::check()

# If all pass, proceed to Step 5-8 of 9-step workflow
```

## When to Stop and Ask

**STOP executing immediately when:**

| Situation | Action |
|-----------|--------|
| Task unclear | Ask for clarification |
| Verification fails | Report failure, ask how to proceed |
| Missing dependency | Report, ask to update plan |
| Test won't pass | Use systematic-debugging skill |
| Plan seems wrong | Stop, discuss before continuing |

**Never:**
- Guess at unclear instructions
- Skip verification steps
- Continue after failures
- Modify plan without approval

## Batch Size Guidance

| Situation | Batch Size |
|-----------|------------|
| New feature, first time | 2-3 tasks |
| Familiar pattern | 4-5 tasks |
| Simple repetitive tasks | 5-7 tasks |
| Complex/risky changes | 1-2 tasks |

## TodoWrite Integration

```r
# At plan load
TodoWrite([
  {content: "Task 1: Create test file", status: "pending"},
  {content: "Task 2: Write failing test", status: "pending"},
  {content: "Task 3: Create function file", status: "pending"},
  # ...
])

# During execution
TodoWrite([
  {content: "Task 1: Create test file", status: "completed"},
  {content: "Task 2: Write failing test", status: "in_progress"},
  # ...
])
```

## Session Continuity

If stopping mid-plan:

```r
# 1. Commit current work
gert::git_add(".")
gert::git_commit("WIP: Tasks 1-3 complete, pausing")

# 2. Update CURRENT_WORK.md
writeLines(c(
  "# Current Work",
  "",
  "## Plan: docs/plans/2024-01-15-add-validation.md",
  "## Progress: Tasks 1-3 complete",
  "## Next: Task 4 - Implement edge case handling",
  "## Branch: fix-issue-42-input-validation"
), ".claude/CURRENT_WORK.md")

# 3. Push to remote
gert::git_push()
```

When resuming:
```
"Read .claude/CURRENT_WORK.md and continue executing the plan from Task 4"
```

## Verification Requirements

**Every task must have verification.** If plan lacks it:

| Task Type | Default Verification |
|-----------|---------------------|
| Create file | `file.exists("path")` |
| Write test | `devtools::test_active_file()` + check output |
| Write code | `devtools::load_all()` succeeds |
| Fix bug | Specific test passes |
| Document | `devtools::document()` succeeds |
| Full check | `devtools::check()` - 0/0/0 |

## Integration with 9-Step Workflow

Executing plans maps to Steps 3-4:

```
Step 3: Make changes locally
        └─→ [executing-plans skill] ← YOU ARE HERE
            └─→ Execute batch
            └─→ Verify (verification-before-completion)
            └─→ Commit (part of task)
            └─→ Repeat

Step 4: Run all checks
        └─→ Final devtools::check() after all tasks
```

## Example Execution Session

```markdown
## Executing: Add Input Validation

**Plan:** docs/plans/2024-01-15-add-validation.md
**Branch:** fix-issue-42-input-validation
**Total Tasks:** 7

---

### Batch 1 (Tasks 1-3)

**Task 1: Add rlang dependency** ✅
```r
usethis::use_package("rlang")
```
Verification: rlang appears in DESCRIPTION Imports ✅

**Task 2: Create test file** ✅
```r
usethis::use_test("validate_input")
```
Verification: file exists ✅

**Task 3: Write failing test** ✅
```r
# Added test code to test-validate_input.R
devtools::test_active_file()
```
Verification: "Error: could not find function" (expected RED) ✅

**Commits:**
- "Add rlang to Imports"
- "Add test file for validate_input"

Ready for feedback. Continue with Tasks 4-6?
```

## Tidyverse Alignment

From [workflow vs script](https://tidyverse.org/blog/2017/12/workflow-vs-script/):
- Each task starts with `devtools::load_all()` (fresh state)
- Progress tracked in files, not memory

From [tidyverse design](https://design.tidyverse.org/):
- **Composable**: Tasks build on each other
- **Consistent**: Same execution pattern for all tasks
