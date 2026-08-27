# Rules (90)

Companion to `AGENTS.md`. Holds only the categorised rule index; the mandatory-rules subset is still listed inline in `AGENTS.md` so it loads as part of every session's context.

| Group | Rules |
|---|---|
| **Core** | `auto-delegation`, `architecture-planning`, `orchestrator-protocol`, `systematic-debugging`, `verification-before-completion`, `pivot-signal`, `cross-cutting-rename`, `branch-harvest-on-fork`, `branch-salvage-workflow`, `pr-shipping-discipline`, `skills-vs-mcp`, `press-release-first`, `human-in-the-loop-decision-points`, `cross-project-scope`, `worktree-location`, `quadratic-loop-cost`, `rule-scoping-guard` |
| **Nix** | `nix-agent-shell-protocol`, `nix-nested-shell-isolation` |
| **MCP** | `btw-timeouts` |
| **Bash** | `bash-safety` |
| **Data** | `data-in-packages`, `data-validation-timeseries`, `credential-management`, `data-glossary-and-entity-resolution` |
| **Stats** | `statistical-reporting`, `suppress-warnings-antipattern`, `survival-reporting`, `na-propagation-rolling-stats` |
| **Viz** | `visualization`, `dynamic-prose-values`, `uniform-typography`, `dashboard-table-styling`, `dashboard-filter-placement`, `hover-popup-standard`, `mermaid-click-anchors`, `mermaid-dashboard-pattern` |
| **Quarto** | `quarto-vignettes`, `acronym-expansion`, `vignette-build-info-block`, `narrative-evidence-block`, `narrative-colour-persistence` |
| **Shiny** | `module-isolation`, `shiny-module-data-sharing`, `shinylive-webr-nonblocking` |
| **Pipeline** | `qa-targets-pipeline`, `ctx-yaml-cache`, `cron-auto-pull-discipline`, `housekeeping-framework`, `portable-build-artifacts`, `unified-observability-schema` |
| **Knowledge** | `wiki-conventions` |
| **Quality** | `accessibility`, `analytical-review-checklist`, `analysis-rationale-mandatory`, `braindump-closed-loop`, `zero-metric-evidence-or-defect`, `checks-must-distinguish-unknown` |
| **Security** | `destructive-fs-guard`, `destructive-ops-guard`, `permission-discipline`, `backup-architecture`, `agent-identity-and-task-scopes`, `agent-no-push-to-main`, `external-code-zero-trust`, `secret-leak-prevention`, `secret-exposure-scanning`, `secrets-single-source`, `private-data-scanning`, `public-private-repo-boundary`, `repo-visibility-gate` |
| **Other** | `website-index-update`, `t-lang-r-package`, `huggingface-upload`, `gh-pages-nojekyll`, `namespace-discipline`, `portable-paths`, `project-charter`, `roborev-resolution`, `roborev-exclude-patterns`, `single-change-experiment`, `snapshot-tests-mandatory`, `search-all-pipeline-stages`, `audience-communication`, `outbound-writing-style`, `follow-the-reference-fully`, `content-licensing`, `llm-portability-statement`, `session-init-phases`, `long-running-process-supervision` |

## Adding a new rule

When a new rule is added under `.claude/rules/<name>.md`:

1. Add the rule slug to the appropriate group in the table above
2. Bump the `# Rules (N)` count in this file's heading
3. Bump the `## Rules (link to this file) (N)` count in `AGENTS.md`
4. If mandatory, also add the slug to the `**Mandatory rules:**` paragraph in `AGENTS.md` (mandatory rules stay inline there so they load in every session context)
5. Mention the new rule in the `## Related` block of every adjacent rule

## Mandatory subset

The mandatory subset is duplicated in `AGENTS.md` for ergonomics. Keep the two in sync.

## Drift history — why this index is not self-maintaining

Reconciled 2026-08-14. Before that pass:

| | |
|---|---|
| Header claimed | 54 |
| Table listed | 56 |
| Rule files on disk | **83** |
| Missing from the index | **27** |
| Listed but non-existent | 0 |

Every drift was an **omission at rule-creation time** — nothing was stale, so no
rule was ever removed without updating the index; rules were simply added
without it. Among the 27 missing were four that `AGENTS.md` declares mandatory:
`human-in-the-loop-decision-points`, `agent-identity-and-task-scopes`,
`worktree-location`, and `external-code-zero-trust` (which `AGENTS.md` calls
"MANDATORY, ALL PROJECTS").

The five-step checklist above existed throughout. It did not hold, because
nothing checks it. This file previously read: *"`agents_md_audit.sh` will
eventually be extended to catch drift."* That "eventually" cost 27 rules.

This is the same failure as llm#944, where a hardcoded mandatory-rules list
inside `check_rule_scoping.sh` disagreed with policy and the checker silently
won. The fix there was to **derive** the list from `AGENTS.md` rather than keep
a second copy.

**The durable fix here is the same:** generate this table from the filesystem,
or make `check_rule_scoping.sh` fail when `ls .claude/rules/*.md` and this index
disagree — it already parses both locations, so the check is cheap and it now
runs automatically (pre-commit + session-init, llm#952).

Until that exists, expect this list to drift again. A hand-maintained index of a
directory is a copy, and copies diverge.
