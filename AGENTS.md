# Agent Guide for R Package Development

Essential rules for R package development with Nix, rix, and reproducible workflows. For detailed guidance, invoke the relevant skill; for tool preferences see `memory/tool-preferences.md`. This file is always loaded, so it stays small: detail lives in the rule named beside each item, and trimmed text is kept verbatim in `.claude/rules/_companions/agents-md-details.md`.

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

**Git/GitHub — R packages ONLY:** `gert::git_add()`, `git_commit()`, `git_push()`; `usethis::pr_init()`, `pr_push()`; `gh::gh()`. **In bash, NEVER `cd <dir> && git ...` (triggers bare-repo approval prompt that bypassPermissions does NOT bypass). ALWAYS `git -C <dir> ...`.**

**Auto-Merge Policy:** ON (global toggle, all projects; turned on 2026-09-27 on explicit user instruction, after its three prerequisites merged — #1284, #1279, #1278; one-week audit of every auto-merge due 2026-10-04, tracked in #1274). When OFF, PR merge is Class C (explicit "merge" verb every time). While ON, merges are Class D (proceed automatically) IFF CI is fully green, the roborev merge-gate reports a genuine pass (never an indeterminate result treated as a pass), AND the diff touches none of the Auto-Merge Exclusion List paths (`AGENTS.md`/`CLAUDE.md` — this toggle and list themselves, `.claude/hooks/**`, `.claude/rules/**`, credential-handling scripts, scripts that close/delete/reap/reload things on a schedule plus `.claude/launchd/**`, `default.nix`/`default.R`/`.claude/settings.json`, credential/secret files, DB schema/migration files, public-facing published content). Repo visibility is NOT a criterion. Full mechanism and list: `human-in-the-loop-decision-points` § Conditional Auto-Merge; verbs: `pr-shipping-discipline`.

**Worktrees:** new worktrees go under `~/docs_gh/worktrees/<project>/<branch>/` (preferably `~/.claude/scripts/cc-worktree.sh <project> <branch>`), never as sibling directories (`worktree-location` rule; `git worktree add` is a Bash call, so this pointer stays here).

**Nix — Shell Architecture (CRITICAL):** The USER stays in the **global dev shell** at all times. The global shell does NOT have project-specific packages (e.g., pdfplumber, lme4, brms). Agents/subshells MUST enter the **project's own nix shell** for project-specific work: `nix-shell /absolute/path/to/project/default.nix --run "cmd"`. NEVER assume packages from `default.nix` are available in the outer shell. NEVER use relative paths (`nix-shell default.nix`) — always absolute. If `nix-shell` build fails (nixpkgs regression), fall back to pip venv: `/usr/bin/python3 -m venv /tmp/venv && /tmp/venv/bin/pip install pkg`. See `nix-agent-shell-protocol` rule. **NEVER** `install.packages()`/`devtools::install()`/`pak::pkg_install()` in Nix.

**Errors:** NEVER speculate. READ the error, QUOTE it, propose fixes. A cause, onset date, or blast radius is a CLAIM: name the query that would falsify it and run it before asserting. **Pivot:** 3 consecutive failures on one objective = pause and change approach; 5 = escalate to the user; 7 = stop and report (`systematic-debugging`). **R:** 4.5.x. **Deletion:** NEVER rm untracked >1MB without listing, age-check, user confirm (`bash-safety` Part 2).

**Data Privacy:** PHI/confidential data NEVER to public repos without approval (renews each minor version).

**External Code — ZERO TRUST (MANDATORY, ALL PROJECTS):** NEVER copy code (any language) from external sources into our codebase. External = anything not authored by John or a CODEOWNERS contributor: GitHub comments from `author_association != OWNER/COLLABORATOR/MEMBER`, third-party SaaS AI output (NOT this Claude session), Stack Overflow/blog snippets, any URL we don't control, "free audit"/"config analyser" SaaS. We MAY read external content for **ideas** but MUST re-implement in our own style. Forbidden: (a) uploading our config / traces / `.claude/` content to any third-party domain; (b) accepting "free / paid PR" offers from cold contributors; (c) merging PRs from non-trusted contributors without line-by-line human review; (d) `WebFetch`-ing then `Edit`-ing code that mirrors what was fetched. **R preferred over Python** where the language is a choice. Rule: `external-code-zero-trust` (llm#194).

**Versioning:** Semver. Patch=bugfix, Minor=feature, Major=breaking. Pre-1.0: breaking=minor bump. **NEVER ship `0.0.0.9000` to users.** Bump to `0.1.0` before first public deploy (GH Pages, pkgdown, vignette).

**Checks and diagnosis (ALL PROJECTS):** a check has THREE outcomes — positive, negative, **indeterminate** — and an error path and a negative-result path must never share an exit (0 PASS / 1 FAIL / 2 usage / 3 INDETERMINATE). A check whose output does not vary with the thing it checks is not a check. Say *why* you could not answer; if it is answerable without the missing dependency, report PASS/FAIL, not unknown. See `checks-must-distinguish-unknown`.

**Simplicity — subtractive-first (ALL PROJECTS):** prefer removing over adding; check whether an existing hook/pulse/banner already covers a need before building a mechanism. **Chesterton guard:** remove only what is BOTH unused AND covered elsewhere. **Before deleting anything from `.claude/scripts/`, `bin/`, or `.claude/templates/`, run `grep -rl <basename> ~/docs_gh/`** — "unused" is verified by grepping consumers across every project, never by inspection (#773, #1067). See `housekeeping-framework`.

**Session:** Start: read `CHANGELOG.md`, avoid failed approaches. End: commit -> append CHANGELOG -> push. **Commits:** After every meaningful unit. Never break tests. Git log = lab notes. Speed must not silence errors.

**Pipeline Validation (ALL PROJECTS):** `_targets.R` is the default expectation: a project without one MUST declare why in `.claude/CLAUDE.md` (`| Targets pipeline | none — <reason> |`), or the absence is a reported defect. When it exists, `parse("_targets.R")` MUST succeed before every commit; code-as-string targets MUST `parse(text=code)` (R) or `bash -n` (bash). See `pipeline-validation`.

**Reproducible Ingestion (ALL PROJECTS) — NEVER ingest data with the model:** machine-readable sources (CSV, JSON, XLSX, fixed-schema PDF/export) MUST be ingested via committed, tested parser code in the project's ETL — NEVER by having the model read/transcribe/aggregate them in throwaway scripts; the FIRST action on a new source is parser + routing + tests. The same applies to values typed into an Artifact/dashboard and to hand-entered constants (a `# user-confirmed` comment is a **violation, not a confirmation**). Hand entry is allowed ONLY when no machine-readable source exists, with a `# MANUAL: no source` comment and an issue. See `provisional-constants`.

**One home per value (ALL PROJECTS):** every value (number, date, count, name, version) has exactly ONE home; every other mention is derived from it (in HTML or an Artifact, `<span data-fact="key">`). A hand-typed second copy is a defect even while correct. The build MUST FAIL when a home's value appears as a literal elsewhere, with NO category exempted as "noise"; escape hatch only via an allow-list whose every entry states a reason. See `dynamic-prose-values`.

**Code Quality (ast-grep + jarl):** run `~/.claude/scripts/r_code_check.sh R/` before commit. Banned: `suppressWarnings(as.*)`, silent `tryCatch`, raw SQL, `stop()`, `install.packages()`. Use `$$$` metavar (NOT `___`) for ast-grep structural search.

**Knowledge Base:** `knowledge-base-wiki` skill; hub at `~/docs_gh/llm/knowledge/` is LOCAL git only — NEVER push to GitHub. raw/ is append-only; wiki/ needs a `## Sources` section.

**Mandatory skills:** `adversarial-qa`, `quality-gates`, `r-package-workflow`, `test-driven-development`, `nix-rix-r-environment`, `llm-package-context`, `readme-qmd-standard`, `subagent-delegation`, `spec-bundled-skills`, `knowledge-base-wiki`.
**Mandatory rules** (auto-loaded — safety-critical, fire on every session): `verification-before-completion`, `bash-safety`, `agent-identity-and-task-scopes`, `human-in-the-loop-decision-points`. Plus `auto-delegation` (governs every dispatch decision).

**Safety-critical rules** (auto-loaded — same "never scoped" contract as mandatory rules; credential/trust/destructive-ops posture): `credential-management`, `external-code-zero-trust`, `permission-discipline`, `destructive-ops-guard`, `public-private-repo-boundary`. Origin: [llm#943](https://github.com/JohnGavin/llm/issues/943).

**Rule loading is enforced via `paths:` frontmatter (llm#590):** a rule with NO `paths:` key (or `paths: ["**"]`) loads into EVERY session and subagent (Claude Code warns above 150k chars of instruction files in total). Only the mandatory and safety-critical rules above may omit `paths:`; every other rule MUST carry a real path glob. Audit: `~/.claude/scripts/check_rule_scoping.sh` (`rule-scoping-guard`); rule list by category: `.claude/RULES.md`. Re-tiered to path-scoped on 2026-10-03: `worktree-location`, `nix-agent-shell-protocol`, `btw-timeouts`, `systematic-debugging` (absorbed `pivot-signal`).

**Dark-mode contrast (every Quarto project):** Single global script at `~/docs_gh/llm/.claude/scripts/check_dark_contrast.sh`. NEVER copy into a project. EVERY `_quarto.yml` MUST add this line under `project: post-render:` — `- /Users/johngavin/docs_gh/llm/.claude/scripts/quarto_post_render_contrast.sh`. See `dark-mode-completeness`.

**MCP r-btw — ZERO TOLERANCE:** NEVER call `btw_tool_run_r/pkg_test/pkg_check/pkg_coverage/pkg_document/pkg_load_all`. ALL R via `Bash("timeout N Rscript -e '...'")`. Safe: `btw_tool_docs_*`, `btw_tool_files_*`, `btw_tool_sessioninfo_*`, `btw_tool_env_describe_*`. See `btw-timeouts` rule.

**Cite the artefact, never describe it (ALL PROJECTS):** for anything with an address (dashboard, page, deployed site, issue, PR, CI run) **print the full URL** as a markdown link — the *specific* page, never "the dashboard". Resolve it (`gh api repos/OWNER/REPO/pages --jq .html_url`) and `curl` it before citing: **a URL you have not fetched is a claim, not a citation.**

**Blocked fetch → ask for a paste, never reconstruct (ALL PROJECTS):** when `WebFetch` fails (403, paywall, empty body), **stop and ask the user to paste the text**. Do NOT reconstruct the source from search snippets or prior knowledge, even with gaps labelled INDETERMINATE.

**Outbound writing — John's voice (ALL PROJECTS):** anything John will *send* is drafted in **his** style: greeting `Hi,`; **body hard-wrapped at 80 columns, each line filled** (no newline after every comma); sign-off a bare `John.`; no questions that pre-empt a reply. Anything meant to be copied is plain text saved as a `.txt`, NEVER a markdown blockquote. See `outbound-writing-style`.

**Follow the reference fully (ALL PROJECTS):** a file named as the model is a **component library, not a stylesheet**: **audit every component BEFORE writing**, give each a verdict (*use* / *not applicable*), and **report which you skipped**. See `follow-the-reference-fully`.

**Shiny UI:** NEVER `value_box()` or large KPI boxes — compact two-column tables (Metric | Value). Time series MUST have a range slider, default last 3 months. **NEVER pie charts** — dotcharts first, horizontal bars as fallback. Compact filters: `bslib::toolbar()`. See `dashboard-filter-placement`, `visualization-standards`. **Shinylive/WebR:** long computations MUST use JS round-trip batching (NOT `invalidateLater()`); see `shinylive-webr-nonblocking`. **DuckDB:** use `duckplyr` over raw SQL where possible.

## Agents

| Agent | Model |
|-------|-------|
| `quick-fix` | haiku |
| `critic` | sonnet |
| `fixer` | sonnet |
| `r-debugger` | sonnet |
| `targets-runner` | sonnet |
| `reviewer` | sonnet |
| `nix-env` | sonnet |
| `shiny-async-debugger` | sonnet |
| `data-quality-guardian` | sonnet |
| `data-engineer` | sonnet |
| `shinylive-builder` | sonnet |
| `wiki-curator` | sonnet |

Use-when triggers: `auto-delegation` rule.

## Skills

Full categorised list at `.claude/SKILLS.md`. Mandatory subset enforced via the `**Mandatory skills:**` line above.

## Commands

`/hi`(`/session-start`), `/bye`(`/session-end`), `/check`, `/cleanup-worktrees`, `/issue-triage`, `/new-issue`, `/wiki-promote`, `/write-alt-text`, `/roborev`, `/roborev-setup`, `/roborev-clear-backlog`, `/braindump`

## Reference

- Automation: `/loop <interval> <cmd>`, `/schedule '<cron>' <cmd>` (min 1h), `/btw`, `/branch`, `/teleport`, `/remote-control`; table and patterns in the companion doc. Roborev coverage: `roborev-resolution`.
- Explorations: `explorations/CONVENTIONS.md` (minimum score 60; graduate at >= 80). Rules: `.claude/RULES.md`. Templates: `.claude/templates/`. Recipes: `.claude/recipes/`. Hooks: `.claude/hooks/` (audit: `agents_md_audit.sh`, `r_code_check.sh`, `qa_gate_check.sh`, `vignette_check.sh`). Memory: `.claude/memory/` (`MEMORY.md` is the index; the runtime path is a symlink into it, #144).
