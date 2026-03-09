# Current Work

## Branch: main

## Session 2026-03-09 (continued)

### DuckDB Non-Determinism Rule
- Added 5 pitfalls to `duckdplyr-not-sql.md` from ThinkR article analysis:
    - Window functions without `window_order()`
    - `distinct(.keep_all = TRUE)` and `slice_min/max` `with_ties` trap
    - Inequality join fan-out (with detection pattern)
    - Synthetic duplicate rows and `union_all()` source tagging
    - Type-dependent deduplication (split/dedup/recombine)
- Added code review checklist and multi-run detection code
- Commits: `ee7606d`, `2de957b`

### Rule Enhancements
- `quarto-vignette-format.md`: sections 9 (sub-bullet formatting), 10 (404 checks), 11 (claims require evidence)
- `visualization-standards.md`: plotly legend/theme contrast rules
- Commit: `fdacee3`

### Previous Session Completed Items
- Config migration (rules, scripts, CLAUDE.md → AGENTS.md)
- 5 new skills created (issues #39-#45 closed)
- Skills consolidation (72→62 skills)
- `/bye` command (symlink to `/session-end`)
- fix_37_audit.R run (113 findings across 12 projects)
- Dependabot vulnerabilities fixed in johngavin.github.io
- ccusage LaunchAgent installed

## Status
- Working tree clean (llm repo)
- llmtelemetry PR #22 open with merge conflict — needs rebase

## Pending
- Rebase and merge llmtelemetry PR #22 (commit stats tab + data API)
