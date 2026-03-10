---
paths:
  - "*.qmd"
  - "*.Rmd"
  - "vignettes/**"
---
# Quarto Vignette Format Rules

## 1. UNIQUE SECTION TITLES

**MANDATORY**: Every section and subsection MUST have a unique, descriptive title.

**Forbidden patterns:**
- `## Row` (generic layout term)
- `## Row {height=20%}` (layout syntax in heading)
- `### Column` (generic)
- Multiple sections with same title

**Required pattern:**
- Use descriptive names: `## Data Coverage`, `## Quality Metrics`
- Add explicit anchors: `## Coverage Timeline {#coverage-timeline}`
- Each heading describes its CONTENT, not its LAYOUT

**Check:** `grep -E "^#{1,4} " vignette.qmd | sort | uniq -d`

## 2. PARAMETERIZED TITLES

**MANDATORY**: Vignette titles must be consistent with pkgdown navbar.

Store titles in a targets target, reference in vignette YAML, ensure `_pkgdown.yml` matches.

## 3. INTERACTIVE TABLES ONLY (NO kable)

**MANDATORY**: All tables MUST use `DT::datatable()`, NEVER `knitr::kable()`.

- `DT::datatable()` provides: column sorting, filtering, search, pagination
- Every `DT::datatable()` MUST have `caption=`
- Use `options = list(pageLength = 15, dom = 'Bfrtip')` for consistent UX
- See `plots-and-tables` rule for full caption standards

**Exception**: Only `knitr::kable()` in PDF-only output (rare).

**Check:** `grep -n "knitr::kable" vignettes/*.qmd vignettes/*.Rmd`

## 4. CODE-AS-TARGETS WITH SHOW/HIDE

**MANDATORY**: User-facing code examples MUST be stored as targets.

1. Store code as character vector target in `R/tar_plans/plan_doc_examples.R`
2. Add `parse_code_example()` validation target
3. Display with code hidden by default (`<details>` collapsed)
4. Output shown by default (no wrapper)
5. Only **user-facing examples** (queries, API usage) need code-as-targets

## 5. DASHBOARD FORMAT

When using `format: dashboard`:
- Pages: Use `#` headings with descriptive names
- Rows: Use `## Row` ONLY for layout, add `{.hidden}` or CSS
- Tabsets: Use `{.tabset}` on columns with descriptive tab names
- Anchors: Always add explicit IDs (`{#data-coverage}`)

## 6. FULL-WIDTH VIGNETTES

**MANDATORY**: All vignettes must fill ~95% of the browser window width.

Required `pkgdown/extra.css`:
```css
body > .container, .container {
  max-width: 95% !important; width: 95%;
}
.col-md-9 { flex: 0 0 80%; max-width: 80%; }
.col-md-3 { flex: 0 0 20%; max-width: 20%; }
.contents { max-width: none; width: 100%; }
.js-plotly-plot { width: 100% !important; }

@media (max-width: 991.98px) {
  #toc { display: none; }
  .col-md-9 { flex: 0 0 100%; max-width: 100%; }
}
```

## 7. DASHBOARD STANDARDS

When building dashboard-format vignettes:
1. Every plot/table card MUST have a `card_footer()` caption
2. Every plotly plot MUST include `config(scrollZoom = TRUE)`
3. Value boxes: `$X,XXX` format (no decimals > $100), `X.XB`/`X.XM` for tokens
4. Every dashboard MUST have a footer with repo link and build date
5. Minimum plot heights: 400px half-width, 500px full-width
6. Table columns with long text must use `white-space: nowrap`
7. Legends above plots (`y = 1.02, yanchor = "bottom"`), never use rangeslider with legend

## 8. CODE FOLDING (MANDATORY)

**ALL vignettes MUST have code folding enabled.** No exceptions, all projects.

Quarto (.qmd):
```yaml
format:
  html:
    code-fold: true              # MANDATORY
    code-summary: "Show code"    # MANDATORY
    code-tools: true             # Optional
```

R Markdown (.Rmd):
```yaml
output:
  html_document:
    code_folding: hide           # MANDATORY
```

Rules:
- Code hidden by default; users click to reveal
- ALL outputs (plots, tables) MUST display — never hide with `results='hide'`
- Use `#| code-fold: false` on individual chunks only for core tutorial examples
- Must work across pkgdown, GitHub, and local HTML builds

## 9. SUB-BULLET FORMATTING

**MANDATORY**: When a concept has sub-components, use nested bullet points.

**Required pattern:**
```markdown
- **DALY (Disability-Adjusted Life Years):** Disease burden combining:
    - **YLL (Years of Life Lost):** Premature mortality component
    - **YLD (Years Lived with Disability):** Morbidity component
```

**Forbidden pattern:**
```markdown
- **DALY (Disability-Adjusted Life Years):** Disease burden = YLL + YLD.
```

Rules:
- Parent-child relationships MUST use indented sub-bullets (4 spaces)
- Acronyms introduced in a parent bullet MUST be defined as sub-bullets
- Never define sub-components inline when they deserve their own line
- Applies to all markdown: vignettes, README, pkgdown articles

**Check:** Review all bullet lists with `+`, `=`, `/` joining concepts.

## 10. NO BROKEN LINKS (404 CHECK)

**MANDATORY**: After building pkgdown articles, verify ALL internal links resolve.

**Check procedure:**
1. Extract all `href` values from `_pkgdown.yml` navbar and articles
2. Verify each referenced file exists in `docs/`
3. Grep built HTML for internal links and verify targets exist

**Commands:**
```bash
# Check all article hrefs in _pkgdown.yml resolve
grep 'href: articles/' _pkgdown.yml | sed 's/.*href: //' | while read f; do
  [ -f "docs/$f" ] || echo "MISSING: docs/$f"
done

# Check for broken internal links in built HTML
grep -ohP 'href="[^"]*\.html[^"]*"' docs/articles/*.html | sort -u | \
  grep -v '^http' | while read link; do
    target=$(echo "$link" | tr -d '"' | sed 's/href=//')
    [ -f "docs/articles/$target" ] || [ -f "docs/$target" ] || echo "BROKEN: $link"
  done
```

**Rules:**
- Every `href` in `_pkgdown.yml` MUST point to an existing file in `docs/`
- When listing website URLs to the user, ALWAYS verify the file exists first
- Never guess vignette filenames — check `ls docs/articles/` or `_pkgdown.yml`

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

**CRITICAL**: After EVERY pkgdown deployment, validate published vignettes.

**Validation steps (run after CI completes):**
```bash
# 1. Fetch published HTML and check for missing evidence
curl -s https://<user>.github.io/<pkg>/articles/<vignette>.html | \
  grep -c "MISSING EVIDENCE" && echo "FAIL: Missing evidence found!"

# 2. Check for empty plot containers
curl -s <url> | grep -c "plotly-graph-div.*></div></div>" | \
  grep -v "^0$" && echo "FAIL: Empty plots found!"

# 3. Verify page loads (no infinite spinners)
curl -s -o /dev/null -w "%{time_total}" <url> | \
  awk '{if ($1 > 10) print "WARN: Page load > 10s"}'
```

**Agent must ALWAYS run post-publish validation:**
1. After any `pkgdown::build_site()` or pkgdown CI workflow
2. Grep published HTML for: `[MISSING EVIDENCE]`, empty divs, broken images
3. Report issues to user before claiming success
4. Do NOT claim workflow complete until validation passes

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

## Checklist

- [ ] **EVIDENCE**: Every claim/assertion has adjacent plot or table evidence
- [ ] **EVIDENCE**: All `tar_read()` calls return non-NULL rendered output
- [ ] **EVIDENCE**: Ran `tar_make()` before building vignettes
- [ ] No duplicate section titles
- [ ] Descriptive headings (no "Row", "Column")
- [ ] Titles match pkgdown navbar
- [ ] No `knitr::kable()` (use `DT::datatable()`)
- [ ] All `DT::datatable()` have `caption=`
- [ ] Code examples stored as targets with parse validation
- [ ] Code examples use `<details>` show/hide
- [ ] `pkgdown/extra.css` sets 95% width
- [ ] Dashboard cards have `card_footer()` captions
- [ ] Plotly plots include `config(scrollZoom = TRUE)`
- [ ] `code-fold: true` and `code-summary: "Show code"` in YAML
- [ ] All outputs visible (no hidden plots/tables)
- [ ] All `_pkgdown.yml` article hrefs resolve (no 404s)
- [ ] All internal links in built HTML verified
