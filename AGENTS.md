# Agent Guide for R Package Development

Essential rules for R package development with Nix, rix, and reproducible workflows.
For detailed guidance, invoke the relevant skill.

## Session Start

```bash
echo $IN_NIX_SHELL  # Should be 1 or impure
which R             # Should be /nix/store/...
```

If not in nix: `caffeinate -i ~/docs_gh/rix.setup/default.sh`
Check: `.claude/CURRENT_WORK.md`, `git status`, open issues.

## Nix Environments

See `nix-rix-r-environment` skill for full details. Quick ref:
- Create `default.R` (generates `default.nix`), `default.sh` (enters shell with GC root)
- **NEVER** `install.packages()` / `devtools::install()` / `pak::pkg_install()` inside Nix
- Add packages: Edit DESCRIPTION -> `default.R` -> exit -> re-enter Nix
- Segfaults = R version mismatch; use `rix::available_dates()` to fix (see memory/nix-operations.md)

## The 9-Step Workflow (MANDATORY)

**NO EXCEPTIONS. NO SHORTCUTS.** See `r-package-workflow` skill for details.

| Step | Action | Key Command |
|------|--------|-------------|
| 0 | Design & Plan | Create `plans/PLAN_*.md` |
| 1 | Create Issue | `gh::gh("POST /repos/...")` |
| 2 | Create Branch | `usethis::pr_init("fix-issue-123")` |
| 3 | Make Changes | Edit, test (RED-GREEN-REFACTOR) |
| 4 | Run Checks + QA | `document()`, `test()`, `check()`, adversarial QA, quality gate >= Silver |
| 5 | Push Cachix | `./push_to_cachix.sh` (requires `package.nix`) |
| 6 | Push GitHub | `usethis::pr_push()` |
| 7 | Wait for CI | Monitor Nix-based workflows ONLY |
| 8 | Merge PR | `usethis::pr_merge_main()` |
| 9 | Log Everything | Include `R/dev/issue/fix_*.R` in PR |

## Data Privacy & Telemetry

- Telemetry with confidential info must **NEVER** be uploaded to public repos without explicit approval.
- Approval renews every **minor version upgrade** (e.g., 1.1 -> 1.2), not patches.

## Critical Rules

**Git/GitHub - Use R packages ONLY:**
- `gert::git_add()`, `git_commit()`, `git_push()`
- `usethis::pr_init()`, `pr_push()`, `pr_merge_main()`
- `gh::gh()` for GitHub API

**Nix:** One persistent shell per session. Verify: `echo $IN_NIX_SHELL`. Issues: `nix-env` agent.

**Errors - NEVER speculate:** READ the error, QUOTE it, then propose fixes.

**R Version:** 4.5.x. Check: `R.version.string`

## Versioning Policy

Semver: Patch = bugfix, Minor = new feature, Major = breaking change. Pre-1.0: breaking = minor bump.

## Testing Before Commit (MANDATORY)

1. Enter project Nix env -> 2. `tar_validate()` -> 3. Test at least one target
4. Check CI triggers -> 5. Include `R/dev/issue/fix_*.R`

Always delegate tests to subagents. Verify pkgdown links after deployment.
See `quality-gates` and `test-driven-development` skills.

## Mandatory QA Protocol

| Protocol | Skill | When |
|----------|-------|------|
| 9-Step Workflow | `r-package-workflow` | Every PR |
| Adversarial QA | `adversarial-qa` | Step 4 |
| Quality Gates | `quality-gates` | Steps 4, 6, 8 |
| TDD | `test-driven-development` | Step 3 |
| Debugging | `systematic-debugging` | When checks fail |

QA gates: Bronze (>=80) = commit, Silver (>=90) = PR, Gold (>=95) = merge to main.
**NEVER skip** adversarial QA, quality gate scoring, or data validation targets.

## Cachix Push Rule

`default.nix` (mkShell) != `package.nix` (buildRPackage). Both required.
Push only THIS project's package. Never push standard R packages.
Run `./push_to_cachix.sh` directly (no user confirmation needed).
- CORRECT: `echo $RESULT | cachix push johngavin` (1 path only)
- WRONG: `cachix push johngavin $RESULT` (pushes entire closure)
- WRONG: `cachix watch-exec` (pushes all new store paths including deps)

## CI Strategy

Public repos: any CI workflow. Private repos: Nix-only, Linux-only.
See memory/ci-strategy.md for details.

## Tool Preferences

| Task | Tool |
|------|------|
| Parallel tasks | `mirai::mirai_map()` |
| Worker pools | `crew::crew_controller_local()` |
| SQL on files | `duckdb` |
| Large data I/O | `arrow` |
| Data manipulation | `dplyr` (duckdb/arrow backend) |
| Pipelines | `targets` + `crew` |
| Package API docs | `pkgctx` (via nix run) |
| Errors & Messages | `cli::cli_abort()`, `cli_alert()` |

## pkgctx

See `llm-package-context` skill. Generate: `nix run github:b-rodrigues/pkgctx -- r . --compact`

## Error Handling

Use `cli::cli_abort(c("x" = "Error", "i" = "Hint"))`, not `stop()`.

## Agents

See memory/agent-patterns.md for full table. Key rules:
- Match model to complexity: haiku=$, sonnet=$$, opus=$$$
- Run independent tasks in parallel
- Delegate btw_tool_pkg_* always; btw_tool_run_r for anything >5s
- See `btw-timeouts.md` rule and `subagent-delegation` skill

## Skills

**Mandatory:** `adversarial-qa`, `quality-gates`, `r-package-workflow`, `test-driven-development`,
`systematic-debugging`, `nix-rix-r-environment`, `llm-package-context`, `readme-qmd-standard`,
`subagent-delegation`, `spec-bundled-skills`

~40 additional domain-specific skills in `~/.claude/skills/`.

## Common Tasks

| Task | Approach |
|------|----------|
| Package API docs | `nix run github:b-rodrigues/pkgctx` |
| GitHub Actions | Check `.github/workflows/` for examples |
| Debugging R errors | `r-debugger` agent |
| Shiny dashboards | `claude --chrome` then `launch_dashboard()` |
| README requirements | `readme-qmd-standard` skill |
| Agent delegation | `subagent-delegation` skill |

## Custom Commands

- `/session-start` - Initialize session
- `/session-end` - End session (commit, push)
- `/check` - Run document(), test(), check()
- `/pr-status` - Check PR and CI status
- `/cleanup` - Review and simplify work
- `/issue-triage` - List GitHub issues by difficulty
- `/new-issue` - Create GitHub issue with branch
- `/triage` - Quick issue analysis
- `/hi` - Config size audit
- `/bye` - Session tidy checks

## File Structure

```
R/                    # Package functions ONLY
├── *.R               # Analysis functions
├── dev/              # Development tools
│   └── issues/       # Fix scripts (MUST include in PRs)
└── tar_plans/        # Modular pipeline components
    └── plan_*.R      # Each returns list of tar_target()

_targets.R            # ONLY orchestrates plans from R/tar_plans/
vignettes/            # Quarto documentation
plans/                # PLAN_*.md working documents
README.qmd            # Source for README.md (NEVER edit directly)
```

## README & Documentation

See `readme-qmd-standard` skill. Key rules:
- README.qmd is source (never edit .md directly)
- Three install methods: R, Nix default.sh, rix integration
- `fs::dir_tree(recurse = 2)` for project structure
- Test ALL code examples before commit

## Vignettes

See `quarto-files.md` rule. Key rules:
- **ZERO computation** - only `tar_load()`/`tar_read()` + display
- Exception: targets introspection (`tar_visnetwork()`, `tar_meta()`, etc.)
- Code examples stored as targets with parse validation
- `DT::datatable()` only (never `knitr::kable()`)

## Targets Pipeline

Never place definitions in `_targets.R` directly. Use `R/tar_plans/plan_*.R` modules.

## Two-Tier Nix Shell

Dev shell (base tools) vs project shell (DESCRIPTION packages).
Agents use `nix-shell default.nix --run "COMMAND"` for project packages.
See memory/architecture.md for details.

## btw MCP Tools

Subset: docs, pkg, files, run, env, session. See `btw-timeouts.md` rule.
**NEVER** call btw_tool_run_r/btw_tool_pkg_* for long-running operations.

## Shinylive/WebR

Use plotly instead of ggplot2 (munsell breaks). See memory/shinylive-issues.md.

## Session End

1. Commit with `gert` (not bash) -> 2. Update `CURRENT_WORK.md` -> 3. Push to remote
