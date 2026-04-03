# Quality Gates Gotchas

Hard-won lessons from real projects. Read these BEFORE writing quality gate code.

## grep-based enforcement has false negatives

The original `qa_no_raw_sql` target used `grep("DBI::dbGetQuery", all_code)`. This is TEXT search — it catches matches in comments and strings (false positives) AND misses calls that span multiple lines or use variables (false negatives).

**Fix:** Use ast-grep for structural search. The updated target uses `ast-grep run -c $CFG -l r -p 'DBI::dbGetQuery(___)' R/ --json=compact` which searches the AST.

**Lesson:** Rules without structural enforcement are suggestions.

## Silent tryCatch swallows errors

`tryCatch(expr, error = function(e) NULL)` hides failures. 12 instances in `plan_vignette_outputs.R` meant errors in vignette data computation were invisible — problems showed up as NULL in rendered output with no clue why.

**Fix:** `tryCatch(expr, error = function(e) { cli::cli_warn(...); NULL })` — log before returning NULL.

## Line count ≠ call count in tool output

ast-grep default output counts LINES per match (multi-line expressions span many lines). Reported "349 tryCatch calls" when the answer was 28 calls across 349 lines. 12x inflation.

**Fix:** Use `--json=compact` + `nrow(jsonlite::fromJSON(...))` for accurate call counts.

## Agent violates its own quality rules

The agent wrote `data.frame()` in 3 files during a session while the style guide says `tibble()`. It then justified the violation as "lightweight utilities" instead of fixing it.

**Fix:** Run `/check` (which includes ast-grep sweep) after every implementation session. Don't trust the agent's self-assessment.

## Old code predates current rules

`stop()` calls survived in `sync_wiki.R` and `ccusage.R` because they were written before `cli::cli_abort()` became the standard. The rule only prevents new violations.

**Fix:** Periodic ast-grep sweeps catch historical violations. Add sweep to `/check` command.
