# Quarto Dynamic Content Generation

## Description

Patterns for generating dynamic content in Quarto documents including tabsets from data, parameterized sections, and programmatically created R chunks. Essential for reports, dashboards, and documentation that adapt to data.

## Purpose

Use this skill when:
- Creating tabsets dynamically from data (one tab per category)
- Generating parameterized report sections
- Building multi-page reports from templates
- Creating slides or sections that vary by input
- Rendering computed content that includes R code
- **Scrollytelling narratives** with closeread (see [closeread-scrollytelling.md](references/closeread-scrollytelling.md))
- **Scroll-driven animations** using OJS reactive variables

## MANDATORY: Project Configuration

**CRITICAL:** When setting up ANY Quarto project, you MUST explicitly specify which files to render.

By default, Quarto auto-discovers and attempts to render ALL `.md` and `.qmd` files in your project. This causes failures when `.md` documentation files contain R code blocks.

### Required `_quarto.yml` Pattern

**ALWAYS include an explicit `render:` section:**

```yaml
project:
  type: website
  output-dir: docs
  render:
    - "index.qmd"
    - "vignettes/*.qmd"

website:
  title: "My Project"
  navbar:
    left:
      - href: index.qmd
        text: Home
```

### What Gets Rendered

| File Pattern | Default Behavior | With explicit `render:` |
|--------------|-----------------|-------------------------|
| `*.qmd` | Rendered | Only if listed |
| `*.md` | Rendered (may fail) | Ignored |
| `README.md` | Tries to render | Ignored |
| `AGENTS.md` | Fails if has code | Ignored |

### Common Render Patterns

```yaml
# Website with vignettes
render:
  - "index.qmd"
  - "vignettes/*.qmd"

# Book project
render:
  - "index.qmd"
  - "chapters/*.qmd"

# Exclude specific files
render:
  - "*.qmd"
  - "!_draft-*.qmd"  # Exclude drafts
```

## Key Concepts

### Why Standard Approaches Fail

```r
# results="asis" with embedded R code does NOT work:
# cat("```{r}\nplot(1:10)\n```")  # R code NOT executed
# Quarto renders the chunk output, then moves on.
# Any R code in the output is treated as plain text.
```

### The Solution: Pre-render with knitr

```r
# Inline knitr::knit() forces evaluation of generated R chunks:
`r knitr::knit(text = your_generated_markdown)`
```

## Dynamic Content Patterns

Four core patterns for generating dynamic content, plus a real-world example.

See [dynamic-patterns.md](references/dynamic-patterns.md) for detailed code examples.

### Pattern Summary

| Pattern | Use Case | Mechanism |
|---------|----------|-----------|
| 1. Dynamic Tabsets | One tab per data category | `knit_child()` with child .qmd, or inline `glue()` |
| 2. Inline Knitting | Generated content with R chunks | `glue()` + inline `` `r knitr::knit(text=...)` `` |
| 3. Data-Driven Sections | Sections from nested data frames | `pmap_chr()` + `nest()` + `knitr::knit()` |
| 4. Parameterized Reports | Template function per region/group | Template function + `map_chr()` + `knitr::knit()` |

### Key Technique: knit_child with child templates

```r
res <- map_chr(categories, \(cat) {
  knitr::knit_child("_child.qmd", envir = environment(), quiet = TRUE)
})
cat(res, sep = "\n")
```

### Key Technique: Inline knitting for generated R chunks

```r
# In a hidden chunk, build markdown with R code using glue:
generated <- glue::glue("```<<r>>\nsummary(mtcars)\n```", .open = "<<", .close = ">>")

# Then force evaluation with inline R:
# `r knitr::knit(text = generated)`
```

## Execution Contexts and Gotchas

Shiny execution contexts (`setup`, `server`, `data`, `server-start`), common delimiter/environment/ordering pitfalls, and `knitr::knit_expand()` for simple substitution.

See [shiny-contexts-and-gotchas.md](references/shiny-contexts-and-gotchas.md) for detailed guidance.

### Context Quick Reference

| Context | When it runs | Use for |
|---------|-------------|---------|
| `setup` | Render + serve | Libraries, shared data |
| `server` | Serve only | Reactive logic |
| `data` | Render (saves .RData) | Expensive data loading |
| `server-start` | Once at startup | Shared DB connections |

### Gotcha Quick Reference

1. **Delimiter conflicts**: Change glue delimiters (`.open = "<<"`, `.close = ">>"`) when generating code fences
2. **Environment isolation**: Always pass `envir = environment()` to `knit_child()`
3. **Chunk ordering**: Use inline `` `r knitr::knit(text=...)` `` -- `results: asis` alone won't execute generated R
4. **IDE highlighting**: Use child .qmd files or split complex templates

## Best Practices

1. **Use child documents** for complex templates (better syntax highlighting)
2. **Always pass `envir = environment()`** to knit_child
3. **Change glue delimiters** when generating code fences
4. **Pre-compute expensive objects** before template generation
5. **Test templates individually** before scaling to full data
6. **Use meaningful chunk labels** for cross-references

## Dynamic Tabsets from Factor Variables

For generating tabsets dynamically from factor levels (e.g., one tab per station/category/region), see [dynamic-tabsets.md](references/dynamic-tabsets.md). Covers `results: asis` with `cat()`, pre-compute and include patterns, explicit tabs, aggregate "All" views, and troubleshooting.

## Resources

- [R Markdown Cookbook - Child Documents](https://bookdown.org/yihui/rmarkdown-cookbook/child-document.html)
- [Andrew Heiss - Dynamic Chunks](https://www.andrewheiss.com/blog/2024/11/04/render-generated-r-chunks-quarto/)
- [Quarto Tabsets Example](https://github.com/quarto-dev/quarto-examples/blob/main/tabsets/tabsets-from-r-chunks/)
- [Quarto Execution Contexts](https://quarto.org/docs/interactive/shiny/execution.html)
- [knitr::knit_expand()](https://bookdown.org/yihui/rmarkdown-cookbook/knit-expand.html)
- [Danielle Navarro: Quarto Syntax from R](https://blog.djnavarro.net/posts/2025-07-05_quarto-syntax-from-r/)

## Related Skills

- targets-vignettes (pre-calculate objects for vignettes)
- shinylive-quarto (Shiny in Quarto)
- pkgdown-deployment (building package websites)
