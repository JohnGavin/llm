---
paths:
  - "R/**"
  - "vignettes/**"
  - "*.qmd"
  - "inst/shiny/**"
---
# Visualization Diagram Standards

Split from `visualization-standards` — covers Mermaid, flowcharts, and diagram-specific rules.

## Mermaid/Flowchart Diagrams

Mermaid diagrams are subject to the same caption requirements as plots and tables.

Every Mermaid diagram MUST:

1. Use **CDN-based Mermaid** (NOT `{mermaid}` chunks) — Quarto `{mermaid}` chunks have broken click/href (Quarto bug #10450)
2. Use **dark theme** with `securityLevel: 'loose'` for clickable nodes
3. Use `<br/>` (NOT `\n`) for multiline node labels
4. Use Quarto figure cross-reference (`::: {#fig-id}`) for captioning
5. Include `click` directives linking nodes to relevant vignettes/URLs (`_blank`)
6. Have a caption with: description, key conclusions, embedded definition links
7. Use consistent node styling per layer/category using the colour palette below

### CDN Init Block (once per document)

```html
<script type="module">
  import mermaid from 'https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs';
  mermaid.initialize({
    startOnLoad: false,
    securityLevel: 'loose',
    theme: 'dark',
    themeVariables: { darkMode: true, background: '#000000', primaryColor: '#999999', lineColor: '#CC0000', primaryTextColor: '#000000' }
  });
  document.querySelectorAll('pre.mermaid').forEach(async (el) => {
    const id = el.id || 'mermaid-' + Math.random().toString(36).slice(2);
    const source = el.querySelector('script[type="text/plain"]');
    const graphDef = source ? source.textContent : el.textContent;
    const { svg } = await mermaid.render(id + '-svg', graphDef);
    el.innerHTML = svg;
  });
</script>
```

### Diagram Pattern

```markdown
::: {#fig-example}

<pre class="mermaid" id="example">
<script type="text/plain">
graph LR
  A["Input"] --> B["Output&lt;br/&gt;Data"]
  click A "input.html" _blank
  style A fill:#999999,stroke:#CC0000,color:#000
</script>
</pre>

**Description of what this diagram shows.**
Key conclusion 1. Key conclusion 2.
[Term](glossary.html#term) links to definitions.
Source: `R/file.R`.

:::
```

### Node Colour Palette (MANDATORY high-contrast)

**Standard:** Black background (`#000000`), gray-60 box fill (`#999999`), black text (`#000000`), red arrows/borders (`#CC0000`).

| Element | Color | Hex |
|---------|-------|-----|
| Background | Black | `#000000` |
| Node fill | Gray 60% | `#999999` |
| Node text | Black | `#000000` |
| Node border | Red | `#CC0000` |
| Arrows/lines | Red | `#CC0000` |
| Cluster/subgraph fill | Dark gray | `#333333` |
| Cluster border | Red | `#CC0000` |

All nodes use the same style: `fill:#999999,stroke:#CC0000,color:#000000`

This replaces the previous per-role colour scheme. Rationale: uniform styling maximizes readability and avoids colour-meaning ambiguity across projects.

## Plotly Legend and Theme Contrast (MANDATORY)

Every `plotly::layout()` MUST include explicit background/font colors:

```r
plotly::layout(..., paper_bgcolor = "white", plot_bgcolor = "white",
  font = list(color = "#1a1a1a"),
  legend = list(font = list(color = "#1a1a1a"), bgcolor = "rgba(255,255,255,0.9)")
) |> plotly::config(scrollZoom = TRUE)
```

Rules: high-contrast legend text, explicit `paper_bgcolor`/`plot_bgcolor`, `font = list(color = "#1a1a1a")`, `config(scrollZoom = TRUE)`.

## Diagram Captions (MANDATORY)

**ALL diagrams MUST have captions** following the same standards as plots and tables.

Every Mermaid/flowchart diagram caption MUST include:
1. **Description**: What the diagram shows (1 sentence)
2. **Node/edge meanings**: What colors, shapes, or line styles represent
3. **Key conclusions**: 2-3 main takeaways
4. **Source function**: The R function that generates the diagram

**Example:**
```markdown
::: {#fig-pipeline}

<pre class="mermaid">...</pre>

Data pipeline showing acquisition (blue), cleaning (orange), analysis (red), and output (green) stages.
Key: Solid arrows = data flow; dashed = optional. All 10 leagues flow through the same QC process.
Source: `R/mermaid_diagrams.R::generate_data_pipeline_mermaid()`.

:::
```

## Diagram Arrow Styling

Use **RED (#CC0000)** for arrow/link colors on dark backgrounds for maximum contrast.

**Mermaid pattern:**
```mermaid
%%{init: {'theme': 'dark'}}%%
graph LR
  A --> B
  linkStyle default stroke:#CC0000,stroke-width:2px
```

**Rationale:** Default grey/black arrows are invisible on dark themes. Red provides strong contrast without competing with node colors.

## Checklist

- [ ] Plotly: explicit `paper_bgcolor`, `plot_bgcolor`, `font` color set
- [ ] Plotly: legend has contrasting `font` and `bgcolor`
- [ ] Plotly: `config(scrollZoom = TRUE)` added
- [ ] **Diagrams have captions with node meanings and conclusions**
- [ ] **Diagram arrows use red (#CC0000) on dark backgrounds**
- [ ] **Every cross-reference uses hyperlinks** (not just "See Section X")
- [ ] Mermaid uses CDN init (not `{mermaid}` chunks)
- [ ] Mermaid uses dark theme with `securityLevel: 'loose'`
- [ ] Node colours use uniform gray-60 fill with red borders (per palette above)