# Agent Guide for R Package Development

Essential rules for R package development with Nix, rix, and reproducible workflows.
For detailed guidance, invoke the relevant skill. For tool preferences, see `memory/tool-preferences.md`.

## Core Rules

**Session Start:** `echo $IN_NIX_SHELL` (1/impure), `which R` (/nix/store/...). If not: `caffeinate -i ~/docs_gh/rix.setup/default.sh`. Check `CHANGELOG.md`, `git status`, open issues.

**Git/GitHub — R packages ONLY:** `gert::git_add()`, `git_commit()`, `git_push()`; `usethis::pr_init()`, `pr_push()`; `gh::gh()`. **In bash, NEVER `cd <dir> && git ...` (triggers bare-repo approval prompt that bypassPermissions does NOT bypass). ALWAYS `git -C <dir> ...`.** See `git-no-compound-cd` rule.

**Nix — Shell Architecture (CRITICAL):** The USER stays in the **global dev shell** at all times. The global shell does NOT have project-specific packages (e.g., pdfplumber, lme4, brms). Agents/subshells MUST enter the **project's own nix shell** for project-specific work: `nix-shell /absolute/path/to/project/default.nix --run "cmd"`. NEVER assume packages from `default.nix` are available in the outer shell. NEVER use relative paths (`nix-shell default.nix`) — always absolute. If `nix-shell` build fails (nixpkgs regression), fall back to pip venv: `/usr/bin/python3 -m venv /tmp/venv && /tmp/venv/bin/pip install pkg`. See `nix-agent-shell-protocol` rule. Verify global shell: `echo $IN_NIX_SHELL` (1/impure). **NEVER** `install.packages()`/`devtools::install()`/`pak::pkg_install()` in Nix.

**Errors:** NEVER speculate. READ error, QUOTE it, propose fixes. **R:** 4.5.x. **Deletion:** NEVER rm untracked >1MB without listing, age-check, user confirm (`safe-deletion` rule).

**Data Privacy:** PHI/confidential data NEVER to public repos without approval (renews each minor version).

**Versioning:** Semver. Patch=bugfix, Minor=feature, Major=breaking. Pre-1.0: breaking=minor bump. **NEVER ship `0.0.0.9000` to users.** Bump to `0.1.0` before first public deploy (GH Pages, pkgdown, vignette).

**Session:** Start: read `CHANGELOG.md`, avoid failed approaches. End: commit -> append CHANGELOG -> push. **Commits:** After every meaningful unit. Never break tests. Git log = lab notes. Speed must not silence errors.

**Pipeline Validation (ALL PROJECTS):** Before every commit: `parse("_targets.R")` MUST succeed. Code-as-string targets MUST `parse(text=code)` for R or `bash -n` for bash.

**Code Quality (ast-grep):** 8 rules at `~/.config/ast-grep/rules/`. Run `~/.claude/scripts/r_code_check.sh R/` before commit. Banned: `suppressWarnings(as.*)`, silent `tryCatch`, raw SQL, `stop()`, `install.packages()`. Use `$$$` metavar (NOT `___`). For structural search prefer `cd ~/.config/ast-grep && ast-grep run -p 'pattern' dir/` over grep.

**Explorations:** `explorations/` is a scratch area for research experiments. Minimum score 60 (vs 80 for production). Graduate to `R/` or `vignettes/` at >= 80. Archive abandoned explorations with a reason comment. See `explorations/CONVENTIONS.md`.

**Knowledge Base (raw/wiki/outputs):** Use `knowledge-base-wiki` skill. Central hub at `~/docs_gh/llm/knowledge/` (LOCAL git only — NEVER push to GitHub, `PRIVATE` marker + pre-push hook block). raw/ is append-only (enforced by `file_protection.sh`), wiki/ requires `## Sources` section, AI-inferred claims tagged `> ⚠ AI-inferred:`, cross-wiki links use `[[topic]]` syntax. T1 health check on every Edit/Write via `wiki_health_onwrite.sh`. Run `/wiki-health` after batch updates. Use `wiki-curator` agent to compile, `critic` (wiki validation mode) for adversarial review.

**Mandatory skills:** `adversarial-qa`, `quality-gates`, `r-package-workflow`, `test-driven-development`, `nix-rix-r-environment`, `llm-package-context`, `readme-qmd-standard`, `subagent-delegation`, `spec-bundled-skills`, `knowledge-base-wiki`.
**Mandatory rules:** `systematic-debugging`, `verification-before-completion`, `btw-timeouts`, `orchestrator-protocol`, `provenance-mandatory`, `raw-folder-readonly`, `confidence-markers`, `wiki-storage-policy`, `git-no-compound-cd`, `look-ahead-bias-prevention`, `nix-agent-shell-protocol`.

**MCP r-btw — ZERO TOLERANCE:** NEVER call `btw_tool_run_r/pkg_test/pkg_check/pkg_coverage/pkg_document/pkg_load_all`. ALL R via `Bash("timeout N Rscript -e '...'")`. Safe: `btw_tool_docs_*`, `btw_tool_files_*`, `btw_tool_sessioninfo_*`, `btw_tool_env_describe_*`. See `btw-timeouts` rule.

**Shiny UI:** NEVER use `value_box()` or similar large KPI boxes - they waste space. Use compact two-column tables instead (Metric | Value). Time series plots MUST have a range slider and default to last 3 months view.

**Shinylive/WebR:** Long computations MUST use JS round-trip batching (NOT `invalidateLater()`). See `shinylive-webr-nonblocking` rule. `proc.time()` does not advance in WASM. Service workers cache aggressively — change port when testing.

**DuckDB queries:** Use `duckplyr` (tidyverse syntax) instead of raw SQL strings where possible. Reserve SQL for complex operations not expressible in dplyr.

## Agents (12)

| Agent | Model | Use When |
|-------|-------|----------|
| `quick-fix` | haiku | Typos, renames, version bumps, obvious syntax fixes |
| `critic` | sonnet | Read-only adversarial review (cannot edit files) |
| `fixer` | sonnet | Apply fixes from critic reports (read-write, cannot self-approve) |
| `r-debugger` | sonnet | Debug R package issues (test failures, R CMD check) |
| `targets-runner` | sonnet | Run tar_make(), inspect pipeline state |
| `reviewer` | sonnet | Code review PRs for R package quality |
| `nix-env` | sonnet | Diagnose Nix shell problems, update deps |
| `shiny-async-debugger` | sonnet | Debug async/crew/ExtendedTask issues |
| `data-quality-guardian` | sonnet | Data validation, pointblank |
| `data-engineer` | sonnet | SQL transforms, dbt pipelines |
| `shinylive-builder` | sonnet | Build/test Shinylive WASM vignettes |
| `wiki-curator` | sonnet | Compile raw/ source material into wiki/ |

## Skills by Category (63)

### Mandatory (always apply)
- `adversarial-qa` — QA protocol with severity tiers
- `quality-gates` — Bronze/Silver/Gold scoring with per-issue point-deduction table
- `r-package-workflow` — 9-step PR workflow
- `test-driven-development` — RED-GREEN-REFACTOR
- `nix-rix-r-environment` — Nix/rix shell management + drift detection
- `llm-package-context` — pkgctx generation
- `readme-qmd-standard` — README.qmd conventions
- `subagent-delegation` — When/how to delegate to agents
- `spec-bundled-skills` — Bundled skill specifications

### R Package Development
- `cli-package` — cli inline markup, conditions, progress
- `dplyr-1.1-patterns` — .by=, pick(), reframe(), join_by(), consecutive_id()
- `rlang-patterns` — {{}} embrace, injection, defusing, try_fetch()
- `vctrs-patterns` — Custom vector classes, vec_cast/ptype2, vec_arith
- `s7-oop` — Modern R OOP: new_class(), generics, S7 vs R6/S4
- `lifecycle-management` — deprecate_soft/warn/stop workflow
- `cran-submission` — CRAN-specific extra checks
- `testthat-patterns` — testthat 3 BDD, snapshots, mocking
- `tidyverse-style` — Code style + air formatter + stringr patterns
- `r-cmd-check-fixes` — Common R CMD check solutions
- `lazy-evaluation-guide` — NSE, tidy eval patterns
- `r-cli-app` — CLI apps with Rapp package

### Data & Analysis
- `missing-data-handling` — Missing data patterns
- `data-validation-pointblank` — pointblank validation
- `data-transformation-stack` — DuckDB + Arrow + dbt stack
- `eda-workflow` — Exploratory data analysis
- `modeling-baselines` — Baseline model patterns + model code checklist
- `model-evaluation-calibration` — Model assessment
- `analysis-rationale-logging` — Decision logging
- `gdc-genomics` — GDC/genomics data
- `erddap-ocean-data` — ERDDAP ocean data access

### Targets & Pipelines
- `targets-pipeline-spec` — Pipeline architecture + tool choice
- `targets-vignettes` — Vignette data pre-computation
- `crew-operations` — crew worker patterns
- `parallel-processing` — mirai, parallel computing

### Shiny & Web
- `shiny-bslib` — bslib Bootstrap 5 components
- `shiny-async-patterns` — ExtendedTask, async
- `shiny-module-data-sharing` — Module data-sharing patterns (reactiveValues, R6, gargoyle)
- `shinylive-deployment` — Shinylive packaging
- `shinylive-quarto` — Shinylive in Quarto vignettes
- `brand-yml` — Brand styling for Shiny/Quarto
- `browser-user-testing` — Browser-based testing
- `plumber2-web-api` — Plumber API development

### Quarto & Documentation
- `quarto-websites` — Quarto website structure
- `quarto-dashboards` — Quarto dashboards
- `quarto-dynamic-content` — Dynamic Quarto features + tabsets
- `quarto-alt-text` — Accessibility alt text
- `webr-multi-page-vignettes` — WebR multi-page vignettes
- `describe-design` — Codebase architecture docs

### Prose Quality
- `deslop` — Remove AI writing patterns from prose (vignettes, emails, READMEs, captions, issues). Overrides: captions MUST have units+source+dynamic values; code quality always paramount

### DevOps & CI
- `ci-workflows-github-actions` — GitHub Actions + R-universe workflows
- `pkgdown-deployment` — pkgdown site deployment
- `static-api-deployment` — Static API hosting

### Project Management
- `project-telemetry` — Pipeline metrics + logging
- `project-review` — Project review workflow
- `writing-plans` — Plan document creation
- `executing-plans` — Plan execution
- `code-review-workflow` — PR review process
- `context-control` — Context window management
- `requirements-spec` — MUST/SHOULD/MAY requirements before complex tasks
- `per-project-claude-md` — Slim project-level config template (overrides global CLAUDE.md)

### AI/LLM Tools
- `gemini-cli-codebase-analysis` — Gemini CLI + subagent patterns
- `ai-assisted-analysis` — AI-assisted data analysis
- `huggingface-r` — HuggingFace from R
- `mcp-servers` — MCP server management
- `hooks-automation` — Hook automation patterns

### Specialized
- `mlops-deployment` — MLOps patterns

## Commands (14)

`/hi`(`/session-start`), `/bye`(`/session-end`), `/check`, `/ctx-check`, `/pr-status`, `/cleanup`, `/issue-triage`, `/new-issue`, `/triage`, `/wiki-health`, `/wiki-promote`, `/write-alt-text`

## Rules (59)

Core: `auto-delegation`, `architecture-planning`, `orchestrator-protocol`, `systematic-debugging`, `verification-before-completion`. Nix: `nix-agent-shell-protocol`, `nix-nested-shell-isolation`. MCP: `btw-timeouts`. Git: `git-no-compound-cd`, `safe-deletion`. Data: `data-in-packages`, `data-validation-timeseries`, `duckdb-non-determinism`, `duckdb-security`, `duckdplyr-not-sql`, `never-drop-missing-stations`. Stats: `statistical-reporting`, `robust-statistics`, `half-life-decay`, `composite-alert-scoring`, `suppress-warnings-antipattern`. Backtest: `look-ahead-bias-prevention`, `backtest-robustness`, `backtest-partitions`, `backtesting-assumptions`, `execution-delay-sensitivity`, `position-sizing-guardrails`, `risk-regime-evaluation`, `robustness-testing`, `snapshot-tests-mandatory`, `strategy-vignette-template`. Viz: `diagram-generation`, `visualization-diagrams`, `visualization-standards`, `reproducible-visualization`, `dynamic-prose-values`. Quarto: `quarto-vignette-data`, `quarto-vignette-evidence`, `quarto-vignette-format`, `quarto-vignette-layout`, `quarto-vignette-validation`, `vignette-targets-export`. Shiny: `module-isolation`, `shiny-module-data-sharing`, `shinylive-webr-nonblocking`. Pipeline: `qa-targets-pipeline`, `ctx-yaml-cache`. Knowledge: `glossary-management`, `wiki-staleness-check`, `wiki-frontmatter`. Medical: `medical-data-anonymization`, `medical-etl-quality`. Other: `website-index-update`, `t-lang-r-package`, `huggingface-upload`.

## Hooks (7 scripts, 5 event hooks)

`session_init.sh`(SessionStart), `context_survival.sh`(compact/resume+PreCompact), `file_protection.sh`(PreToolUse:Edit|Write), `context_monitor.sh`(PostToolUse:Bash|Task), `wiki_health_onwrite.sh`(PostToolUse:Edit|Write), `session_stop.sh`(Stop). Audit: `agents_md_audit.sh`, `r_code_check.sh`, `qa_gate_check.sh`, `vignette_check.sh`.

## Memory (14 files)

`MEMORY.md`(index), `agent-patterns.md`, `architecture.md`, `ci-strategy.md`, `nix-operations.md`, `shinylive-issues.md`, `tool-preferences.md`, `feedback_safe-deletion.md`, `feedback_never-edit-default-nix.md`, `feedback_nix-shell-portability.md`, `feedback_no-compound-cd.md`, `feedback_knowledge-base-discipline.md`, `feedback_github-pages-user-sites.md`, `feedback_ast-grep-lessons.md`
