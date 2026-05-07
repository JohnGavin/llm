---
paths:
  - "DESCRIPTION"
  - "default.R"
  - "inst/extdata/ctx/**"
---
# ctx.yaml Central Cache Management

## Central Cache (Version-Stamped)

All `.ctx.yaml` files in ONE location:
```
/Users/johngavin/docs_gh/proj/data/llm/content/inst/ctx/external/
```

**Naming:** `{pkg}@{version}.ctx.yaml` (e.g., `dplyr@1.1.4.ctx.yaml`)

Different projects/nix shells get different versions — no overwrites. Git-tracked for persistence.

### NEVER Delete ctx Files

| Action | Allowed? |
|---|---|
| Generate NEW versioned ctx | Yes |
| Delete old ctx manually | **NEVER** — another project may need it |
| `ctx_cleanup()` (90-day cleanup) | Yes |

## Session Triggers

### Session Start — audit + fix gaps
```r
source("~/docs_gh/llm/R/tar_plans/plan_pkgctx.R")
ctx_audit("DESCRIPTION")  # ~1 second
# If gaps: launch ctx_sync() in background
ctx_sync("DESCRIPTION")   # ~30s per package
```

### Session End — verify
```r
ctx_audit("DESCRIPTION")  # Confirm 0 MISSING
```

OTHER_VERSION is acceptable — means nix-shell pins different version than latest ctx.

## Rules

- **NEVER** copy ctx into individual project repos
- **NEVER** commit dependency ctx to git
- **ALWAYS** use central cache + version-stamped names
- Old versions auto-cleaned after 90 days (`ctx_cleanup()`)

## Regeneration Triggers

- Installed version differs from ctx `version:` field
- Package added to DESCRIPTION
- After `Rscript default.R` + nix shell re-entry

## MANDATORY: Read Context Before Unfamiliar APIs

Before using a package you haven't verified this session:
1. Check if ctx exists: `ls ~/docs_gh/proj/data/llm/content/inst/ctx/external/{pkg}@*.ctx.yaml`
2. If yes: read it (contains all exports, signatures, arguments)
3. If no: generate with `nix run github:b-rodrigues/pkgctx -- r {pkg} --compact`

Critical for: crew, mirai, duckdb, pointblank, targets (complex APIs).

## Quick Reference

| Action | Command |
|--------|---------|
| Check cache | `ls ~/...inst/ctx/external/*.ctx.yaml \| wc -l` |
| Audit project | `ctx_audit("DESCRIPTION")` |
| Sync project | `ctx_sync("DESCRIPTION")` |
| Version check | `grep "^version:" cache/{pkg}@*.ctx.yaml` |
| Find stale | `find cache/ -name "*.ctx.yaml" -mtime +30` |
