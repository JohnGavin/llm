---
description: When re-encoding the same dataset across multiple charts in one narrative, colour mapping for each entity must stay stable across all panels.
type: rule
name: narrative-colour-persistence
paths:
  - "**/*.qmd"
  - "vignettes/**"
  - "dashboard/**"
---

# Rule: Narrative Colour Persistence

## When This Applies

Any Quarto vignette, Shiny app, or dashboard that shows the same dataset re-encoded across two or more charts within a single page or scrollytelling narrative. Applies to ggplot2, plotly, and any other charting library. Applies regardless of whether the visual encoding changes (colour → size, colour → shape) between panels.

## CRITICAL: Same Entity, Same Colour — Always

When the same categorical entity (project, rule, model, category) appears in multiple charts, using different colours across panels breaks the reader's colour-meaning association. The reader builds a colour legend from panel 1. In panel 2, the mapping shifts. The reader must rebuild context instead of reading the data.

This is not an aesthetic preference. It is a legibility and trust requirement: a chart where "sonnet" is blue in one panel and orange in another is misleading, even if each panel has a legend.

## Required Pattern

### 1. Define a named palette vector once in setup

```r
# In the setup chunk — define ONCE, reuse everywhere
PALETTE <- c(
  "rules"   = "#4ea8de",
  "skills"  = "#69d4a0",
  "hooks"   = "#ffd93d",
  "agents"  = "#f08080",
  "memory"  = "#c084fc"
)
```

Name every entity that appears in any chart on the page. Names must exactly match the factor levels in the data.

### 2. Bind colour with `scale_*_manual(values = PALETTE)`

```r
# ggplot2
ggplot(df, aes(x = n, y = category, fill = category)) +
  geom_col() +
  scale_fill_manual(values = PALETTE)

# plotly
plot_ly(df, x = ~n, y = ~category, color = ~category,
        colors = PALETTE)
```

### 3. Never redefine colours in individual chart calls

```r
# WRONG: inline palette, may differ from PALETTE
ggplot(...) + scale_fill_viridis_d()

# WRONG: different object, might use different order
ggplot(...) + scale_fill_manual(values = c("blue", "green", "yellow"))

# RIGHT: always reference the named PALETTE object
ggplot(...) + scale_fill_manual(values = PALETTE)
```

## Palette Construction Rules

| Rule | Detail |
|------|--------|
| Named, not positional | `c("rules" = "#4ea8de")` not `c("#4ea8de")` |
| Accessibility compliant | Use `viridis` palette entries or `brewer.pal("Dark2")` as source |
| Consistent across scroll scenes | Same `PALETTE` in every `cr-section` |
| Never red + green as sole pair | Combine with shape or label |
| Dark-mode compatible | All palette entries must meet 4.5:1 contrast on dark backgrounds |

## Closeread / Scrollytelling

In closeread narratives with multiple `cr-section` blocks, the setup chunk runs once. The `PALETTE` object is available in all subsequent chunks via normal R scoping. No special handling required — just reference `PALETTE` in every chart chunk.

```r
# setup chunk (runs once)
PALETTE <- c("core" = "#4ea8de", "qa" = "#69d4a0", "data" = "#ffd93d")

# scene 1 chunk
ggplot(...) + scale_fill_manual(values = PALETTE)  # uses PALETTE

# scene 5 chunk (same page, different cr-section)
ggplot(...) + scale_fill_manual(values = PALETTE)  # same PALETTE
```

## Progressive Disclosure Exception

When a scene introduces a NEW category not present in prior scenes, add it to `PALETTE` in the setup chunk with a visually distinct colour. Do not assign it to a slot already claimed by another category. If the palette grows beyond 8 categories, switch to a reduced encoding (show only a highlighted subset per scene).

## Forbidden Patterns

| Pattern | Why wrong | Fix |
|---------|-----------|-----|
| `scale_fill_viridis_d()` per chart | Assigns colours by factor order, not name — order may differ across charts | Define `PALETTE`, use `scale_fill_manual(values = PALETTE)` |
| Inline `c("blue", "green")` per chart | Positional mapping breaks when data order changes | Named vector: `c("rules" = "blue", "skills" = "green")` |
| Palette defined inside a chart function | Hidden from other charts; cannot reuse | Move to setup chunk, reference by name |
| Different colour for same entity in plotly vs ggplot on same page | Cross-library inconsistency | Define one `PALETTE`, use in both |
| Colours chosen per-scene without coordination | Scene 1 blue ≠ scene 4 blue for same entity | Single `PALETTE` in setup |

## Verification

Before committing: visually scan the rendered page from top to bottom. For each categorical entity, verify its colour is identical across every chart. If using closeread, scroll through all scenes.

## Related

- `accessibility` rule — palette contrast requirements (4.5:1 minimum)
- `visualization` rule — core chart standards (no pie charts, Cleveland dot plots)
- `narrative-evidence-block` rule — companion standard for methodology transparency
- `dynamic-prose-values` rule — values referenced in prose must be dynamic
- Issue #155 — Phase 1 origin
