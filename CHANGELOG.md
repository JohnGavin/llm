# Changelog

Cumulative lab notes. Track completed work, **failed approaches**, accuracy checkpoints, and known limitations. Git-tracked — survives across machines and sessions.

Convention: newest entries at top. Each entry has a date, what was done, and why.

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
