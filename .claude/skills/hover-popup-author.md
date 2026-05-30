# Skill: hover-popup-author

Add a Tippy.js hover popup to a Quarto vignette using the `tt()` helper.

## When to use

When adding hover tooltips in any `.qmd` vignette for term definitions, acronym
expansions, or contextual annotations. The tooltip must meet the standard in
`.claude/rules/hover-popup-standard.md`.

## Prerequisites

The vignette MUST include the shared partial at the top of the body (immediately
after the closing `---` of the YAML frontmatter):

```markdown
{{< include /_includes/hover-popups.qmd >}}
```

All vignettes under `vignettes/` and `vignettes/articles/` already have this
include added as part of Issue #246.

## Usage

In a knitr chunk with `results = "asis"`:

```r
source(here::here("R", "hover_popup_helper.R"))

cat(tt(
  "LLM",
  paste0(
    "<b>Large Language Model</b>. A neural network trained on large text corpora ",
    "to generate, summarise, and classify text. ",
    "See <a href='https://en.wikipedia.org/wiki/Large_language_model'>Wikipedia</a>."
  )
))
```

Or via `htmltools::HTML()` in an inline expression:

```r
htmltools::HTML(tt(
  "targets",
  paste0(
    "<b>targets pipeline</b>. A make-like build system for R that caches outputs ",
    "and only reruns what has changed. See the ",
    "<a href='https://books.ropensci.org/targets/'>targets book</a>."
  )
))
```

## Rules enforced by `tt()`

The helper raises an error if:

1. `body` contains fewer than 2 sentences — add more contextual explanation.
2. `body` has no `<a href="...">` anchor — add at least one external reference.

## Quarto span syntax (alternative)

For one-off spans without R code:

```markdown
The [DALY]{.tt data-tippy-content="<b>Disability-adjusted life year</b>. One DALY equals one year of healthy life lost to illness, disability, or premature death. See <a href='https://www.who.int/data/gho/indicator-metadata-registry/imr-details/158'>WHO IMR definition</a>."} is the unit of analysis.
```

Note: double-quotes inside `data-tippy-content` must be escaped as `&quot;` when
using raw HTML syntax. The R `tt()` helper does this automatically.

## QA gate

`check_hover_popups("docs")` (in `plan_qa_gates.R`) validates all rendered HTML:

- Pages with bare `<abbr title>` and no `.tt` elements: error
- `.tt` elements with < 2 sentences: error
- `.tt` elements with no `<a href>`: error

Run locally: `timeout 60 Rscript -e 'source("R/tar_plans/plan_qa_gates.R"); check_hover_popups("docs")'`

## Related

- `.claude/rules/hover-popup-standard.md` — full authoring standard
- `_includes/hover-popups.qmd` — Tippy.js shared partial
- `R/hover_popup_helper.R` — `tt()` function source
- `R/tar_plans/plan_qa_gates.R` — `check_hover_popups()` gate
- Issue #246 — origin
