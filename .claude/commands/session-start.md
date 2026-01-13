# /session-start - Initialize Development Session

Run the session initialization checklist from AGENTS.md Section 1.

## Steps

1. Verify nix shell is active
2. Check git status and current branch
3. Read `.claude/CURRENT_WORK.md` if exists
4. List open GitHub issues
5. Summarize what to work on

## Commands to Execute

```bash
# Verify nix shell
echo "IN_NIX_SHELL: $IN_NIX_SHELL"
which R
```

```r
library(gert)
library(gh)

# Git status
cat("## Git Status\n")
cat("Branch:", git_branch(), "\n")
status <- git_status()
if (nrow(status) > 0) {
  print(status)
} else {
  cat("Working tree clean\n")
}

# Recent commits
cat("\n## Recent Commits\n")
log <- git_log(max = 5)
for (i in seq_len(nrow(log))) {
  cat("-", substr(log$commit[i], 1, 7), log$message[i], "\n")
}

# Open issues
cat("\n## Open Issues\n")
issues <- gh("GET /repos/{owner}/{repo}/issues",
             owner = "JohnGavin",
             repo = "randomwalk",
             state = "open",
             .limit = 10)
for (issue in issues) {
  cat("#", issue$number, "-", issue$title, "\n")
}
```

## Output Format

```
## Session Start Checklist

### Environment
- Nix shell: [active/inactive]
- R path: [/nix/store/...]

### Git Status
- Branch: [branch-name]
- Status: [clean/modified files]

### Recent Commits
- [hash] [message]

### Open Issues
- #[num] [title]

### Current Work
[Contents of CURRENT_WORK.md or "No current work file"]

## Recommended Next Action
[Based on open issues and current state]
```
