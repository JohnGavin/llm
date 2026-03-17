---
paths:
  - "*.qmd"
  - "*.Rmd"
  - "vignettes/**"
---
# Quarto Vignette Layout Rules

Split from `quarto-vignette-format` — covers layout, styling, and structural rules.

## 6. FULL-WIDTH VIGNETTES (100% RELATIVE WIDTH)

**MANDATORY**: All vignettes MUST use 100% of the browser window width.

**Key principle:** Use RELATIVE units (percentages) not ABSOLUTE units (pixels, cm).
This ensures full width regardless of device (desktop, tablet, mobile).

Required `pkgdown/extra.css`:
```css
body > .container, .container, .container-fluid {
  max-width: 100% !important; width: 100% !important;
  padding-left: 1rem; padding-right: 1rem;
}
.col-md-9 { flex: 0 0 85% !important; max-width: 85% !important; }
.col-md-3 { flex: 0 0 15% !important; max-width: 15% !important; }
.contents, main, article { max-width: none !important; width: 100% !important; }
.js-plotly-plot, .plotly, .datatables, table.dataTable { width: 100% !important; }
@media (max-width: 991.98px) {
  #toc { display: none; }
  .col-md-9 { flex: 0 0 100% !important; max-width: 100% !important; }
  .col-md-3 { display: none; }
}
```

**Forbidden:**
- `max-width: 1200px` or any fixed pixel width
- `width: 80vw` when 100% would work
- Bootstrap default `container` max-widths

**Check:** After pkgdown build, visually verify vignettes fill browser width on:
- Desktop (1920px+ wide)
- Laptop (1366px)
- Tablet (768px)
- Mobile (375px)

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

Rules:
- Code hidden by default; users click to reveal
- ALL outputs (plots, tables) MUST display — never hide with `results='hide'`
- Use `#| code-fold: false` on individual chunks only for core tutorial examples
- Must work across pkgdown, GitHub, and local HTML builds
- **FORBIDDEN**: `echo = FALSE` in `knitr::opts_chunk$set()` when `code-fold: true` is active — `code-fold` handles visibility; `echo = FALSE` removes code entirely, preventing user inspection

**Distinction — echo=FALSE vs code-fold:**
- `code-fold: true` (YAML header): Code is present in HTML but collapsed. Users can click "Show code" to inspect. This is the CORRECT approach for all vignettes.
- `echo = FALSE` (opts_chunk): Code is stripped from HTML entirely. Users cannot inspect it at all.
- `echo = FALSE` on individual chunks via `#| echo: false` is acceptable for setup chunks (`include=FALSE` already handles these) or chunks that only produce side effects (e.g., `library()` calls).
- The FORBIDDEN combination is `code-fold: true` in YAML + `echo = FALSE` in `opts_chunk$set()` globally — this contradicts the purpose of code-fold by removing all code before fold can act on it.

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
