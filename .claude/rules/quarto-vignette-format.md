---
paths:
  - "*.qmd"
  - "vignettes/**"
---
# Quarto Vignette Format Rules

## 0. QUARTO FORMAT ONLY (NO .Rmd)

All vignettes MUST use `.qmd`. R Markdown `.Rmd` is FORBIDDEN for vignettes.

Required YAML header: `format: html:` with `code-fold: true`, `code-summary: "Show code"`.

Forbidden: `.Rmd` in `vignettes/`, `output: rmarkdown::html_vignette`, `VignetteEngine{knitr::rmarkdown}`.

**Exception — VignetteIndexEntry:** When `VignetteBuilder: quarto` is in DESCRIPTION and the package is on CRAN, Quarto vignettes MUST include `VignetteIndexEntry` + `VignetteEngine{quarto::html}` + `VignetteEncoding{UTF-8}`. For pkgdown-only articles, omit them.

## 0b. CHUNK-TARGET MAPPING

Every R code chunk MUST: (1) have a unique name, (2) map to a pipeline target, (3) use `show_target("vig_*")` with `#| echo: false` and `#| results: asis`.

Exceptions: `setup`, `pkgdown-banner`, `session-info`.

## 0c. README MUST BE README.qmd

`README.md` auto-generated from `README.qmd`. Static code examples with fabricated `#>` output are FORBIDDEN. All code targets MUST `parse(text=code)` for R or `bash -n` for bash.

## 0d. _targets.R PARSE CHECK (ALL PROJECTS)

Before every commit: `parse("_targets.R")` MUST succeed. A syntax error in `_targets.R` breaks the entire pipeline — no target can run, no vignette can render, no validation can execute. This applies to ALL projects, not just coMMpass.

## 1. UNIQUE SECTION TITLES

Every heading must be unique and descriptive. Forbidden: `## Row`, `### Column`, duplicate titles. Use `## Data Coverage {#data-coverage}`.

## 2. PARAMETERIZED TITLES

Vignette titles must be consistent with pkgdown navbar. Store in targets, reference in YAML.

## 3. INTERACTIVE TABLES + MANDATORY CAPTIONS

All tables MUST use `DT::datatable()`, NEVER `knitr::kable()`. Every table MUST have `caption=`.

### Table Targets MUST Return data.frame (Not DT)

`DT::datatable` objects contain hardcoded nix store paths in `htmlDependency` attributes. When serialized to RDS and loaded on CI, paths break.

**MANDATORY**: Table targets return plain `data.frame`/`tibble`. DT wrapping happens in the `.qmd` file at render time.

### DataTables CDN Required

Each vignette MUST include the DataTables CDN:
```html
<link rel="stylesheet" href="https://cdn.datatables.net/1.13.8/css/jquery.dataTables.min.css">
<script src="https://cdn.datatables.net/1.13.8/js/jquery.dataTables.min.js"></script>
```

### Number Formatting (ZERO TOLERANCE FOR SPURIOUS PRECISION)

15+ decimal places is FORBIDDEN. Defaults:

| Type | Function | Example |
|------|----------|---------|
| Counts | `round(x, 0)` | 32874 |
| Scores | `signif(x, 4)` | 1.065 |
| Percentages | `round(x, 1)` | 32.2% |
| Probabilities | `round(x, 4)` | 0.4521 |
| Money | `round(x, 0)` | 11484 |

Rows ordered by primary metric (highest first). Time columns in reverse chronological.

## 4. CODE-AS-TARGETS WITH SHOW/HIDE

User-facing code examples MUST be stored as targets:
1. Store as character vector target in `plan_doc_examples.R`
2. Validate with `parse_code_example()` target
3. Display hidden by default (`<details>` collapsed)
4. Extract viz code into named functions, use `deparse(body(fn))` for provenance

## 5. DASHBOARD FORMAT

When using `format: dashboard`: descriptive `#` page names, `## Row` only for layout with `{.hidden}`, `{.tabset}` with descriptive tabs, explicit anchor IDs.

See also: `quarto-vignette-layout`, `quarto-vignette-evidence`.

## Checklist (Format)

- [ ] No duplicate section titles
- [ ] Titles match pkgdown navbar
- [ ] No `knitr::kable()` — use `DT::datatable()` with `caption=`
- [ ] All `DT::datatable()` have `caption=`
- [ ] Code examples stored as targets (section 4)
- [ ] Dashboard pages have descriptive names (section 5)
