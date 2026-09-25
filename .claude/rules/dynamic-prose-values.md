---
name: dynamic-prose-values
description: Every data-dependent number in published text is computed at build time and checked by a publish gate — never typed by hand
globs: ["**/*.qmd", "**/*.Rmd", "**/R/*.R", "**/*.html", "**/scripts/**"]
paths:
  - "**/*.qmd"
  - "**/*.Rmd"
  - "vignettes/**"
  - "README*"
  - "**/*.html"
  - "artifact/**"
  - "dashboard/**"
  - "scripts/**"
  - "R/**"
---

# Rule: Dynamic Prose Values (Mandatory, No Exceptions)

## When This Applies

Any text a reader sees — vignettes, dashboards, generated HTML pages, Claude
Artifacts, chart captions and subtitles, `alt`/`title` tooltips, strings in a
page's own JavaScript, email templates, README — that contains a number,
date, count, percentage, list or name that depends on the data or on a
config value.

## CRITICAL: Compute it at build time, or it is wrong the next time data arrives

Every data-dependent value in published text MUST be produced by code from
the same objects the charts and tables use. A number typed by hand is
correct only until the next session, recording, or parameter change — and
nothing tells you when that happens.

This includes **copies of reference tables** (a thresholds table copied from
a params function, a chart list copied from a catalogue). Generate the table
from its source of truth; never maintain a second copy by hand.

## How, by output type

| Output | Pattern |
|---|---|
| Quarto / Rmd | inline R: `` `r n_sessions` `` |
| Captions/subtitles built in R | `sprintf("%d of %d sessions", n_x, n_sessions)` |
| Generated HTML / Claude Artifact | `<span data-fact="n_sessions"></span>` placeholders, filled at build from a facts file the build computes (e.g. `facts.json`); the fill step **errors** on a key the build did not compute |
| Reference table in a page | generated from its source (`params()`, catalogue, audit CSV) and injected by id |
| Page JavaScript strings | computed from the page's own embedded data, not a literal |
| Email templates | values from the summary object passed in |

## Enforcement: a publish gate, not this file

This rule existed, correctly worded, while a dashboard carried 77 hand-typed
numbers — because it only loaded for `.qmd` files and nothing checked. A rule
is not a control.

Every project that publishes text MUST run a gate in its build/publish step
that **fails** when page text contains a count-like number that is not
computed. Minimum:

- Scan visible text, `alt`/`title`/`aria-label` attributes (including those
  built inside JavaScript strings), and JavaScript string literals.
- Flag at least: `N of M`, `n = N`, `N sessions/rallies/strokes/...`,
  `N%`, `N km/h`/`mph`, `~N` / `about N`.
- Skip only: filled `data-fact` placeholders, tables/blurbs the build
  generates in full, and elements marked `data-fixed="<reason>"`.
- **Falsify it before trusting it** (see `verification-before-completion`):
  run it on the pre-fix page (it must report the known hits) and on a copy
  with one planted hand-typed count (it must catch it).

A reference implementation exists in a private dashboard project (an
exported gate function plus a fill function, run as the last two steps of
its splice/publish script); ask the owner for it rather than re-deriving.

## `data-fixed`: the only allowed hand-typed numbers

Mark a number `data-fixed="<reason>"` only when it must **not** change with
the data:

| Allowed | Example | Reason value |
|---|---|---|
| Evidence from a dated check | "wrong on 14 of 16 video-checked strokes" | `dated video check` |
| An external reference | "NTRP roughly 4.5–5.5" | `external reference` |
| A design constant of the page | "vs the previous 2 sessions" tab | `design` |
| A definition | "Beaufort 9 = 41 knots" | `definition` |

Evidence must say when or on what it was checked ("on the 17 Aug session"),
so a reader knows it is a snapshot. If the evidence would be re-derived by
code, it is not fixed: compute it.

## Violations

| Pattern | Problem | Fix |
|---|---|---|
| `"n = 9"`, `"6 of 9 sessions"` in a caption | Stale at session 10 | `data-fact` / inline R |
| `"0 of 42 charts mislabelled"` | Catalogue grew to 53 | count from the catalogue |
| Static thresholds table beside `dq_params()` | Two sources, will drift | generate from `dq_params()` |
| `title="... wrong for 5 of 9 sessions"` in JS | Gate-invisible if only text is scanned | compute, or drop the count |
| `"~93%"` in prose | Drifts silently | compute from the data |
| Fixing only the numbers the user named | The rest stay stale | run the gate over the whole page |

## Origin

A private dashboard project, 2026-09-25. A chart title read
n = 11 while its caption said "n = 9"; the gate then found 77 hand-typed
numbers on one page, two of them already false (a "fastest stroke" claim, a
chart count), plus two reference tables maintained by hand. User: "never do
this by hand again … make this mandatory."

## Related

- `provisional-constants` — the same principle for literals in source code
- `statistical-reporting` §6, `visualization` "Dynamic Values" — earlier one-line statements of this rule
- `checks-must-distinguish-unknown` — the gate must be able to fail
- `cross-cutting-rename` — the same single-source discipline for labels
