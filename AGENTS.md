# Agent Guide for R Package Development

Essential rules for R package development with Nix, rix, and reproducible workflows.
For detailed guidance, invoke the relevant skill. For tool preferences, see `memory/tool-preferences.md`.

## Core Rules

**Session Start:** `echo $IN_NIX_SHELL` (1/impure), `which R` (/nix/store/...). If not: `caffeinate -i ~/docs_gh/rix.setup/default.sh`. Check `CHANGELOG.md`, `git status`, open issues.

**Git/GitHub — R packages ONLY:** `gert::git_add()`, `git_commit()`, `git_push()`; `usethis::pr_init()`, `pr_push()`; `gh::gh()`. **In bash, NEVER `cd <dir> && git ...` (triggers bare-repo approval prompt that bypassPermissions does NOT bypass). ALWAYS `git -C <dir> ...`.** See `git-no-compound-cd` rule.

**Nix:** One persistent shell. Verify: `echo $IN_NIX_SHELL`. **NEVER** `install.packages()`/`devtools::install()`/`pak::pkg_install()` in Nix.

**Errors:** NEVER speculate. READ error, QUOTE it, propose fixes. **R:** 4.5.x. **Deletion:** NEVER rm untracked >1MB without listing, age-check, user confirm (`safe-deletion` rule).

**Data Privacy:** PHI/confidential data NEVER to public repos without approval (renews each minor version).

**Versioning:** Semver. Patch=bugfix, Minor=feature, Major=breaking. Pre-1.0: breaking=minor bump.

**Session:** Start: read `CHANGELOG.md`, avoid failed approaches. End: commit -> append CHANGELOG -> push. **Commits:** After every meaningful unit. Never break tests. Git log = lab notes. Speed must not silence errors.

**Pipeline Validation (ALL PROJECTS):** Before every commit: `parse("_targets.R")` MUST succeed. Code-as-string targets MUST `parse(text=code)` for R or `bash -n` for bash.

**Code Quality (ast-grep):** 8 rules at `~/.config/ast-grep/rules/`. Run `~/.claude/scripts/r_code_check.sh R/` before commit. Banned: `suppressWarnings(as.*)`, silent `tryCatch`, raw SQL, `stop()`, `install.packages()`. Use `$$$` metavar (NOT `___`). For structural search prefer `cd ~/.config/ast-grep && ast-grep run -p 'pattern' dir/` over grep.

**Knowledge Base (raw/wiki/outputs):** Use `knowledge-base-wiki` skill. Central hub at `~/docs_gh/llm/knowledge/` (LOCAL git only — NEVER push to GitHub, `PRIVATE` marker + pre-push hook block). raw/ is append-only (enforced by `file_protection.sh`), wiki/ requires `## Sources` section, AI-inferred claims tagged `> ⚠ AI-inferred:`, cross-wiki links use `[[topic]]` syntax. T1 health check on every Edit/Write via `wiki_health_onwrite.sh`. Run `/wiki-health` after batch updates. Use `wiki-curator` agent to compile, `critic` (wiki validation mode) for adversarial review.

**Mandatory skills:** `adversarial-qa`, `quality-gates`, `r-package-workflow`, `test-driven-development`, `nix-rix-r-environment`, `llm-package-context`, `readme-qmd-standard`, `subagent-delegation`, `spec-bundled-skills`, `knowledge-base-wiki`.
**Mandatory rules:** `systematic-debugging`, `verification-before-completion`, `btw-timeouts`, `orchestrator-protocol`, `provenance-mandatory`, `raw-folder-readonly`, `confidence-markers`, `wiki-storage-policy`, `git-no-compound-cd`.

**MCP r-btw — ZERO TOLERANCE:** NEVER call `btw_tool_run_r/pkg_test/pkg_check/pkg_coverage/pkg_document/pkg_load_all`. ALL R via `Bash("timeout N Rscript -e '...'")`. Safe: `btw_tool_docs_*`, `btw_tool_files_*`, `btw_tool_sessioninfo_*`, `btw_tool_env_describe_*`. See `btw-timeouts` rule.

**Shiny UI:** NEVER use `value_box()` or similar large KPI boxes - they waste space. Use compact two-column tables instead (Metric | Value). Time series plots MUST have a range slider and default to last 3 months view.

**DuckDB queries:** Use `duckplyr` (tidyverse syntax) instead of raw SQL strings where possible. Reserve SQL for complex operations not expressible in dplyr.

## Agents (10)

| Agent | Use When |
|-------|----------|
| `critic` | Read-only adversarial review (cannot edit files) |
| `fixer` | Apply fixes from critic reports (read-write, cannot self-approve) |
| `r-debugger` | Debug R package issues (test failures, R CMD check) |
| `targets-runner` | Run tar_make(), inspect pipeline state |
| `reviewer` | Code review PRs for R package quality |
| `nix-env` | Diagnose Nix shell problems, update deps |
| `shiny-async-debugger` | Debug async/crew/ExtendedTask issues |
| `data-quality-guardian` | Data validation, pointblank |
| `data-engineer` | SQL transforms, dbt pipelines |
| `shinylive-builder` | Build/test Shinylive WASM vignettes |

## Skills by Category (61)

### Mandatory (always apply)
- `adversarial-qa` — QA protocol with severity tiers
- `quality-gates` — Bronze/Silver/Gold scoring
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

### AI/LLM Tools
- `gemini-cli-codebase-analysis` — Gemini CLI + subagent patterns
- `ai-assisted-analysis` — AI-assisted data analysis
- `huggingface-r` — HuggingFace from R
- `mcp-servers` — MCP server management
- `hooks-automation` — Hook automation patterns

### Specialized
- `mlops-deployment` — MLOps patterns

## Commands (11)

| Command | Purpose |
|---------|---------|
| `/session-start` | Initialize session (check env, status, config audit) |
| `/session-end` | End session (commit, push, summary) |
| `/bye` | Alias for /session-end |
| `/check` | Run document(), test(), check() |
| `/pr-status` | Check PR and CI status |
| `/cleanup` | Review and simplify work |
| `/issue-triage` | List issues by difficulty |
| `/new-issue` | Create issue with branch |
| `/triage` | Quick issue analysis |
| `/write-alt-text` | Generate fig-alt for all vignette figures |
| `/hi` | Alias for /session-start |

## Rules (28)

| Rule | Enforces |
|------|----------|
| `architecture-planning` | Mandatory planning phase before coding |
| `btw-timeouts` | MCP tool timeout limits |
| `ctx-yaml-cache` | Context YAML caching |
| `data-in-packages` | Data storage conventions |
| `data-validation-timeseries` | Time series validation |
| `diagram-generation` | Mermaid diagram generation patterns |
| `duckdb-non-determinism` | DuckDB parallelism pitfalls (window order, fan-out, dedup) |
| `duckdb-security` | DuckDB connection hardening, file/network access, resource limits |
| `duckdplyr-not-sql` | Use duckdplyr not raw SQL |
| `glossary-management` | Glossary term management |
| `module-isolation` | Module isolation patterns |
| `shiny-module-data-sharing` | Module data-sharing patterns and anti-patterns |
| `orchestrator-protocol` | Auto-coordinate agents after plan approval |
| `quarto-vignette-data` | Vignette data rules (no sampling, pre-compute, zero computation) |
| `quarto-vignette-evidence` | Claims require evidence, content quality rules |
| `quarto-vignette-format` | Vignette format rules (headings, tables, code-as-targets, dashboards) |
| `quarto-vignette-layout` | Full-width CSS, dashboard standards, code-folding, broken links |
| `quarto-vignette-validation` | Post-publish validation, missing evidence, dark mode |
| `reproducible-visualization` | Plot reproducibility via targets |
| `safe-deletion` | Pre-deletion verification: size, age, diff, user approval for >1MB |
| `statistical-reporting` | Effect sizes, multiple comparisons, precision, exploratory vs confirmatory |
| `suppress-warnings-antipattern` | Ban suppressWarnings(as.*) with solutions |
| `systematic-debugging` | Scientific method debugging (Hypothesis-Experiment-Conclusion) |
| `verification-before-completion` | No completion claims without evidence |
| `vignette-targets-export` | Pre-computed RDS for CI vignette builds |
| `visualization-diagrams` | Mermaid/flowchart diagram standards, arrow styling, Plotly theme |
| `visualization-standards` | Tufte/Gelman principles + caption standards |
| `website-index-update` | Add project to johngavin.github.io on major version |

## Hooks (8 registered, 4 scripts)

| Hook | Event |
|------|-------|
| `session_init.sh` | SessionStart — env, mappings, sizes, skill audit |
| `context_survival.sh restore` | SessionStart(compact\|resume) |
| `context_survival.sh save` | PreCompact |
| `file_protection.sh` | PreToolUse(Edit\|Write) — blocks NAMESPACE/man/, warns config |
| `context_monitor.sh` | PostToolUse(Bash\|Task) — context % warnings |
| `session_stop.sh` | Stop — memory health, uncommitted config, decision log |

**Scripts** (`.claude/scripts/`, manually callable): `r_code_check.sh`, `qa_gate_check.sh`, `record_prediction.sh`, `vignette_check.sh`

## Memory Files (8)
`MEMORY.md` (index), `agent-patterns.md`, `architecture.md`, `ci-strategy.md`, `feedback_safe-deletion.md`, `nix-operations.md`, `shinylive-issues.md`, `tool-preferences.md`
