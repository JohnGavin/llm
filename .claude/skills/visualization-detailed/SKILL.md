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

#### Why this is MANDATORY, not optional polish

`plotly::plot_ly()` / `plotly::layout()` default to a **white** canvas
(`paper_bgcolor`/`plot_bgcolor` unset → white) regardless of the surrounding
page theme. Every `renderPlotly({...})` in a dark-themed app (bslib
`bootswatch = "darkly"`, `page_navbar` dark mode, etc.) that omits the three
lines above renders a bright-white rectangle inside a black page, and any
marker/line colour chosen to be visible against black (e.g. `"#6c757d"`
medium grey) becomes low-contrast or reads as **"black dots"** against that
unthemed white background instead. This is exactly the kind of defect a
developer testing in only ONE browser/window size can miss — the white
plot area may be partially masked by other CSS, scroll further off-screen,
or simply not draw the reporter's attention, and reads differently across
browsers' default widget/WebGL fallback rendering. Symptom pattern to
recognise: **"a chart or whole tab looks blank/wrong in one browser but
fine in another"** — before chasing a browser-specific JS bug, first grep
every `renderPlotly`/`plot_ly(` call in the file for a missing
`paper_bgcolor`/`plot_bgcolor`/`font` triplet. This is a cheap, high-yield
check to make BEFORE speculative fixes.

> ⚠ Confidence note: in the mycare dashboard incident (2026-07-26) that
> prompted this expansion, the missing theming was found and fixed as a
> confirmed, independently-verified defect (plots had zero explicit
> bg/font styling). The user's separately-reported "Chrome shows blank
> tabs, Edge doesn't" symptom cleared after a round of fixes that included
> this one, but no browser console error was ever captured to prove this
> specific defect was the (sole) cause — treat the causal link as
> plausible, not certain, and still ask for DevTools console/network
> output FIRST on any future cross-browser-only report (see Related).

**Audit pattern** (run before considering a Shiny/plotly dashboard file
done):
```bash
grep -n "renderPlotly({" app.R                # locate each block
grep -c "paper_bgcolor" app.R                 # should be >= number of renderPlotly() blocks
```
A quicker structural check: every `plotly::layout(` call in a dark-themed
app should have `paper_bgcolor`/`plot_bgcolor`/`font` somewhere in the same
call or piped immediately after it. Missing count = number of untested
white-on-black plots.

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

## Part 5: Variable Labels Drive Titles (ggplot2 / table1 / gtsummary)

R has a long-standing (informal, `haven`/`labelled`-ecosystem) convention of
storing a natural-language description of a variable in its **`label`
attribute**. Set it once and let ggplot2, `table1`, and `gtsummary` all
consume it — instead of typing the same description into `labs()`, a
`table1` formula, and a `gtsummary` header separately, which is how the
three surfaces drift out of sync with each other.

### ggplot2 4.0.0+ auto-titles from the `label` attribute (VERIFIED)

**ggplot2 4.0.0** ("An attempt is made to use a variable's label attribute
as default label", per its `NEWS.md`) auto-derives an axis/legend title from
a variable's `label` attribute when `labs()` doesn't set one explicitly.
This project's `default.nix` currently pins **ggplot2 4.0.1**, so the
behaviour below is available as-is — no version bump needed.

```r
library(ggplot2)

df <- data.frame(x = 1:5, y = c(2, 4, 3, 5, 6))
attr(df$x, "label") <- "Days since treatment start"
attr(df$y, "label") <- "Tumour volume (mm^3)"

p <- ggplot(df, aes(x, y)) + geom_point()
get_labs(p)$x
#> [1] "Days since treatment start"
get_labs(p)$y
#> [1] "Tumour volume (mm^3)"
```

Verified in this project's nix shell: `get_labs(p)$x`/`$y` return exactly the
two label strings set via `attr()`, with no explicit `labs()` call. The same
mechanism works whether the `label` attribute was set by hand (as above) or
by `labelled::var_label(x) <- "..."` — both write to the identical `label`
attribute; ggplot2 does not care which one set it.

**Don't duplicate the text.** Once a column carries a `label` attribute, an
explicit `labs(x = "Days since treatment start")` on the same plot is
redundant — remove it and let the attribute drive the title, so a future
change to the label only has to happen in one place.

### table1 and gtsummary consume the same attribute

> The two examples below use the documented public API of `table1` and
> `gtsummary` (both long-stable, widely-used packages). Neither package is
> installed in this project's current nix shell (`default.R` would need
> `table1`/`gtsummary` added), so — unlike the ggplot2 example above — these
> are **not independently verified in this environment**. They are shown
> for the documented, standard usage pattern; verify them once the packages
> are added to `default.R`.

`table1` uses its own `label<-()` generic:

```r
library(table1)

label(df$x) <- "Days since treatment start"
table1(~ x, data = df)   # row header reads "Days since treatment start"
```

`gtsummary::tbl_summary()` reads the same `label` attribute automatically
for its row headers, falling back to the raw column name only when no label
is set:

```r
library(gtsummary)

df |> gtsummary::tbl_summary()   # uses attr(df$x, "label") for the row header
```

### Value labels flow through to factor levels, then to legends/facets

For a **categorical** variable, the payoff compounds: `labelled::val_labels()`
(or `haven::labelled()`) attaches the code→meaning map once, and converting
to a factor (`labelled::to_factor()` / `haven::as_factor()`) turns that map
into the factor's `levels` — which then becomes every legend entry and
facet label ggplot2 draws, with no separate re-typing of "1 = low, 2 =
medium, 3 = high" anywhere in the plotting code. The full round-trip
example, plus the **attribute-preservation gotcha** (arithmetic inside
`dplyr::mutate()` silently drops both the `label` and the labelled class —
verified in the companion doc) live in the
[`data-glossary-and-entity-resolution`](../../rules/data-glossary-and-entity-resolution.md)
rule (JohnGavin/llm#730). Check any labelled column survived a
transformation BEFORE it reaches a plot or table — a silently-dropped label
doesn't error, it just falls back to the bare column name, which is easy to
miss in review.

## Checklist

- [ ] Caption has all 7 items, 3+ sentences
- [ ] Plotly has explicit bg/fg colors + scrollZoom
- [ ] Mermaid uses CDN (not `{mermaid}` chunks)
- [ ] Diagrams have captions with node meanings
- [ ] All numbers dynamic (no hardcoding)
- [ ] Variable `label` attribute set once, not re-typed in `labs()`/table headers

## Related

- `accessibility` rule — contrast, alt text
- `quarto-vignettes` rule — vignette structure
- `visualization` rule — Core visualization standards; Plotly Dark Theming section cross-references this skill
- `data-glossary-and-entity-resolution` rule — `label`/`labels` attributes as
  the single source for the data glossary AND plot/table titles
  (JohnGavin/llm#729, JohnGavin/llm#730)
