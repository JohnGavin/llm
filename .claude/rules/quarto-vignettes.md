---
description: Quarto vignette format, layout, data handling, evidence rules, and deployment validation
paths:
  - "*.qmd"
  - "vignettes/**"
---

# Rule: Quarto Vignette Standards

## Part 1: Format Requirements

### MANDATORY: Quarto Only

- All vignettes use `.qmd` (`.Rmd` FORBIDDEN)
- Required YAML: `format: html:` with `code-fold: true`, `code-summary: "Show code"`
- README.md auto-generated from README.qmd
- Every R chunk must have unique name and map to a pipeline target

### Number Formatting (ZERO TOLERANCE)

| Type | Function | Example |
|------|----------|---------|
| Counts | `round(x, 0)` | 32874 |
| Scores | `signif(x, 4)` | 1.065 |
| Percentages | `round(x, 1)` | 32.2% |
| Probabilities | `round(x, 4)` | 0.4521 |

**15+ decimal places is FORBIDDEN.**

### Tables: DT Only

- ALL tables use `DT::datatable()`, NEVER `knitr::kable()`
- Every table MUST have `caption=`
- DT dark mode via `pkgdown/extra.css` (not per-widget JS)
- Table targets return `data.frame`, NOT DT widgets (contains Nix paths)

## Part 2: Layout Standards

### Full-Width (100% Relative)

Vignette body width is 100% relative (`pkgdown/extra.css`). A worked CSS snippet is in the companion doc.

**Forbidden:** Fixed pixel widths (`max-width: 1200px`)

### Code Folding (MANDATORY)

Every vignette's YAML sets `code-fold: true` and `code-summary: "Show code"`. A worked YAML snippet is in the companion doc.

**FORBIDDEN:** `echo = FALSE` globally when `code-fold: true` is active.

### Sub-Bullet Formatting

Nested detail belongs in sub-bullets, not collapsed into one line. A worked REQUIRED/FORBIDDEN example is in the companion doc.

## Part 3: Data Rules

### CRITICAL: No Computation in Vignettes

**ALL data from:** `tar_load()`, `tar_read()`, or pre-saved RDS in `inst/extdata/`.

**Forbidden:** Database queries, API calls, `lm()`, aggregations.

### Zero Inline Computation

Every chunk is ONE expression, e.g. `show_target("vig_target_name")`.

**Forbidden in non-setup chunks:** `<-`, `print()`, `ggplot()`, `if/else`, `for`.

### No Sampled Data Without Approval

Never use `head()`, `sample_n()`, `slice()` without explicit user approval and documentation.

### CI Pattern: Pre-Computed RDS

CI NEVER runs `tar_make()`. Export vignette targets as RDS. A worked export loop is in the companion doc.

## Part 4: Evidence Rules

### CRITICAL: Claims Require Evidence

Every claim MUST have adjacent empirical evidence (plot, table, test result) within 3 lines.

**Forbidden:** Claim with no adjacent output. `safe_tar_read()` returning NULL.

### No Empty Sections

Every `##`/`###` heading MUST have prose before any code chunk.

### Captioned Visual Required

Every vignette MUST have at least one captioned table or plot.

## Part 5: Deployment Validation

### Post-Publish Validation Table

After every deployment, produce:

| Column | Description |
|--------|-------------|
| Article | vignette slug |
| HTTP | 200 required |
| Errors | count of `#> Error` |
| NULLs | count of `#> NULL` |
| Status | OK/WARN/FAIL |

### Error Pattern Check (MANDATORY)

Grep every rendered article for `"MISSING EVIDENCE"`, `"target not available"`, and `"#> NULL"`; exit 1 on any hit. A worked bash loop is in the companion doc.

### Dark Mode Toggle (MANDATORY)

All pkgdown sites MUST have dark/light toggle defaulting to dark.

### Build-Info Footer (MANDATORY)

Every article footer states pkg version, git SHA, R version, and build date, each hyperlinked to GitHub release/commit/CRAN. A worked example is in the companion doc.

## Fence Parity (Mandatory)

Every `.qmd` file MUST have balanced code fences. An orphan triple-backtick
(unmatched fence) causes Quarto to silently interpret all subsequent markdown as
raw code, breaking headings, prose, and R chunks below the orphan.

**QA gate:** `~/.claude/scripts/check_qmd_fence_parity.sh` — run automatically by `r_code_check.sh` on `vignettes/` and `docs/` at pre-commit time. Manual check + selftest invocation is in the companion doc.

| Pattern | Allowed? |
|---------|----------|
| Triple-backtick code fences (` ``` `) | Yes — must be balanced (even count) |
| Quadruple-backtick escape fences (` ```` `) | Yes — valid for prose showing markdown syntax |
| Orphan opening or closing triple-backtick | **No** — caught by QA gate, exit 1 |

## Pre-Commit Checklist

- [ ] `parse("_targets.R")` succeeds
- [ ] All `vig_*` targets built locally
- [ ] RDS exported to `inst/extdata/vignettes/`
- [ ] No single RDS > 2MB
- [ ] `grep "MISSING EVIDENCE" docs/articles/*.html` returns 0
- [ ] Dark mode toggle present
- [ ] `check_qmd_fence_parity.sh vignettes/` exits 0

## Related

- [`_companions/quarto-vignettes-details.md`](_companions/quarto-vignettes-details.md) — worked code examples split out of this rule (llm#465)
- `accessibility` — WCAG contrast, alt text
- `visualization` — chart standards, captions
