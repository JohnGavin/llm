---
paths:
  - "*.qmd"
  - "vignettes/**"
---
# Quarto Vignette Evidence Rules

Content quality rules for vignette sections. See `quarto-vignette-validation` for deployment checks.

## 11. CLAIMS REQUIRE EVIDENCE (MANDATORY)

**CRITICAL**: Every claim, assertion, or "Key Finding" MUST have adjacent empirical evidence.

**Definition of a claim:**
- Any statement about data patterns, quantitative assertions, comparisons
- Any "Key Finding" callout box
- Words like: "shows", "demonstrates", "reveals", "indicates"

**Requirements:**
1. Evidence MUST appear within 3 lines of the claim (before or after)
2. Evidence MUST be a rendered output (plot, table, test result) — not prose
3. `safe_tar_read()` returning NULL is NOT evidence — the target must exist
4. Claims without evidence are FORBIDDEN — delete the claim or add evidence

**Pre-publication check:**
```r
vignette_targets <- grep("^vig_", tar_manifest()$name, value = TRUE)
tar_make(names = all_of(vignette_targets))
missing <- setdiff(vignette_targets, names(tar_meta())[tar_meta()$error == FALSE])
stopifnot("Missing vignette targets" = length(missing) == 0)
```

**Forbidden:** Claim with no adjacent output. Evidence block returning NULL.

**Good:** Claim immediately followed by `tar_read(vig_X)` rendering a visible plot/table.

**Build-time validation:** After rendering, grep HTML for `<!-- empty tar_read -->` patterns.

## 13. NO EMPTY SECTIONS (MANDATORY)

Every section (`##`/`###`) MUST contain prose text before any code chunk. A heading followed directly by a code chunk is FORBIDDEN.

**Rationale:** In CI builds with `eval=FALSE`, heading + unevaluated chunk = empty section.

**Draft placeholders:** `*This section is under development. See [issue #N] for planned content.*`

**Check:** `awk '/^#{2,4} / { h=$0; next } /^```\{r/ { if (h) print FILENAME": "h; h=""; next } /^[[:space:]]*$/ { next } { h="" }' vignettes/*.qmd`

## 14. CAPTIONED TABLE OR PLOT REQUIRED (MANDATORY)

Every vignette MUST contain at least one captioned table (`DT::datatable(..., caption=)`) or captioned plot (`fig-cap:`). Vignettes with zero visual evidence MUST NOT be merged.

## 15. NO USER INSTRUCTIONS IN ANALYSIS VIGNETTES (MANDATORY)

Analysis vignettes MUST NOT instruct users to run commands.

**Forbidden:** "Run `tar_make()` locally", "Execute `devtools::test()`"

**Allowed:** README.qmd setup instructions, how-to vignettes, descriptive pkgdown banners:
```markdown
::: {.callout-note}
## Online documentation
This vignette shows pre-computed results from the targets pipeline.
Some outputs may appear as placeholders in the online version.
:::
```

## 16. REPRODUCIBILITY SECTIONS MUST ALWAYS RENDER (MANDATORY)

`sessionInfo()` chunks MUST have `eval=TRUE` (override global `eval = !in_pkgdown`). Empty `<details>` sections are an ERROR.

```markdown
```{r session-info, eval=TRUE}
sessionInfo()
```
```

## 17. CHANGELOG FOOTER (ASPIRATIONAL)

**Status:** This rule requires a `vig_git_changelog` target that does NOT exist in most projects.
Until a project implements this target (extracting recent git log entries into a formatted
changelog), this rule is ASPIRATIONAL, not MANDATORY.

**To implement:** Add a `vig_git_changelog` target to `plan_vignette_outputs.R` that uses
`gert::git_log()` to extract the last 10 commits touching vignette files, format as a tibble,
and return it. Then include `safe_tar_read("vig_git_changelog")` in each vignette.

**For projects without vig_git_changelog:** Omit the `## Recent Changes` section entirely.
Do NOT add a placeholder that renders as NULL.

**Check:** `grep -L 'vig_git_changelog' vignettes/*.qmd` — only enforce if `vig_git_changelog` target exists in the pipeline.

## Checklist

- [ ] Every claim/assertion has adjacent plot or table evidence
- [ ] All `tar_read()` calls return non-NULL rendered output
- [ ] No heading followed directly by code chunk without prose
- [ ] Every vignette has at least one captioned table or plot
- [ ] Analysis vignettes don't instruct users to run commands
- [ ] sessionInfo() chunks use `eval=TRUE`
- [ ] Every vignette has ## Recent Changes with vig_git_changelog
