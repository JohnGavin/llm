---
description: Every clickable node URL in a diagram, caption, or vignette prose that points to project source MUST include a line anchor (#L<n>), never just the file root.
type: rule
name: mermaid-click-anchors
paths:
  - "vignettes/**"
  - "*.qmd"
  - "R/**"
---

# Rule: Mermaid Click Links — Line Anchors Mandatory

## When This Applies

Any clickable link in a vignette that points into the current project's source tree:

- Hand-written Mermaid `click` directives in `.qmd` or static HTML
- `node_links`-style R tables that generate `<a href>` elements
- Markdown links in prose adjacent to a diagram
- ggiraph `data_id` / `onclick` JS that opens source
- plotly `customdata` / `onclick` that opens source

Does NOT apply to: external concept links (papers, CRAN, Stack Overflow, external docs), or links into other projects' source trees.

## CRITICAL: Every URL Into Project Source Must Include `#L<n>`

A reader who clicks a node in a diagram expects to land on the function or target that the node represents. Landing at line 1 of a 200-line file forces the reader to search for the symbol. Line anchors are not optional polish — they are the contract of a clickable diagram.

### Required pattern

```
# Hand-written Mermaid click directive
click NODE "https://github.com/OWNER/REPO/blob/REF/R/file.R#L11" _blank

# Markdown link in prose
[`function_name()`](https://github.com/OWNER/REPO/blob/main/R/file.R#L80)

# Caption reference (from strategy-name-consistency rule, historical project)
Code: [`hd_hac_sharpe()`](https://github.com/JohnGavin/historical/blob/main/packages/pkg/R/falsification.R#L80)
```

### Forbidden patterns

```
# WRONG: file root — forces reader to search
click NODE "https://github.com/OWNER/REPO/blob/main/R/file.R" _blank

# WRONG: no anchor on a function-specific caption link
Code: [`plan_vix_macro_overlay()`](https://github.com/JohnGavin/historical/blob/main/R/plan_vix_macro_overlay.R)
```

## Surface Coverage Table

| Surface | Required pattern |
|---------|-----------------|
| Mermaid `click` directive | `click NODE "…/file.R#L<n>" _blank` |
| `node_links` R table → `<a href>` | URL column must contain `#L<n>` |
| Markdown prose link to project source | `[name](…/file.R#L<n>)` |
| ggiraph `onclick` JS | URL string must contain `#L<n>` |
| plotly `customdata` / `onclick` | URL string must contain `#L<n>` |

## The `diagram_node_links()` / `gh_url()` Helper Pattern

Each project keeps a single source-of-truth helper (suggested: `R/diagram_node_links.R`). Click directives are **generated**, never hand-coded.

```r
diagram_node_links <- function() {
  tibble::tribble(
    ~node,        ~file,                        ~line,
    "VIX_level",  "R/plan_vix_macro_overlay.R",  11L,
    # one row per clickable node across all diagrams
  )
}

gh_url <- function(node, ref = "main", repo = NULL) {
  if (is.null(repo)) repo <- gh::gh_tree_remote()$repo  # or hardcode
  row <- diagram_node_links()[diagram_node_links()$node == node, ]
  stopifnot("node not registered" = nrow(row) == 1L,
            "line missing"        = !is.na(row$line))
  sprintf("https://github.com/%s/blob/%s/%s#L%d", repo, ref, row$file, row$line)
}
```

Click directives are then emitted in a pre-render chunk, never authored by hand:

```r
purrr::map_chr(diagram_node_links()$node,
               ~ sprintf(' click %s "%s" _blank', .x, gh_url(.x)))
```

Start with `NA_integer_` for unknown lines; resolve each `NA` before going live.

## CI / QA Guard (Mandatory Once a Project Adopts This)

Add a target in `plan_qa_gates.R` (or equivalent) that:

1. Greps rendered HTML for `github.com/<OWNER>/<REPO>/blob/.../*.R` URLs that do **not** contain `#L`
2. Fails the build if any such bare-file URL is found in a diagram or its caption
3. Optionally verifies `#L<n>` is within the file's current line count (catches stale anchors after a refactor)

```r
# Example QA target
tar_target(qa_no_bare_source_urls, {
  html_files <- list.files("docs", pattern = "\\.html$", recursive = TRUE, full.names = TRUE)
  bare <- grep("github\\.com/.*/blob/[^#]+\\.R[^#\"']", readLines(html_files), value = TRUE)
  if (length(bare) > 0) stop("Bare source URLs found (missing #L<n>): ", paste(bare, collapse = "\n"))
  TRUE
})
```

## Migration Plan (Per Project)

1. Audit: `grep -rn 'click [A-Z][a-zA-Z_]*' docs/ R/ vignettes/` to find current state
2. Build `R/diagram_node_links.R` with `NA_integer_` for the `line` column initially
3. Resolve each `NA` to a real line (manual, or via `getSrcLocation()` for exported functions)
4. Replace hand-coded click directives with the `purrr::map_chr()`-generated form
5. Add the QA gate target; track in a project-level meta issue

Reference implementation: [JohnGavin/historical#240](https://github.com/JohnGavin/historical/issues/240)

## Forbidden Patterns

| Pattern | Why wrong | Fix |
|---------|-----------|-----|
| `click NODE "…/file.R" _blank` (no `#L`) | Reader must search file for symbol | Add `#L<n>` to URL |
| `[fn()](…/file.R)` in caption or prose | Same issue — file-root link | `[fn()](…/file.R#L<n>)` |
| Hand-coded click URLs not from a helper | Stale after refactors | Use `diagram_node_links()` + `gh_url()` |
| No QA gate after adopting the pattern | Regressions go undetected | Add `qa_no_bare_source_urls` target |

## Related

- `visualization` — core visualization standards; `visualization-detailed` skill for full Mermaid + interactive guidance
- `visualization-detailed` skill — Mermaid CDN pattern, click URL syntax, interactive libraries
- `narrative-evidence-block` — `### Data sources` function links must also include `#L<n>`
- `strategy-name-consistency` (historical project) — first documented the caption `#L<n>` requirement for function links; language promoted here to global rule
- Issue [JohnGavin/llm#193](https://github.com/JohnGavin/llm/issues/193) — origin of this rule
- PR [JohnGavin/historical#240](https://github.com/JohnGavin/historical/issues/240) — reference implementation
