---
paths:
  - "DESCRIPTION"
  - "default.R"
  - "inst/extdata/ctx/**"
---
# ctx.yaml Central Cache Management

## Central Cache (Version-Stamped)

All dependency `.ctx.yaml` files live in ONE location:

    /Users/johngavin/docs_gh/proj/data/llm/content/inst/ctx/external/

**Naming:** `{pkg}@{version}.ctx.yaml` (e.g., `dplyr@1.1.4.ctx.yaml`)

Different projects using different nix shells get different ctx files — no overwrites.
Each project resolves its version via `packageVersion()` in its own nix shell.

This directory is git-tracked (not gitignored). Files are committed to the
llm/content repo for persistence and recoverability.

### NEVER delete ctx files manually

The central cache is **shared across all projects**. A file like
`rlang@1.1.6.ctx.yaml` may be needed by project A (pinned to nix date X)
even if project B (pinned to date Y) has `rlang@1.1.7` installed. Deleting
the old version to "fix" an OTHER_VERSION audit breaks project A.

| Action | Allowed? |
|---|---|
| Generate a NEW versioned ctx file | Yes — always additive |
| Delete an old versioned ctx file manually | **NEVER** — another project may need it |
| `ctx_cleanup()` (removes files untouched >90 days) | Yes — the dedicated cleanup function |
| `rm` / `file.remove()` on ctx files | **NEVER** unless `ctx_cleanup()` logic |

## MANDATORY: Per-Project Session Triggers

Central code lives in `llm/R/tar_plans/plan_pkgctx.R`. Call from any project:

### Session Start — audit + fix gaps immediately (background)

```r
source("~/docs_gh/llm/R/tar_plans/plan_pkgctx.R")
ctx_audit("DESCRIPTION")
```

Reports OK/STALE/OTHER_VERSION/MISSING for every dep. Takes ~1 second.

**If any gaps found:** immediately launch `ctx_sync()` as a background subagent or `run_in_background` Bash task. Do NOT wait until session end — the ctx files are needed throughout the session.

```r
# Run in background — don't block the session
ctx_sync("DESCRIPTION")  # ~30s per package via nix run github:b-rodrigues/pkgctx
```

### Session End — verify all ctx files are current

```r
source("~/docs_gh/llm/R/tar_plans/plan_pkgctx.R")
ctx_audit("DESCRIPTION")
```

Confirm 0 MISSING. OTHER_VERSION entries are acceptable if `ctx_sync()` was
run — they mean the running nix-shell pins a different version than the latest
ctx file. The correct fix is to run `ctx_sync()` from within the project's own
nix-shell (where `packageVersion()` matches the pin), NOT to delete the old
version. If the project's nix-shell is not available in the current session,
leave OTHER_VERSION entries as-is — they are usable (API signatures rarely
change between minor versions).

## Rules

- **NEVER** copy ctx files into individual project repos
- **NEVER** commit dependency ctx to git (only self-context in plan_pkgctx.R)
- **ALWAYS** use the central cache path — no per-project `.claude/context/`
- **ALWAYS** use version-stamped names: `{pkg}@{version}.ctx.yaml`
- Self-context: `mypackage@0.1.0.ctx.yaml` goes in the central cache too
- Old versions auto-cleaned after 90 days untouched (`ctx_cleanup()`)
- See `llm-package-context` skill for full function reference

## Regeneration Triggers

Regenerate a package's ctx when:
- Installed version differs from ctx `version:` field
- Package added to any project's DESCRIPTION
- After `Rscript default.R` + nix shell re-entry (new package versions)

## Anti-Patterns

- Storing ctx in project `inst/extdata/ctx/` (ships with install)
- Running `nix run github:b-rodrigues/pkgctx` for every dependency (slow)
- Generating ctx for base R packages (utils, stats, methods, graphics, grDevices, datasets, tools, parallel)
- **Deleting ctx files to fix OTHER_VERSION** (breaks other projects sharing the cache; always additive — see "NEVER delete" section above)
- Force-regenerating by deleting old versions and running `ctx_sync` (the new file may have a different version than the running shell's, creating a new OTHER_VERSION entry while losing the old one)

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
