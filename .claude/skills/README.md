# Claude Skills for R Development

This folder contains reusable Claude skills for R development with reproducible Nix environments.

## What are Skills?

Skills are composable, portable bundles of instructions and resources that Claude can use across different projects. They help maintain consistency and best practices across your work.

## Available Skills

### 🔧 nix-rix-r-environment

**Purpose**: Set up and work within reproducible R development environments using Nix and the rix R package.

**Use when**:
- Starting new R projects requiring reproducible environments
- Working with R packages needing specific versions
- Setting up CI/CD with Nix
- Executing R code in controlled environments
- Ensuring consistency between local and GitHub Actions environments

**Key concepts**:
- Use ONE persistent nix shell for all work (not new shells per command)
- Lock package versions for reproducibility
- Same environment locally and in CI/CD
- Version control nix configurations

**Key files**:
- `SKILL.md` - Complete nix/rix workflow and best practices

### 📦 r-package-workflow

**Purpose**: Complete workflow for R package development from issue creation to PR merge using R packages (gert, gh, usethis) instead of CLI commands.

**Use when**:
- Developing R packages with version control
- Following GitHub-based development workflow
- Need to ensure proper testing and documentation
- Want reproducible development logs

**Key files**:
- `SKILL.md` - Complete workflow steps and best practices
- `workflow-template.R` - Annotated script template for development tasks

### 🎯 targets-vignettes

**Purpose**: Use the targets package to pre-calculate all objects displayed in package vignettes, separating computation from presentation.

**Use when**:
- Creating vignettes with heavy computational requirements
- Building reproducible data analysis pipelines
- Want vignettes to build quickly without re-running expensive calculations
- Creating telemetry and project statistics vignettes

**Key files**:
- `SKILL.md` - Pipeline patterns and vignette integration

### 🌐 shinylive-quarto

**Purpose**: Deploy Shiny apps that run entirely in the browser using WebAssembly through Shinylive for R within Quarto documents.

**Use when**:
- Creating interactive R dashboards that run in the browser
- Building package vignettes with interactive Shiny components
- Deploying Shiny apps without server infrastructure
- Publishing interactive tutorials or demonstrations

**Key concepts**:
- GitHub Pages hosts the static dashboard HTML/JS files
- R-Universe compiles packages to WebAssembly binaries
- Browser loads dashboard from GitHub Pages, packages from R-Universe

**Key files**:
- `SKILL.md` - Complete WebAssembly workflow, R-Universe setup, and GitHub Pages deployment

### 📊 project-telemetry

**Purpose**: Implement comprehensive project telemetry, logging, and statistics tracking for R packages using the logger package and targets.

**Use when**:
- Setting up logging infrastructure for R packages
- Creating telemetry vignettes to document project statistics
- Tracking git history and development metrics
- Monitoring test coverage and package health

**Key files**:
- `SKILL.md` - Logging patterns and telemetry vignette creation

### 🚀 pkgdown-deployment

**Purpose**: Deploy R package documentation using pkgdown and GitHub Pages with a hybrid workflow (Nix for logic, Native R for deployment).

**Use when**:
- Deploying pkgdown sites from Nix-based R projects
- Encountering `Permission denied` errors with bslib in Nix CI
- Building vignettes that depend on targets pipeline data
- Setting up GitHub Actions for documentation deployment

**Key concepts**:
- Nix store is read-only, conflicts with bslib runtime copying
- Use Native R (`r-lib/actions`) for pkgdown build step
- "Data Snapshot" pattern for vignette data via `inst/extdata`
- Logic verified in Nix, presentation in Native R

**Key files**:
- `SKILL.md` - Complete hybrid deployment workflow

### 🔍 gemini-cli-codebase-analysis

**Purpose**: Use Gemini CLI to analyze large codebases or multiple files that exceed Claude's context limits, leveraging Gemini's massive context window.

**Use when**:
- Analyzing entire R package codebases
- Searching for patterns across many files
- Verifying implementation of features across codebase
- Understanding project-wide architecture
- Working with files totaling more than 100KB
- Planning large refactoring efforts

**Key concepts**:
- Gemini for **analysis and understanding** (read-only)
- Claude Code for **modifications and changes**
- Integration with ellmer R package for reproducible analysis
- Use `@` syntax to include files and directories

**Key files**:
- `SKILL.md` - Complete Gemini CLI workflow for R package analysis

### 🏗️ architecture-planning

**Purpose**: Mandatory "Planning Phase" that prevents hallucination-driven development by forcing validation against DESCRIPTION and default.nix before coding.

**Use when**:
- Starting work on a new GitHub issue
- Planning complex refactoring
- Adding new features to an R package
- You need to prevent introducing unlisted dependencies
- You want to ensure the solution fits the existing architecture

**Key concepts**:
- **Step 0** of the r-package-workflow (before `usethis::pr_init()`)
- Phase 1: Brainstorming - validate dependencies, propose solution
- Phase 2: Detailed Planning - create actionable checklist
- Prevents "Phantom Dependencies" (using packages not in DESCRIPTION)

**Key files**:
- `SKILL.md` - Complete planning protocol with examples

### 🐛 systematic-debugging

**Purpose**: Rigorous scientific method for resolving R CMD check failures, test failures, and Nix environment issues using Hypothesis → Experiment → Conclusion loops.

**Use when**:
- `devtools::check()` fails
- `devtools::test()` reports failures
- CI/CD workflows fail
- "Object not found" errors occur in nix-shell
- You are stuck in a cycle of repeated error messages

**Key concepts**:
- **STOP** before editing code
- Phase 1: Isolate (reproduce with minimal code)
- Phase 2: Hypothesize (state *why* it's failing)
- Phase 3: Experiment (test hypothesis without changing source)
- Phase 4: Implement & Verify (permanent fix + regression check)

**Key files**:
- `SKILL.md` - Debugging protocol with common R failure patterns

### ✅ verification-before-completion

**Purpose**: Enforce "evidence before claims" - no completion claims without fresh verification output.

**Use when**:
- About to claim "tests pass" or "check succeeds"
- Before committing or creating PRs
- Before saying "Done!" or expressing satisfaction
- After any fix, before claiming it works

**Key concepts**:
- Run verification command in THIS message, not earlier
- Quote actual output as evidence
- Never use "should", "probably", "seems to"
- Applies at Steps 4, 5, 7 of 9-step workflow

**Key files**:
- `SKILL.md` - R package verification commands and patterns

### 🧪 test-driven-development

**Purpose**: Write the test first, watch it fail, write minimal code to pass. RED-GREEN-REFACTOR for R packages.

**Use when**:
- Implementing new functions
- Fixing bugs (write test that reproduces bug first)
- Adding features to existing functions
- Refactoring (tests protect against regressions)

**Key concepts**:
- Write failing test FIRST (RED)
- Watch it fail for the RIGHT reason
- Write MINIMAL code to pass (GREEN)
- Refactor with test protection
- Delete code written before tests

**Key files**:
- `SKILL.md` - TDD workflow with testthat patterns

### 📝 writing-plans

**Purpose**: Write comprehensive implementation plans with bite-sized tasks (2-5 minutes each) before touching code.

**Use when**:
- After `architecture-planning` approves design
- Before `usethis::pr_init()` (Step 2)
- For multi-file changes
- To enable parallel work or session continuity

**Key concepts**:
- Each task is ONE action (2-5 minutes)
- Explicit file paths and code snippets
- Verification step for every task
- YAGNI, DRY, TDD throughout

**Key files**:
- `SKILL.md` - Plan structure and task templates

### ⚡ executing-plans

**Purpose**: Load plan, execute tasks in batches with checkpoints, report progress.

**Use when**:
- Have a written implementation plan
- Implementing multi-task features
- Want structured progress with verification
- Need pause/resume across sessions

**Key concepts**:
- Execute 3 tasks per batch (adjustable)
- Verify after each task
- Report and get feedback between batches
- Stop immediately if blocked or unclear

**Key files**:
- `SKILL.md` - Execution workflow and session continuity

### 👥 code-review-workflow

**Purpose**: Request and receive code reviews using R packages (gh, gert) with technical rigor.

**Use when**:
- Completing a PR (Steps 6-7)
- After major implementation milestones
- Before merging to main
- Receiving feedback on PRs

**Key concepts**:
- Technical evaluation, not performative agreement
- Never say "You're absolutely right!"
- Push back with reasoning if feedback is wrong
- Address comments with commit references

**Key files**:
- `SKILL.md` - PR workflow and review response patterns

### 🔄 ci-workflows-github-actions

**Purpose**: Comprehensive GitHub Actions workflows for R package CI/CD - covering Nix builds, r-universe testing, WASM compilation, code coverage, and Cachix integration.

**Use when**:
- Setting up CI/CD for R packages
- Testing against r-universe build process
- Building WebAssembly (WASM) packages for Shinylive
- Configuring code coverage reporting
- Using Cachix for Nix store caching

**Key concepts**:
- r-universe reusable workflows (`uses: r-universe-org/workflows/...@v3`)
- Two-tier Cachix: public `rstats-on-nix` + project-specific
- Hybrid workflow: Nix for logic, Native R for pkgdown/bslib
- Path-filtered triggers to avoid unnecessary CI runs

**Key files**:
- `SKILL.md` - Complete workflow catalog and patterns

### 🦆 data-wrangling-duckdb

**Purpose**: Use DuckDB as primary data wrangling tool - query JSON/CSV/Parquet directly with SQL, avoiding traditional ETL pipelines.

**Use when**:
- Processing JSON from APIs (RSS feeds, curl output)
- Querying log files or CSV exports
- Joining data across formats
- Data larger than memory (with Arrow)

**Key concepts**:
- `read_json_auto()`, `read_csv_auto()` - query files directly
- dplyr + dbplyr for tidy SQL generation
- Arrow integration for large data
- Export to any format with `COPY ... TO`

**Key files**:
- `SKILL.md` - DuckDB patterns and anti-patterns

### ⚡ parallel-processing

**Purpose**: Use nanonext → mirai → crew stack for parallel processing, replacing future/furrr with more efficient alternatives.

**Use when**:
- Running parallel computations
- Integrating parallel workers with targets
- Building async/concurrent applications
- Python ↔ R interop via sockets

**Key concepts**:
- `mirai::mirai_map()` - simple parallel map
- `crew::crew_controller_local()` - managed worker pools
- `targets` + `crew` - production pipelines
- `nanonext` - low-level async sockets

**Key files**:
- `SKILL.md` - Stack overview and patterns

### 🔍 eda-workflow

**Purpose**: Systematic exploratory data analysis - *what to look for* in data, not just *how to query it*. The critical human step that AI cannot automate.

**Use when**:
- Starting analysis of a new dataset
- Preparing data for statistical modeling
- Validating assumptions before fitting models
- AI has executed analysis but you need to verify data understanding

**Key concepts**:
- Phase-based EDA: structure → distributions → missingness → relationships → outliers → assumptions
- Documentation template for EDA findings
- Integration with targets for reproducible EDA pipelines
- Complements `data-wrangling-duckdb` (tools) with methodology (what to check)

**Key files**:
- `SKILL.md` - Complete EDA checklist and patterns

### 📋 analysis-rationale-logging

**Purpose**: Document *why* analysis decisions were made, not just *what* was done. Addresses the "garden of forking paths" problem with audit trails.

**Use when**:
- Making decisions during statistical analysis
- Choosing between modeling approaches
- Handling data issues (outliers, missingness, transformations)
- Separating exploratory from confirmatory analysis

**Key concepts**:
- Decision log structure: alternatives considered, rationale, timing
- "Decided BEFORE seeing" vs "Decided AFTER seeing" distinction
- Pre-registration integration
- `log_decision()` helper function for R workflows

**Key files**:
- `SKILL.md` - Decision templates and logging patterns

### 🤖 ai-assisted-analysis

**Purpose**: Effective workflow for using LLMs as analysis collaborators while maintaining scientific rigor. AI handles execution; humans verify data understanding.

**Use when**:
- Using Claude/LLMs to execute statistical analyses
- Delegating code generation while maintaining rigor
- Building reproducible AI-assisted workflows
- Verifying AI-generated analysis is trustworthy

**Key concepts**:
- Human EDA → AI execution → Human validation cycle
- Effective prompting with specific deliverables
- Validation checklists for AI output
- Extracting and versioning AI-generated code

**Key files**:
- `SKILL.md` - AI collaboration patterns and anti-patterns

### 📚 tidyverse-style

**Purpose**: Comprehensive guide to tidyverse packages, style conventions, and when to use each package. Covers recommended packages, excluded packages with rationale.

**Use when**:
- Deciding which tidyverse package to use for a task
- Reviewing code for tidyverse style compliance
- Choosing between tidyverse and base R approaches
- Setting up package dependencies

**Key concepts**:
- Tier 1 (Always): dplyr, ggplot2, tidyr, purrr, stringr, readr
- Tier 2 (When needed): lubridate, forcats, glue, tibble, cli, rlang
- Excluded: tidyverse meta-package, plyr, reshape2, magrittr (limited)
- Base pipe `|>` over magrittr `%>%`

**Key files**:
- `SKILL.md` - Package recommendations and style guide

### ⚙️ hooks-automation

**Purpose**: Configure Claude Code hooks for automatic linting, formatting, and testing on file changes.

**Use when**:
- Setting up automated quality checks
- Configuring pre-commit style validation
- Implementing automatic testing after edits
- Creating custom validation pipelines

**Key concepts**:
- `preToolExecution` and `postToolExecution` hooks
- Matcher patterns for tool filtering
- Environment variables ($TOOL_INPUT, $FILE_PATH)
- Fast, non-blocking hook design

**Key files**:
- `SKILL.md` - Hook configuration and R package patterns

### 🔌 mcp-servers

**Purpose**: Extend Claude Code with MCP (Model Context Protocol) servers for domain-specific capabilities.

**Use when**:
- Using r-btw for R documentation lookup
- Accessing live R session data
- Browser automation with claude-in-chrome
- Debugging MCP connection issues

**Key concepts**:
- r-btw tools: docs, environment, files, git, GitHub API
- claude-in-chrome: browser automation, screenshots
- Configuration in `.claude/mcp.json`
- When to use MCP vs built-in tools

**Key files**:
- `SKILL.md` - MCP server documentation and patterns

### 🌐 browser-user-testing

**Purpose**: Automated user testing of deployed websites (pkgdown, Shiny, dashboards) using browser automation with persona-based navigation and vignette report generation.

**Use when**:
- Testing newly deployed pkgdown documentation sites
- Validating Shinylive or Shiny apps in production
- Performing accessibility and usability reviews
- Generating user journey documentation with GIF recordings
- Testing responsive design across viewport sizes

**Key concepts**:
- Persona-based testing (Newcomer, Analyst, Developer, Researcher, Mobile)
- GIF recording of user journeys for documentation
- Console error and 404 detection
- Accessibility audit checklists
- Responsive design testing (mobile/tablet/desktop viewports)
- Vignette report template for findings

**Key files**:
- `SKILL.md` - Complete browser testing workflow and report templates

### 🧠 context-control

**Purpose**: Manage Claude's context window effectively to prevent information loss and maintain productivity.

**Use when**:
- Sessions are getting long
- Claude starts forgetting earlier decisions
- Need to checkpoint work before compaction
- Managing large codebase exploration

**Key concepts**:
- `/compact` - compress conversation history
- `/clear` - reset context completely
- TodoWrite for persistent state
- External checkpoints in `.claude/CURRENT_WORK.md`

**Key files**:
- `SKILL.md` - Context commands and session strategies

## Skill Count

Currently **25 skills** available:

### Core Workflow (9-Step)
1. architecture-planning - Step 0: Design validation
2. writing-plans - Pre-Step 2: Detailed task breakdown
3. executing-plans - Step 3: Systematic execution
4. test-driven-development - Step 3: TDD discipline
5. verification-before-completion - Steps 4, 5, 7: Evidence before claims
6. code-review-workflow - Steps 6-7: PR review process
7. r-package-workflow - Complete 9-step workflow

### Environment & Tools
8. nix-rix-r-environment - Reproducible Nix/R environments
9. pkgdown-deployment - Hybrid deployment workflow
10. targets-vignettes - Pre-calculate vignette objects
11. shinylive-quarto - WebAssembly Shiny apps

### CI/CD & Deployment
12. ci-workflows-github-actions - GitHub Actions patterns (r-universe, WASM, coverage, Cachix)

### Diagnostics & Analysis
13. systematic-debugging - Scientific debugging protocol
14. project-telemetry - Logging and statistics
15. gemini-cli-codebase-analysis - Large codebase analysis

### Data & Parallel Processing
16. data-wrangling-duckdb - SQL on files (JSON/CSV/Parquet), avoid ETL
17. parallel-processing - nanonext → mirai → crew → targets stack

### Statistical Analysis Workflow
18. eda-workflow - Systematic EDA: what to look for, not just how to query
19. analysis-rationale-logging - Document *why* decisions were made (garden of forking paths defense)
20. ai-assisted-analysis - LLM collaboration with human validation
21. tidyverse-style - Package recommendations and style guide

### Claude Code Features
22. hooks-automation - Pre/post tool execution hooks
23. mcp-servers - MCP server integration (r-btw, browser)
24. context-control - Context management (/compact, /clear, checkpoints)

### Testing & Validation
25. browser-user-testing - Persona-based browser testing with GIF recordings

## How to Use Skills

### In Claude Code

Skills in the `.claude/skills/` folder are automatically available to Claude Code when working in this project directory.

**To invoke a skill:**
1. Simply reference the skill concept in your conversation (e.g., "set up a nix environment for R")
2. Claude will automatically use the skill knowledge
3. Skills are composable - you can use multiple skills together

### In Other Projects

**To reuse these skills:**

1. **Copy the entire folder** to your new project:
   ```bash
   cp -r /path/to/claude_rix/.claude/skills /path/to/new-project/.claude/
   ```

2. **Or copy individual skills**:
   ```bash
   mkdir -p /path/to/new-project/.claude/skills
   cp -r /path/to/claude_rix/.claude/skills/nix-rix-r-environment \
         /path/to/new-project/.claude/skills/
   ```

3. **Commit to git** so team members get them automatically:
   ```bash
   git add .claude/skills/
   git commit -m "Add Claude skills for R development"
   ```

## Skill Structure

Each skill is a folder containing:

```
skill-name/
├── SKILL.md              # Main documentation (required)
├── supporting-files.*    # Templates, examples, etc. (optional)
└── other-resources.*     # Any other helpful files (optional)
```

## Creating New Skills

To create a new skill:

1. Create a new folder in `.claude/skills/`
2. Add a `SKILL.md` file with:
   - Description
   - Purpose (when to use it)
   - How it works
   - Examples and patterns
   - Best practices
3. Add any supporting files (templates, scripts, etc.)
4. Document the skill in this README

## Best Practices

1. **Keep skills focused**: One clear purpose per skill
2. **Include examples**: Show concrete usage patterns
3. **Add templates**: Provide copy-paste starting points
4. **Document dependencies**: Note required tools/packages
5. **Version control**: Commit skills to share with team
6. **Test skills**: Verify they work in new projects

## Skill Compatibility

These skills are designed to work across:
- **Claude Code**: Desktop IDE integration
- **Claude.ai**: Web interface
- **Claude API**: Programmatic access

The same skill files work in all environments!

## Contributing

When adding or updating skills:

1. Follow the existing structure
2. Include clear examples
3. Test in a fresh project
4. Update this README
5. Commit with descriptive message

## Resources

- [Claude Skills Blog Post](https://claude.com/blog/skills)
- [Claude Code Documentation](https://code.claude.com/docs)
- [Example Skills Repository](https://github.com/anthropics/claude-skills)

## Questions?

Skills are a powerful way to codify best practices and share knowledge. Experiment with creating your own!
