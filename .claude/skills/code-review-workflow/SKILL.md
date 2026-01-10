# Code Review Workflow for R Packages

## Description

Request and receive code reviews using R packages (gh, gert) within the PR workflow. Emphasizes technical evaluation over performative agreement.

## Purpose

Use this skill when:
- Completing a PR (Step 6-7 of 9-step workflow)
- After major implementation milestones
- Before merging to main
- When receiving feedback on PRs

## Part 1: Requesting Code Review

### When to Request

| Situation | Action |
|-----------|--------|
| PR ready for review | Create PR with `usethis::pr_push()` |
| After major task batch | Self-review before continuing |
| Before merge | Final review check |
| Stuck on approach | Request early feedback |

### Creating a Review-Ready PR

```r
# 1. Ensure all checks pass (verification-before-completion)
devtools::document()
devtools::test()
devtools::check()

# 2. Push to cachix first (Step 5)
# ../push_to_cachix.sh

# 3. Create/update PR
usethis::pr_push()

# 4. Add reviewers via gh package
gh::gh(
  "POST /repos/{owner}/{repo}/pulls/{pull_number}/requested_reviewers",
  owner = "JohnGavin",
  repo = "randomwalk",
  pull_number = 123,
  reviewers = c("reviewer1", "reviewer2")
)
```

### PR Description Template

```r
pr_body <- '
## Summary
- [What this PR does in 1-2 sentences]

## Changes
- [ ] Added `new_function()` with tests
- [ ] Updated documentation
- [ ] All checks pass locally

## Testing
```r
devtools::test()
# [ FAIL 0 | WARN 0 | SKIP 0 | PASS 47 ]

devtools::check()
# 0 errors ✔ | 0 warnings ✔ | 0 notes ✔
```

## Issue
Closes #123
'

# Create PR with body
usethis::pr_push()
# Then update body via gh if needed
```

### Self-Review Checklist

Before requesting human review:

```markdown
## Pre-Review Checklist

### Code Quality
- [ ] Functions are documented with roxygen2
- [ ] No commented-out code
- [ ] Variable names are descriptive
- [ ] Complex logic has comments

### Testing
- [ ] All new functions have tests
- [ ] Edge cases are tested
- [ ] Tests follow TDD (wrote test first)
- [ ] `devtools::test()` passes

### Package Standards
- [ ] `devtools::check()` returns 0/0/0
- [ ] NAMESPACE is updated (`devtools::document()`)
- [ ] Dependencies in DESCRIPTION
- [ ] No hardcoded paths (use `here::here()`)

### Git
- [ ] Commits are atomic and well-messaged
- [ ] Branch is up to date with main
- [ ] No merge conflicts
```

## Part 2: Receiving Code Review

### The Response Pattern

```
WHEN receiving feedback:

1. READ: Complete feedback without reacting
2. UNDERSTAND: Restate requirement in own words
3. VERIFY: Check against actual code
4. EVALUATE: Is feedback technically correct?
5. RESPOND: Technical reply or reasoned pushback
6. IMPLEMENT: Fix issues one at a time
```

### Forbidden Responses

From AGENTS.md and tidyverse principles:

**NEVER say:**
- "You're absolutely right!"
- "Great point!"
- "Excellent feedback!"
- "Let me implement that now" (before understanding)

**INSTEAD:**
- Restate the technical requirement
- Ask clarifying questions if unclear
- Push back with technical reasoning if wrong
- Just fix it (actions > words)

### Handling Review Comments

```r
# Fetch PR comments
comments <- gh::gh(
  "GET /repos/{owner}/{repo}/pulls/{pull_number}/comments",
  owner = "JohnGavin",
  repo = "randomwalk",
  pull_number = 123
)

# Process each comment
for (comment in comments) {
  # 1. Understand the issue
  # 2. Verify in code
  # 3. Fix or respond
}
```

### Response Types

| Feedback Type | Response |
|--------------|----------|
| Bug found | Fix it, reply with commit SHA |
| Style suggestion | Apply if consistent with tidyverse, or explain why not |
| Design question | Explain reasoning, or revise if convinced |
| Missing test | Add test, verify it fails first (TDD) |
| Unclear feedback | Ask: "Could you clarify what you mean by X?" |
| Disagree | Push back with technical reasoning |

### Pushing Back (When Appropriate)

```markdown
# Reviewer says: "Use a for loop instead of purrr::map"

# Response (technical, not defensive):
I chose `purrr::map()` here because:
1. It's consistent with tidyverse style used elsewhere in the package
2. The `.progress` argument gives free progress bars for long operations
3. Type-stable variants (`map_dbl`, `map_chr`) catch errors early

Happy to discuss if you see issues with this approach.
```

### Implementing Fixes

```r
# For each piece of feedback:

# 1. Create fix commit
gert::git_add("R/fixed_file.R")
gert::git_commit("Address review: improve error message clarity")

# 2. Reply to comment with commit reference
gh::gh(
  "POST /repos/{owner}/{repo}/pulls/{pull_number}/comments/{comment_id}/replies",
  owner = "JohnGavin",
  repo = "randomwalk",
  pull_number = 123,
  comment_id = 456,
  body = "Fixed in abc1234. Added more descriptive error messages."
)

# 3. Push updates
gert::git_push()
```

## Part 3: Final Review Before Merge

### Pre-Merge Checklist

```r
# 1. All CI checks pass
pr_status <- gh::gh(
  "GET /repos/{owner}/{repo}/pulls/{pull_number}",
  owner = "JohnGavin",
  repo = "randomwalk",
  pull_number = 123
)
stopifnot(pr_status$mergeable == TRUE)

# 2. All review comments addressed
# 3. Approved by reviewer(s)
# 4. Branch is up to date with main

# 5. Final local verification
devtools::check()

# 6. Merge
usethis::pr_merge_main()
usethis::pr_finish()
```

## Integration with 9-Step Workflow

```
Step 6: Push to GitHub (usethis::pr_push())
        └─→ [code-review-workflow: requesting]

Step 7: Wait for GitHub Actions
        └─→ CI runs
        └─→ [code-review-workflow: receiving feedback]
        └─→ Address comments, push fixes

Step 8: Merge PR
        └─→ [code-review-workflow: final review]
        └─→ usethis::pr_merge_main()
```

## Tidyverse Alignment

From [tidyverse design](https://design.tidyverse.org/):
- **Human-centered**: Review is about code quality, not ego
- **Consistent**: Same review standards across all PRs

From AGENTS.md:
> "Prioritize technical accuracy and truthfulness over validating beliefs"

This applies to both giving and receiving reviews - technical correctness matters more than social comfort.

## Common Review Issues in R Packages

| Issue | Fix |
|-------|-----|
| Missing `@export` | Add to roxygen, run `devtools::document()` |
| Undocumented parameter | Add `@param` in roxygen |
| No test for new function | Add test file, follow TDD |
| Hardcoded path | Use `here::here()` or `testthat::test_path()` |
| Not in NAMESPACE | Check `@export`, run `devtools::document()` |
| R CMD check NOTE | Address the specific note |
| Missing dependency | `usethis::use_package()` |
