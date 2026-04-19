# Changelog

Cumulative lab notes. Track completed work, **failed approaches**, accuracy checkpoints, and known limitations. Git-tracked — survives across machines and sessions.

Convention: newest entries at top. Each entry has a date, what was done, and why.

## 2026-04-19

### Completed
- **Infrastructure vignette (#64):** 5 mermaid diagrams with clickable nodes (38 click directives), 5 figcaptions, 11 tables, irishbuoys pipeline case study (19 plans, ~294 targets). Dark navbar. Live at gh-pages.
- **Telemetry RDS export (#64):** 34 targets exported to `inst/extdata/vignettes/`. NULLs reduced 24→8. DT widgets stripped to data.frames (Nix path fix). safe_tar_read re-wraps as DT at render time.
- **AGENTS.md sync (#68):** Counts updated (12a/62s/59r/14c/14m). `agents_md_audit.sh` wired into session_init Phase 10. Warns on drift at every session start.
- **Day-grouped block activity (#65):** `get_block_history(days=5, grouped=TRUE)` — day headers with weekday + totals, blocks indented. 108 tests pass.
- **Issues closed:** #46 (socviz — rules already cover it), #51 (qa_duckdb_determinism template), #52 (shiny-module rule already exists), #58 (skill examples audit), #60 (burn-rate done), #61 (worktrees done), #63 (nix skill/rule aligned), #64, #65, #66, #67, #68
- **Link-check script:** `vignette_check.sh` extracts URLs from rendered HTML, curls each, reports 404s
- **Broken links fixed:** duckplyr→tidyverse.org, mirai→CRAN, memory→AGENTS.md anchor

### Failed Approaches
- **Closeread format:** Mermaid diagrams failed on hidden scroll sections. Switched to dashboard format → diagrams failed on hidden pages. CSS force-visible hacks broke page navigation. Final fix: standard HTML with panel-tabset, diagrams outside tabs.
- **Mermaid in dashboard tabs:** 7 failed attempts documented in #66. Root cause: mermaid-init.js renders on window.load, hidden elements get zero dimensions. No client-side fix works reliably. Solution: don't put diagrams in tabs.
- **QA grep for "NULL":** Grepped for literal "NULL" but deployed HTML has `#&gt; NULL` (HTML-encoded). Also missed "unavailable" fallback text. Must grep for both patterns.
- **DT widgets in RDS:** Exported DT::datatable objects contain hardcoded `/nix/store/` paths. CI fails with "path for html_dependency not found". Fix: strip to data.frame, re-wrap at render time.

### Accuracy / Metrics
- Issues: 11 closed this session (46,51,52,58,60,61,63,64,65,66,67,68), 6 remain open
- Telemetry NULLs: 24→8 (remaining need arch fixes: Gemini DB, tar_meta bug, vctrs bug)
- Infrastructure vignette: 0 NULLs, 0 broken links, 5 diagrams, 5 captions
- AGENTS.md: fully synced with audit hook
- Tests: 108 passing (ccusage)

### Known Limitations
- 8 telemetry NULLs remain: vig_gemini_* (no DB), vig_pipeline_* (tar_meta arch issue), vig_pred_* (vctrs bug)
- Backtesting agent not yet created (portfolio-level design documented in #68 comment)
- No automated post-deploy link check in CI (vignette_check.sh exists but not wired into workflow)
- Mermaid diagrams inside panel-tabset tabs still won't render (by design — kept outside tabs)

## 2026-04-17 – 2026-04-18

### Completed
- **Cost optimization:** Auto-delegation rule with mandatory model routing triggers — opus for architecture only, sonnet for all named agents, haiku for single-file edits
- **Burn-rate alerts (#60):** `burn_rate_check.sh` tracks weekly spend vs cap ($500), fires WARN/CRITICAL at 80%/95% projected, integrated into session_init + context_monitor
- **Worktree support (#61 steps 1-5):** session_init detects worktree context, warns about _targets/ conflicts, suggests sonnet worktree when budget critical, scans sibling dirs + prunable worktrees
- **Agent model pinning:** All 12 agents now have explicit `model:` frontmatter (was 9/10). Restored `quick-fix` haiku agent. Added `data-engineer` + `data-quality-guardian` as sonnet.
- **Nix lock guard:** `default.sh` PID-based lockfile wraps only nix-build step — second tab waits for completion instead of erroring
- **GNU grep portability:** Fixed 8 `grep "foo\|bar"` → `grep -E "foo|bar"` in session_init.sh (BRE alternation fails silently in GNU grep from Nix)
- **Backtest rules:** execution-delay-sensitivity, position-sizing-guardrails, risk-regime-evaluation, backtest-robustness
- **YAML frontmatter:** Added to all 14 rules that were missing it (56/56 now complete)
- **Oversized rules:** Shrunk 8 of 9 rules over 150 lines (extracted code to 3 skill reference files, trimmed 5 rules). 1 remains at 151 (robust-statistics, within tolerance).
- **Weekly cap calibration:** Analyzed 8 weeks of ccusage data — set `CLAUDE_WEEKLY_CAP_USD=500` (weeks <$700 no lockout, >$1000 always lockout)
- **Model mix tracking:** `model_mix_log.sh` logs weekly opus/sonnet/haiku % to CSV, wired into session_stop.sh
- **Nix lock scope fix:** Multiple iTerm tabs can now run default.sh — lock wraps only nix-build, second tab waits

### Failed Approaches
- `grep -q "CRITICAL\|WARN"` silently failed under GNU grep (Nix) — the `\|` BRE alternation works in BSD grep but not GNU. Caused burn-rate TIP and WARN aggregation to not fire. Diagnosed via step-by-step `set -euo pipefail` debugging. Fix: always use `grep -E` for alternation.
- `local` keyword inside top-level `if` block in session_init.sh caused unbound variable error — `local` is function-scoped only in bash.
- Concurrent nix-build from two iTerm tabs caused store lock contention (both appeared hung). Fixed by killing duplicate, then redesigning lock to wrap only nix-build step.

### Accuracy / Metrics
- April 1-17 usage: opus=86% of output ($2,688), sonnet=6% ($18), haiku=8% ($9). Total $2,715.
- Opus is 11x more expensive than sonnet, 26x more than haiku per output token
- Estimated savings from auto-delegation: 28% ($755/month) at "moderate" mix (60/25/15)
- 12/12 agents have model frontmatter (was 9/10)
- AGENTS.md: 191 lines (under 200 limit)
- Issues created: #60 (burn-rate), #61 (worktrees)
- Rules: 55/56 under 150 lines (robust-statistics at 151)

### Known Limitations
- Auto-delegation is rule-based (advisory to orchestrator), not enforced by hooks — orchestrator can still ignore it
- Model mix tracking is observational — no automated alert if opus % stays high
- Weekly cap is token-based internally, ccusage USD is an estimate

## 2026-03-31 – 2026-04-01

### Completed
- difftastic added to nix + git config + 5 config touchpoints (critic, code-review, /check, verification, roborev)
- docker-client + orbstack added to nix system_pkgs
- OrbStack integration: /check --linux (CI parity), PHI container isolation, Linux debugging in r-debugger
- ggauto added to visualization-standards rule + eda-workflow skill
- roborev config fix (TOML hooks=[] conflict with [[hooks]])
- roborev refine successfully auto-fixed 2 review findings

### Failed Approaches
- Claimed "difftastic not in nixpkgs" without reading nix-shell output (terminal wrapper noise obscured "found"). Another instance of lesson #6: verify tool output before reporting.
- roborev `hooks = []` + `[[hooks]]` TOML conflict — appended array-of-tables while empty array existed. Must remove empty default before adding entries.

### Accuracy / Metrics
- Nix dev toolchain: R, ast-grep, tree-sitter, difftastic, docker-client, orbstack, claude-code, copilot, duckdb
- All 6 projects have roborev hooks + structural diff note in review_guidelines
- Visualization ladder: ggauto (EDA) → ggplot2 (publication) → ggiraph (interactive) → plotly (Shiny)

### Known Limitations
- OrbStack Linux container check (`/check --linux`) not yet tested end-to-end
- ggauto not yet in any project's DESCRIPTION Suggests (add when first used)
- vignette-targets-export.md still at 171 lines (>150 limit)
- 2 rules still missing YAML frontmatter

## 2026-03-30

### Completed
- ast-grep + tree-sitter added to nix system_pkgs, R grammar setup script
- ast-grep code sweep found: 1 dbGetQuery, 8 stop(), 19 data.frame(), 12 silent tryCatch
- Fixed all violations: dbGetQuery→dplyr, stop→cli_abort, data.frame→tibble, silent tryCatch→cli_warn
- 7 lessons + meta-lessons incorporated into 5 config files
- quality-gates: qa_no_raw_sql now uses ast-grep (structural, not text grep)
- /check command: now includes ast-grep code sweep step
- suppress-warnings-antipattern: added silent tryCatch as banned pattern
- verification-before-completion: line count ≠ call count section
- systematic-debugging: never accept unverified justifications
- roborev config fix: removed duplicate hooks=[] conflicting with [[hooks]]
- roborev refine successfully ran and auto-fixed 2 review findings

### Failed Approaches
- ast-grep line count reported as call count (349 vs 28 tryCatch). Use --json=compact + nrow().
- Justified data.frame() as "lightweight utilities" instead of using tibble(). Speed must not silence standards.
- Said "349 tryCatch — expected for targets" without checking. Reality: 289 lines in ONE file, all silent error swallowing.
- roborev config: appended [[hooks]] while hooks=[] existed — TOML parse error. Must remove empty array before adding entries.

### Accuracy / Metrics
- Banned pattern violations: dbGetQuery 0, stop() 0, suppressWarnings() 0 (all clean)
- ast-grep: 307 unique functions, 880 call network edges in llm project
- roborev: 192 completed reviews, daemon healthy, 2 auto-fixes applied

### Known Limitations
- vignette-targets-export.md at 171 lines (>150 limit)
- 2 rules missing YAML frontmatter: medical-data-anonymization.md, medical-etl-quality.md
- R-universe: micromort still failing

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
