# Skills by Category (65)

Companion to `AGENTS.md`. See `AGENTS.md` for project identity, mandatory rules, and core operating instructions; this file holds only the skill catalogue.

To invoke a skill, the user types `/<skill-name>` or asks for the topic and the relevant skill is auto-selected.

## Mandatory (always apply)
- `adversarial-qa` — QA protocol with severity tiers
- `quality-gates` — Bronze/Silver/Gold scoring with per-issue point-deduction table
- `r-package-workflow` — 9-step PR workflow
- `test-driven-development` — RED-GREEN-REFACTOR
- `nix-rix-r-environment` — Nix/rix shell management + drift detection
- `llm-package-context` — pkgctx generation
- `readme-qmd-standard` — README.qmd conventions
- `subagent-delegation` — When/how to delegate to agents
- `spec-bundled-skills` — Bundled skill specifications

## R Package Development
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

## Data & Analysis
- `missing-data-handling` — Missing data patterns
- `data-validation-pointblank` — pointblank validation
- `data-transformation-stack` — DuckDB + Arrow + dbt stack
- `eda-workflow` — Exploratory data analysis
- `modeling-baselines` — Baseline model patterns + model code checklist
- `model-evaluation-calibration` — Model assessment
- `survival-analysis` — Time-to-event analysis: KM curves, Cox PH, parametric TTE, censoring
- `analysis-rationale-logging` — Decision logging
- `gdc-genomics` — GDC/genomics data
- `erddap-ocean-data` — ERDDAP ocean data access

## Targets & Pipelines
- `targets-pipeline-spec` — Pipeline architecture + tool choice
- `targets-vignettes` — Vignette data pre-computation
- `crew-operations` — crew worker patterns
- `parallel-processing` — mirai, parallel computing

## Shiny & Web
- `shiny-bslib` — bslib Bootstrap 5 components (incl. 0.11.0+ Toolbars)
- `shiny-async-patterns` — ExtendedTask, async
- `shiny-module-data-sharing` — Module data-sharing patterns (reactiveValues, R6, gargoyle)
- `shinylive-deployment` — Shinylive packaging
- `shinylive-quarto` — Shinylive in Quarto vignettes
- `brand-yml` — Brand styling for Shiny/Quarto
- `browser-user-testing` — Browser-based testing
- `plumber2-web-api` — Plumber API development

## Quarto & Documentation
- `quarto-websites` — Quarto website structure
- `quarto-dashboards` — Quarto dashboards
- `quarto-dynamic-content` — Dynamic Quarto features + tabsets
- `quarto-alt-text` — Accessibility alt text
- `webr-multi-page-vignettes` — WebR multi-page vignettes
- `describe-design` — Codebase architecture docs
- `closeread-scrollytelling` — Sticky-panel scrollytelling with closeread extension

## Prose Quality
- `deslop` — Remove AI writing patterns from prose (vignettes, emails, READMEs, captions, issues). Overrides: captions MUST have units+source+dynamic values; code quality always paramount

## DevOps & CI
- `ci-workflows-github-actions` — GitHub Actions + R-universe workflows
- `pkgdown-deployment` — pkgdown site deployment
- `static-api-deployment` — Static API hosting

## Project Management
- `project-telemetry` — Pipeline metrics + logging
- `project-review` — Project review workflow
- `writing-plans` — Plan document creation
- `executing-plans` — Plan execution
- `code-review-workflow` — PR review process
- `context-control` — Context window management
- `requirements-spec` — MUST/SHOULD/MAY requirements before complex tasks
- `per-project-claude-md` — Slim project-level config template (overrides global CLAUDE.md)
- `skill-authoring` — Checklist and template for creating new skills (quality gate)

## AI/LLM Tools
- `gemini-cli-codebase-analysis` — Gemini CLI + subagent patterns
- `ai-assisted-analysis` — AI-assisted data analysis
- `huggingface-r` — HuggingFace from R
- `mcp-servers` — MCP server management
- `hooks-automation` — Hook automation patterns

## Specialized
- `mlops-deployment` — MLOps patterns

## Adding a new skill

When a new skill is added under `.claude/skills/<name>/SKILL.md`:

1. Add a one-line bullet to the appropriate section above (name + 1-line description)
2. Bump the count in the `# Skills by Category (N)` heading
3. Bump the count in `AGENTS.md`'s `## Skills (link to this file) (N)` pointer (keep the two counts in sync)
4. Mention the new skill in any relevant rule file's `## Related` block

The `skill_quality_onwrite.sh` hook enforces the 500-line per-skill ceiling.
