---
paths:
  - "R/**"
  - "vignettes/**"
  - "*.qmd"
---
# Diagram Generation in Vignettes

## Mandatory Rule

All mermaid diagrams in vignettes MUST be pre-computed via targets. Never generate diagrams inline in vignettes.

```r
# WRONG — computation in vignette
cat("graph LR\n  A --> B")

# RIGHT — pre-computed target
tar_read("my_diagram")
```

## Technology Decisions

| Approach | Use? | Reason |
|----------|------|--------|
| `{=html}` + mermaid CDN in `.qmd` | YES | Click `href` works with `securityLevel: 'loose'`. Zero R deps. Dark theme control |
| Fenced mermaid in README.md | YES | GitHub renders natively. Output from `knitr::knit()` |
| `targets::tar_visnetwork()` | YES | Auto-generated DAG, always in sync |
| DiagrammeR | NO | Heavy dep (~8 MB), clickable nodes broken (GH #452 since 2019) |
| Shinylive + mermaid.js | NO | 10-15 MB WASM for a static diagram |
| Quarto `{mermaid}` chunks | NO | Click/href broken (Quarto bug #10450) |

## Pandoc Arrow Encoding Workaround

Pandoc HTML-encodes `>` to `&gt;` everywhere — including inside `<pre>` tags. This breaks mermaid arrows (`-->`).

**Solution**: script tag injection pattern:

1. Emit diagram text in `<script type="text/plain" data-mermaid="id">` (script content is never entity-encoded)
2. Emit empty `<pre class="mermaid" id="id"></pre>` as the render target
3. JavaScript copies text from script into pre, then calls `mermaid.run()`

```r
emit_mermaid <- function(target_name, fallback_msg) {
  diagram <- safe_tar_read(target_name)
  if (!is.null(diagram)) {
    id <- gsub("[^a-z0-9]", "", target_name)
    cat(sprintf('<pre class="mermaid" id="%s"></pre>\n', id))
    cat(sprintf('<script type="text/plain" data-mermaid="%s">\n', id))
    cat(diagram)
    cat("\n</script>\n")
  } else {
    cat(paste0("*", fallback_msg, "*\n"))
  }
}
```

## Mermaid CDN Init Block

Use ES module import with explicit render control:

```html
<script type="module">
import mermaid from 'https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs';
mermaid.initialize({
  startOnLoad: false,
  securityLevel: 'loose',  // required for click href
  theme: 'dark',
  themeVariables: { background: '#000000', primaryColor: '#999999', lineColor: '#CC0000', primaryTextColor: '#000000' }
});
document.querySelectorAll('script[data-mermaid]').forEach(function(s) {
  var target = document.getElementById(s.getAttribute('data-mermaid'));
  if (target) target.textContent = s.textContent;
});
await mermaid.run({ querySelector: '.mermaid' });
</script>
```

## Dark Theme Variables (MANDATORY)

High-contrast dark theme: black background, gray-60 box fill, black text, red arrows. Use `mermaid_dark_theme_header()` from `R/diagrams.R` for the `%%{init:...}%%` prefix.

| Element | Color | Hex |
|---------|-------|-----|
| Background | Black | `#000000` |
| Node fill | Gray 60% | `#999999` |
| Node text | Black | `#000000` |
| Borders/arrows | Red | `#CC0000` |
| Cluster fill | Dark gray | `#333333` |

All nodes: `fill:#999999,stroke:#CC0000,color:#000000`

### Multiline Labels

Use `<br/>` (HTML entity `&lt;br/&gt;` inside script tags) for multiline node labels. NEVER use `\n` — it renders literally in Mermaid.

## Staleness Detection

Diagram targets must depend on the metadata they introspect:

```r
# Pipeline diagram — depends on plan file contents
tar_target(diagram, {
  plan_hash <- digest::digest(lapply(plan_files, readLines))
  generate_pipeline_diagram()
})

# Concept diagram — depends on NAMESPACE
tar_target(diagram, {
  ns_hash <- digest::digest(file = "NAMESPACE")
  generate_concept_diagram()
})
```
