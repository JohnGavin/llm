# /pr-pass - Loop Until CI Passes

Automatically fix CI failures until all checks pass. This command orchestrates the fix-push-wait loop.

## When to Use

- After creating a PR that has failing checks
- When CI fails after a push
- To automate the "fix until green" cycle

## Algorithm

```
MAX_ITERATIONS = 5
iteration = 0

while iteration < MAX_ITERATIONS:
    1. Check current CI status
    2. If all checks pass → SUCCESS, exit
    3. If checks failing:
       a. Parse failure details
       b. Fix each issue (delegate to /address-bugs)
       c. Commit fixes
       d. Push
       e. Wait for CI (poll every 30s, max 5min)
    4. iteration++

if iteration >= MAX_ITERATIONS:
    Report: "Max iterations reached. Manual intervention needed."
    Show remaining failures
```

## Implementation

### Step 1: Get Current PR

```bash
# Get current branch's PR
PR_NUM=$(gh pr view --json number --jq '.number' 2>/dev/null)
if [ -z "$PR_NUM" ]; then
  echo "No PR found for current branch. Create one first."
  exit 1
fi
echo "Working on PR #$PR_NUM"
```

### Step 2: Check CI Status

```bash
gh pr checks $PR_NUM --json name,state,conclusion --jq '
  .[] | "\(.name): \(.state) (\(.conclusion // "pending"))"
'
```

### Step 3: Parse Failures

```bash
# Get failed check details
gh pr checks $PR_NUM --json name,state,conclusion,detailsUrl --jq '
  .[] | select(.conclusion == "failure" or .conclusion == "cancelled") |
  {name: .name, url: .detailsUrl}
'
```

### Step 4: Get Failure Logs

For each failed check, fetch the log:

```bash
# Get workflow run ID from check
gh run list --branch $(git branch --show-current) --json databaseId,conclusion,name --jq '
  .[] | select(.conclusion == "failure") | .databaseId
' | head -1 | xargs -I {} gh run view {} --log-failed
```

### Step 5: Fix and Commit

After identifying issues:

1. Make fixes to code
2. Stage changes: `git add -A`
3. Commit: `git commit -m "fix: Address CI failure - [specific issue]"`
4. Push: `git push`

### Step 6: Wait for CI

```bash
# Poll until checks complete (max 5 minutes)
for i in {1..10}; do
  sleep 30
  STATUS=$(gh pr checks $PR_NUM --json conclusion --jq 'all(.conclusion == "success")')
  if [ "$STATUS" = "true" ]; then
    echo "All checks passed!"
    exit 0
  fi
  PENDING=$(gh pr checks $PR_NUM --json state --jq '[.[] | select(.state == "pending")] | length')
  if [ "$PENDING" = "0" ]; then
    echo "Checks complete but some failed. Analyzing..."
    break
  fi
  echo "Waiting... ($i/10)"
done
```

## Output Format

```
## PR Pass Progress

### Iteration 1
- Checks: 3 passed, 2 failed
- Failures:
  - R-CMD-check: Error in test-foo.R line 42
  - Coverage: Coverage dropped below 80%
- Fixes applied:
  - Fixed test-foo.R assertion
  - Added tests for uncovered function
- Committed: abc1234 "fix: Address R-CMD-check failures"
- Pushed, waiting for CI...

### Iteration 2
- Checks: 5 passed, 0 failed
- All checks green!

## Result: SUCCESS
PR #123 is ready for review.
```

## Safeguards

1. **Max 5 iterations** - prevents infinite loops
2. **Confirm destructive fixes** - ask before major changes
3. **Log all changes** - full audit trail
4. **Bail on ambiguous errors** - ask user if unsure

## Integration

This command uses:
- `/address-bugs` for parsing and fixing specific failures
- `/check` for local validation before push
- Git operations via gert (per AGENTS.md rules)
