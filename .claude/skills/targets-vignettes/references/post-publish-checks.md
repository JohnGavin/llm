# Post-Publish Checks — Code Examples

Reference for `quarto-vignette-validation.md` rule.

## Missing Evidence — Pre-deployment bash check

```bash
grep -r "\[MISSING EVIDENCE\]" docs/articles/*.html && exit 1
```

## Missing Evidence — CI YAML step

```yaml
- name: Check for missing evidence
  run: |
    if grep -r "\[MISSING EVIDENCE\]" docs/articles/*.html; then
      echo "ERROR: Missing evidence found in vignettes"
      exit 1
    fi
```

## Dark Mode Toggle — `_pkgdown.yml`

```yaml
template:
  bootstrap: 5
  light-switch: true
  bslib:
    preset: "shiny"
```

## Dark Mode Toggle — `pkgdown/extra.js`

```js
if (!localStorage.getItem('theme')) {
  document.documentElement.setAttribute('data-bs-theme', 'dark');
}
```

## Build-Info Footer — Inline chunk

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

Replace `PKGNAME` with the actual package name.

## Build-Info Footer — Pre-computed target

```r
tar_target(vig_build_info, {
  # ... same code as above, returning the markdown string ...
  sprintf("**pkg** %s | **Git** %s | **R** %s | **Built** %s",
          ver_link, sha_link, r_link, build_time)
})
```

Then in the vignette: `safe_tar_read("vig_build_info")` with `results: asis`.
