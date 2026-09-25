---
paths:
  - ".claude/rules/visualization.md"
---

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

## Axis Ranges Are Data-Driven, Never Preset — worked example and origin

```r
# WRONG — bakes in a 0-100 range regardless of what the data does
scale_y_continuous(limits = c(0, 100), labels = scales::percent)

# RIGHT — range comes from the data; ggplot's default already does this
scale_y_continuous(labels = scales::percent,
                    breaks = scales::pretty_breaks(),
                    expand = ggplot2::expansion(mult = 0.05))
```

Full text of the user correction (2026-09-11): an earlier draft of the rule
carved out a zero-baseline exception for `geom_col`/`geom_bar` on Tufte/Cairo
lie-factor grounds (a truncated bar's *length* misrepresents its value). That
exception is removed: the house style already forbids bar charts outright
(see "Core Principles" — "NEVER pie charts. NEVER bar charts. — Use dot plots
(Cleveland)"), so the geometry the exception was written for is not used here
in the first place. The axis-range rule is unconditional: **every** chart's
range comes from the data, full stop — prefer a line/point/dot-plot geometry
(which never needed a zero baseline) over a bar/column geometry (which would)
in every case, rather than making the axis rule conditional on which geometry
was chosen. Every audit-grep hit needs removal — there is no justified
exception.

### Origin

`tennis` project, 2026-09-10 — "Stroke-in accuracy across sessions, by
drill" (a line/point chart, data range ~50-100%) had `limits = c(0, 100)`
hardcoded, flattening a real, visible trend into the top half of the
chart. An audit of the same script found two more instances of the same
mistake on similarly-shaped charts (a share-trend line and a per-instance
accuracy distribution) — none of the three needed a zero baseline; all
three were fixed by removing the literal `limits=` and relying on
`pretty_breaks()` + `expansion()` to size the range from the data.
