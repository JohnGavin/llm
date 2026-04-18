---
paths: ["**/_targets.R", "**/plan_qa*.R", "**/plan_vig*.R"]
---

# Rule: QA Targets in Every Pipeline

## When This Applies
Any project using targets for pre-computed vignette outputs, dashboards,
or any user-visible rendered content.

## CRITICAL: Validate Outputs Before Rendering

Every pipeline that produces user-visible outputs (plots, tables, HTML)
MUST have QA validation targets that run AFTER computation targets
and BEFORE rendering. Without these, a single corrupted target cascades
to broken HTML deployed to users.

## Mandatory QA Targets

| Target | What | Fails Build? | Priority |
|--------|------|-------------|----------|
| `qa_no_nulls` | All `vig_*` targets return non-NULL | Yes — abort | P0 |
| `qa_html_no_nulls` | Rendered HTML has zero NULL/Error | Yes — abort | P0 |
| `qa_plot_valid` | Plot targets are ggplot, table targets are data.frame | Yes — abort | P1 |
| `qa_no_raw_sql` | Code targets contain no `dbGetQuery`/`SELECT` | Warn | P1 |
| `qa_rds_sync` | RDS fallback files match target names | Yes — abort | P2 |
| `qa_target_qmd_sync` | `.qmd` file `tar_read()` calls match target names | Yes — abort | P2 |

## Encoding Safety

All string data from external APIs (yfinance, CoinGecko, FRED) MUST pass through:
```r
iconv(x, to = "UTF-8", sub = "")
```
before storing in Parquet or RDS. Embedded NUL bytes (0x00) in strings corrupt
serialisation and cause cascading NULL outputs in rendered vignettes.

## Cascading Failure Isolation

Use `tar_option_set(error = "continue")` so one broken target doesn't prevent
all others from building. Report failures at the end, not during.

## No Raw SQL in Code Targets

Use `duckplyr::read_parquet_duckdb()` for zero-SQL access to Parquet files.
`dplyr::tbl(con, sql("SELECT..."))` still contains raw SQL inside `sql()`.
`duckplyr` is the only truly SQL-free approach for DuckDB-backed Parquet.

## Version Discipline

- NEVER ship `0.0.0.9000` to users
- Bump to `0.1.0` before first public deploy (GH Pages, pkgdown, vignette)
- After that: patch = bugfix, minor = feature, major = breaking

## Why This Rule Exists

Learned from the `historicaldata` project (2026-04-12): 1 corrupted target
(`vig_meta_lse_currency` with embedded NUL bytes from yfinance) cascaded to
25 NULL outputs in rendered HTML. Deployed to GH Pages. No pipeline target
caught it. Users saw "NULL" instead of plots and tables for days.

## Related Rules

- `quarto-vignette-validation` — post-publish checks
- `quarto-vignette-data` — zero inline computation
- `duckdplyr-not-sql` — no raw SQL
- `verification-before-completion` — grep HTML for NULL before push
