---
description: One body font size everywhere in dashboards and vignettes — no per-element overrides
paths:
  - "**/*.qmd"
  - "dashboard/**"
  - "**/*.css"
  - "**/*.scss"
---

# Rule: Uniform Typography in Dashboards and Vignettes (Mandatory)

## When This Applies

Every dashboard (Quarto, Shiny, pkgdown), every analytical vignette, every
report. Applies to all prose on the page: headings (separately styled),
body paragraphs, captions, glossary terms and definitions, panel-tabset
text, table cells, methodology blocks, callout boxes.

## Source

A private personal-finance project, session 30, 2026-06-02. User report (paraphrased):
"make all text font size the same ... do this everywhere through the
document ... no exceptions ... this was asked before so reopen all closed
issues related to this request and start tracking your failures
explicitly".

## Recurrence — 2026-08-27, historical project

Reported again, by the same user, on a leaderboard dashboard: *"the font size is too small. match the main text. repeat this throughout the document."* The target was a DT table caption and its `<details>` disclosure summary.

**This rule already forbade it** — `caption { font-size: smaller }` was in the Forbidden Patterns table below at the time. It was violated anyway, because the Required Pattern's selector list did not name the two surfaces that actually carried the drift: `details summary` (a shared-CSS rule set it to `0.9em`) and DT's injected `.dt-caption`. Every listed selector was compliant; the size drift lived in the gap between them.

**The generalisable lesson: a typography rule is only as good as its selector list.** "Set the body size once and let everything inherit" fails silently the moment a framework or a shared stylesheet introduces a new text surface with its own default — DataTables, Quarto callouts, `<details>`, tooltip/popover bodies, plot legends rendered as HTML. When adding any new text-bearing UI element, add its selector to the list in the same commit. When a size-drift report arrives, **find the surface that is not in the list** rather than assuming the rule was never applied.

Verification for this class is a computed-style sweep, not a source grep: a source that contains no `font-size` override can still render at the wrong size because a vendored stylesheet set one.

## CRITICAL: One Body Size, No Per-Element Overrides

Prose font size drift across a single page makes the page look like it was
assembled by three different authors at three different times. The fix is
trivial: set the body font size ONCE; let everything inherit.

A page with the glossary at 18px, the methodology intro at 16px, the
caption at 14px and the table cells at 13px is a maintenance failure even
if every individual size is justifiable in isolation.

## Required Pattern (CSS)

```css
/* One root font size. Everything inherits unless explicitly overridden. */
html { font-size: 16px; }

/* Every text-bearing element renders at the body size */
body,
p, li, dd, dt, td, th,
caption, figcaption,
.figure-caption, .quarto-figure-caption, p.caption,
.dataTables_wrapper, .dataTables_filter input, .dataTables_info,
table.dataTable, table.dataTable th, table.dataTable td,
table.dataTable caption, .dt-caption,
details, details summary,
.panel-tabset .nav-link,
.cell-output, .cell-output-stdout,
.callout, .callout p,
dl, dl dt, dl dd {
  font-size: 16px !important;
  line-height: 1.5;
}

/* Headings stay larger but are uniform within each level */
h1 { font-size: 22px !important; }
h2 { font-size: 20px !important; }
h3 { font-size: 18px !important; }
h4 { font-size: 17px !important; }
```

The `16px` value is the recommended default. A project may choose 15px or
17px instead, but the SAME size must apply to every body-text surface on
the page.

## Allowed Overrides (Closed Set)

Only these elements may have a different font-size from the body:

| Element | Acceptable size | Why |
|---|---|---|
| Dashboard title banner (`h1.title`) | 22px or `font-size: 1.4rem` | Compact heading; bigger is fine |
| Subtitle banner (`p.subtitle`) | 16px (same as body) or 18px | Slight uplift acceptable |
| Code blocks / monospace | Same as body, OR ±2px max | Monospace tends to read denser; minor adjustment OK |
| `<sub>` / `<sup>` HTML elements | Smaller per browser default | Standard typographic behaviour |

Anything not in this table that has a custom `font-size` in inline
`style=` or a per-element CSS rule is a defect.

## Forbidden Patterns

| Pattern | Why wrong | Fix |
|---|---|---|
| `<p style="font-size:14px">` in a code-gen chunk | Hardcoded per-element size | Strip the style; let CSS handle it |
| `.glossary-term { font-size: 0.9em }` | Drift from body | Remove the rule |
| `.methodology p { font-size: 1.1em }` | Drift from body | Remove the rule |
| `caption { font-size: smaller }` | Browser-default smaller — too small | Set to body size via the required CSS pattern |
| `details summary { font-size: 0.9em }` | A disclosure summary IS body prose — it is the only text a reader sees until they click | Remove the override; it is in the required selector list above |
| A `<details>` disclosure whose summary is smaller than the text it hides | Inverts the hierarchy: the always-visible line is smaller than the optional one | Summary at body size |
| `<dl style="font-size: 0.95rem">` | Inline drift | Remove the inline style |
| Inline `style="font-size: 23px"` on a panel | Drift, even if "matches" body | Remove and rely on inheritance |

## When the User Says "Make Everything Size N"

The fix is the CSS pattern above with `N` substituted for `16px`. Do NOT
patch one element at a time. Do NOT add a per-section `font-size`
declaration. Do NOT trust `rem` units to scale uniformly across all
frameworks — Quarto, Bootstrap, DataTables and brand-yml all set their
own `font-size` defaults in different units. Use `px` and `!important` to
guarantee uniformity.

## Verification

After applying:
1. Open the rendered page in a browser
2. Open DevTools, inspect a paragraph in each of: body prose, glossary
   term, glossary definition, caption, table cell, callout, methodology,
   tab-panel text
3. The computed `font-size` for all of them must be the same
4. Headings may differ (per the headings table above)

## Related

- `accessibility` — minimum readable size (the 16px default meets WCAG)
- `dashboard-table-styling` — tables inherit body font size from this rule
- `narrative-evidence-block` — methodology block follows this rule
- `narrative-colour-persistence` — same single-source-of-truth principle
  applied to colour
- private-repo `knowledge_base/lessons_learnt.md` L-3 — origin failure log (same project as the Source above)
- private-repo issue tracker (same project) — reference implementation
