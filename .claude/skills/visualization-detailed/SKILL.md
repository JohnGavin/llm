---
name: visualization-detailed
description: >
  Detailed guidance for data visualization in R. Use this skill when:
  (1) Creating complex visualizations with plotly or ggiraph,
  (2) Setting up dark-mode compatible plotly theming,
  (3) Implementing Mermaid diagrams with clickable nodes,
  (4) Writing mandatory 7-item figure captions,
  (5) Building reproducible visualizations backed by targets pipelines.
  Covers interactive libraries, Mermaid CDN patterns, and caption requirements.
metadata:
  category: Quarto & Docs
  tier: workflow
  maturity: stable
---

# Skill: Detailed Visualization Guidance

Detailed guidance for visualization: captions, interactive libraries, Mermaid diagrams, reproducible patterns.

## Triggers

- Creating complex visualizations
- Setting up plotly theming
- Mermaid diagram implementation
- Caption writing for figures

## Part 1: Mandatory Captions (7 Items + Links)

**Minimum 3 sentences. 1-sentence = VIOLATION.**

| Item | Description |
|------|-------------|
| 1. Description | What it shows |
| 2. Variables/units | Every axis named with units |
| 3. Label definitions | Colors, shapes, abbreviations |
| 4. Conclusions | 2-3 key findings |
| 5. Source | Data source, methodology |
| 6. Cross-refs | Links to related content |
| 7. Glossary | Domain terms linked |

### Linked Caption Elements (Astrobites Pattern)

**Source:** [Astrobites PTA Plus Astrometry](https://astrobites.org/2026/05/02/pta_plus_astrometry/)

Caption elements SHOULD link to their sources:

| Element | Link To |
|---------|---------|
| Title/subtitle | Source data or methodology docs |
| Axis labels | Variable definitions or data dictionary |
| Legend | Full legend explanation if truncated |
| Caption text | Source file or function in repo |

**Template:**
```markdown
**Figure N.** [Brief description](link-to-methodology).
Data: [dataset name](link-to-data).
Code: [`function_name()`](github-link#L123).
```

**Quarto example:**
```yaml
#| fig-cap: |
#|   **Figure 3.** [Wave height distribution](methodology.html#wave-heights)
#|   across Irish buoy network. Data: [Marine Institute ERDDAP](https://erddap.marine.ie/).
#|   Code: [`plot_wave_distribution()`](https://github.com/user/repo/blob/main/R/plots.R#L45).
```

### Captions Are Pre-Computed Targets

**FORBIDDEN:** Hardcoded captions, captions added in vignette chunks.

```r
# Target returns DT with caption baked in
DT::datatable(data, caption = htmltools::tags$caption(
  style = "caption-side: top; text-align: left;",
  paste0("Summary (N=", nrow(data), "). Key finding. Source: API.")))
```

### Number Formatting (ZERO TOLERANCE)

| Type | Format | Example |
|------|--------|---------|
| Counts | `round(x, 0)` | 32874 |
| Scores | `signif(x, 4)` | 1.065 |
| Percentages | `round(x, 1)` | 32.2% |

**15+ decimal places is FORBIDDEN.**

## Part 2: Interactive Libraries

| Library | Use For | Size |
|---------|---------|------|
| **plotly** | Shiny, range sliders | ~3MB |
| **ggiraph** | pkgdown, static sites | ~200KB |
| **DT** | Tables | ~500KB |

### Plotly Theming (MANDATORY)

```r
plotly::layout(...,
  paper_bgcolor = "#000000", plot_bgcolor = "#000000",
  font = list(color = "#ffffff"),
  legend = list(orientation = "h", x = 0.5, y = -0.15)
) |> plotly::config(scrollZoom = TRUE)
```

**bslib Darkly requires CSS:**
```css
.bslib-card .plotly .main-svg { background: #000000 !important; }
```

## Part 3: Mermaid Diagrams

### Technology Choice

| Approach | Use? | Reason |
|----------|------|--------|
| `{=html}` + CDN mermaid | YES | Click href works |
| Quarto `{mermaid}` chunks | NO | Click broken (bug #10450) |
| DiagrammeR | NO | Heavy, clicks broken |

### CDN Init Pattern

```html
<script type="module">
import mermaid from 'https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs';
mermaid.initialize({
  startOnLoad: false, securityLevel: 'loose', theme: 'dark',
  themeVariables: { background: '#000000', primaryColor: '#999999', lineColor: '#CC0000' }
});
await mermaid.run({ querySelector: '.mermaid' });
</script>
```

### Node Color Palette

| Element | Hex |
|---------|-----|
| Background | `#000000` |
| Node fill | `#999999` |
| Node text | `#000000` |
| Borders/arrows | `#CC0000` |

All nodes: `fill:#999999,stroke:#CC0000,color:#000000`

### Pandoc Arrow Workaround

Use `<script type="text/plain" data-mermaid="id">` for diagram text (avoids `>` encoding).

### Quarto 1.8 Dashboard

Use external `.js` files only — inline scripts stripped.

### Click Links: Line Anchors Mandatory

Every clickable node URL that points into the current project's source tree MUST include `#L<n>`. Bare-file URLs (no anchor) force readers to search for the symbol the node represents.

**Surface coverage:**

| Surface | Required pattern |
|---------|-----------------|
| Mermaid `click` directive | `click NODE "…/file.R#L<n>" _blank` |
| `node_links` R table → `<a href>` | URL column must contain `#L<n>` |
| Markdown prose link to project source | `[name](…/file.R#L<n>)` |
| ggiraph `onclick` JS | URL string must contain `#L<n>` |
| plotly `customdata` / `onclick` | URL string must contain `#L<n>` |

**Wrong:**
```
click VIX_level "https://github.com/OWNER/REPO/blob/main/R/plan_vix_macro_overlay.R" _blank
```

**Right:**
```
click VIX_level "https://github.com/OWNER/REPO/blob/main/R/plan_vix_macro_overlay.R#L11" _blank
```

**The `diagram_node_links()` / `gh_url()` helper (always generate, never hand-code):**

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

# Emit click directives — never author these by hand
purrr::map_chr(diagram_node_links()$node,
               ~ sprintf(' click %s "%s" _blank', .x, gh_url(.x)))
```

**Migration steps:** (1) audit existing click directives, (2) build `diagram_node_links.R` with `NA_integer_` lines, (3) resolve each `NA`, (4) replace hand-coded URLs with the generated form, (5) add QA gate (`qa_no_bare_source_urls` target). Reference: [JohnGavin/historical#240](https://github.com/JohnGavin/historical/issues/240).

See `mermaid-click-anchors` rule for the full specification, forbidden patterns, and CI guard.

## Part 4: Reproducible Visualization

### Rule 7: Data Behind Plots

Every plot backed by accessible raw data via targets pipeline.

```r
# In vignette — NEVER inline ggplot()
tar_read(plot_trends)

# Next chunk — hidden data table
tar_read(data_trends) |> DT::datatable(caption = "Raw data")
```

### Rule 9: Dynamic Text

**NEVER hardcode numbers.**

```r
# Bad
"Average cost was $42.50"

# Good
paste0("Average cost was ", dollar(mean(data$cost)))
```

## Checklist

- [ ] Caption has all 7 items, 3+ sentences
- [ ] Plotly has explicit bg/fg colors + scrollZoom
- [ ] Mermaid uses CDN (not `{mermaid}` chunks)
- [ ] Diagrams have captions with node meanings
- [ ] All numbers dynamic (no hardcoding)

## Related

- `accessibility` rule — contrast, alt text
- `quarto-vignettes` rule — vignette structure
