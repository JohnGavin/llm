---
name: dynamic-prose-values
description: One home per value — every number/date/time/count/version in prose, captions, dashboards and generated artifacts is derived from its single source, never hand-typed; enforced by a build gate, not by care
globs: ["**/*.qmd", "**/*.Rmd", "**/R/*.R"]
paths:
  - "**/*.qmd"
  - "vignettes/**"
  - "README*"
  - "**/*.yml"
  - "**/*.yaml"
  - "**/template/**"
  - "**/dashboard/**"
  - "**/render*.R"
---

# Rule: One Home Per Value — Dynamic Prose Values (Mandatory, No Exceptions)

## When This Applies
Any prose, caption, label, table cell, or generated page (vignette, README, email template, Quarto or Shiny dashboard, Claude Artifact, a YAML-driven site) that contains a specific value — a number, date, time, count, percentage, version, name, or any derived quantity. Also to values **about the artifact itself**: its version, its page count, its fact count.

## CRITICAL: Every Value Has Exactly One Home; Everything Else Is Derived

A value lives in ONE place — a data record, a parameter file, or a computed target. Every other mention is an inline expression, placeholder or generated output that resolves from that home. A hand-typed second copy is a defect **even while it is still correct**: it drifts silently, and the reader becomes the integrity check.

Specific values in prose MUST be embedded expressions evaluated by the pipeline or at render time.

### In Quarto vignettes (.qmd)
Use inline R: `` `r variable_name` `` or `` `r round(max_hmax, 1)` ``

### In targets-built captions (R code)
```r
caption = paste0("Max Wave: ", round(max_hmax, 1), " m at ", max_station, " on ", format(max_date, "%Y-%m-%d"))
```

### In email templates (R functions)
```r
paste0(n_stations, " stations affected | Max Beaufort ", max_beaufort)
```

### In a generated page driven by a YAML/JSON data file
The data file holds each value once; the text uses a placeholder the generator resolves (`{{ref:flight.out.dep}}`, `{{d:2}}`, `{{nights:City}}`, `{{p:name}}`). A value with no natural record goes in a `params:` block — never typed twice.

## Enforce It in the Generator, Not in Review

A rule that says "be careful" fails at some rate per edit, and the number of edits is large. The generator MUST make a restatement a **build failure**:

| Requirement | Why |
|---|---|
| **The build fails when a home's value appears as a literal elsewhere.** | Otherwise the rule is advice. |
| **No category is exempt as "noise".** | In the originating incident, clock times, dates and counts were excluded from the duplication check as noisy — and that is exactly where the drift happened next. |
| **The only escape hatch is an allow-list where every entry states a reason**; an entry that matches nothing is reported as stale. | Exceptions stay visible and expire. |
| **Legacy artifacts use a ratchet**: report the debt as one line; a per-artifact `strict` flag turns it into an error. | Older work is not broken, but the debt is never silent. Flag it on sight. |
| **Values about the artifact itself are derived too** (version, page/fact counts). | A hand-typed "Version 2026-08-29" and "Facts 16" outlived two releases. |

### Prove it — and test the generator, not only the validator

1. **Propagation test:** change ONE home value in a scratch copy, render, and count the places that moved. All of them, and none of the old value, must remain.
2. **Falsify the gate:** neuter its matching in a scratch copy and confirm its tests go red; plant a typed literal and confirm the build refuses **and writes nothing**.
3. **Exercise the renderer, not just the checker.** A validator unit-test suite passed while the placeholder resolvers were broken (`sub()` stripped only the first delimiter); only rendering a real page found it.

## Violations

| Pattern | Problem | Fix |
|---------|---------|-----|
| `"29.9 m"` in prose | Hardcoded value | `paste0(round(max_hmax, 1), " m")` |
| `"2026-03-01"` in prose | Hardcoded date | `format(max_date, "%Y-%m-%d")` |
| `"5 stations"` in prose | Hardcoded count | `paste0(n_stations, " stations")` |
| `"M6"` in prose (when referring to max station) | Hardcoded station | `max_station` variable |
| A departure time typed in the booking **and** the day plan | Two copies | One record; the plan uses `{{ref:...}}` |
| `Version: 2026-08-29` / `Facts: 16` typed on a Build page | Values about the artifact | Derive from the version field and the list lengths |
| A duplication check that skips times/dates/counts "as noise" | The exemption is the drift | Remove the exemption; use a reasoned allow-list |
| A check that only warns, forever | Debt nobody reads | Ratchet to `strict` per artifact |
| Same clock time typed twice with no home | An unnamed parameter | Promote to `params:` |

## Exception
Static reference text is allowed when it describes a fixed property that has no other home:
- "Beaufort 9 = 41 knots" (definition, never changes)
- "M6 is 320km offshore" (geographic fact)
- "Data source: Marine Institute ERDDAP" (attribution)

A value that merely *happens* to coincide with another (two unrelated events closing at the same hour) is excused via the allow-list with that reason, not by exempting the category.

## Origin
User instruction, 2026-09-25: a trip dashboard's Build page showed a hand-typed "Version 2026-08-29" and "Facts 16" after the data had changed twice; the fix was made structural and global rather than a one-off edit. Measured on that project: 89 restated values across ~40 strings, all clock times, dates, night counts and a traveller count that an earlier check had deliberately excluded.

## Related
- `provisional-constants` — hand-typed literals that admit they are provisional; the same defect seen from the code side
- `data-glossary-and-entity-resolution` — one canonical name per entity
- `cross-cutting-rename` — what to do when a home's value must change everywhere
- `checks-must-distinguish-unknown` / `verification-before-completion` — falsify the gate; a check that has never failed is not a check
