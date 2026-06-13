---
description: Hover popups use Tippy.js via the shared partial — never bare abbr title attributes
paths:
  - "**/*.qmd"
  - "vignettes/**"
  - "_includes/**"
---

# Rule: Hover-Popup Standard (All Vignettes, All Projects)

## When This Applies

Any vignette, README, or published Quarto page that uses hover-style tooltips for
term definitions, acronym expansions, or contextual annotations.

## Decision: Mechanism M2 — Tippy.js

Browser-default `<abbr title="…">` renders at OS tooltip size (~11 px). This rule
mandates Tippy.js for all hover popups. Rationale: full CSS control, mobile tap
behaviour, `allowHTML` for rich content, ~12 KB total weight.

Alternatives considered and rejected:
- **M1 (`popover` API)**: browser support still patchy on Safari ≤17.
- **M3 (CSS-only `:hover`)**: not touch-friendly; no tap-to-show on mobile.

## Required Partial Include

Every `.qmd` page that uses hover popups MUST include the shared partial at the
**top** of the document body (after the YAML front-matter):

```markdown
{{< include /_includes/hover-popups.qmd >}}
```

(Path is project-root-relative. Projects that live in a sub-directory use the
absolute path `/_includes/hover-popups.qmd` or adjust the relative depth.)

## Author Helper — `tt()` R Function

Use the `tt(term, body)` helper from `R/hover_popup_helper.R`:

```r
cat(tt("LLM", paste0(
  "<b>Large Language Model</b>. A neural network trained on large text corpora ",
  "to generate, summarise, and classify text. See ",
  "<a href='https://en.wikipedia.org/wiki/Large_language_model'>Wikipedia</a> and ",
  "the <a href='https://johngavin.github.io/llm/vignettes/telemetry.html'>",
  "Project Telemetry vignette</a>."
)))
```

Or use the Quarto span syntax directly:

```markdown
[LLM]{.tt data-tippy-content="<b>Large Language Model</b>. …"}
```

## Tooltip Content Requirements

Every tooltip body MUST contain:

| Requirement | Minimum |
|---|---|
| Length | ≥ 2 sentences |
| External link | ≥ 1 `<a href="…">` to an external reference |
| HTML-escaped characters | Use `tt()` helper — it escapes `"` and `&` automatically |
| Units / abbreviation expansion | Full name in `<b>…</b>` as first element |

## Styling Requirements

The shared partial (`_includes/hover-popups.qmd`) enforces:

| Property | Value |
|---|---|
| Font size | `1rem` (body parity) — never smaller than `0.95rem` |
| Font family | `inherit` — no monospace unless content is code |
| Max width | `min(80ch, 500px)` — prose wraps cleanly |
| Dark-mode | `var(--bs-tertiary-bg)` / `var(--bs-body-color)` for system-aware theming |
| Z-index | Above plotly and Mermaid layers (managed by Tippy) |
| Mobile | `interactive: true` — tap shows, tap-elsewhere dismisses |

## Accessibility

- `.tt` elements receive `tabindex="0"` via Tippy (keyboard-focusable).
- `aria-describedby` is wired automatically by Tippy when `aria.content = "describedby"`.
- Do NOT use `<abbr title="…">` without upgrading to the Tippy pattern — bare `title=`
  is inaccessible on touch devices and styled at OS defaults.
- Dark-mode contrast: tooltip background MUST pass 4.5:1 against tooltip text.
  The shared partial uses Bootstrap CSS variables which respect the active theme.

## QA Gate

`check_hover_popups()` in `R/tar_plans/plan_qa_gates.R` scans rendered HTML and
aborts the pipeline if:

1. A page has bare `<abbr title="…">` with NO `.tt[data-tippy-content]` elements.
2. Any `.tt[data-tippy-content]` element has a body shorter than 2 sentences.
3. Any `.tt[data-tippy-content]` element has no embedded `<a href=`.
4. Tippy.js is not loaded on pages that contain `.tt` elements.

Run locally: `Rscript -e 'source("R/tar_plans/plan_qa_gates.R"); check_hover_popups("docs")'`

## Forbidden Patterns

| Pattern | Why wrong | Fix |
|---|---|---|
| `<abbr title="short gloss">TERM</abbr>` | Browser-default sizing, no links, inaccessible on mobile | Migrate to `tt()` + shared partial |
| Tooltip body with 1 sentence | Insufficient context | Add ≥ 2 sentences + external link |
| Tooltip body with no `<a href>` | No pathway to deeper reading | Add external reference |
| Hardcoded colours in tooltip CSS | Breaks dark-mode | Use Bootstrap CSS variables |
| Inline `data-tippy-content` with raw `"` inside `"…"` | Attribute parsing breaks | Use `tt()` helper which calls `htmltools::htmlEscape()` |

## Relationship to `acronym-expansion` Rule

This rule extends `acronym-expansion`: the `<abbr title="…">` pattern described
there is the **fallback** for plain-text contexts (email, plain HTML without JS).
In vignettes with the Tippy partial loaded, ALL acronym hovers MUST use the
`tt()` pattern — `<abbr title>` is prohibited where Tippy is available.

## Related

- `_includes/hover-popups.qmd` — shared partial (Tippy.js loader + CSS)
- `R/hover_popup_helper.R` — `tt()` author helper
- `R/tar_plans/plan_qa_gates.R` — `check_hover_popups()` build-time gate
- `acronym-expansion` rule — first-use expansion pattern (prose context)
- `accessibility` rule — dark-mode contrast, keyboard navigation
- `dynamic-prose-values` rule — popup content with derived values must use `r expr`
- Issue #246 — origin specification
