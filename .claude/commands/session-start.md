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

## Config Audit
- Config sizes: [OK/warnings]
- Mapping validation: [OK/mismatches]

## Recommended Next Action
[Based on open issues and current state]
```

## Config Audit Steps

6. Run config size audit (`~/.claude/hooks/config_size_check.sh`)
7. Run skill token audit (`~/.claude/hooks/count_skill_tokens.sh`)
8. Run mapping validation (`~/.claude/validate_claude_md.sh`)
9. Summarize any warnings

## ctx.yaml Cache (auto from session_init.sh hook)

10. Hook reports OK/STALE/OTHER_VERSION/MISSING counts
11. If any gaps: immediately launch background ctx_sync:

```bash
# Run as background task — don't block the session
timeout 600 Rscript -e 'source("~/docs_gh/llm/R/tar_plans/plan_pkgctx.R"); ctx_sync("DESCRIPTION")'
```

This generates missing + refreshes stale ctx files (~30s per package) while the session continues.
