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
  themeVariables: { background: '#1a1a1a', primaryColor: '#2d5f8a' }
});
document.querySelectorAll('script[data-mermaid]').forEach(function(s) {
  var target = document.getElementById(s.getAttribute('data-mermaid'));
  if (target) target.textContent = s.textContent;
});
await mermaid.run({ querySelector: '.mermaid' });
</script>
```

## Dark Theme Variables

Match `theme_micromort_dark()` with `#1a1a1a` background. Use `mermaid_dark_theme_header()` from `R/diagrams.R` for the `%%{init:...}%%` prefix in target-generated diagrams.

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
