---
paths:
  - "tproject.toml"
  - "flake.nix"
  - "src/**/*.t"
  - "packages/**/DESCRIPTION"
---
# Rule: T Language Projects with R Packages

## When This Applies
Any project using the T language (`tproject.toml` present) that also contains an R package.

## CRITICAL: tproject.toml Is the Single Source of Truth for Nix

`t update` regenerates `flake.nix` from `tproject.toml`. **NEVER edit `flake.nix` directly.**

## Two Files, Two Audiences

| File | Audience | Installs via |
|------|----------|-------------|
| `tproject.toml` | Nix/T users | `nix develop` |
| `DESCRIPTION` | R users (no nix) | `pak::pak()` |

**Every new R dep must be added to BOTH.** Missing from one = broken for that audience.

## Adding a Dependency

1. `tproject.toml` `[r-dependencies] packages` — add the package name
2. `DESCRIPTION` Imports or Suggests — add the package name
3. `t update` (inside `nix develop`)
4. `exit && nix develop` (picks up regenerated flake.nix)
5. `Rscript -e 'library(newpkg)'` — verify

## Compiled Packages Segfault Across Shells

Claude's dev shell and the project's `nix develop` shell have different R binaries. Compiled packages (glmnet, duckdb, arrow) segfault when loaded in the wrong shell.

**Always run inside `nix develop`:**
```bash
nix develop /path/to/project --command bash -c 'Rscript -e "..."'
```

## No Degraded Implementations

If code needs package X, install X first. Never write fallback branches.

## Detailed Guides

See `~/docs_gh/llm/knowledge/t-lang/wiki/` for:
- `dependency-management.md` — full checklist and common mistakes
- `nix-shell-architecture.md` — which shell for which task
- `anti-patterns.md` — things that cause bugs

## Related Rules

- `duckdplyr-not-sql` — duckplyr gotchas in nix shells
- `huggingface-upload` — data hosting for T projects
- `nix-nested-shell-isolation` — ABI mismatch details
