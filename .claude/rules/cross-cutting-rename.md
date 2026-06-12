---
description: User-facing label renames go through a single source of truth + audit grep, never ad-hoc search-and-replace
paths:
  - "**/*.qmd"
  - "R/**"
  - "dashboard/**"
---

# Rule: Cross-Cutting Rename Discipline (Mandatory, All Projects)

## When This Applies

Any user-ask that involves renaming a user-facing noun — a scenario label, a
column header, a chart title, a tab name, a metric name, a project codename,
an acronym expansion. Triggered when a single label appears in user-facing
prose in more than one file.

## Source

JohnGavin/premortem session 30, 2026-06-02. User had to ask three times to
replace "Plan A / Plan B / Plan C" labels in a dashboard. The first two
fix attempts only touched the layer the user pointed at, leaving the rename
incomplete in YAML descriptions, sweep-report headings, knowledge-base docs,
test labels and historical issue text. Full failure analysis in
`<project>/knowledge_base/lessons_learnt.md` L-1.

## CRITICAL: Rename via a Single Source of Truth, Not by Search-and-Replace

A user-facing label that appears in two files must be defined in ONE file
and read from a map by every other surface. If the rename is implemented as
"find and replace this string in the file you're editing right now", the
next session will be the third ask.

## The Discipline (5 steps)

### Step 1 — Single source of truth

Define the label in ONE place. For R projects: a named character vector or
list at the top of a helper file (e.g. `R/labels.R`,
`dashboard/R/dashboard_data.R`). For Python: a constants module. For Quarto:
a YAML config or an R helper sourced by the qmd.

```r
# CORRECT — single source of truth
LABELS <- c(
  "Plan_A" = "£60k gifts",
  "Plan_B" = "£120k gifts",
  "Plan_C" = "£120k then £60k after 7y"
)

label_for <- function(key) {
  out <- LABELS[[key]]
  if (is.null(out)) stop("Unknown key: ", key, " — add to LABELS")
  out
}
```

`stop()` on unknown key is intentional. A typo at the call site MUST
surface as an error, not as `NA` in the rendered HTML.

### Step 2 — Every emit point reads from the map

Replace every hand-written instance of the label string with a call to the
helper. This applies to:

| Surface | Pattern |
|---|---|
| Quarto tab headings | `### \`r label_for("Plan_A")\`` |
| Plot titles | `labs(title = label_for("Plan_A"))` |
| fig-cap / fig-alt | `#\| fig-cap: !expr paste0(label_for("Plan_A"), " — ...")` |
| Inline R sprintf | `sprintf("... %s ...", label_for("Plan_A"))` |
| Callout text (Quarto) | Build via `cat(sprintf(...))` with `results: asis` |
| Markdown report headings | Build via R / templating, never hand-write |
| YAML description strings | Source the helper from R; YAML can't read R, so write the descriptive label into YAML and reference its source-of-truth status in a comment |

### Step 3 — Exhaustive audit grep BEFORE claiming completion

After every rename, run a project-wide grep for every old form of the
label. Do NOT trust your edit count — the grep is the verification.

```bash
# Generic template — adapt the patterns per project
grep -rnE "<old-label-1>|<old-label-2>|<old-label-3>" \
  <project>/ \
  --include="*.qmd" --include="*.R" --include="*.py" \
  --include="*.yaml" --include="*.md" \
  --include="*.css" --include="*.scss" --include="*.html"
```

The grep must return zero hits OR only documented exceptions (other
domains using the same letter, lessons-learnt self-references, historical
issue text). If any user-facing surface still has the old label, the
rename is incomplete.

### Step 4 — Render, then re-grep the rendered output

For any project that produces HTML, PDF or other rendered output, the grep
must also be run against the rendered artefacts. A label can leak in via
a static asset, an embedded image caption, a frozen vignette or a
snapshot test fixture.

```bash
quarto render <document>.qmd
grep -E "<old-label-1>|<old-label-2>|<old-label-3>" \
  <output-dir>/*.html <output-dir>/*.pdf
```

### Step 5 — Lessons-learnt entry on the second ask

If the user has to ask for the same rename a SECOND time, the project MUST
add an entry to its `knowledge_base/lessons_learnt.md` (or equivalent)
naming:
- which surfaces leaked the old label
- why the first fix missed them
- the discipline added to prevent the third ask

If a third ask happens, the lessons-learnt was incomplete or unread.

## Disambiguation (when the same letter is reused)

When the same letter ("A", "B") is used in TWO different domains (e.g. one
project has "Plan A" = a gifting strategy AND "Scenario A" = a pension-IHT
regime), the rename MUST be scoped to ONE domain. Document the
disambiguation in the lessons-learnt doc and in the audit greps so the
unrelated domain is not accidentally swept up.

## Forbidden Patterns

| Pattern | Why wrong | Fix |
|---|---|---|
| Hand-writing the label in `planning.qmd` tab headings | Will drift from the map | `### \`r label_for("Plan_A")\`` |
| Hardcoding the label in a fig-cap string | Same drift | `!expr paste0(label_for(...), " — ...")` |
| `sprintf("... Plan A ...", x)` | Hardcoded | `sprintf("... %s ...", label_for("Plan_A"), x)` |
| Closing an issue after touching only `planning.qmd` | Other surfaces still leak | Run audit grep, fix everywhere, re-render, re-grep |
| Trusting the diff count instead of a fresh grep | Edits may have missed an instance | The grep is the only acceptance test |
| Excluding `tests/` from the audit | Test display labels are user-facing in CI logs | Include `tests/` |

## Integration With Existing Rules

- `verification-before-completion` — the audit grep + render + re-grep is
  the verification gate for cross-cutting renames
- `dynamic-prose-values` — same principle applied to dynamic numeric values;
  this rule applies it to label strings
- `narrative-colour-persistence` — same principle applied to colour mappings
  (which are themselves labelled by the canonical key)

## Related

- `verification-before-completion`
- `dynamic-prose-values`
- `narrative-colour-persistence`
- `pivot-signal` — if the second rename attempt fails the same way as the
  first, stop and escalate
- premortem issue 0021 — reference implementation of this rule
