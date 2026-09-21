# Companion: Visualization Standards (Core) — Worked Examples and Incident Detail

Worked examples and incident detail split out of the always-loaded
[`visualization`](../visualization.md) rule to keep it under the repo's
150-line limit. The normative content (principles, palettes, legend position,
plotly dark theming requirement, caption minimums, number formatting, variable
labels) stays in the rule; this file holds the verbatim text moved out of it,
loaded on demand.


## Sections Moved from the Rule Body (2026-09-21 line-limit pass)

Original verbatim text moved out of the rule; the normative summary stays in the rule.

**Recognise this defect from its symptom, not just by reading code:** a
chart, or occasionally a whole tab, that "looks blank/wrong in one browser
but fine in another" is the pattern this produces — check for missing
`paper_bgcolor`/`plot_bgcolor`/`font` on every `renderPlotly`/`plot_ly()`
call BEFORE chasing a browser-specific JS theory. See `visualization-detailed`
skill's "Plotly Theming" section for the audit grep pattern and full writeup
(origin: mycare dashboard incident, 2026-07-26 — reported as Chrome-only
blank tabs; confirmed defect was missing theming on every plot in the app,
found while investigating, though the causal link to the Chrome symptom was
never proven via a captured console error).

```r
# WRONG — describes the axes, states no question
subtitle = "Strokes hit vs stroke-in accuracy, one point per drill instance"

# RIGHT — the question the chart exists to answer
subtitle = "Does hitting more strokes in a drill instance track with accuracy — a within-drill fatigue or warm-up signal?"
```

Applies equally to a table's intro sentence (`section-note`, caption,
`<p>` above the table) — e.g. "Which rallies were flagged, and why?" or
"Does each proposed split actually resolve the rally under threshold?"
rather than only "columns are X, Y, Z."

**When there's no real question** (a pure reference/lookup table — a
glossary, a raw variable listing, a schema diagram) this doesn't apply;
don't force a question onto content that is genuinely just data-shape
description. The test is "wherever possible," not "always" — see
`checks-must-distinguish-unknown`'s spirit: don't manufacture a false
question to satisfy a checklist.
