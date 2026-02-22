# /setup-pipeline-ci - Setup Targets CI Pipeline

Set up GitHub Actions CI for a targets pipeline project (Nix-based).

## Steps

1. **Verify project prerequisites:**
   - Check for `default.nix` (required — all projects use Nix)
   - Check for `_targets.R` (targets pipeline)
   - Check for `vignettes/` directory
   - Report findings

2. **Add `tar_validate()` to R-CMD-check:**
   - If `_targets.R` exists and `.github/workflows/R-CMD-check.yml` exists
   - Add validation step after the R CMD check step
   - Use `hashFiles('_targets.R') != ''` condition

3. **Generate run-pipeline workflow:**
   - Use Nix template from `targets-ci-pipeline` skill
   - Write to `.github/workflows/run-pipeline.yml`

4. **Ensure `_targets/` is gitignored:**
   - Check `.gitignore` for `_targets/` entry
   - Add if missing

5. **Verify mandatory CI features in all Nix workflows:**
   - `GITHUB_PAT: ${{ secrets.GITHUB_TOKEN }}` at job level
   - `actions/checkout@v6`
   - Verbose Nix installer options
   - Report any missing features

6. **Summary:**
   - List files created/modified
   - List next steps (e.g., "push to trigger first pipeline run")

## Templates

Refer to `targets-ci-pipeline` skill for complete workflow templates.

## Output Format

```
## Pipeline CI Setup

- Nix environment: [default.nix found / MISSING]
- Pipeline: [_targets.R found / not found]
- Vignettes: [found / not found]

### Files Modified
- .github/workflows/R-CMD-check.yml (added tar_validate step)
- .github/workflows/run-pipeline.yml (created)
- .gitignore (added _targets/)

### Mandatory CI Checklist
- [x] GITHUB_PAT at job level
- [x] actions/checkout@v6
- [x] Verbose Nix installer
- [x] tar_validate() in R-CMD-check
- [x] _targets/ gitignored

### Next Steps
1. Commit and push to trigger first pipeline run
2. targets-runs branch will be created automatically
```
