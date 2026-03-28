# Changelog

Cumulative lab notes. Track completed work, **failed approaches**, accuracy checkpoints, and known limitations. Git-tracked — survives across machines and sessions.

Convention: newest entries at top. Each entry has a date, what was done, and why.

## 2026-03-21 – 2026-03-28 (mega session)

### Completed
- DuckDB security rule from Willison research (closes #53)
- PHI detection scanner — regex + statistical (closes #54)
- pkgctx centralized architecture — version-stamped, cross-project, auto-sync
- Hook consolidation 12→8, session_init.sh combined R phases
- Orchestrator protocol, critic-fixer agents, context survival hooks
- R-universe build status at session start (Phase 6)
- CI optimization: 7 workflows deleted, frequencies reduced, paths filters — ~4,700 min/month saved
- plan_pkgdown.R + plan_pkgctx.R pushed to all 7 projects
- r-quantities ecosystem (units, errors, quantities) in vctrs-patterns skill
- Reproducibility/verification gap analysis — 5 gaps filled (statistical-reporting, data provenance, versioning, external validation, numerical stability)
- CHANGELOG.md convention + /session-start reads it + /session-end appends
- quarto-alt-text: ggplot2→description mapping, fig-cap complementarity, /write-alt-text command
- crew+Shiny: complete runnable apps, UX framing in decision matrix
- Autoresearch patterns: structured experiment commits, auto-revert, risk-graduated phases, eval/experiment separation
- safe-deletion rule after 522MB worktree deletion incident
- roborev integration: hooks + .roborev.toml on 6 projects + notification hooks
- agentsview -no-browser fix + launchd plist
- /ctx-check global command
- CLAUDE.md created for micromort, randomwalk, irishbuoys; ctx section added to all 7 projects
- micromort issues: #63 (Shiny explorer), #64 (units package)

### Failed Approaches
- `grep -oP` in hooks — Perl regex not in nix grep. Use `sed` or `grep -oE`.
- `sed -i ''` — macOS syntax fails with GNU sed in nix. Use Claude Code Edit tool.
- `stat -f '%Sm'` — macOS stat not available in nix. Use R `file.mtime()`.
- pkgctx timeout 120s too short for dplyr (45KB). Bumped to 300s.
- Non-versioned ctx filenames caused cross-project overwrites. Fixed: `{pkg}@{version}.ctx.yaml`.
- Deleted 522MB agent worktree without verifying content. Now have safe-deletion rule.
- llm-package-context SKILL said `.claude/context/` but central cache is at `~/docs_gh/.../inst/ctx/external/`. Sessions wrote ad-hoc code checking locally, found 0. Fixed skill + created /ctx-check command.
- session_init.sh had no timeout + 3 separate Rscript startups (~8s). Combined into single Rscript + added 30s timeout.
- `roborev status | head -5` caused SIGPIPE (exit 141) killing the hook. Fixed: capture full output first, then filter.
- CLAUDE.md instructions are passive — Claude ignores them when writing ad-hoc code. Slash commands (/ctx-check) are the only reliable way to force correct code paths.

### Accuracy / Metrics
- Config: 28 rules, 65 skills, 10 agents, 11 commands, 8 hooks
- llm ctx coverage: 100% (26/26 deps)
- CI: ~4,700 min/month saved (from ~13,300 to ~8,600 projected)
- R-universe: 5 OK, 1 failing (micromort)
- roborev: 180 completed reviews, daemon healthy

### Known Limitations
- Other projects still have missing ctx (coMMpass 26, football 21, randomwalk 16) — generated on first session in each project
- pkgctx generates from latest CRAN, not pinned nix version — OTHER_VERSION status
- No project-level CLAUDE.md for llm itself (uses AGENTS.md)
- 2 rules >150 lines (vignette-targets-export 171, quarto-vignette-format)
- 2 rules missing YAML frontmatter (medical-data-anonymization, medical-etl-quality)

## 2026-03-25

### Completed
- Statistical reporting rule (effect sizes before p-values, multiple comparisons)
- Data provenance + external source validation in data-validation-timeseries rule
- Data versioning in data-in-packages rule
- Numerical stability attacks (Category 11) in adversarial-qa skill
- CHANGELOG.md convention established across all projects

### Failed Approaches
- (none yet — this section records dead ends so future sessions don't retry them)

### Accuracy / Metrics
- Config: 27 rules, 65 skills, 10 agents, 10 commands (all consistent)
- CI: ~4,700 min/month saved by removing redundant workflows + reducing frequency
- ctx cache: 60 versioned files, 8 missing for llm project

### Known Limitations
- pkgctx generates ctx from latest CRAN source, not pinned nix version — OTHER_VERSION status
- ctx_sync runs sequentially, not yet parallelised via crew
- No project-level CLAUDE.md for micromort, coMMpass, football, crypto

## 2026-03-21 – 2026-03-24

### Completed
- DuckDB security hardening rule (Willison research)
- PHI detection scanner (regex + statistical)
- pkgctx centralized architecture (version-stamped, cross-project)
- Hook consolidation (12 → 8)
- Orchestrator protocol, critic-fixer agents, context survival hooks
- R-universe build status check at session start
- CI optimization: deleted 7 workflows, reduced frequencies, paths filters
- plan_pkgdown.R pushed to all 6 projects
- r-quantities ecosystem (units, errors, quantities) added to vctrs-patterns skill
- micromort issues: #63 (Shiny explorer app), #64 (adopt units package)

### Failed Approaches
- `grep -oP` in hooks — Perl regex not available in nix grep. Fixed: use `sed` throughout
- pkgctx timeout 120s too short for dplyr (45KB ctx). Fixed: bumped to 300s
- Non-versioned ctx filenames caused cross-project overwrites. Fixed: `{pkg}@{version}.ctx.yaml`

### Accuracy / Metrics
- R-universe: 5 OK, 1 failing (micromort)
- Quality gates: irishbuoys, micromort, millsratio, llmtelemetry have plan_qa_gates.R
