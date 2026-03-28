# /ctx-check - Check ctx.yaml Coverage

Run this EXACT code. Do NOT modify it or write your own version.

```bash
timeout 30 Rscript -e '
  source("~/docs_gh/llm/R/tar_plans/plan_pkgctx.R")
  ctx_audit("DESCRIPTION")
'
```

If any packages show MISSING or OTHER_VERSION, run:

```bash
timeout 600 Rscript -e '
  source("~/docs_gh/llm/R/tar_plans/plan_pkgctx.R")
  ctx_sync("DESCRIPTION")
'
```

Report the results as a table.
