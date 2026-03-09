# Current Work

## Branch: main

## Completed This Session (2026-03-09)

### Config Migration (from plan)
- Migrated 13 global rules from `~/.claude/rules/` to git-backed `llm/.claude/rules/` with symlink
- Migrated `validate_claude_md.sh` and `session_end_check.sh` to git with symlinks
- Merged CLAUDE.md into AGENTS.md (185 lines, under 200 limit), symlinked
- Merged `/hi` into `/session-start` via symlink
- Created `memory/tool-preferences.md` and updated `memory/architecture.md`

### Skills Creation (Issues #39-#45)
- Created 5 new skills: `dplyr-1.1-patterns`, `rlang-patterns`, `vctrs-patterns`, `s7-oop`, `data-transformation-stack`
- Extended `tidyverse-style` with stringr patterns reference
- Extended `static-api-deployment` with API design patterns reference
- All 7 issues closed

### Skills/Rules Consolidation (72 → 62 skills, 14 → 15 rules)
- 6 skill merges (content moved to references in absorbing skill):
  - gemini-subagent → gemini-cli-codebase-analysis
  - quarto-dynamic-tabsets → quarto-dynamic-content
  - data-wrangling-duckdb + data-engineering-dbt → data-transformation-stack
  - nix-drift-detection → nix-rix-r-environment
  - r-universe-workflows → ci-workflows-github-actions
  - vignette-code-folding → quarto-vignette-format rule
- 4 skills converted to rules: architecture-planning, systematic-debugging, reproducible-visualization, verification-before-completion
- 4 rules consolidated: dashboard-standards, plot-captions + tufte-visualization → visualization-standards, pipeline-choice, model-files
- New rule: `website-index-update` (add project to johngavin.github.io on major version)

### Commits
- `d49b3c9` — config migration
- `d6c32b9` — new skills (closes #39-#45)
- `6db6eb0` — validator regex fix (rollback point for consolidation)
- `0989573` — consolidation (72→62 skills)
- `a216df4` — website-index-update rule

## Status
- Working tree clean
- All validation passes (62 skills, 15 rules, 9 commands, all consistent)

## Pending
- Run `Rscript R/dev/issues/fix_37_audit.R` to audit sibling projects
- Homepage repo has 9 Dependabot vulnerabilities
- ccusage LaunchAgent not installed
