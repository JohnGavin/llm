---
name: feedback_ast-grep-lessons
description: 7 lessons from ast-grep code sweep — rules need enforcement, agent violates own rules, verify counts
type: feedback
---

7 lessons from first ast-grep code sweep (2026-03-30):

1. **Rules need structural enforcement.** grep-based `qa_no_raw_sql` missed `dbGetQuery` that ast-grep found. Text grep has false negatives (comments, strings) and false positives. ast-grep searches the AST.

2. **Old code doesn't auto-update.** `stop()` survived in sync_wiki.R and ccusage.R because they were written before the cli::cli_abort style standard. Schedule periodic sweeps.

3. **The agent violates its own rules.** I wrote `data.frame()` in 3 files this session while the style guide says `tibble()`. I then justified it as "lightweight utilities" instead of fixing it. Speed must not silence standards.

4. **Silent tryCatch is the suppressWarnings of control flow.** 12 `tryCatch(error = function(e) NULL)` in plan_vignette_outputs.R meant errors were invisible. Changed to `cli::cli_warn()` + NULL.

5. **Line count ≠ call count.** ast-grep default output reported 349 lines for 28 tryCatch calls (12x inflation from multi-line matches). Use `--json=compact` + `nrow()` for accurate counts.

6. **Never accept "expected" or "lightweight" as justification.** I said "349 tryCatch — expected for targets" without checking. Reality: 289 lines were in ONE file, all silent error swallowing.

7. **Periodic code sweeps are necessary.** Rules only prevent NEW violations. Old code predating the rule persists until someone sweeps. `/check` now includes ast-grep sweep.

**How to apply:** Run `/check` which includes ast-grep sweep. When reporting counts, use --json. When justifying a violation, cite the documented exception or fix it.
