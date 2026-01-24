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
| 7 | Wait for CI | Monitor ALL workflows |
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

*Documentation:* `pkgdown-deployment`, `project-telemetry`, `project-review`

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

## Custom Commands

- `/session-start` - Initialize session
- `/session-end` - End session (commit, push)
- `/check` - Run document(), test(), check()
- `/pr-status` - Check PR and CI status
- `/cleanup` - Review and simplify work

## File Structure

```
R/              # Package code
R/dev/issues/   # Fix scripts (include in PRs)
R/tar_plans/    # Targets plans
vignettes/      # Quarto files
plans/          # PLAN_*.md working documents
```

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
- **NEVER call btw_tool_run_r directly for:**
  - devtools::test(), check(), build() → Use `verbose-runner` agent
  - Any operation expecting >10 lines output → Use `verbose-runner` agent
  - Debugging test failures → Use `r-debugger` agent
- **NEVER call btw_tool_pkg_* directly** → Always use appropriate agent
- **Exception:** Simple one-liners, checking values, quick calculations

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
