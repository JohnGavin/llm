---
name: closeread-scrollytelling
description: >
  Build scrolly analytical narratives in Quarto using the closeread extension —
  sticky chart panels with scrolling prose, progressive disclosure of a single
  dataset across multiple re-encoded scenes, and consistent transparency blocks.
  Use when a static vignette would benefit from guided reveal and the dataset
  fits one chart's worth of points re-cast 3-7 different ways.
metadata:
  author: John Gavin
  version: "1.0"
mandatory: false
---

# Closeread Scrollytelling

## What it is

Closeread is a Quarto extension by Andrew Bray and James Goldie (v1.0.1, Quarto ≥ 1.3.0)
that adds sticky chart panels with scroll-driven focus changes. As the reader scrolls
through prose, trigger references (`@cr-sceneN`) swap which sticky panel is visible.
Use it for analytical narratives that reveal a single dataset's structure incrementally —
where each scene re-encodes the same rows with a different aesthetic mapping.

## When to use vs alternatives

| Situation | Tool |
|-----------|------|
| Same dataset, 3–7 different encodings, linear narrative arc | **closeread** |
| Independent panels, no narrative flow, user browses freely | Static panel-tabsets |
| User needs to filter, explore, or change parameters live | Shinylive / Shiny |

## Setup

### Frontmatter

```yaml
---
title: "My scrollytelling vignette"
format:
  closeread-html:        # must be closeread-html, not plain html
    toc: false
    code-fold: true
    code-summary: "Show code"
execute:
  echo: false
  warning: false
  message: false
---
```

### Extension installation

The extension is already present in this repo at
`vignettes/articles/_extensions/qmd-lab/closeread/`. For a new project:

```bash
quarto add qmd-lab/closeread
```

The `_extension.yml` contributes a `closeread-html` format, injects `closeread.lua`,
and sets `page-layout: full` — no extra configuration needed.

## The four building blocks

### a. `cr-section` block — outer container

Each scrollytelling segment lives in a `cr-section` div. Multiple sections are
allowed per page. (Source: `scrolly-config-evolution.qmd` lines 69–94)

```markdown
:::{.cr-section}

... sticky panel + prose + triggers ...

:::
```

### b. Sticky panel — chart that stays in view

The sticky panel has a unique id and the `.sticky` class. The id must match the
trigger reference in prose. (Source: `scrolly-config-evolution.qmd` lines 71–84)

```markdown
:::{#cr-scene1 .sticky}
```{r scene1-plot}
#| fig-alt: "Alt text describing the chart for screen readers."
ggplot(cfg, aes(x = n_bytes, y = n_lines)) +
  geom_point(colour = "#888888", alpha = 0.6, size = 2) +
  labs(title = paste0("All ", n_files, " config files"), x = "File size (bytes)", y = "Lines") +
  base_theme
```
:::
```

### c. Focus trigger — switch the active sticky panel

`@cr-sceneN` in prose body activates (or keeps visible) the corresponding sticky.
Multiple triggers to the same scene are allowed — use them to break prose into
readable chunks without changing the chart. (Source: `scrolly-config-evolution.qmd`
lines 88, 90)

```markdown
Every session loads `~/.claude/CLAUDE.md`. Behind it sit `r n_files` files ...

@cr-scene1

The spread along the y-axis is striking. Most files sit under 100 lines ...

@cr-scene1
```

### d. Setup chunk — pre-loaded data and named palette

Define the shared dataset and colour palette once in an `include: false` setup
chunk. All scene chunks inherit these objects via normal R scoping.
(Source: `scrolly-config-evolution.qmd` lines 16–67)

```r
#| include: false
library(ggplot2)
library(dplyr)

cfg <- safe_tar_read("vig_scrolly_config")

# Stable colour palette — used unchanged across all 5 scenes
category_palette <- c(
  rules    = "#e6194b",
  skills   = "#3cb44b",
  agents   = "#4363d8",
  hooks    = "#f58231",
  memory   = "#911eb4",
  commands = "#46f0f0",
  scripts  = "#aaffc3"
)

n_files <- nrow(cfg)
```

## The progressive-disclosure pattern

The "re-encoding pattern": keep the same `cfg` tibble across all scenes; change
only the `aes()` mapping. The reader stays oriented to the dataset while the
analytical lens shifts. From `scrolly-config-evolution.qmd` (lines 101–112,
129–143, 213–223):

- Scene 1: `aes(x = n_bytes, y = n_lines)` — baseline, no colour
- Scene 2: `aes(..., colour = category)` — reveal category with `scale_colour_manual(values = category_palette)`
- Scene 3: `aes(..., colour = category, size = age_clamped)` — add git-age as size
- Scene 4: alpha-fade all except hotspots — highlight outliers with same `category_palette[["rules"]]`
- Scene 5: `facet_wrap(~category)` + `scale_fill_manual(values = category_palette)` — small multiples

Each scene adds one encoding; each uses the same `category_palette`. The colour
legend built in scene 2 remains valid through scene 5 without re-reading it.

## Required conventions

- **Persistent colour:** define palette as named vector in setup, reuse
  `scale_*_manual(values = PALETTE)` in every scene →
  see `narrative-colour-persistence` rule
- **Methodology block:** every vignette ends with `## Methodology` + three H3s
  (`### What this vignette computes`, `### Data sources`, `### AI disclosure`) →
  see `narrative-evidence-block` rule
- **Pre-computed data only:** `safe_tar_read()` from RDS in `inst/extdata/vignettes/`;
  no live queries, no `lm()`, no aggregations in scene chunks →
  see `quarto-vignettes` rule
- **QR partial top and bottom:** `{{< include ../../_includes/qr-footer.qmd >}}`
  at top (before `cr-section`) and bottom (after `## Methodology`) → see #146

## Performance notes

- Rendered page weight: `scrolly-config-evolution.html` ≈ 42 KB
- Render time: 5 scenes × small dataset ≈ 10 s local
- Do NOT use closeread when: dataset > 5,000 points (use shinylive or static),
  or the reader needs to filter/explore live (use shinylive)

## Closeread quirks

- Format key is `closeread-html`, not plain `html` with a filter
- Trigger syntax is `@cr-sceneN` — Pandoc-style reference to a div id
- Sticky blocks need BOTH the `.sticky` class AND a matching div id
- Focus triggers may repeat; each re-renders the same sticky (useful for prose breaks)
- Tested with closeread v1.0.1, Quarto ≥ 1.3.0

## Cross-references

- Worked example: `vignettes/articles/scrolly-config-evolution.qmd`
- Targets plan: `R/tar_plans/plan_scrolly_config.R`
- Sibling rules: `narrative-evidence-block`, `narrative-colour-persistence`
- Sibling skills: `quarto-dynamic-content`, `shinylive-quarto`, `quarto-alt-text`
- Upstream: https://closeread.dev/ · https://github.com/qmd-lab/closeread
- Reference inspiration: https://puntofisso.net/eurovision/ (closes #155)
