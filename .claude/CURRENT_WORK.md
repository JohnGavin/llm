# Current Work

## Branch: main

## Completed This Session (2026-03-07)

### Issue #37 (missing data handling) — plan implementation
- Created global rule `~/.claude/rules/no-suppress-coercion.md` with path-matching YAML
- Created hook `.claude/hooks/r_code_check.sh` for suppressWarnings/read.csv checks
- Appended Research Notes to `~/.claude/skills/missing-data-handling/SKILL.md`
- Created cross-project audit script `R/dev/issues/fix_37_audit.R`

### Issue #38 — R_LIBS_SITE nix segfault docs
- Added nested shell R_LIBS_SITE contamination section to `memory/nix-operations.md`
- Updated MEMORY.md index with both segfault categories

### Issue #28 — Projects page for homepage
- Created `content/projects.md` in johngavin.github.io (irishbuoys, footbet, llm)
- Added Projects menu entry in `config.toml`
- Pushed to remote (deploys via Netlify)

### Issue #19 — ccusage refresh frequency
- Already resolved (plist already had 12-hour interval)
- Note: LaunchAgent not installed in ~/Library/LaunchAgents/

### Issue #13 — shiny-async-debugger agent
- Created `.claude/agents/shiny-async-debugger.md`
- 5-phase protocol, 5 common failure patterns, sonnet model

## Status
- All issues closed (0 open)
- Both repos (llm, johngavin.github.io) clean and pushed

## Pending
- Run `Rscript R/dev/issues/fix_37_audit.R` to audit sibling projects
- Homepage repo has 9 Dependabot vulnerabilities
- ccusage LaunchAgent not installed
- 9 skills >500 lines could be slimmed
