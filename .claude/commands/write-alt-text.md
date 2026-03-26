# /write-alt-text - Generate Alt Text for All Figures

Scan all .qmd vignettes for figures missing `fig-alt:` and generate accessible alt text.

## Workflow

1. Find all figure chunks: `grep -rn "#| label: fig-" vignettes/*.qmd`
2. For each figure chunk:
   a. Read ~50 lines of context (prose before + code + prose after)
   b. Check if `fig-alt:` already exists — skip if present and adequate
   c. Extract from ggplot2 code: geom type, aes mappings, facets, overlays
   d. Extract from data code: distribution shape, transformations applied
   e. Read fig-cap to determine complementarity (caption has insight → alt = structure)
   f. Draft alt text using Amy Cesal's formula (type → data → insight)
   g. Verify against quality checklist
3. Present all drafts for review before applying
4. Apply approved alt text as `#| fig-alt: |` in each chunk

## Quality Checklist (per figure)

- [ ] Starts with chart type (Scatter chart, Histogram, etc.)
- [ ] Names axis variables
- [ ] Includes specific values/ranges from code
- [ ] States key insight from surrounding prose
- [ ] Complements (not duplicates) fig-cap
- [ ] Plain language (no "geom", "aesthetic", "aes")
- [ ] 2-5 sentences depending on complexity

## Output Format

For each figure, show:
```
### fig-{label} (vignettes/{file}.qmd:{line})
**fig-cap:** {existing caption}
**Chart type:** {from ggplot2 code}
**Draft fig-alt:**
{proposed alt text}
```

Then ask: "Apply these alt texts? (all / select / revise)"

See `quarto-alt-text` skill for templates, code mapping table, and examples.
