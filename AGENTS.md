# Agent Guide for R Package Development

This document provides comprehensive guidelines for agents working on R package development projects using Nix, rix, and reproducible workflows.

## 1. Quick Start for New Sessions

### Session Initialization Checklist

✅ **Environment:** Verify you're in the nix shell (`caffeinate -i ~/docs_gh/rix.setup/default.sh`)
✅ **Context:** Read `.claude/CURRENT_WORK.md` if it exists
✅ **State:** Check `git status` and review recent commits
✅ **Checkpoint:** Review any `CLAUDE_CHECKPOINT.md` or session summary files
✅ **Packages:** Review installed vs. potential external R packages (CRAN/GitHub/R-universe)

**Package Review Protocol:**
At the start of each session, review the list of installed R packages. Identify potentially useful R packages available (CRAN, r-universe, GitHub) that are NOT already installed but might be relevant to project objectives (see `PLAN*.md` or GH issues). Highlight their pros and cons compared to the installed packages.

## 2. Key Documentation References

**Core Guides:**
- **Main Context:** `context_claude.md` (This document)
- **9-Step Workflow:** [Section 4 below](#4-the-9-step-mandatory-workflow) (CRITICAL)
- **Environment QuickRef:** [`NIX_QUICKREF.md`](./NIX_QUICKREF.md) (Fixes for top 5 issues)

**Wiki & Detailed Guides:**
- **Gemini CLI Guide:** [`WIKI_CONTENT/Gemini-CLI-Guide.md`](./WIKI_CONTENT/Gemini-CLI-Guide.md)
- **Session Continuity:** [`WIKI_CONTENT/Session-Continuity.md`](./WIKI_CONTENT/Session-Continuity.md)
- **Nix Generation:** [`WIKI_CONTENT/Environment-Sync-and-Nix-Generation.md`](./WIKI_CONTENT/Environment-Sync-and-Nix-Generation.md)
- **Shinylive Lessons:** [`WIKI_SHINYLIVE_LESSONS_LEARNED.md`](./WIKI_SHINYLIVE_LESSONS_LEARNED.md)
- **Targets & Pkgdown:** [`TARGETS_PKGDOWN_OVERVIEW.md`](./TARGETS_PKGDOWN_OVERVIEW.md)

**Skills:**
- **Nix Environment:** `.claude/skills/nix-rix-r-environment/SKILL.md`
- **Workflow Skill:** `.claude/skills/r-package-workflow/SKILL.md`

## 3. Critical Workflow Principles

**NEVER use bash git/gh commands** - Always use R packages:
- ✅ `gert::git_add()`, `gert::git_commit()`, `gert::git_push()`
- ✅ `usethis::pr_init()`, `usethis::pr_push()`, `usethis::pr_merge_main()`
- ✅ `gh::gh("POST /repos/...")` for GitHub API

**ALWAYS log commands** - For reproducibility:
- Create `R/dev/issue/fix_issue_123.R` files documenting all R commands
- Include log files IN the PR, not after merge (prevents duplicate CI/CD runs)

**ALWAYS work in Nix environment:**
- Use ONE persistent shell per session
- Don't launch new shells for individual commands
- See [`NIX_TROUBLESHOOTING.md`](./archive/detailed-docs/NIX_TROUBLESHOOTING.md) for environment degradation issues

**ALWAYS View Results via GitHub Pages:**
- All viewing of results must ultimately be through the deployed GitHub Pages website.
- Supply URLs pointing to the various output webpages (vignettes, dashboards, etc.).

**EXECUTE R COMMANDS CLEANLY:**
- When executing R commands from the shell, prefer `Rscript` or `R --quiet --no-save` to avoid boilerplate startup messages.
    - ✅ `Rscript -e 'some_command()'`
    - ✅ `R --quiet --no-save -e 'some_command()'`
    - ❌ `R -e 'some_command()'` (due to verbose startup)

**README Example Standard:**
- Include a Nix-shell example that works without `R CMD INSTALL`, e.g. `devtools::load_all("pkg")`.
- Provide an explicit `R_LIBS_USER` example when using a custom library path.

## 4. The 9-Step Mandatory Workflow

**⚠️ CRITICAL: THIS IS NOT OPTIONAL - ALL CHANGES MUST FOLLOW THIS WORKFLOW ⚠️**

**NO EXCEPTIONS. NO SHORTCUTS. NO "SIMPLE FIXES".**

```
┌────────────────────────────────────────────────────────────────┐
│ 1. Create GitHub Issue (#123)                                 │
│ 2. Create dev branch (usethis::pr_init())                     │
│ 3. Make changes locally                                       │
│ 4. Run all checks (devtools::check(), etc.)                   │
│ 5. ⚠️ MANDATORY: Push to johngavin cachix ⚠️                   │
│    └─→ nix-store ... | cachix push johngavin                  │
│ 6. Push to GitHub (usethis::pr_push())                        │
│ 7. Wait for GitHub Actions (pulls from cachix - fast!)        │
│ 8. Merge PR (usethis::pr_merge_main())                        │
│ 9. Log everything (R/dev/issue/fix_issue_123.R)                   │
└────────────────────────────────────────────────────────────────┘
```

**Step Details:**

1.  **📝 Create GitHub Issue**: Use `gh` package or GitHub website.
2.  **🌿 Create Development Branch**: `usethis::pr_init("fix-issue-123-description")`.
3.  **✏️ Make Changes**: Edit code on dev branch. Commit using `gert` (NOT bash).
4.  **✅ Run Checks**: `devtools::document()`, `test()`, `check()`, `pkgdown::build_site()`. Fix ALL errors/notes.
5.  **🚀 Push to Cachix (MANDATORY)**:
    - Run: `../push_to_cachix.sh` (or `nix-store ... | cachix push johngavin`)
    - **Why?** GitHub Actions pulls from cachix. Saves time/resources. Ensures consistency.
6.  **🚀 Push to Remote**: `usethis::pr_push()` (Only after cachix push succeeds).
7.  **⏳ Wait for GitHub Actions**: Monitor all workflows. All must pass.
8.  **🔀 Merge via PR**: `usethis::pr_merge_main()`, `usethis::pr_finish()`.
9.  **📋 Log Everything**: Ensure session log (e.g., `R/dev/issue/fix_issue_123.R`) was included in the PR.

**Consequences of Skipping:**
If you commit directly to main or skip steps, you must create a retrospective issue and log file explaining the violation.

**Forbidden Commands:**
❌ `git add .`, `git commit`, `git push`
❌ `gh pr create`, `gh issue create`

**One-time Setup:** Run `usethis::git_vaccinate()` to add common temp files to global `.gitignore`.

## 5. Nix Environment Management

**Detailed Guide:** [`NIX_PACKAGE_DEVELOPMENT.md`](/Users/johngavin/docs_gh/rix.setup/NIX_PACKAGE_DEVELOPMENT.md)
**Quick Reference:** [`NIX_QUICKREF.md`](./NIX_QUICKREF.md)

**Quick Verification:**
ALWAYS verify you're running inside the nix shell:
```bash
echo $IN_NIX_SHELL  # Should be 1 or impure
which R             # Should be /nix/store/...
```
If failed: `exit` and re-run `caffeinate -i ~/docs_gh/rix.setup/default.sh`.

**Generating Nix Files:**
We use a 3-file strategy (`package.nix`, `default.nix`, `packages.R`) managed by `R/dev/nix/maintain_env.R`.
See [`WIKI_CONTENT/Environment-Sync-and-Nix-Generation.md`](./WIKI_CONTENT/Environment-Sync-and-Nix-Generation.md) for details.

To update environment:
```r
source("R/dev/nix/maintain_env.R")
maintain_env()
```

## 6. Session Continuity

**Full Guide:** [`WIKI_CONTENT/Session-Continuity.md`](./WIKI_CONTENT/Session-Continuity.md)

**Key Principles:**
- **Document Everything:** Update `.claude/CURRENT_WORK.md` every 2-3 hours.
- **Git Checkpoints:** Commit "WIP" often. Use `git stash` if needed.
- **Restart Clean:** Session history does not persist. Rely on files and logs.

**End-of-Session Checklist:**
1. Commit/Stash work (`gert`).
2. Update `.claude/CURRENT_WORK.md`.
3. Push to remote.
4. Exit.

## 7. R Code Standards

**Organization:**
- Organize code into an R package.
- Prepare for R-Universe/CRAN submission.

**Style & Docs:**
- Use `usethis::document()` and `test()`.
- Use `logger` package for comments/logs.
- Prefer tidyverse.
- Use `air` for formatting (`air format ...`).
- Use `typst` for formulas.

**File Structure:**
- `R/`: Package code.
- `R/dev/` with subfolder by topic e.g. 
    - `R/dev/logs/` log scripts.
    - `R/dev/bugs/`: bug fix scripts.
    - `R/dev/issues/`: fix issue scripts.
    - `R/dev/features/`: new feature scripts etc
- `R/tar_plans/`: Targets plans.
- `vignettes/`: Source Quarto files (README, vignettes).
- `inst/logs/`: Session logs.

## 8. Targets Package

- **Pre-calculation:** Use `targets` to precalculate vignette objects.
- **Vignettes:** Should rely on `targets::read()` or `targets::load()`. Minimize computation in .qmd.

## 9. Website (pkgdown) & Documentation

**Standards:**
- Build site with `pkgdown`.
- **Hybrid Workflow:**
    - Use Nix for R CMD Check & Unit Tests.
    - Use Native R for pkgdown + Quarto (due to bslib incompatibility).
    - See [`TARGETS_PKGDOWN_OVERVIEW.md`](./TARGETS_PKGDOWN_OVERVIEW.md).
- **Code Visibility:** Hidden by default, toggleable.

**Infographics:**
- Create for major versions explaining package functionality.
- Embed in README via targets.

## 10. Special Topics

### Shinylive & Dashboards
**Guide:** [`WIKI_SHINYLIVE_LESSONS_LEARNED.md`](./WIKI_SHINYLIVE_LESSONS_LEARNED.md)
- Use `resources: - shinylive-sw.js` in YAML.
- Prefer `library()` calls or `webr::install()` with custom repos.
- Avoid `webr::mount()` from GitHub Releases (CORS issues).

**⚠️ MANDATORY Browser Testing:**
Before committing Shinylive vignettes:
1. Open built HTML in browser, wait for app to load (10-30s)
2. Open DevTools (F12) → Console tab
3. **Check for errors** (404s, WASM failures, Service Worker issues)
4. **DO NOT PROCEED** if ANY console errors appear
See [wiki](https://github.com/JohnGavin/llm/wiki) for detailed checklist.

### Version Bumping
Always bump version when making changes: `usethis::use_version("patch"|"minor"|"major")`
- **patch**: Bug fixes (2.0.0 → 2.0.1)
- **minor**: New features (2.0.1 → 2.1.0)
- **major**: Breaking changes (2.1.0 → 3.0.0)

### GitHub API via CLI
```bash
export GH_TOKEN=$GITHUB_PAT
gh issue list --state open --json number,title
gh pr view 123 --json state,mergeable
```
Always query API for ground truth (don't trust old docs).

### Gemini CLI for Large Codebases
**Guide:** [`WIKI_CONTENT/Gemini-CLI-Guide.md`](./WIKI_CONTENT/Gemini-CLI-Guide.md)
- Use `gemini -p` for large context analysis.
- Use `@path` syntax to include files/directories.

### Telemetry
- Create `telemetry.qmd` vignette.
- Visualize targets pipeline (`tar_viznetwork`).
- Track compilation time, memory, git history.

### Code Coverage in Nix
**Guide:** [`WIKI_CONTENT/Code_Coverage_with_Nix.md`](./WIKI_CONTENT/Code_Coverage_with_Nix.md)

`covr::package_coverage()` fails in Nix with "error reading from connection". Solution: **automated CI workflow**.

**How it works:**
1. `.github/workflows/coverage.yaml` runs on push to main (when R/ or tests/ change)
2. Uses standard R (r-lib/actions/setup-r), NOT Nix
3. Generates coverage and commits `inst/extdata/coverage.rds` back to repo
4. Telemetry vignette loads cached coverage via `readRDS()`

**No manual action required** - coverage updates automatically when code changes.

**To add to a new project:**
1. Copy `.github/workflows/coverage.yaml` from randomwalk
2. Add `inst/extdata/` to `.gitignore` exceptions
3. Update telemetry vignette to load from `inst/extdata/coverage.rds`

### Isolated Shell
- LLMs should run in `--pure` nix shell/container for security.
- Limit write access.

## 11. Documentation Maintenance & Cleanup

*   **Session Tidy-up**: When tidying up towards the end of each session:
    *   Consider reducing the number of `*.md` files in `./R/dev/<topic>` by merging files and merging duplicated topics to produce fewer, more detailed markdown files.
    *   Summarise the themes, topics, and contents by similarity.
    *   Suggest which parts might be better migrated to a wiki page on that topic or theme on the GitHub repository or to a FAQs wiki page.
    *   Raise GitHub issues for any outstanding issues, todos, or features identified during cleanup.
    *   **Documentation Rationalization**: The overall documentation consolidation and rationalization effort is tracked under [Docs: Rationalize and Consolidate Project Documentation](https://github.com/JohnGavin/llm/issues/1). Detailed documentation has been migrated to the [Project Wiki](https://github.com/JohnGavin/llm/wiki). This effort aims to reduce duplication, move detailed technical content to the GitHub Wiki, and convert actionable plans into discrete GitHub issues.

## 12. Session Start Protocol

*   **Initial Review**: At the start of each session:
    *   Review all `./*.md` files for next steps, todos, issues, bugs, and new features.
    *   Review open GitHub issues.
    *   Group the issues/items by similarity.
    *   Order them by difficulty, placing the easiest first within each group and between groups.

## 13. Vignette Requirements

*   **Session Info**: Always include `sessionInfo()` at the bottom of each vignette (`.qmd` file) to aid in reproducibility and debugging.
    ```r
    ## Session Info

    ```{r session-info}
    sessionInfo()
    ```

* Ditto for the github hash sha for this version of the vignette.
