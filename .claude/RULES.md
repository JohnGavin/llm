# Rules (52)

Companion to `AGENTS.md`. Holds only the categorised rule index; the mandatory-rules subset is still listed inline in `AGENTS.md` so it loads as part of every session's context.

| Group | Rules |
|---|---|
| **Core** | `auto-delegation`, `architecture-planning`, `orchestrator-protocol`, `systematic-debugging`, `verification-before-completion`, `pivot-signal`, `cross-cutting-rename`, `branch-harvest-on-fork` |
| **Nix** | `nix-agent-shell-protocol`, `nix-nested-shell-isolation` |
| **MCP** | `btw-timeouts` |
| **Bash** | `bash-safety` |
| **Data** | `data-in-packages`, `data-validation-timeseries`, `credential-management` |
| **Stats** | `statistical-reporting`, `suppress-warnings-antipattern`, `survival-reporting` |
| **Viz** | `visualization`, `dynamic-prose-values`, `uniform-typography`, `dashboard-table-styling`, `dashboard-filter-placement` |
| **Quarto** | `quarto-vignettes`, `acronym-expansion`, `vignette-build-info-block` |
| **Shiny** | `module-isolation`, `shiny-module-data-sharing`, `shinylive-webr-nonblocking` |
| **Pipeline** | `qa-targets-pipeline`, `ctx-yaml-cache` |
| **Knowledge** | `wiki-conventions` |
| **Quality** | `accessibility`, `analytical-review-checklist`, `analysis-rationale-mandatory`, `braindump-closed-loop` |
| **Security** | `destructive-fs-guard`, `destructive-ops-guard`, `permission-discipline`, `backup-architecture` |
| **Other** | `website-index-update`, `t-lang-r-package`, `huggingface-upload`, `gh-pages-nojekyll`, `namespace-discipline`, `portable-paths`, `project-charter`, `roborev-resolution`, `single-change-experiment`, `snapshot-tests-mandatory`, `search-all-pipeline-stages`, `audience-communication` |

## Adding a new rule

When a new rule is added under `.claude/rules/<name>.md`:

1. Add the rule slug to the appropriate group in the table above
2. Bump the `# Rules (N)` count in this file's heading
3. Bump the `## Rules (link to this file) (N)` count in `AGENTS.md`
4. If mandatory, also add the slug to the `**Mandatory rules:**` paragraph in `AGENTS.md` (mandatory rules stay inline there so they load in every session context)
5. Mention the new rule in the `## Related` block of every adjacent rule

## Mandatory subset

The mandatory subset is duplicated in `AGENTS.md` for ergonomics. Keep the two in sync — `agents_md_audit.sh` will eventually be extended to catch drift.
