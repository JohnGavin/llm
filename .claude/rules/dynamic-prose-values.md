---
name: dynamic-prose-values
description: One home per value — every number/date/time/count/version in prose, captions, dashboards and generated artifacts is derived from its single source, never hand-typed; enforced by a build/publish gate, not by care
metadata:
  type: rule
paths:
  - "**/*.qmd"
  - "**/*.Rmd"
  - "vignettes/**"
  - "README*"
  - "**/*.html"
  - "**/artifact/**"
  - "**/*.yml"
  - "**/*.yaml"
  - "**/template/**"
  - "**/dashboard/**"
  - "**/render*.R"
  - "**/R/*.R"
---

# Rule: One Home Per Value — Dynamic Prose Values (Mandatory, No Exceptions)

## When This Applies
Any text a reader sees that contains a specific value — a number, date, time, count, percentage, list, version or name. That covers vignettes, README, generated HTML pages, Quarto or Shiny dashboards, Claude Artifacts, YAML-driven sites, chart captions and subtitles, `alt`/`title`/`aria-label` tooltips, strings in a page's own JavaScript, and email templates. It also covers values **about the artifact itself**: its version, its page count, its fact count.

## CRITICAL: Every Value Has Exactly One Home; Everything Else Is Derived

A value lives in ONE place — a data record, a parameter file, or a computed target. Every other mention is an inline expression, placeholder or generated output that resolves from that home. A hand-typed second copy is a defect **even while it is still correct**: it drifts silently, and the reader becomes the integrity check.

This includes **copies of reference tables** (a thresholds table copied from a params function, a chart list copied from a catalogue). Generate the table from its source; never maintain a second copy by hand.

## How, by output type

| Output | Pattern |
|---|---|
| Quarto / Rmd | inline R: `` `r n_sessions` `` or `` `r round(max_hmax, 1)` `` |
| Captions/subtitles built in R | `sprintf("%d of %d sessions", n_x, n_sessions)` |
| Email templates | values from the summary object passed in: `paste0(n_stations, " stations affected")` |
| Generated HTML / Claude Artifact | `<span data-fact="n_sessions"></span>` placeholders, filled at build from a facts file the build computes (e.g. `facts.json`); the fill step **errors** on a key the build did not compute |
| Page driven by a YAML/JSON data file | each value held once; text uses a placeholder the generator resolves (`{{ref:flight.out.dep}}`, `{{nights:City}}`); a value with no natural record goes in a `params:` block |
| Reference table in a page | generated from its source (`params()`, catalogue, audit CSV) and injected by id |
| Page JavaScript strings, tooltips | computed from the page's own embedded data, not a literal |

## Enforce It in the Generator, Not in Review

A rule that says "be careful" fails at some rate per edit, and the number of edits is large. This rule once existed, correctly worded, while a dashboard carried 77 hand-typed numbers — it loaded only for `.qmd` and nothing checked. The build/publish step MUST make a restatement a **failure**:

| Requirement | Why |
|---|---|
| **The build fails when a home's value appears as a literal elsewhere, or page text holds a count-like number that is not computed.** | Otherwise the rule is advice. |
| **Scan everything a reader sees**: visible text, `alt`/`title`/`aria-label` (including attributes built inside JavaScript), and JavaScript string literals. Flag at least `N of M`, `n = N`, `N <unit>`, `N%`, `~N` / `about N`. | A gate that scans only visible text misses tooltips, where stale counts hide. |
| **No category is exempt as "noise".** | In one incident, clock times, dates and counts were excluded from the duplication check as noisy — exactly where the drift happened next. |
| **The only escape hatch is a reasoned allow-list**: a config entry stating its reason, or in a page an element marked `data-fixed="<reason>"`. An allow-list entry that matches nothing is reported as stale. | Exceptions stay visible and expire. |
| **Legacy artifacts use a ratchet**: report the debt as one line; a per-artifact `strict` flag turns it into an error. | Older work is not broken, but the debt is never silent. Flag it on sight. |
| **Values about the artifact itself are derived too** (version, page/fact counts). | A hand-typed "Version 2026-08-29" and "Facts 16" outlived two releases. |

**Enforcement is per-project today.** This repo ships no shared checker yet — tracked in [#1272](https://github.com/JohnGavin/llm/issues/1272) (a `check_dark_contrast.sh`-style script over rendered HTML). Until it lands, each publishing project wires its own gate; a project that publishes text without one has an open defect, not an exemption. A working gate plus a `data-fact` fill function exists in a private dashboard project (run as the last two steps of its splice/publish script); read it for the idea, as #1272 describes.

### Prove it — and test the generator, not only the validator

1. **Propagation test:** change ONE home value in a scratch copy, render, and count the places that moved. All of them must move, and no copy of the old value may remain.
2. **Falsify the gate:** run it on the pre-fix page (it must report the known hits); plant a typed literal and confirm the build refuses **and writes nothing**; neuter its matching in a scratch copy and confirm its tests go red.
3. **Exercise the renderer, not just the checker.** A validator unit-test suite passed while the placeholder resolvers were broken (`sub()` stripped only the first delimiter); only rendering a real page found it.

## Allowed literals (`data-fixed` / allow-list)

A literal is allowed only when it must **not** change with the data, and each carries its reason:

| Allowed | Example | Reason value |
|---|---|---|
| Evidence from a dated check | "wrong on 14 of 16 video-checked strokes (17 Aug session)" | `dated video check` |
| An external reference | "NTRP roughly 4.5–5.5" | `external reference` |
| A definition or fixed property | "Beaufort 9 = 41 knots", "M6 is 320km offshore" | `definition` |
| A design constant of the page | "vs the previous 2 sessions" tab | `design` |
| Attribution | "Data source: Marine Institute ERDDAP" | `attribution` |
| Two unrelated values that happen to coincide | two events closing at the same hour | `coincidence: <what>` |

Evidence must say when or on what it was checked, so a reader knows it is a snapshot. If code would re-derive it, it is not fixed: compute it.

## Violations and origin

The worked table of violations (hardcoded captions, copied reference tables, JS tooltip counts, values about the artifact, "noise"-exempt checks, warn-forever checks, fixing only the named numbers) and the two 2026-09-25 origin incidents are in [`_companions/dynamic-prose-values-details.md`](_companions/dynamic-prose-values-details.md). The normative rule above is complete without it.

## Related
- `provisional-constants` — hand-typed literals that admit they are provisional; the same defect seen from the code side
- `statistical-reporting` §6, `visualization` "Dynamic Values" — earlier one-line statements of this rule
- `data-glossary-and-entity-resolution` — one canonical name per entity
- `cross-cutting-rename` — when a home's value must change everywhere
- `checks-must-distinguish-unknown` / `verification-before-completion` — falsify the gate; a check that has never failed is not a check
