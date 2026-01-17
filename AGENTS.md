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

**Agents (5 available):**
- `.claude/agents/r-debugger.md` - Debug R CMD check/test failures with scientific method
- `.claude/agents/reviewer.md` - Code review specialist for PRs
- `.claude/agents/nix-env.md` - Diagnose/fix Nix shell and environment issues
- `.claude/agents/targets-runner.md` - Run and debug targets pipelines
- `.claude/agents/shinylive-builder.md` - Build and test Shinylive/WASM vignettes

**Skills (30 available):**

*Core Workflow:*
- `.claude/skills/architecture-planning/SKILL.md` - Step 0: Design validation before coding
- `.claude/skills/writing-plans/SKILL.md` - Pre-Step 2: Detailed task breakdown
- `.claude/skills/executing-plans/SKILL.md` - Step 3: Systematic batch execution
- `.claude/skills/test-driven-development/SKILL.md` - Step 3: RED-GREEN-REFACTOR
- `.claude/skills/verification-before-completion/SKILL.md` - Steps 4,5,7: Evidence before claims
- `.claude/skills/code-review-workflow/SKILL.md` - Steps 6-7: PR review process
- `.claude/skills/r-package-workflow/SKILL.md` - Complete 9-step workflow

*Environment & Tools:*
- `.claude/skills/nix-rix-r-environment/SKILL.md` - Reproducible Nix/R environments
- `.claude/skills/pkgdown-deployment/SKILL.md` - Hybrid deployment workflow
- `.claude/skills/targets-vignettes/SKILL.md` - Pre-calculate vignette objects
- `.claude/skills/shinylive-quarto/SKILL.md` - WebAssembly Shiny apps in Quarto
- `.claude/skills/shinylive-deployment/SKILL.md` - **NEW**: GitHub Actions Shinylive automation

*CI/CD & Deployment:*
- `.claude/skills/ci-workflows-github-actions/SKILL.md` - GitHub Actions patterns
  **⚠️ MANDATORY: Read this skill BEFORE writing ANY GitHub Actions workflow!**

*Diagnostics & Analysis:*
- `.claude/skills/systematic-debugging/SKILL.md` - Scientific debugging protocol
- `.claude/skills/project-telemetry/SKILL.md` - Logging and statistics
- `.claude/skills/gemini-cli-codebase-analysis/SKILL.md` - Large codebase analysis
- `.claude/skills/project-review/SKILL.md` - **NEW**: Technical debt assessment and cleanup

*Data & Parallel Processing:*
- `.claude/skills/data-wrangling-duckdb/SKILL.md` - SQL on files (JSON/CSV/Parquet)
- `.claude/skills/parallel-processing/SKILL.md` - nanonext → mirai → crew stack (event-driven)
- `.claude/skills/crew-operations/SKILL.md` - **NEW**: Logging, auto-scaling, monitoring

*Shiny & Async:*
- `.claude/skills/shiny-async-patterns/SKILL.md` - **NEW**: ExtendedTask, crew+Shiny, non-blocking
- `.claude/skills/lazy-evaluation-guide/SKILL.md` - **NEW**: 6 meanings of "lazy" in R

*Quarto & Dynamic Content:*
- `.claude/skills/quarto-dynamic-content/SKILL.md` - **NEW**: Dynamic tabsets, knitr::knit_child()

*ML/AI:*
- `.claude/skills/huggingface-r/SKILL.md` - **NEW**: hfhub, tok, safetensors for HF Hub models

*Statistical Analysis Workflow:*
- `.claude/skills/eda-workflow/SKILL.md` - Systematic EDA checklist
- `.claude/skills/analysis-rationale-logging/SKILL.md` - Document why decisions were made
- `.claude/skills/ai-assisted-analysis/SKILL.md` - LLM collaboration with human validation
- `.claude/skills/tidyverse-style/SKILL.md` - Package recommendations and style guide

*Claude Code Features:*
- `.claude/skills/hooks-automation/SKILL.md` - Pre/post tool execution hooks
- `.claude/skills/mcp-servers/SKILL.md` - MCP server integration (r-btw, browser)
- `.claude/skills/context-control/SKILL.md` - Context management (/compact, /clear, checkpoints)


*New Skills (Added via CLI):*
- **Nix Environment**: Defining and using reproducible development environments with `rix`.
- **R Targets Pipeline**: creating and running data analysis pipelines with the `targets` package.
- **GitHub Actions CI/CD**: Automating tests, analysis, and documentation deployment.
- **Pkgdown Documentation**: Building and deploying static websites for R projects.
- **Gert/Git**: Programmatic git operations from within R.
- **CLI & Shell Automation**: Robust shell scripting and CLI tool usage.

## 2a. Agents vs Skills

**Skills** = Context/instructions loaded into main Claude session
**Agents** = Isolated subagents with restricted tools for specific tasks

| When to Use | Skills | Agents |
|-------------|--------|--------|
| General guidance | ✅ | |
| Complex multi-step tasks | ✅ | |
| Isolated high-output tasks | | ✅ |
| Strict tool restrictions needed | | ✅ |
| Debugging R errors | | ✅ `r-debugger` |
| Code reviews | | ✅ `reviewer` |
| Nix environment issues | | ✅ `nix-env` |
| Targets pipeline debugging | | ✅ `targets-runner` |
| Shinylive/WASM builds | | ✅ `shinylive-builder` |

**Invoke agents:**
```
# In Claude Code
"Use the r-debugger agent to investigate this test failure"
"Use the reviewer agent to review PR #123"
```

**Custom Commands (6 available):**
- `/session-start` - Initialize session (nix check, git status, open issues)
- `/session-end` - End session (commit, update CURRENT_WORK.md, push)
- `/check` - Run devtools::document(), test(), check()
- `/pr-status` - Check PR and CI workflow status
- `/new-issue` - Create issue + branch + log file
- `/cleanup` - Review and simplify current session's work

## 3. Critical Workflow Principles

**⚠️ MANDATORY: Always Read Actual Errors - NEVER Speculate:**
When debugging CI/workflow failures:
1. **READ THE ACTUAL ERROR MESSAGE** from the workflow logs
2. **NEVER speculate** about what the error "might be"
3. If you cannot access or read the error:
   - **STOP immediately**
   - Tell the user which URL you cannot access
   - Explain WHY you cannot access it
   - **ASK the user to look up the error for you**
4. Only proceed with fixes after you have the EXACT error message
5. Quote the actual error in your response before proposing solutions

**⚠️ BEFORE writing ANY GitHub Actions workflow:**
→ MUST read `.claude/skills/ci-workflows-github-actions/SKILL.md`
→ Use the Decision Matrix: Simple tasks (email, coverage) → Native R via `r-lib/actions`, NOT Nix
→ Skills are NOT automatically triggered - you must proactively consult them

**⚠️ MANDATORY: Quarto Project Configuration:**
When setting up ANY Quarto project (website, book, etc.):
1. **ALWAYS configure `_quarto.yml` to explicitly specify which files to render**
2. Use the `render:` section to list only `.qmd` files
3. **NEVER let Quarto auto-discover files** - it will try to render ALL `.md` files
4. `.md` files with R code blocks (like documentation) will fail with: "You must use the .qmd extension for documents with executable code"

**Required `_quarto.yml` pattern:**
```yaml
project:
  type: website
  output-dir: docs
  render:
    - "index.qmd"
    - "vignettes/*.qmd"
```

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
│ 0. Design & Plan                                              │
│    └─→ architecture-planning skill                            │
│    └─→ writing-plans skill                                    │
│                                                                │
│ 1. Create GitHub Issue (#123)                                 │
│ 2. Create dev branch (usethis::pr_init())                     │
│ 3. Make changes locally                                       │
│    └─→ executing-plans skill (batch execution)                │
│    └─→ test-driven-development skill (RED-GREEN-REFACTOR)     │
│                                                                │
│ 4. Run all checks (devtools::check(), etc.)                   │
│    └─→ verification-before-completion skill                   │
│                                                                │
│ 5. ⚠️ MANDATORY: Push to johngavin cachix ⚠️                   │
│    └─→ nix-store ... | cachix push johngavin                  │
│    └─→ verification-before-completion skill                   │
│                                                                │
│ 6. Push to GitHub (usethis::pr_push())                        │
│    └─→ code-review-workflow skill                             │
│                                                                │
│ 7. Wait for GitHub Actions (pulls from cachix - fast!)        │
│    └─→ verification-before-completion skill                   │
│    └─→ code-review-workflow skill (handle feedback)           │
│                                                                │
│ 8. Merge PR (usethis::pr_merge_main())                        │
│ 9. Log everything (R/dev/issue/fix_issue_123.R)               │
└────────────────────────────────────────────────────────────────┘
```

**Key Skill Integration:**
- **Step 0**: Use `architecture-planning` to validate design, then `writing-plans` to create bite-sized tasks
- **Step 3**: Use `test-driven-development` (write test first!) and `executing-plans` for systematic progress
- **Steps 4,5,7**: Use `verification-before-completion` - NO claims without fresh evidence
- **Steps 6-7**: Use `code-review-workflow` for PRs and handling feedback

**Step Details:**

1.  **📝 Create GitHub Issue**: Use `gh` package or GitHub website.
2.  **🌿 Create Development Branch**: `usethis::pr_init("fix-issue-123-description")`.
3.  **✏️ Make Changes**: Edit code on dev branch. Commit using `gert` (NOT bash).
4.  **✅ Run Checks**: `devtools::document()`, `test()`, `check()`, `pkgdown::build_site()`. Fix ALL errors/notes.
    - **Test Coverage**: Run `covr::package_coverage()` locally (or rely on CI - see Code Coverage section below).
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
3. If `WIKI_CONTENT/` changed: run `Rscript R/dev/wiki/sync_wiki.R` (syncs wiki + README).
4. Push to remote.
5. Exit.

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

## 7a. Tool Preferences

**Parallel Processing Stack** (prefer in this order):
```
nanonext → mirai → crew → targets
   ↓         ↓       ↓        ↓
 sockets   async   workers  pipelines
```
- **nanonext**: Low-level async sockets (NNG bindings) - use for custom protocols
- **mirai**: Async evaluation built on nanonext - use for simple parallel tasks
- **crew**: Worker pools built on mirai - use with targets for pipeline parallelism
- **targets + crew**: Production pipelines with `tar_option_set(controller = crew_controller_local())`

**Data Wrangling Stack** (prefer over base R):
```r
# ✅ PREFERRED: duckdb for data wrangling
library(duckdb)
library(dplyr)
library(dbplyr)

con <- dbConnect(duckdb())

# Read JSON from API, process with SQL
result <- con |>
  tbl(sql("SELECT * FROM read_json_auto('data.json')")) |>
  filter(status == "active") |>
  collect()

# Query Parquet files directly
tbl(con, sql("SELECT * FROM 'data/*.parquet'")) |>
  summarise(n = n())

# ❌ AVOID: Traditional ETL pipelines when duckdb can handle directly
```

**DuckDB Use Cases:**
- RSS feed wrangling: `read_json_auto()` for feed parsing
- Shell command output: `shellfs` extension for CLI → SQL
- Log analysis: Query CSV/JSON/Parquet without loading into R
- Cross-format joins: Join CSV with Parquet with JSON in one query

**Arrow for Large Data:**
```r
library(arrow)
# Use Arrow for:
# - Data larger than memory
# - Parquet/Feather file I/O
# - Zero-copy data sharing with Python (via reticulate)
```

**Decision Matrix:**

| Task | Tool |
|------|------|
| Simple parallel map | `mirai::mirai_map()` |
| Worker pool for targets | `crew::crew_controller_local()` |
| SQL on files (JSON/CSV/Parquet) | `duckdb` |
| Large data I/O | `arrow` |
| Tidy data manipulation | `dplyr` (on duckdb or arrow backend) |
| Pipeline orchestration | `targets` + `crew` |

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

**Template:** [`vignettes/telemetry.qmd`](./vignettes/telemetry.qmd) (use as reference for all projects)

**Required Content for All Projects:**

1. **GitHub CI Workflow Run Time Distributions** (MANDATORY)
   - Fetch last 10 runs per workflow via `gh::gh("/repos/{owner}/{repo}/actions/runs")`
   - Show summary statistics: mean, median, min, max, SD
   - Create box plots and histograms of run times
   - Plot trends over time (are workflows getting faster/slower?)
   - Show success rates by workflow

2. **Git History & Contributors**
   - Commit activity over time
   - Contributors table with commit counts
   - Commits by day of week

3. **Project Structure**
   - File counts by extension
   - Directory tree (limited depth)

4. **GitHub Repository Statistics**
   - Stars, forks, open issues, watchers
   - List of open issues

5. **Session Info** (at bottom of vignette)
   - `sessionInfo()` output

6. **Git Commit Info** (after sessionInfo)
   - Current commit SHA, author, date, message

**Implementation Pattern:**
```r
# Fetch workflow runs
runs <- gh::gh(
"/repos/{owner}/{repo}/actions/runs",
  owner = owner, repo = repo,
  per_page = 100
)

# Calculate durations
tibble(
  name = sapply(runs$workflow_runs, `[[`, "name"),
  run_started_at = sapply(runs$workflow_runs, `[[`, "run_started_at"),
  updated_at = sapply(runs$workflow_runs, `[[`, "updated_at")
) |>
  mutate(duration_minutes = as.numeric(difftime(updated_at, run_started_at, units = "mins")))
```

**Optional Additions:**
- `tar_viznetwork()` for targets pipeline visualization
- Test coverage metrics (from `inst/extdata/coverage.rds`)
- Package dependency graph
- Memory/timing statistics from targets metadata

### Code Coverage

**Guide:** [`WIKI_CONTENT/Code_Coverage_with_Nix.md`](./WIKI_CONTENT/Code_Coverage_with_Nix.md)

**Local Testing (non-Nix):**
```r
covr::package_coverage()           # Full coverage report
covr::report()                     # Interactive HTML report
```

**Note:** `covr::package_coverage()` fails in Nix with "error reading from connection". Use CI workflow instead.

**CI Setup (Recommended):**
```r
# Add test-coverage GitHub Action
usethis::use_github_action("test-coverage")
```

**How it works:**
1. `.github/workflows/test-coverage.yaml` runs on push/PR to main
2. Uses standard R (r-lib/actions/setup-r), NOT Nix
3. Uploads coverage to [Codecov](https://codecov.io) for PR badges/checks
4. Optionally commits `inst/extdata/coverage.rds` for telemetry vignette

**Codecov Setup:**
1. Sign in to [codecov.io](https://codecov.io) with GitHub
2. Enable the repository (public repos: tokenless, private: add `CODECOV_TOKEN` secret)
3. Add badge to README: `[![codecov](https://codecov.io/gh/USER/REPO/branch/main/graph/badge.svg)](https://codecov.io/gh/USER/REPO)`

**To add to a new project:**
1. Run `usethis::use_github_action("test-coverage")`
2. Enable repo on codecov.io
3. Add badge to README
4. (Optional) Update telemetry vignette to load from `inst/extdata/coverage.rds`

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

*   **Git Commit Info**: Include a table showing the latest git hash/SHA commits in a subsection after `sessionInfo()`.
    ## Session Info

    ```{r session-info}
    sessionInfo()
    ```

* Ditto for the github hash sha for this version of the vignette.
