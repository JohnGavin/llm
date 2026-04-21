# /session-end - End Development Session

Run the end-of-session checklist from AGENTS.md Section 6.

## Steps

1. Check for uncommitted changes
2. Check for unresolved roborev findings
3. Prompt to commit or stash
4. Append to `CHANGELOG.md` — completed work, failed approaches, accuracy changes, new limitations
5. Update `.claude/CURRENT_WORK.md` with session summary (ephemeral)
6. Push to remote
7. Sync ctx.yaml cache (verify, regenerate if needed)
8. Report session summary

## Commands to Execute

```r
library(gert)
library(usethis)

# Check status
status <- git_status()
branch <- git_branch()

cat("## Session End Checklist\n\n")
cat("Branch:", branch, "\n")

if (nrow(status) > 0) {
  cat("\n### Uncommitted Changes\n")
  print(status)
  cat("\nAction needed: commit or stash these changes\n")
} else {
  cat("Working tree clean\n")
}

# Check if ahead of remote
cat("\n### Remote Sync\n")
# Would need to check git_ahead_behind()
```

## Roborev Findings Check

Before committing, verify no unresolved roborev findings remain:

```bash
/usr/local/bin/roborev summary --json | jq '.verdicts | {total: .total, failed: .failed, addressed: .addressed}'
```

If `verdicts.failed > 0` AND `verdicts.addressed < verdicts.failed`:
- Report unaddressed failures with severity
- Ask user: "Proceed with commit despite unresolved roborev findings? (Y/N)"
- If no, do NOT commit; suggest fixing failures first

## ctx.yaml Cache Verification

After commit/push, verify all ctx files are current:

```r
source("~/docs_gh/llm/R/tar_plans/plan_pkgctx.R")
audit <- ctx_audit("DESCRIPTION")
```

If any MISSING or OTHER_VERSION remain (background sync from session start didn't finish), run `ctx_sync("DESCRIPTION")` now.

## CHANGELOG.md Update (MANDATORY)

Append a new dated entry to `CHANGELOG.md` with:
- **Completed:** what was done this session
- **Failed Approaches:** what was tried and didn't work (and why) — prevents future sessions retrying dead ends
- **Accuracy / Metrics:** any measurable changes (test count, coverage, quality score)
- **Known Limitations:** issues discovered but not yet fixed

```markdown
## YYYY-MM-DD

### Completed
- [what was done]

### Failed Approaches
- Tried X because Y. Failed because Z. Workaround: W.

### Accuracy / Metrics
- Tests: N passing, coverage: X%

### Known Limitations
- [issues for next session]
```

## Prompt User

After running checks, ask:
1. "Should I commit these changes with message: [suggested message]?"
2. "Should I append to CHANGELOG.md?" (show draft entry)
3. "Should I push to remote?"
4. "Should I sync ctx.yaml cache?" (if audit showed gaps)

## Output Format

```
## Session End Summary

### Changes
- [X files modified / committed / pushed]

### CURRENT_WORK.md Updated
[Yes/No - contents if updated]

### Next Session
- Continue on branch: [branch]
- Open issue: #[num]
- Next task: [description]
```
