# Agent Guide for R Package Development

Essential rules for R package development with Nix, rix, and reproducible workflows.
For detailed guidance, invoke the relevant skill. For tool preferences, see `memory/tool-preferences.md`.

## Core Rules

**Session Start:** `echo $IN_NIX_SHELL` (1/impure), `which R` (/nix/store/...). If not: `caffeinate -i ~/docs_gh/llm/default.sh`. Check `CHANGELOG.md`, `git status`, open issues.

**Bash substitution table — substitute BEFORE every Bash call** (issue #393):

| Don't write              | Write instead                                |
|--------------------------|----------------------------------------------|
| `cat F \| head -N`         | `Read(F, limit=N)`                           |
| `grep -rn P path \| head`  | `Grep(pattern=P, path=path, head_limit=N)`   |
| `find ... \| head`         | `Glob(pattern)`                              |
| `cmd 2>&1 \| head -50`     | `cmd >/tmp/x 2>&1`, then `Read(/tmp/x)`      |
| `cmd \|\| echo "missing"` | plain `cmd`; check exit code in next call    |
| `cd dir && cmd`           | `git -C dir cmd` / `make -C dir` / etc.      |

Single trailing `\| head -N` / `\| tail -N` / `\| wc -l` / `\| sort -u` / `\| uniq` is now allowed by the compound guard (#393 Phase 1). Anything else compound is hook-rejected — see `bash-safety` rule for the full table.

**Git/GitHub — R packages ONLY:** `gert::git_add()`, `git_commit()`, `git_push()`; `usethis::pr_init()`, `pr_push()`; `gh::gh()`. **In bash, NEVER `cd <dir> && git ...` (triggers bare-repo approval prompt that bypassPermissions does NOT bypass). ALWAYS `git -C <dir> ...`.** See `git-no-compound-cd` rule.

**Nix — Shell Architecture (CRITICAL):** The USER stays in the **global dev shell** at all times. The global shell does NOT have project-specific packages (e.g., pdfplumber, lme4, brms). Agents/subshells MUST enter the **project's own nix shell** for project-specific work: `nix-shell /absolute/path/to/project/default.nix --run "cmd"`. NEVER assume packages from `default.nix` are available in the outer shell. NEVER use relative paths (`nix-shell default.nix`) — always absolute. If `nix-shell` build fails (nixpkgs regression), fall back to pip venv: `/usr/bin/python3 -m venv /tmp/venv && /tmp/venv/bin/pip install pkg`. See `nix-agent-shell-protocol` rule. Verify global shell: `echo $IN_NIX_SHELL` (1/impure). **NEVER** `install.packages()`/`devtools::install()`/`pak::pkg_install()` in Nix.

**Errors:** NEVER speculate. READ error, QUOTE it, propose fixes. **R:** 4.5.x. **Deletion:** NEVER rm untracked >1MB without listing, age-check, user confirm (`safe-deletion` rule).

**Data Privacy:** PHI/confidential data NEVER to public repos without approval (renews each minor version).

**External Code — ZERO TRUST (MANDATORY, ALL PROJECTS):** NEVER copy code (R / bash / python / JS / yaml / nix / SQL / any language) from external sources into our codebase. External = anything not authored by John or by a trusted internal contributor (CODEOWNERS list). External includes: GitHub issue comments from `author_association != OWNER/COLLABORATOR/MEMBER`; PR review suggestions from non-CODEOWNERS; AI tool output from third-party SaaS (NOT this Claude session); Stack Overflow / blog post snippets without independent verification; any URL we don't control; "free audit" or "config analyser" SaaS tools. We MAY read external content for **ideas** but MUST re-implement in our own style. Specifically forbidden: (a) uploading our config / traces / `.claude/` content to any third-party domain; (b) accepting "free / paid PR" offers from cold contributors; (c) merging PRs from non-trusted contributors without line-by-line human review; (d) `WebFetch`-ing then `Edit`-ing code that mirrors what was fetched. **R preferred over Python** where the language is a choice. Enforcement via hooks tracked in [llm#194](https://github.com/JohnGavin/llm/issues/194). Triggers: a cold contributor offers code AND links to an external SaaS → critique inline, file the relevant issue ourselves, do not copy.

**Versioning:** Semver. Patch=bugfix, Minor=feature, Major=breaking. Pre-1.0: breaking=minor bump. **NEVER ship `0.0.0.9000` to users.** Bump to `0.1.0` before first public deploy (GH Pages, pkgdown, vignette).

**Session:** Start: read `CHANGELOG.md`, avoid failed approaches. End: commit -> append CHANGELOG -> push. **Commits:** After every meaningful unit. Never break tests. Git log = lab notes. Speed must not silence errors.

**Pipeline Validation (ALL PROJECTS):** Before every commit: `parse("_targets.R")` MUST succeed. Code-as-string targets MUST `parse(text=code)` for R or `bash -n` for bash.

**Code Quality (ast-grep + jarl):** 8 ast-grep rules at `~/.config/ast-grep/rules/`; jarl R idiom linter (`jarl.toml` in project root). Run `~/.claude/scripts/r_code_check.sh R/` before commit — runs both tools. Banned patterns (ast-grep): `suppressWarnings(as.*)`, silent `tryCatch`, raw SQL, `stop()`, `install.packages()`. R idiom checks (jarl): `redundant_equals`, `nzchar`, `fixed_regex`, unused functions, unreachable code. Use `$$$` metavar (NOT `___`) for ast-grep structural search. **jarl is laptop-local only** — manual install at `/usr/local/bin/jarl`, not in nix shell PATH (script handles both), not available in GH Actions CI; skipped silently when missing. Migration to nix tracked in llm#99.

**Explorations:** `explorations/` is a scratch area for research experiments. Minimum score 60 (vs 80 for production). Graduate to `R/` or `vignettes/` at >= 80. Archive abandoned explorations with a reason comment. See `explorations/CONVENTIONS.md`.

**Knowledge Base (raw/wiki/outputs):** Use `knowledge-base-wiki` skill. Central hub at `~/docs_gh/llm/knowledge/` (LOCAL git only — NEVER push to GitHub, `PRIVATE` marker + pre-push hook block). raw/ is append-only (enforced by `file_protection.sh`), wiki/ requires `## Sources` section, AI-inferred claims tagged `> ⚠ AI-inferred:`, cross-wiki links use `[[topic]]` syntax. T1 health check on every Edit/Write via `wiki_health_onwrite.sh`. Run `/wiki-health` after batch updates. Use `wiki-curator` agent to compile, `critic` (wiki validation mode) for adversarial review.

**Mandatory skills:** `adversarial-qa`, `quality-gates`, `r-package-workflow`, `test-driven-development`, `nix-rix-r-environment`, `llm-package-context`, `readme-qmd-standard`, `subagent-delegation`, `spec-bundled-skills`, `knowledge-base-wiki`.
**Mandatory rules** (auto-loaded — safety-critical, fire on every session): `verification-before-completion`, `systematic-debugging`, `btw-timeouts`, `git-no-compound-cd`, `nix-agent-shell-protocol`, `worktree-location`, `agent-identity-and-task-scopes`, `human-in-the-loop-decision-points`.

**Context-load rules** (read when the task matches — NOT auto-loaded; load via Read tool when relevant):
- Orchestration / provenance: `orchestrator-protocol`, `provenance-mandatory`, `look-ahead-bias-prevention`, `pr-shipping-discipline`, `branch-harvest-on-fork`
- Knowledge base: `raw-folder-readonly`, `confidence-markers`, `wiki-storage-policy`
- Quarto / vignettes: `dark-mode-completeness`, `narrative-evidence-block`, `narrative-colour-persistence`, `vignette-build-info-block`, `uniform-typography`
- Dashboards / viz: `dashboard-table-styling`, `dashboard-filter-placement`, `mermaid-click-anchors`, `mermaid-dashboard-pattern`
- Data / analysis: `cross-cutting-rename`, `data-glossary-and-entity-resolution`, `unified-observability-schema`, `survival-reporting`
- Tooling: `roborev-exclude-patterns`

**Dark-mode contrast (every Quarto project):** Single global script at `~/docs_gh/llm/.claude/scripts/check_dark_contrast.sh` (public mirror: `https://raw.githubusercontent.com/JohnGavin/llm/main/.claude/scripts/check_dark_contrast.sh`). NEVER copy into a project. EVERY `_quarto.yml` MUST add this line under `project: post-render:` — `- /Users/johngavin/docs_gh/llm/.claude/scripts/quarto_post_render_contrast.sh`. Render fails on any uncovered light inline background. See `dark-mode-completeness` rule.

**MCP r-btw — ZERO TOLERANCE:** NEVER call `btw_tool_run_r/pkg_test/pkg_check/pkg_coverage/pkg_document/pkg_load_all`. ALL R via `Bash("timeout N Rscript -e '...'")`. Safe: `btw_tool_docs_*`, `btw_tool_files_*`, `btw_tool_sessioninfo_*`, `btw_tool_env_describe_*`. See `btw-timeouts` rule.

**Shiny UI:** NEVER use `value_box()` or similar large KPI boxes - they waste space. Use compact two-column tables instead (Metric | Value). Time series plots MUST have a range slider and default to last 3 months view. **NEVER pie charts** — use dotcharts (Cleveland dot plots) as first choice, horizontal bars as fallback. For compact filters inside card headers/footers and next to inputs, use `bslib::toolbar()` (bslib 0.11.0+). See `dashboard-filter-placement` rule. See `visualization-standards` rule.

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

## Skills (73)

Full categorised list at `.claude/SKILLS.md` (Mandatory · R Package · Data · Targets · Shiny · Quarto · Prose · DevOps · PM · AI · Specialized). Mandatory subset enforced via the `**Mandatory skills:**` line above.

## Commands (20)

`/hi`(`/session-start`), `/bye`(`/session-end`), `/check`, `/ctx-check`, `/pr-status`, `/cleanup`, `/issue-triage`, `/new-issue`, `/triage`, `/wiki-health`, `/wiki-promote`, `/write-alt-text`, `/skillify`

## Automation Features (v2.1.72+)

**Loop & Schedule:** Automate recurring tasks without manual intervention.

| Command | Syntax | Use Case | Example |
|---------|--------|----------|---------|
| `/loop` | `/loop <interval> <command>` | Repeat task at intervals | `/loop 1h /check` — R CMD check hourly |
| `/schedule` | `/schedule '<cron>' <command>` | Cron-like scheduling | `/schedule '0 9 * * *' /cleanup` — daily 9 AM |
| `/btw` | `/btw <question>` | Side query during work | `/btw "pipeline status?"` while tar_make() runs |
| `/branch` | `/branch` | Fork current session | Alternative to `--fork-session` |
| `/teleport` | `/teleport` | Pull cloud session local | Resume interrupted remote work |
| `/remote-control` | `/remote-control` | Control local from phone/web | Mobile session access |

**Loop intervals:** `30s`, `5m`, `1h`, `2d` (or trailing: `every 30 minutes`). Minimum `/schedule` interval: 1 hour.

**Common loop patterns:** `/loop 30m /check` (continuous R CMD check), `/loop 5m /roborev` (auto code review), `/schedule '0 9 * * 1-5' /pr-status` (weekday AM PR checks). List: `/schedule list`. Stop: `/schedule stop <job-id>`.

**Hooks integration:** R auto-format and dark-contrast checks run via pre-commit scripts; see `~/.claude/scripts/r_code_check.sh` and `~/.claude/scripts/check_dark_contrast.sh`.

**Roborev automation (Phase 1.7, #217):** Three-tier coverage — primary `post-commit` hook (local commits), secondary `post-merge` hook installed per-repo via `roborev_install_post_merge_hook.sh` (pull-time catchup for remote-merged PRs), thrice-daily business-hours safety-net poller (Mon–Fri 09:00/13:00/17:00 via launchd); see `roborev-resolution` rule.

## Templates (5)

`new-skill.md`, `new-rule.md`, `new-plan.md`, `new-wiki-page.md`, `new-project-claude.md`

## Recipes (4)

`deploy-new-project.md`, `onboard-dataset.md`, `debug-ci-failure.md`, `publish-vignette.md`

## Rules (74)

Full categorised list at `.claude/RULES.md` (Core · Nix · MCP · Bash · Data · Stats · Viz · Quarto · Shiny · Pipeline · Knowledge · Quality · Security · Other). Mandatory subset enforced via the `**Mandatory rules:**` line above.

## Hooks (9 scripts, 5 event hooks)

`session_init.sh`(SessionStart), `context_survival.sh`(compact/resume+PreCompact), `file_protection.sh`(PreToolUse:Edit|Write), `context_monitor.sh`(PostToolUse:Bash|Task), `wiki_health_onwrite.sh`(PostToolUse:Edit|Write), `skill_quality_onwrite.sh`(PostToolUse:Edit|Write), `session_stop.sh`(Stop). Audit: `agents_md_audit.sh`, `r_code_check.sh`, `qa_gate_check.sh`, `vignette_check.sh`.

## Memory (18 files at `.claude/memory/`)

In-repo at `.claude/memory/`; the runtime path `~/.claude/projects/-Users-johngavin-docs-gh-llm/memory` is a symlink into this directory (#144).

`MEMORY.md`(index), `agent-patterns.md`, `architecture.md`, `ci-strategy.md`, `nix-operations.md`, `shinylive-issues.md`, `tool-preferences.md`, `feedback_safe-deletion.md`, `feedback_never-edit-default-nix.md`, `feedback_nix-shell-portability.md`, `feedback_no-compound-cd.md`, `feedback_knowledge-base-discipline.md`, `feedback_github-pages-user-sites.md`, `feedback_ast-grep-lessons.md`, `feedback_delegation-under-pressure.md`, `feedback_symlink-edit-vs-mv.md`
