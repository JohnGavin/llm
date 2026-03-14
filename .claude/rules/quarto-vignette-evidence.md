---
paths:
  - "*.qmd"
  - "*.Rmd"
  - "vignettes/**"
---
# Quarto Vignette Evidence Rules

Split from `quarto-vignette-format` — covers evidence, validation, and content quality.

## 11. CLAIMS REQUIRE EVIDENCE (MANDATORY)

**CRITICAL**: Every claim, assertion, or "Key Finding" in a vignette MUST have
immediately adjacent empirical evidence in the form of a plot or table.

**Definition of a claim:**
- Any statement about data patterns ("Home teams score more")
- Any quantitative assertion ("~380 matches per season")
- Any comparison ("Dixon-Coles outperforms GLM")
- Any "Key Finding" callout box
- Any statement using words like: "shows", "demonstrates", "reveals", "indicates"

**Requirements:**
1. Evidence MUST appear within 3 lines of the claim (before or after)
2. Evidence MUST be a rendered output (plot, table, test result) — not prose
3. `safe_tar_read()` returning NULL is NOT evidence — the target must exist
4. Claims without evidence are FORBIDDEN — delete the claim or add evidence

**Audit procedure:**
1. Grep for "Key Finding", `::: {.callout-`, and assertion words
2. For each match, verify an adjacent `tar_read()` or output block exists
3. Run `tar_make()` and verify the output renders (not NULL/empty)
4. Review rendered HTML — blank sections indicate missing evidence

**Pre-publication check (MANDATORY):**
```r
# Verify all vignette targets exist before building
vignette_targets <- grep("^vig_", tar_manifest()$name, value = TRUE)
tar_make(names = all_of(vignette_targets))
missing <- setdiff(vignette_targets, names(tar_meta())[tar_meta()$error == FALSE])
stopifnot("Missing vignette targets" = length(missing) == 0)
```

**Forbidden patterns:**
```markdown
# BAD: Claim with no evidence
Most historical league-seasons achieve 100% completeness.

# BAD: Evidence block returns NULL
```{r}
safe_tar_read("vig_completeness_plot")  # Returns NULL - target doesn't exist!
```

# GOOD: Claim immediately followed by rendered evidence
Most historical league-seasons achieve 100% completeness, as shown below.

```{r}
tar_read(vig_completeness_plot)  # Must render a visible heatmap
```
```

**Build-time validation:**
Add to `vignettes/_validate.R` or CI pipeline:
```r
# After rendering, check HTML for empty evidence blocks
html <- readLines("docs/articles/vignette.html")
empty_chunks <- grep("<!-- empty tar_read -->", html)
if (length(empty_chunks) > 0) stop("Evidence blocks returned NULL!")
```

## 12. POST-PUBLISH VALIDATION (MANDATORY)

**CRITICAL**: After EVERY pkgdown deployment, validate published vignettes with a **timestamped tabulation**.

**Agent must ALWAYS run post-publish validation:**
1. After any `pkgdown::build_site()` or pkgdown CI workflow
2. Produce the **Validation Table** (see R code below)
3. Report issues to user before claiming success
4. Do NOT claim workflow complete until validation passes
5. Print full website URLs for every article so the user can click and verify

**Validation Table (MANDATORY format):**

The agent MUST produce a table with these columns for **every** article:
- `Article` — vignette slug
- `URL` — full clickable URL
- `HTTP` — status code (must be 200)
- `Size` — page size in KB
- `Updated` — `Last-Modified` header or git commit datetime for the article
- `Age` — human-readable time since last update (e.g. "2 min ago", "3 hours ago")
- `Errors` — count of `#> Error` patterns in rendered HTML
- `NULLs` — count of `#> NULL` patterns
- `Warns` — count of `#> Warning` patterns
- `Status` — OK / WARN / FAIL

**R code for validation (adapt base_url and articles per project):**

```r
validate_pkgdown_deploy <- function(base_url, articles) {
  now <- Sys.time()
  results <- lapply(articles, function(slug) {
    url <- paste0(base_url, "/articles/", slug, ".html")
    tryCatch({
      resp <- httr2::request(url) |> httr2::req_perform()
      body <- httr2::resp_body_string(resp)
      http <- httr2::resp_status(resp)
      size_kb <- round(nchar(body) / 1024)
      last_mod <- httr2::resp_header(resp, "last-modified")
      updated <- if (!is.null(last_mod)) {
        as.POSIXct(last_mod, format = "%a, %d %b %Y %H:%M:%S", tz = "GMT")
      } else NA
      age_mins <- if (!is.na(updated)) round(as.numeric(difftime(now, updated, units = "mins"))) else NA
      age_str <- if (is.na(age_mins)) "unknown"
        else if (age_mins < 60) paste0(age_mins, " min ago")
        else if (age_mins < 1440) paste0(round(age_mins / 60), " hours ago")
        else paste0(round(age_mins / 1440), " days ago")
      count_pat <- function(p) {
        m <- gregexpr(p, body, fixed = TRUE)[[1]]
        if (m[1] == -1L) 0L else length(m)
      }
      errs <- count_pat("#&gt; Error")
      nulls <- count_pat("#&gt; NULL")
      warns <- count_pat("#&gt; Warning")
      status <- if (http != 200) "FAIL" else if (errs > 0 || nulls > 0) "WARN" else "OK"
      data.frame(Article = slug, URL = url, HTTP = http, Size = paste0(size_kb, " KB"),
        Updated = format(updated, "%Y-%m-%d %H:%M UTC"), Age = age_str,
        Errors = errs, NULLs = nulls, Warns = warns, Status = status,
        stringsAsFactors = FALSE)
    }, error = function(e) {
      data.frame(Article = slug, URL = url, HTTP = "FAIL", Size = "-",
        Updated = "-", Age = "-", Errors = NA, NULLs = NA, Warns = NA,
        Status = "FAIL", stringsAsFactors = FALSE)
    })
  })
  do.call(rbind, results)
}
```

**Additional checks (run after table):**
1. Site structure pages (index.html, reference/index.html, articles/index.html)
2. Anchor targets for any cross-article `#fragment` links
3. Dark mode toggle presence
4. Print all article URLs for user verification

**Pre-computed outputs for CI:**
When vignettes use `tar_read()`, ensure CI can build without `_targets/`:
1. Store pre-computed outputs in `inst/extdata/vignettes/` as RDS
2. Modify `safe_tar_read()` to fallback to RDS when targets unavailable
3. Update CI to use pre-computed data OR run `tar_make()`

```r
# Example fallback pattern in vignette setup
safe_tar_read <- function(name) {
 # Try targets first
 result <- tryCatch(targets::tar_read_raw(name), error = function(e) NULL)

 # Fallback to pre-computed RDS
 if (is.null(result)) {
   rds_path <- system.file(
     paste0("extdata/vignettes/", name, ".rds"),
     package = "pkgname"
   )
   if (file.exists(rds_path)) {
     result <- readRDS(rds_path)
   }
 }

 # Return visible error if still missing
 if (is.null(result)) {
   htmltools::div(
     style = "background:#dc3545;color:white;padding:1em;",
     paste0("[MISSING EVIDENCE] Target `", name, "` not found.")
   )
 } else {
   result
 }
}
```

## 13. NO EMPTY SECTIONS (MANDATORY)

**CRITICAL**: Every section (`##` or `###`) MUST contain at least one line of prose text before any code chunk. A heading followed directly by a code chunk with no explanatory text is FORBIDDEN.

**Rationale:** In CI builds where `eval=FALSE`, a heading + unevaluated code chunk renders as a completely empty section with no content, confusing readers.

**Required patterns:**
```markdown
### Forest Plot

Forest plot showing hazard ratios from the multivariate Cox regression.
Each row represents a covariate with 95% CI bars.

```{r forest-plot}
safe_tar_read("vig_forest_plot")
```
```

**Forbidden pattern:**
```markdown
### Forest Plot

```{r forest-plot}
safe_tar_read("vig_forest_plot")
```
```

**Draft placeholders:** If a section is incomplete, it MUST contain:
```markdown
*This section is under development. See [issue #N] for planned content.*
```

**Check:** `awk '/^#{2,4} / { h=$0; next } /^```\{r/ { if (h) print FILENAME": "h; h=""; next } /^[[:space:]]*$/ { next } { h="" }' vignettes/*.qmd`

## 14. CAPTIONED TABLE OR PLOT REQUIRED (MANDATORY)

**CRITICAL**: Every vignette MUST contain at least one captioned table (`DT::datatable(..., caption=)`) or captioned plot (`fig.cap=` or `fig-cap:`).

Vignettes with zero visual evidence are incomplete drafts and MUST NOT be merged.

**Check:** `grep -qE 'fig\.cap|fig-cap|caption\s*=' vignettes/my-vignette.qmd || echo "ERROR: no captions"`

## 15. NO USER INSTRUCTIONS IN ANALYSIS VIGNETTES (MANDATORY)

**CRITICAL**: Analysis vignettes are for users to understand the project and its outputs. They MUST NOT contain instructions telling users to run commands.

**Forbidden patterns in analysis vignettes:**
- "Run `targets::tar_make()` to populate the data"
- "Run `tar_make()` locally to see full output"
- "Execute `devtools::test()` to verify"
- Any imperative instruction telling users to run pipeline/build commands

**Allowed exceptions:**
- `README.qmd` — may contain setup/installation instructions
- Introduction vignette — first few sections may have "Getting Started" instructions
- How-to vignettes — explicitly instructional by nature
- pkgdown callout banners — may note that "Full output requires a local pipeline run" (descriptive, not imperative)

**Correct pkgdown banner pattern:**
```markdown
::: {.callout-note}
## Online documentation
This vignette shows pre-computed results from the targets pipeline.
Some outputs may appear as placeholders in the online version.
:::
```

**Wrong pattern:**
```markdown
::: {.callout-note}
Run `targets::tar_make()` locally to see full output.
:::
```

## 16. REPRODUCIBILITY SECTIONS MUST ALWAYS RENDER (MANDATORY)

**CRITICAL**: `sessionInfo()` and git commit info sections MUST always produce visible output, even in CI/pkgdown builds where most chunks have `eval=FALSE`.

**Required pattern:** Use `eval=TRUE` explicitly on reproducibility chunks:
```markdown
```{r session-info, eval=TRUE}
sessionInfo()
```
```

**Forbidden pattern:** Letting `sessionInfo()` inherit `eval = !in_pkgdown`:
```markdown
```{r session-info}
sessionInfo()
```
```
This renders as an empty collapsible section in pkgdown, which is confusing.

**Rules:**
- `sessionInfo()` chunks MUST have `eval=TRUE` (override the global `eval = !in_pkgdown`)
- Git commit info chunks that use `safe_tar_read()` SHOULD be wrapped with a fallback showing `Sys.time()` and `R.version.string` if the target is unavailable
- Empty `<details>` sections with no content are an ERROR — either always render content or remove the section entirely

**Check:** After pkgdown build, grep published HTML for empty `<details>` blocks:
```bash
awk '/<details>/,/<\/details>/' docs/articles/*.html | grep -B1 '</details>' | grep -v '<summary>\|</details>\|^--$'
```

## 17. CHANGELOG FOOTER (MANDATORY)

Every vignette MUST include a `## Recent Changes` section that displays
`safe_tar_read("vig_git_changelog")`. This shows the last 20 project
commits with lines added, files changed, and change categories.
Place before `## Reproducibility`.

**Required pattern:**
```markdown
## Recent Changes

Recent project commits with lines added, files changed, and change categories.

```{r changelog}
safe_tar_read("vig_git_changelog")
```
```

**Check:** `grep -L 'vig_git_changelog' vignettes/*.qmd`

## 18. [MISSING EVIDENCE] VALIDATION (MANDATORY)

**CRITICAL**: Before any pkgdown deployment, grep for `[MISSING EVIDENCE]` patterns.
These indicate `safe_tar_read()` failures where targets weren't pre-computed.

**Pre-deployment check (MANDATORY):**
```bash
# Must return 0 matches; any match = FAIL
grep -r "\[MISSING EVIDENCE\]" docs/articles/*.html && exit 1
```

**CI integration (add to pkgdown.yml):**
```yaml
- name: Check for missing evidence
  run: |
    if grep -r "\[MISSING EVIDENCE\]" docs/articles/*.html; then
      echo "ERROR: Missing evidence found in vignettes"
      exit 1
    fi
```

**Common causes:**
1. Forgot to run `tar_make()` before building vignettes
2. Forgot to export RDS files to `inst/extdata/vignettes/`
3. Target name typo in vignette `safe_tar_read()` call
4. Target exists but returns NULL

**Fix procedure:**
1. Run `tar_make(names = starts_with("vig_"))`
2. Export: `for (t in tar_manifest()$name[grepl("^vig_", tar_manifest()$name)]) saveRDS(tar_read_raw(t), paste0("inst/extdata/vignettes/", t, ".rds"))`
3. Rebuild: `pkgdown::build_site()`
4. Verify: `grep -r "\[MISSING EVIDENCE\]" docs/articles/*.html` returns nothing

## 19. DARK MODE TOGGLE (MANDATORY)

**MANDATORY**: All pkgdown sites MUST have a dark/light mode toggle defaulting to dark.

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
// Default to dark mode if no preference stored
if (!localStorage.getItem('theme')) {
  document.documentElement.setAttribute('data-bs-theme', 'dark');
}
```

**Rules:**
- The lightswitch toggle appears automatically in the pkgdown navbar
- Dark mode is the DEFAULT for first-time visitors
- User preference is persisted in localStorage
- All visualizations (ggplot2, plotly, DT, Mermaid) must be readable in both modes
- Mermaid diagrams MUST use the dark theme (see `diagram-generation.md`)

**Check:** After pkgdown build, verify:
1. Toggle appears in navbar (sun/moon icon)
2. First load defaults to dark
3. All plots/tables readable in both modes

## Checklist

- [ ] **CHANGELOG**: Every vignette has ## Recent Changes with vig_git_changelog
- [ ] **EVIDENCE**: Every claim/assertion has adjacent plot or table evidence
- [ ] **EVIDENCE**: All `tar_read()` calls return non-NULL rendered output
- [ ] **EVIDENCE**: Ran `tar_make()` before building vignettes
- [ ] **SECTIONS**: No heading followed directly by code chunk without prose
- [ ] **CAPTIONS**: Every vignette has at least one captioned table or plot
- [ ] **NO INSTRUCTIONS**: Analysis vignettes don't instruct users to run commands
- [ ] **REPRODUCIBILITY**: sessionInfo() chunks use `eval=TRUE` (always render)
- [ ] **MISSING EVIDENCE**: `grep -r "\[MISSING EVIDENCE\]" docs/articles/*.html` returns 0 matches
- [ ] **DARK MODE**: Toggle present, defaults to dark, all content readable in both modes
