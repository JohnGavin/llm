---
paths:
  - "*.qmd"
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

**Agent workflow (manual — no automated enforcement yet):**
1. After any `pkgdown::build_site()` or CI workflow
2. Produce the validation table for every article
3. Report issues before claiming success
4. Print full URLs for user verification

**Lesson learned (2026-03-14):** This validation step is entirely agent-driven — there is no
hook, CI step, or target that enforces it. Agents routinely skip it because nothing blocks
completion without it. The `qa_vignette_compliance` target in `plan_qa_gates.R` partially
addresses this by checking source .qmd files, but does NOT check the deployed HTML output.
Full post-publish validation remains a manual agent responsibility.

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

## 20. BUILD-INFO FOOTER (MANDATORY)

Every vignette and dashboard MUST include a build-info footer with linked metadata.
This provides traceability from rendered HTML back to exact source code, R version,
and build timestamp.

### Required Output Format

```
pkgname 0.1.0 | Git abc1234 | R 4.5.2 | Built 2026-04-13 14:30:00
```

Where each value is a **clickable hyperlink**:

| Element | Links to | URL pattern |
|---------|----------|-------------|
| Version (`0.1.0`) | GitHub release/tag for that version | `https://github.com/{owner}/{repo}/releases/tag/v{version}` |
| Git SHA (`abc1234`) | GitHub commit page | `https://github.com/{owner}/{repo}/commit/{full_sha}` |
| R version (`4.5.2`) | CRAN R release news | `https://cran.r-project.org/doc/manuals/r-release/NEWS.html` |
| Build timestamp | Not linked (informational) | — |

### Required R Code (as a target or inline chunk)

Store as a `vig_build_info` target in `plan_vignette.R`, or use this chunk
directly in each vignette:

```r
#| label: build-info
#| echo: false
#| results: asis

# Discover GitHub remote URL
gh_url <- tryCatch({
  remote <- system("git remote get-url origin 2>/dev/null", intern = TRUE)
  sub("\\.git$", "", sub("^git@github\\.com:", "https://github.com/", remote))
}, error = function(e) NULL)

git_sha_short <- tryCatch(
  system("git rev-parse --short HEAD 2>/dev/null", intern = TRUE),
  error = function(e) "N/A"
)
git_sha_full <- tryCatch(
  system("git rev-parse HEAD 2>/dev/null", intern = TRUE),
  error = function(e) git_sha_short
)

pkg_ver <- tryCatch(
  as.character(packageVersion("PKGNAME")),
  error = function(e) "dev"
)

r_ver <- as.character(getRversion())
build_time <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")

# Build linked markdown
ver_link <- if (!is.null(gh_url)) {
  sprintf("[%s](%s/releases/tag/v%s)", pkg_ver, gh_url, pkg_ver)
} else pkg_ver

sha_link <- if (!is.null(gh_url) && git_sha_short != "N/A") {
  sprintf("[`%s`](%s/commit/%s)", git_sha_short, gh_url, git_sha_full)
} else sprintf("`%s`", git_sha_short)

r_link <- sprintf("[%s](https://cran.r-project.org/doc/manuals/r-release/NEWS.html)", r_ver)

cat(sprintf(
  "\n---\n\n**PKGNAME** %s | **Git** %s | **R** %s | **Built** %s\n",
  ver_link, sha_link, r_link, build_time
))
```

Replace `PKGNAME` with the actual package name. For non-package projects,
use the project directory name and omit the version link.

### Fallbacks

| Environment | Behaviour |
|-------------|-----------|
| Local dev (git available) | Full SHA, version from `packageVersion()` |
| CI (GitHub Actions) | SHA from `$GITHUB_SHA`, version from DESCRIPTION |
| WebR/Shinylive (no git) | Hardcoded fallback version, SHA = "N/A" |
| pkgdown articles | Use `Sys.getenv("GITHUB_SHA")` if git unavailable |

### Pre-Computed as Target (Preferred)

For the code-as-target pattern, store as `vig_build_info`:

```r
tar_target(vig_build_info, {
  # ... same code as above, returning the markdown string ...
  sprintf("**pkg** %s | **Git** %s | **R** %s | **Built** %s",
          ver_link, sha_link, r_link, build_time)
})
```

Then in the vignette: `safe_tar_read("vig_build_info")` with `results: asis`.

## Pre-computed outputs for CI

When vignettes use `tar_read()`, CI needs fallback to pre-computed RDS. See `vignette-targets-export` rule for the `safe_tar_read()` pattern and RDS export workflow.

## Checklist

- [ ] Validation table produced after every deployment
- [ ] `grep "[MISSING EVIDENCE]" docs/articles/*.html` returns 0
- [ ] Dark mode toggle present, defaults to dark
- [ ] All content readable in both light and dark modes
- [ ] Ran `tar_make()` before building vignettes
- [ ] Build-info footer present with linked version, SHA, and R version
