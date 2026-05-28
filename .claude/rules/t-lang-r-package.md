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
4. `bash default.post.sh` — re-apply closure-rebuild shellHook (stripped by step 3)
5. `exit && nix develop` (picks up patched flake.nix)
6. `Rscript -e 'library(newpkg)'` — verify

## Compiled Packages Segfault Across Shells

Claude's dev shell and the project's `nix develop` shell have different R binaries. Compiled packages (glmnet, duckdb, arrow) segfault when loaded in the wrong shell.

**Always run inside `nix develop`:**
```bash
nix develop /path/to/project --command bash -c 'Rscript -e "..."'
```

## No Degraded Implementations

If code needs package X, install X first. Never write fallback branches.

## CRITICAL: Preserve the Closure-Rebuild shellHook After `t update`

`t update` regenerates `flake.nix` wholesale and **strips** the
closure-rebuild shellHook that prevents compiled-package segfaults. Every
T-lang R project MUST:

1. Ship a `default.post.sh` in the project root (reference: `JohnGavin/historical`)
2. Run `bash default.post.sh` **immediately** after every `t update`
3. Never commit `flake.nix` after `t update` without running `default.post.sh`

Verify the patch is present before committing:

```bash
grep -q "Closure-rebuild" flake.nix || {
  echo "ERROR: run bash default.post.sh first"
  exit 1
}
```

Upstream fix tracked in llm#303. When T-lang bakes the closure-rebuild into
its template, `default.post.sh` is no longer needed for this purpose.

## Detailed Guides

See `~/docs_gh/llm/knowledge/t-lang/wiki/` for:
- `dependency-management.md` — full checklist and common mistakes
- `nix-shell-architecture.md` — which shell for which task
- `anti-patterns.md` — things that cause bugs

## Related Rules

- `duckdplyr-not-sql` — duckplyr gotchas in nix shells
- `huggingface-upload` — data hosting for T projects
- `nix-nested-shell-isolation` — ABI mismatch details and T-lang workaround
- llm#303 — upstream T-lang template fix request
