# llm — Project Config

Global config: `~/.claude/CLAUDE.md` (loaded first, all rules apply unless overridden here).

## Project Identity

| Field | Value |
|-------|-------|
| Package name | `llm` |
| Primary domain | Claude Code configuration, agent workflows, Nix + R toolchain |
| Stage | Active development |
| Environment | `dev` |
| Nix shell | `/Users/johngavin/docs_gh/llm/default.nix` |
| Targets store | `_targets/` (default) |
| R version | 4.5.x (from `default.nix`) |

## Active Skills (prioritized for this project)

- `knowledge-base-wiki` — central knowledge hub lives here at `knowledge/`
- `targets-pipeline-spec` — orchestrates agent/skill/rule config generation
- `nix-rix-r-environment` — manages the global dev shell and project shells
- `hooks-automation` — hooks for session management, context survival, file protection
- `ci-workflows-github-actions` — CI for the llm package itself

## Project-Specific Rules

### Data Sensitivity

- [x] No PHI or confidential data in the package source
- Note: `knowledge/` subdirectory is a separate local-only git repo with a pre-push block. It is excluded from this package's git history via `.gitignore`.

### Quality Gate Threshold

Minimum score: 80 (production)

### Disabled Global Rules

- `look-ahead-bias-prevention`: no financial backtesting in this project
- `data-validation-timeseries`: no time-series data pipeline

### Exploration Area

The `explorations/` directory uses relaxed quality thresholds (minimum 60).
See `explorations/CONVENTIONS.md` for the graduation workflow.

### Project-Specific Agents

- `targets-runner`: enter project shell first:
  `nix-shell /Users/johngavin/docs_gh/llm/default.nix --run "Rscript -e 'targets::tar_make()'"`
- `nix-env`: regenerate default.nix with:
  `nix-shell ~/docs_gh/rix.setup/default.nix --run "Rscript /Users/johngavin/docs_gh/llm/default.R"`

## Session Conventions

- Read `knowledge/` INDEX.md to orient on current cross-project knowledge state
- Run `~/.claude/scripts/r_code_check.sh R/` before committing
- CHANGELOG.md append at session end is mandatory (global rule)
- `.claude/CURRENT_WORK.md` is session-ephemeral (gitignored)
