# pkgctx Project Integration Examples

**CENTRAL CACHE:** All ctx files go to `~/docs_gh/proj/data/llm/content/inst/ctx/external/`
**NEVER** use per-project `.claude/context/` — use the central cache.

## Preferred Method: ctx_sync() (automatic)

```r
# From ANY project directory:
source("~/docs_gh/llm/R/tar_plans/plan_pkgctx.R")
ctx_audit("DESCRIPTION")   # report coverage
ctx_sync("DESCRIPTION")    # generate missing + refresh stale
```

This reads DESCRIPTION, checks the central cache, and generates any missing ctx files automatically. Version-stamped: `{pkg}@{version}.ctx.yaml`.

## Manual Generation (single package)

```bash
CTX=~/docs_gh/proj/data/llm/content/inst/ctx/external

# CRAN package
nix run github:b-rodrigues/pkgctx -- r dplyr --compact > $CTX/dplyr@1.1.4.ctx.yaml

# Bioconductor
nix run github:b-rodrigues/pkgctx -- r bioc:TCGAbiolinks --compact > $CTX/TCGAbiolinks@2.34.0.ctx.yaml

# GitHub
nix run github:b-rodrigues/pkgctx -- r github:ropensci/rix --compact > $CTX/rix@0.18.1.ctx.yaml

# Current package (self-context)
nix run github:b-rodrigues/pkgctx -- r . --compact > $CTX/mypackage@0.1.0.ctx.yaml
```

## Using Context in Prompts

```bash
# Read a package's API before using it
cat ~/docs_gh/proj/data/llm/content/inst/ctx/external/targets@1.11.4.ctx.yaml

# Combine multiple for a task
cat $CTX/targets@*.ctx.yaml $CTX/dplyr@*.ctx.yaml > /tmp/combined.ctx.yaml
```

## Automated (session_init.sh hook)

The `session_init.sh` hook runs `ctx_audit` at every session start and auto-launches
`ctx_sync` in background if any gaps are found. No manual intervention needed.

The `plan_pkgctx()` targets also run on every `tar_make()`.
