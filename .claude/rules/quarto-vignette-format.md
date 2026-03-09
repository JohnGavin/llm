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

## Checklist

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
