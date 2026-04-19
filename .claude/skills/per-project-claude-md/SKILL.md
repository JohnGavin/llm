---
name: per-project-claude-md
description: Use when setting up a per-project CLAUDE.md for a new R package or analysis project. Creates a slim project-level config that points to global rules and adds project-specific overrides. Triggers: per-project config, project CLAUDE.md, project-level claude config, project overrides.
---
# Per-Project CLAUDE.md Skill

Slim project-level config at `<project>/.claude/CLAUDE.md`. Points to global `~/.claude/CLAUDE.md` for shared rules, then adds only what is genuinely project-specific.

## When to Use

- Setting up a new R package project
- A project has rules that conflict with global defaults
- You need to disable a global rule for one project (e.g., a non-R project that ignores R-specific rules)
- A project has sensitive-data rules the global config doesn't cover

## What Goes in a Per-Project CLAUDE.md

Keep it short. The global CLAUDE.md is loaded first; per-project config supplements, it does not replace.

Appropriate project-level overrides:
- Nix shell path (absolute path to project's `default.nix`)
- Package name and primary domain (so agents don't have to discover it)
- Active skills subset (which global skills are most relevant)
- Disabled rules (with reason)
- PHI / data sensitivity flags
- Project-specific agents or targets store paths
- Quality gate threshold if exploration-mode (60 instead of 80)

Do NOT copy-paste global rules into the per-project file. Reference them by name.

## Template

Copy, fill in the `<PLACEHOLDERS>`, and save to `<project>/.claude/CLAUDE.md`.

```markdown
# <PROJECT_NAME> — Project Config

Global config: `~/.claude/CLAUDE.md` (loaded first, all rules apply unless overridden here).

## Project Identity

| Field | Value |
|-------|-------|
| Package name | `<package_name>` |
| Primary domain | <e.g. marine buoys, cancer genomics, fintech> |
| Stage | <exploration / active development / maintenance> |
| Nix shell | `<absolute_path>/default.nix` |
| Targets store | `_targets/` (default) |
| R version | 4.5.x (from `default.nix`) |

## Active Skills (prioritized for this project)

Most relevant global skills for this project, listed so agents don't have to guess:

- `<skill-name>` — <one-line reason>
- `<skill-name>` — <one-line reason>

## Project-Specific Rules

### Data Sensitivity

<!-- Mark one: -->
- [ ] No PHI or confidential data
- [ ] Contains PHI — NEVER push to public GitHub; all data files in `.gitignore`
- [ ] Confidential client data — see `<path>/data/README.md` for handling rules

### Quality Gate Threshold

<!-- Default is Bronze (80). Override only if this is an exploration project. -->
<!-- Minimum score: 80 (production) | 60 (exploration) -->
Minimum score: 80

### Disabled Global Rules

<!-- Only list rules that genuinely do not apply. Include reason. -->
<!-- Example:
- `quarto-vignette-data`: no vignettes in this project
- `data-validation-timeseries`: no time-series data
-->

### Project-Specific Agents

<!-- Only if this project has custom agent configurations beyond the global 11. -->
<!-- Example:
- `targets-runner`: always use `nix-shell <absolute_path>/default.nix --run "Rscript -e targets::tar_make()"`
-->

## Session Conventions

<!-- Project-specific session start/end checks beyond the global defaults. -->
<!-- Example:
- Check `data/raw/` freshness: files older than 7 days may need re-download
- Run `plan_data_validation` targets before committing
-->
```

## Symlink Pattern (Optional)

If a project's per-project CLAUDE.md should track the main llm config repo, use a symlink:

```bash
# From inside the project's .claude/ directory
ln -s ~/docs_gh/llm/.claude/skills/per-project-claude-md/TEMPLATE.md CLAUDE.md
```

Only use a symlink when the project truly has no project-specific overrides — i.e., it is a satellite project that follows all global rules exactly.

## Creating a Per-Project CLAUDE.md

1. Run this skill
2. Agent creates `<project>/.claude/CLAUDE.md` from the template above
3. Agent fills in the placeholders based on the project's `DESCRIPTION`, `default.nix`, and `_targets.R`
4. Agent opens the file for user review
5. User edits any fields that need adjustment

## Validation Checklist

After creating the per-project CLAUDE.md, verify:

- [ ] Nix shell path is absolute (not relative)
- [ ] No global rules are copied wholesale (reference by name only)
- [ ] PHI flag is set correctly
- [ ] Quality gate threshold is 80 unless explicitly exploration
- [ ] Disabled rules each have a reason
