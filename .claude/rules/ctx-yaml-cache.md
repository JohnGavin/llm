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

## MANDATORY: Read Context Before Using Unfamiliar APIs

Before writing code that uses an R package you haven't used in this session:

1. Check if `{pkg}.ctx.yaml` exists in the central cache
2. If yes: **read it first** — it contains every exported function, signature, and argument
3. If no: generate it (`nix run github:b-rodrigues/pkgctx -- r {pkg} --compact`)
4. Reference the context when writing code — this prevents hallucinated function names and wrong argument orders

```bash
# Quick check: does context exist for this package?
ls ~/docs_gh/proj/data/llm/content/inst/ctx/external/{pkg}.ctx.yaml 2>/dev/null
```

**When to read context:** Any time you write `library(pkg)` or `pkg::func()` for a package you haven't verified in this session. Especially critical for: crew, mirai, duckdb, pointblank, targets (complex APIs with many arguments).

## Staleness Detection

At session start, check for stale contexts (>30 days old or version mismatch):

```bash
# Find stale ctx files (>30 days)
find ~/docs_gh/proj/data/llm/content/inst/ctx/external/ -name "*.ctx.yaml" -mtime +30
```

```r
# Version mismatch check (run in R)
ctx_dir <- "~/docs_gh/proj/data/llm/content/inst/ctx/external/"
ctx_files <- list.files(ctx_dir, pattern = "\\.ctx\\.yaml$", full.names = TRUE)
for (f in ctx_files) {
  pkg <- sub("\\.ctx\\.yaml$", "", basename(f))
  ctx_ver <- sub(".*version:\\s*", "", grep("^version:", readLines(f, 5), value = TRUE))
  if (requireNamespace(pkg, quietly = TRUE)) {
    inst_ver <- as.character(packageVersion(pkg))
    if (ctx_ver != inst_ver) cat("STALE:", pkg, "ctx=", ctx_ver, "installed=", inst_ver, "\n")
  }
}
```

Stale contexts risk: hallucinated arguments that existed in old versions, missing new functions, wrong default values.

## Agent Integration

Agents (`r-debugger`, `reviewer`, `critic`, `fixer`, `targets-runner`) SHOULD read `.ctx.yaml` for any package central to their task:

| Agent | When to Read Context |
|-------|---------------------|
| `critic` / `reviewer` | Before reviewing code that uses external packages — verify function signatures are correct |
| `fixer` | Before applying fixes that call package functions — confirm argument names |
| `r-debugger` | When debugging errors involving external packages — check if API changed |
| `targets-runner` | Before diagnosing pipeline failures involving package calls |

**Pattern for agents:**
```
Before writing or reviewing code using {pkg}:
1. cat ~/docs_gh/proj/data/llm/content/inst/ctx/external/{pkg}.ctx.yaml
2. Verify function names, arguments, and return types match
3. If ctx missing: flag as "unverified API usage" in report
```

## Quick Reference

| Action | Command |
|--------|---------|
| Check cache | `ls ~/docs_gh/proj/data/llm/content/inst/ctx/external/*.ctx.yaml \| wc -l` |
| Sync project | Run `sync_ctx_cache()` from llm-package-context skill |
| Regenerate one | `generate_ctx("dplyr")` and write to cache |
| Version check | `grep "^version:" cache/dplyr.ctx.yaml` vs `packageVersion("dplyr")` |
| Find stale | `find cache/ -name "*.ctx.yaml" -mtime +30` |
| Read before use | `cat cache/{pkg}.ctx.yaml` before writing `pkg::func()` |
