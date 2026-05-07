---
description: Visualization standards, captions, diagrams, Mermaid, plotly theming
paths:
  - "R/**"
  - "vignettes/**"
  - "*.qmd"
---

# Rule: Visualization Standards

Consolidated from: `visualization-standards`, `visualization-diagrams`, `diagram-generation`, `reproducible-visualization`.

---

## Part 1: Core Principles (Tufte/Gelman)

1. **Every graph makes a comparison** — never single metric
2. **Small multiples** — `facet_wrap()` for 5+ categories
3. **Maximize data-ink** — `theme_minimal()`, no 3D
4. **Show data, not just summaries** — points + smooth
5. **NEVER pie charts. NEVER bar charts.** — Use dot plots (Cleveland)

### ggauto for Standard Charts

```r
library(ggauto)
df |> ggauto(x_var, y_var)  # Auto-selects accessible chart type
```

### Color Accessibility

- **Mandatory palettes:** `viridis`, `brewer.pal(n, "Dark2")`
- **NEVER** red/green alone. For 2 groups: blue `#2c3e50` + orange `#e67e22`

---

## Part 2: Mandatory Captions (7 Items)

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

---

## Part 3: Interactive Libraries

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

---

## Part 4: Mermaid Diagrams

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

---

## Part 5: Reproducible Visualization

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

---

## Checklist

- [ ] Caption has all 7 items, 3+ sentences
- [ ] No pie charts or bar charts — use dot plots
- [ ] Colorblind-safe palette
- [ ] Plotly has explicit bg/fg colors + scrollZoom
- [ ] Mermaid uses CDN (not `{mermaid}` chunks)
- [ ] Diagrams have captions with node meanings
- [ ] All numbers dynamic (no hardcoding)

---

## Related

- `accessibility` — contrast, alt text
- `quarto-vignettes` — vignette structure
