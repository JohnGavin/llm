---
paths:
  - "*.qmd"
  - "*.Rmd"
  - "vignettes/**"
  - ".github/workflows/**"
---
# Quarto Vignette Deployment Validation

Post-publish and pre-deployment checks. See `quarto-vignette-evidence` for content quality rules.

## 12. POST-PUBLISH VALIDATION (MANDATORY)

After EVERY pkgdown deployment, produce a **Validation Table** with these columns:

| Column | Description |
|--------|-------------|
| Article | vignette slug |
| URL | full clickable URL |
| HTTP | status code (must be 200) |
| Size | page size in KB |
| Updated | Last-Modified header or git commit datetime |
| Age | human-readable (e.g. "2 min ago") |
| Errors | count of `#> Error` in HTML |
| NULLs | count of `#> NULL` in HTML |
| Status | OK / WARN / FAIL |

**Agent workflow:**
1. After any `pkgdown::build_site()` or CI workflow
2. Produce the validation table for every article
3. Report issues before claiming success
4. Print full URLs for user verification

Use `httr2::request(url) |> req_perform()` to fetch each article, count error patterns with `gregexpr()`, and report. See `R/dev/validate_pkgdown_deploy.R` for the reference implementation.

**Additional checks:** site structure pages, cross-article `#fragment` links, dark mode toggle.

## 18. [MISSING EVIDENCE] VALIDATION (MANDATORY)

Before any pkgdown deployment, grep for `[MISSING EVIDENCE]` patterns.

**Pre-deployment check:**
```bash
grep -r "\[MISSING EVIDENCE\]" docs/articles/*.html && exit 1
```

**CI integration:**
```yaml
- name: Check for missing evidence
  run: |
    if grep -r "\[MISSING EVIDENCE\]" docs/articles/*.html; then
      echo "ERROR: Missing evidence found in vignettes"
      exit 1
    fi
```

**Common causes:** Forgot `tar_make()`, forgot RDS export, target name typo, target returns NULL.

**Fix:** Run `tar_make(names = starts_with("vig_"))`, export RDS to `inst/extdata/vignettes/`, rebuild site, verify grep returns nothing.

## 19. DARK MODE TOGGLE (MANDATORY)

All pkgdown sites MUST have a dark/light mode toggle defaulting to dark.

**Required `_pkgdown.yml`:**
```yaml
template:
  bootstrap: 5
  light-switch: true
  bslib:
    preset: "shiny"
```

**Required `pkgdown/extra.js`:**
```js
if (!localStorage.getItem('theme')) {
  document.documentElement.setAttribute('data-bs-theme', 'dark');
}
```

**Rules:** Dark mode default for first-time visitors. All visualizations readable in both modes. Mermaid uses dark theme (see `diagram-generation.md`).

## Pre-computed outputs for CI

When vignettes use `tar_read()`, CI needs fallback to pre-computed RDS. See `vignette-targets-export` rule for the `safe_tar_read()` pattern and RDS export workflow.

## Checklist

- [ ] Validation table produced after every deployment
- [ ] `grep "[MISSING EVIDENCE]" docs/articles/*.html` returns 0
- [ ] Dark mode toggle present, defaults to dark
- [ ] All content readable in both light and dark modes
- [ ] Ran `tar_make()` before building vignettes
