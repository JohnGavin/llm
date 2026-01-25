# Agent Guide for R Package Development

Essential rules for R package development with Nix, rix, and reproducible workflows.
For detailed guidance, invoke the relevant skill.

## Session Start

```bash
# Verify nix shell
echo $IN_NIX_SHELL  # Should be 1 or impure
which R             # Should be /nix/store/...
```

If not in nix: `caffeinate -i ~/docs_gh/rix.setup/default.sh`

Check: `.claude/CURRENT_WORK.md`, `git status`, open issues.

## Project-Specific Nix Environments (UPDATED)

**For each R package project**, create a project-specific Nix environment with persistent GC root:

1. **Create `default.R`** - Generates `default.nix` from DESCRIPTION:
   ```r
   # Reads DESCRIPTION and creates default.nix with rix()
   source("default.R")
   ```

2. **Create `default.sh`** with GC root - Fast, persistent Nix shell:
   ```bash
   chmod +x default.sh
   ./default.sh  # First run: builds and creates nix-shell-root
   ./default.sh  # Subsequent runs: FAST (seconds, not minutes!)

   # To force rebuild:
   rm nix-shell-root && ./default.sh
   ```

3. **Key Features**:
   - **Persistent GC root** (`nix-shell-root`) prevents garbage collection
   - **Fast subsequent runs** - packages cached in `/nix/store/`
   - All DESCRIPTION dependencies available
   - No missing package errors in Shiny apps
   - Reproducible across machines

4. **Files created**:
   ```
   project/
   ├── default.R          # Generates default.nix from DESCRIPTION
   ├── default.sh         # Enters Nix shell with GC root
   ├── default.nix        # Generated Nix configuration
   └── nix-shell-root     # Symlink to /nix/store (GC protection)
   ```

5. **CRITICAL: Always exclude Nix files from git and R builds**:

   **Add to `.gitignore`:**
   ```
   nix-shell-root
   ```

   **Add to `.Rbuildignore`:**
   ```
   ^nix-shell-root$
   ^default\.R$
   ^default\.nix$
   ^default\.sh$
   ^default-ci\.nix$
   ```

   Why: nix-shell-root is a symlink to /nix/store that doesn't exist in CI/other machines

5. **Testing examples in Nix**:
   ```bash
   ./default.sh  # Enter Nix environment
   R
   > devtools::load_all()
   > # Run your examples here - all packages available!
   ```

**Reference implementations**:
- Simple version: `millsratio/default.sh`
- Advanced version: `/Users/johngavin/docs_gh/llm/default.sh`

## Critical Nix Rules (MUST READ)

**See `NIX_RULES.md` for detailed explanation**

### NEVER Install Packages Inside Nix
```r
# ✗ FORBIDDEN - Breaks Nix immutability
install.packages()       # NO!
devtools::install()      # NO!
pak::pkg_install()       # NO!

# ✓ ALLOWED - Safe operations
devtools::load_all()     # YES - temporary load
devtools::document()     # YES - updates docs
devtools::test()         # YES - runs tests
```

**To add packages:** Edit DESCRIPTION → Run `default.R` → Exit → Re-enter Nix

## The 9-Step Workflow (MANDATORY)

**NO EXCEPTIONS. NO SHORTCUTS.** See `r-package-workflow` skill for details.

| Step | Action | Key Command |
|------|--------|-------------|
| 0 | Design & Plan | Create `plans/PLAN_*.md` |
| 1 | Create Issue | `gh::gh("POST /repos/...")` |
| 2 | Create Branch | `usethis::pr_init("fix-issue-123")` |
| 3 | Make Changes | Edit, test (RED-GREEN-REFACTOR) |
| 4 | Run Checks | `devtools::document()`, `test()`, `check()` |
| 5 | Push Cachix | `../push_to_cachix.sh` |
| 6 | Push GitHub | `usethis::pr_push()` |
| 7 | Wait for CI | Monitor Nix-based workflows ONLY |
| 8 | Merge PR | `usethis::pr_merge_main()` |
| 9 | Log Everything | Include `R/dev/issue/fix_*.R` in PR |

## Critical Rules

**Git/GitHub - Use R packages ONLY:**
- `gert::git_add()`, `git_commit()`, `git_push()`
- `usethis::pr_init()`, `pr_push()`, `pr_merge_main()`
- `gh::gh()` for GitHub API

**Nix Environment:**
- One persistent shell per session
- Verify with `echo $IN_NIX_SHELL`
- For issues: invoke `nix-env` agent

**Errors - NEVER speculate:**
1. READ the actual error message
2. QUOTE the error before proposing fixes
3. If you can't access logs, ASK the user

**R Version:** Use 4.5.x (current major). Check: `R.version.string`

## Testing Before Commit (MANDATORY)

**NEVER commit without testing:**
1. Enter project-specific Nix environment (./default.sh or ./default_dev.sh)
2. Run `tar_validate()` - MUST pass
3. Run `tar_make(names = "config")` - Test at least one target
4. Check GitHub CI will trigger (modify .github/workflows if needed)
5. Include R/dev/issue/fix_*.R script documenting changes

**Common Testing Mistakes:**
- ❌ Testing in wrong Nix environment (e.g., llm instead of project)
- ❌ Not running tar_validate() before commit
- ❌ Assuming CI will run (check workflow triggers!)
- ✅ Always test in project-specific Nix shell

## GitHub Actions CI Strategy

**CRITICAL: We use Nix-based CI, NOT standard r-lib/actions**

### What We DON'T Use
- ❌ `usethis::use_github_action("check-standard")` - Tests on Windows/Mac/Linux
- ❌ Multi-platform matrix builds (Windows, macOS, Ubuntu with different R versions)
- ❌ r-lib/actions workflows that attempt package installation

### What We DO Use
- ✅ **Nix-based workflows** that test in reproducible Nix shells
- ✅ **Single platform** Nix builds that guarantee reproducibility
- ✅ Custom workflows that respect Nix immutability

### Documented Exceptions
1. **pkgdown website deployment**:
   - Build locally with pkgdown::build_site()
   - Push to gh-pages branch
   - Why: bslib attempts to install packages in Nix (forbidden)

2. **Documentation-only workflows**:
   - May use r-lib/actions for non-code tasks
   - Never for package testing or building

### Codecov Token Setup
If using test-coverage.yaml, it will fail without token:
1. Get token from https://codecov.io
2. Add to repo: Settings → Secrets → Actions → New repository secret
3. Name: `CODECOV_TOKEN`
4. Error if missing: "Token required - not valid tokenless upload"

## Tool Preferences

| Task | Tool |
|------|------|
| Parallel tasks | `mirai::mirai_map()` |
| Worker pools | `crew::crew_controller_local()` |
| SQL on files | `duckdb` |
| Large data I/O | `arrow` |
| Data manipulation | `dplyr` (duckdb/arrow backend) |
| Pipelines | `targets` + `crew` |

## Agents (8 available)

**Delegation saves context**: Subagents keep verbose output in their context, returning only summaries to the main conversation.

| Agent | Model | Thinking | Use For |
|-------|-------|----------|---------|
| `planner` | opus | 16k | Architecture decisions, multi-file refactoring |
| `verbose-runner` | sonnet | 4k | Tests, checks, builds (verbose output contained) |
| `quick-fix` | haiku | 1k | Typos, simple edits, obvious fixes |
| `r-debugger` | sonnet | 8k | R CMD check/test failures |
| `reviewer` | sonnet | 8k | Code reviews |
| `nix-env` | sonnet | 8k | Nix shell issues |
| `targets-runner` | sonnet | 8k | Pipeline debugging |
| `shinylive-builder` | sonnet | 8k | WASM builds |

### When to Delegate

**Core rule:** Delegate when output > 10 lines OR complex reasoning needed
**Never delegate:** Simple file checks (ls, cat), one-line commands, reading files

**Common mistakes I make:**
- Using agents to check symlinks exist (just use `ls -la`)
- Using btw tools directly for builds/tests (always delegate)
- Using wrong agent for task (quick-fix for complex verification)

For detailed rules → invoke `subagent-delegation` skill

## Skills by Category

**Invoke a skill when you need detailed guidance on that topic.**

*Core Workflow:* `r-package-workflow`, `test-driven-development`, `verification-before-completion`

*Environment:* `nix-rix-r-environment`, `ci-workflows-github-actions`

*Data:* `data-wrangling-duckdb`, `parallel-processing`, `crew-operations`

*Shiny:* `shiny-async-patterns`, `shinylive-quarto`, `shinylive-deployment`

*Documentation:* `pkgdown-deployment`, `project-telemetry`, `project-review`, `readme-qmd-standard`

*Analysis:* `eda-workflow`, `tidyverse-style`, `analysis-rationale-logging`

*Context:* `context-control`, `gemini-subagent`

## Skill Loading Triggers

Load the skill when you encounter these situations:

| Situation | Load Skill |
|-----------|------------|
| Writing GitHub Actions | `ci-workflows-github-actions` (MANDATORY) |
| Quarto project setup | Use `render:` section in `_quarto.yml` |
| Shinylive vignette | `shinylive-quarto` + browser test |
| Debugging R errors | Use `r-debugger` agent |
| Context filling up | `context-control` |
| Large codebase analysis | `gemini-subagent` |
| Testing Shiny dashboards | Use `--chrome` option to launch Claude with browser |

## Testing Shiny Apps

**With Chrome Extension:**
```bash
# Launch Claude with Chrome extension
claude --chrome

# Then in R:
launch_dashboard()  # Can interact with browser
```

**Without Chrome Extension:**
- Only verify functions exist
- Don't actually launch (will hang waiting for browser)

## Custom Commands

- `/session-start` - Initialize session
- `/session-end` - End session (commit, push)
- `/check` - Run document(), test(), check()
- `/pr-status` - Check PR and CI status
- `/cleanup` - Review and simplify work

## File Structure (CRITICAL)

```
R/                    # Package functions ONLY
├── *.R               # Analysis functions
├── dev/              # Development tools
│   └── issues/       # Fix scripts (MUST include in PRs)
└── tar_plans/        # Modular pipeline components (MANDATORY)
    └── plan_*.R      # Each returns list of tar_target()

_targets.R            # ONLY orchestrates plans from R/tar_plans/
vignettes/            # Quarto documentation
plans/                # PLAN_*.md working documents
README.qmd            # Source for README.md (NEVER edit README.md directly)
```

## README Requirements (MANDATORY)

**Every project MUST include Nix installation instructions in README:**

1. **Use README.qmd as source** - Never edit README.md directly
2. **Include THREE installation methods:**
   - Standard R (remotes/devtools)
   - **Nix with default.sh method (CRITICAL)**
   - rix integration example
3. **Auto-generate project structure** using fs::dir_tree()
4. **Create targets plan** for auto-regenerating README on vignette changes

See `readme-qmd-standard` skill for complete template.

### Targets Pipeline Structure (MANDATORY)

**NEVER place pipeline definitions directly in _targets.R**

**Correct Structure:**
1. **R/tar_plans/plan_*.R**: Modular pipeline components
   - Each file defines one logical group (e.g., plan_data_acquisition.R)
   - Must return a list of tar_target() objects
   - Example: plan_data_acquisition, plan_quality_control

2. **_targets.R**: Orchestrator ONLY
   ```r
   # Set global options
   tar_option_set(...)

   # Source functions (exclude R/dev/ and R/tar_plans/)
   for (file in list.files("R", pattern = "\\.R$", full.names = TRUE)) {
     if (!grepl("R/(dev|tar_plans)/", file)) source(file)
   }

   # Source and combine plans
   plan_files <- list.files("R/tar_plans", pattern = "^plan_.*\\.R$", full.names = TRUE)
   for (plan_file in plan_files) source(plan_file)

   # Combine all plans
   c(plan_data_acquisition, plan_quality_control, ...)
   ```

**Why This Matters:**
- **Modularity**: Plans can be reused across projects
- **Testing**: Individual plans can be tested in isolation
- **Collaboration**: Multiple developers can work on different plans
- **Reproducibility**: Clear separation of concerns

## btw MCP Tool Configuration

**Current subset** (saves ~6k tokens vs all tools):
`btw::btw_tools(c('docs', 'pkg', 'files', 'run', 'env', 'session'))`

| Loaded | Category | Purpose |
|--------|----------|---------|
| ✓ | docs | R help pages, vignettes, NEWS |
| ✓ | pkg | check, test, document, coverage |
| ✓ | files | read, write, list, search |
| ✓ | run | execute R code |
| ✓ | env | describe data frames, environment |
| ✓ | session | platform info, package versions |

**CRITICAL DELEGATION RULE FOR BTW TOOLS:**

### ⚠️ btw_tool_run_r HAS NO TIMEOUT - IT WILL HANG FOREVER!

**NEVER call btw_tool_run_r directly for:**
- devtools::test(), check(), build() → Use `verbose-runner` agent
- Any operation expecting >10 lines output → Use `verbose-runner` agent
- Debugging test failures → Use `r-debugger` agent
- shiny::runApp() or launch_dashboard() → WILL HANG (waits for browser)
- Any function that might wait for user input → Use agent with timeout

**NEVER call btw_tool_pkg_* directly** → Always use appropriate agent

**ALWAYS RUN SUBAGENTS IN PARALLEL** when tasks are independent:
```
# GOOD - Parallel execution
Task(test), Task(check), Task(document) in one message

# BAD - Sequential execution
Task(test) then wait, then Task(check) then wait...
```

**Exception:** Simple one-liners, checking values, quick calculations

| Excluded | Why | Alternative |
|----------|-----|-------------|
| git | Use `gert::git_*()` per 9-step workflow | gert R package |
| github | Use `gh::gh()` per 9-step workflow | gh R package |
| agents | Redundant - Task tool has same agents | Task tool subagents |
| cran | Rarely needed for active dev | WebSearch |
| web | Redundant | WebFetch tool |
| ide | Rarely used | - |

**Re-enable if needed:** Edit `~/.claude.json` mcpServers args:
- Add `'git'` if gert isn't working
- Add `'github'` if gh::gh() fails
- Add `'cran'` when searching for new packages

## Package Context for LLMs (pkgctx)

Generate compact API documentation for R/Python packages to provide Claude with function signatures and documentation. **Reduces token usage by ~67%** while preserving essential API information.

### Quick Usage (No Installation Required)

```bash
# Generate context for current package
nix run github:b-rodrigues/pkgctx -- r . --compact > package.ctx.yaml

# Generate context for dependencies
nix run github:b-rodrigues/pkgctx -- r dplyr --compact > .claude/context/dplyr.ctx.yaml
nix run github:b-rodrigues/pkgctx -- r targets --compact --hoist-common-args > .claude/context/targets.ctx.yaml
```

### When to Use pkgctx

- **Before asking Claude about package APIs** - Provide context files in prompts
- **CI/CD integration** - Auto-update context on push, detect API drift
- **Document dependencies** - Keep `.claude/context/` with key package APIs
- **Reduce token usage** - Use `--compact` flag for ~67% reduction

### Integration Pattern

```bash
# Generate contexts for frequently used packages
mkdir -p .claude/context
for pkg in dplyr tidyr purrr gert gh usethis devtools; do
  nix run github:b-rodrigues/pkgctx -- r "$pkg" --compact > ".claude/context/${pkg}.ctx.yaml"
done
```

**Full details:** See `llm-package-context` skill for CI workflows, API drift detection, and advanced usage.

## Session End

1. Commit with `gert` (not bash)
2. Update `.claude/CURRENT_WORK.md`
3. Push to remote
4. If wiki changed: `Rscript R/dev/wiki/sync_wiki.R`
