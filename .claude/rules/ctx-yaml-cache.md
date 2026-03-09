---
paths:
  - "DESCRIPTION"
  - "default.R"
  - "inst/extdata/ctx/**"
---
# ctx.yaml Central Cache Management

## Central Cache

All dependency `.ctx.yaml` files live in ONE location:

    /Users/johngavin/docs_gh/proj/data/llm/content/inst/ctx/external/

This directory is gitignored. Files are local-only for LLM context.

## MANDATORY: Session-Start Sync

When starting work on ANY R package project:

1. Read DESCRIPTION -> extract Imports + Suggests
2. For each dependency, check if `{pkg}.ctx.yaml` exists in the cache
3. If exists: compare `version:` line in ctx vs `packageVersion(pkg)` installed
4. If missing or version mismatch: regenerate using `generate_ctx()`
5. Report summary: N synced, N regenerated, N missing (not installed)

## Rules

- **NEVER** copy ctx files into individual project repos
- **NEVER** commit dependency ctx to git (only self-context in plan_pkgctx.R)
- **ALWAYS** use the central cache path -- no per-project `.claude/context/`
- Self-context (`mypackage.ctx.yaml`) goes in the central cache too
- Stubs (metadata only, no signatures) are acceptable for uninstalled packages
- See `llm-package-context` skill for `sync_ctx_cache()` and `generate_ctx()` functions

## Regeneration Triggers

Regenerate a package's ctx when:
- Installed version differs from ctx `version:` field
- Package added to any project's DESCRIPTION
- After `Rscript default.R` + nix shell re-entry (new package versions)

## Anti-Patterns

- Storing ctx in project `inst/extdata/ctx/` (ships with install)
- Running `nix run github:b-rodrigues/pkgctx` for every dependency (slow)
- Generating ctx for base R packages (utils, stats, methods, graphics, grDevices, datasets, tools, parallel)

## Quick Reference

| Action | Command |
|--------|---------|
| Check cache | `ls ~/docs_gh/proj/data/llm/content/inst/ctx/external/*.ctx.yaml \| wc -l` |
| Sync project | Run `sync_ctx_cache()` from llm-package-context skill |
| Regenerate one | `generate_ctx("dplyr")` and write to cache |
| Version check | `grep "^version:" cache/dplyr.ctx.yaml` vs `packageVersion("dplyr")` |
