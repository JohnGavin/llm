---
description: Quarto vignette format, layout, data handling, evidence rules, and deployment validation
paths:
  - "*.qmd"
  - "vignettes/**"
---

# Rule: Quarto Vignette Standards

Consolidated from: `quarto-vignette-format`, `quarto-vignette-layout`, `quarto-vignette-data`, `quarto-vignette-evidence`, `quarto-vignette-validation`, `vignette-targets-export`.

---

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

---

## Part 2: Layout Standards

### Full-Width (100% Relative)

```css
/* pkgdown/extra.css */
body > .container { max-width: 100% !important; width: 100% !important; }
.col-md-9 { flex: 0 0 85% !important; }
```

**Forbidden:** Fixed pixel widths (`max-width: 1200px`)

### Code Folding (MANDATORY)

```yaml
format:
  html:
    code-fold: true       # MANDATORY
    code-summary: "Show code"
```

**FORBIDDEN:** `echo = FALSE` globally when `code-fold: true` is active.

### Sub-Bullet Formatting

```markdown
# REQUIRED:
- **DALY:** Disease burden combining:
    - **YLL:** Premature mortality
    - **YLD:** Morbidity component

# FORBIDDEN:
- **DALY:** Disease burden = YLL + YLD.
```

---

## Part 3: Data Rules

### CRITICAL: No Computation in Vignettes

**ALL data from:** `tar_load()`, `tar_read()`, or pre-saved RDS in `inst/extdata/`.

**Forbidden:** Database queries, API calls, `lm()`, aggregations.

### Zero Inline Computation

Every chunk is ONE expression:
```r
show_target("vig_target_name")
```

**Forbidden in non-setup chunks:** `<-`, `print()`, `ggplot()`, `if/else`, `for`.

### No Sampled Data Without Approval

Never use `head()`, `sample_n()`, `slice()` without explicit user approval and documentation.

### CI Pattern: Pre-Computed RDS

CI NEVER runs `tar_make()`. Export vignette targets as RDS:
```r
vignette_targets <- grep("^vig_", tar_manifest()$name, value = TRUE)
for (name in vignette_targets) {
  saveRDS(tar_read_raw(name), file.path("inst/extdata/vignettes", paste0(name, ".rds")))
}
```

---

## Part 4: Evidence Rules

### CRITICAL: Claims Require Evidence

Every claim MUST have adjacent empirical evidence (plot, table, test result) within 3 lines.

**Forbidden:** Claim with no adjacent output. `safe_tar_read()` returning NULL.

### No Empty Sections

Every `##`/`###` heading MUST have prose before any code chunk.

### Captioned Visual Required

Every vignette MUST have at least one captioned table or plot.

---

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

```bash
for pattern in "MISSING EVIDENCE" "target not available" "#> NULL"; do
  grep -FHc "$pattern" docs/articles/*.html | grep -v ':0$' && exit 1
done
```

### Dark Mode Toggle (MANDATORY)

All pkgdown sites MUST have dark/light toggle defaulting to dark.

### Build-Info Footer (MANDATORY)

```
pkgname 0.1.0 | Git abc1234 | R 4.5.2 | Built 2026-04-13
```

Each element hyperlinked to GitHub release/commit/CRAN.

---

## Pre-Commit Checklist

- [ ] `parse("_targets.R")` succeeds
- [ ] All `vig_*` targets built locally
- [ ] RDS exported to `inst/extdata/vignettes/`
- [ ] No single RDS > 2MB
- [ ] `grep "MISSING EVIDENCE" docs/articles/*.html` returns 0
- [ ] Dark mode toggle present

---

## Related

- `accessibility` — WCAG contrast, alt text
- `visualization` — chart standards, captions
